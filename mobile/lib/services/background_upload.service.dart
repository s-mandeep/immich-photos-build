import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/asset_metadata.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/upload_retry.tracker.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:immich_mobile/utils/fork_native.dart';
import 'package:immich_mobile/utils/upload_batch_budget.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart' as api;
import 'package:path/path.dart' as p;

part 'background_upload.service.freezed.dart';

/// Fork: livePhotoVideoId marker for a Live Photo still queued without its motion part.
const String kStillWithoutMotion = 'fork:motion-pending';

final backgroundUploadServiceProvider = Provider((ref) {
  final db = ref.watch(driftProvider);
  final service = BackgroundUploadService(
    ref.watch(uploadRepositoryProvider),
    ref.watch(storageRepositoryProvider),
    db.localAssetRepository,
    db.backupRepository,
    ref.watch(assetMediaRepositoryProvider),
    ref.watch(assetServiceProvider),
  );

  ref.onDispose(service.dispose);
  return service;
});

/// Metadata for upload tasks to track live photo handling
@Freezed(fromJson: false, toJson: false)
abstract class UploadTaskMetadata with _$UploadTaskMetadata {
  const UploadTaskMetadata._();

  const factory UploadTaskMetadata({
    required String localAssetId,
    required bool isLivePhotos,
    required String livePhotoVideoId,
    String? checksum,
  }) = _UploadTaskMetadata;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'localAssetId': localAssetId,
      'isLivePhotos': isLivePhotos,
      'livePhotoVideoId': livePhotoVideoId,
      'checksum': checksum,
    };
  }

  factory UploadTaskMetadata.fromMap(Map<String, dynamic> map) {
    return UploadTaskMetadata(
      localAssetId: map['localAssetId'] as String,
      isLivePhotos: map['isLivePhotos'] as bool,
      livePhotoVideoId: map['livePhotoVideoId'] as String,
      checksum: map['checksum'] as String?,
    );
  }

  factory UploadTaskMetadata.fromJson(String source) =>
      UploadTaskMetadata.fromMap(json.decode(source) as Map<String, dynamic>);

  String toJson() => json.encode(toMap());
}

/// Service for handling background uploads using iOS URLSession (background_downloader)
///
/// This service handles asynchronous background uploads that can continue
/// even when the app is suspended. Primarily used for iOS background backup.
class BackgroundUploadService {
  BackgroundUploadService(
    this._uploadRepository,
    this._storageRepository,
    this._localAssetRepository,
    this._backupRepository,
    this._assetMediaRepository,
    this._assetService,
  ) {
    _uploadRepository.onUploadStatus = _onUploadCallback;
    _uploadRepository.onTaskProgress = _onTaskProgressCallback;
  }

  final UploadRepository _uploadRepository;
  final StorageRepository _storageRepository;
  final LocalAssetRepository _localAssetRepository;
  final BackupRepository _backupRepository;
  final AssetMediaRepository _assetMediaRepository;
  final AssetService _assetService;
  final Logger _logger = Logger('BackgroundUploadService');

  final StreamController<TaskStatusUpdate> _taskStatusController = StreamController<TaskStatusUpdate>.broadcast();
  final StreamController<TaskProgressUpdate> _taskProgressController = StreamController<TaskProgressUpdate>.broadcast();

  // ignore: unused-code
  Stream<TaskStatusUpdate> get taskStatusStream => _taskStatusController.stream;
  // ignore: unused-code
  Stream<TaskProgressUpdate> get taskProgressStream => _taskProgressController.stream;

  bool shouldAbortQueuingTasks = false;

  /// Fork: chaining. While set (app in the background), finished uploads top the URLSession queue up
  /// with the next batch so the library drains without the app being opened.
  String? _chainUserId;
  Timer? _chainTimer;
  bool _chainRunning = false;

  /// Top up once fewer tasks than this are left in the session.
  static const int chainRefillBelow = 100;

  void startChaining(String userId) => _chainUserId = userId;

  void stopChaining() {
    _chainUserId = null;
    _chainTimer?.cancel();
    _chainTimer = null;
  }

  void _scheduleChainedBatch() {
    if (_chainUserId == null || _chainRunning) {
      return;
    }
    // Debounce: iOS reports finished tasks in bursts when it wakes the app.
    _chainTimer?.cancel();
    _chainTimer = Timer(const Duration(seconds: 3), () => unawaited(_runChainedBatch()));
  }

  Future<void> _runChainedBatch() async {
    final userId = _chainUserId;
    if (userId == null || _chainRunning) {
      return;
    }
    _chainRunning = true;
    try {
      await ForkNative.withBackgroundTime(() async {
        final queued = await queuedCount();
        if (queued >= chainRefillBelow) {
          return;
        }
        final added = await uploadBackupCandidates(userId);
        _logger.info("Chained batch: $queued still queued, $added added");
      });
    } catch (error, stack) {
      _logger.warning("Chained batch failed", error, stack);
    } finally {
      _chainRunning = false;
    }
  }

  void _onTaskProgressCallback(TaskProgressUpdate update) {
    if (!_taskProgressController.isClosed) {
      _taskProgressController.add(update);
    }
  }

  void _onUploadCallback(TaskStatusUpdate update) {
    if (!_taskStatusController.isClosed) {
      _taskStatusController.add(update);
    }
    unawaited(_handleTaskStatusUpdate(update));
  }

  void dispose() {
    stopChaining();
    unawaited(_taskStatusController.close());
    unawaited(_taskProgressController.close());
  }

  /// Enqueue tasks to the background upload queue
  Future<List<bool>> enqueueTasks(List<UploadTask> tasks) {
    return _uploadRepository.enqueueBackgroundAll(tasks);
  }

  /// Get a list of tasks that are ENQUEUED or RUNNING
  Future<List<Task>> getActiveTasks(String group) {
    return _uploadRepository.getActiveTasks(group);
  }

  /// Start background upload using iOS URLSession
  ///
  /// Fork: hands iOS's background URLSession a large batch instead of ~6 held in the app. The batch is
  /// bounded by [UploadBatchBudget] (300 files, 2 GB, 25% of free storage, counting what is already
  /// queued), skips assets already queued or just uploaded, and is enqueued in chunks so a cut-off run
  /// still hands its work to iOS. Returns the number of tasks enqueued.
  Future<int> uploadBackupCandidates(String userId, {Set<String> skipIds = const {}}) async {
    shouldAbortQueuingTasks = false;

    final queued = await _queuedState();
    // Temp files belong to the queued tasks; only clear them when nothing is queued.
    if (queued.ids.isEmpty) {
      await _storageRepository.clearCache();
    }

    final skip = {...queued.ids, ...await _recentlyCompletedIds(), ...skipIds};
    final retry = UploadRetryTracker.instance..reload();
    final candidates = retry.due(
      (await _backupRepository.getCandidates(userId)).where((a) => !skip.contains(a.id)).toList(),
      (asset) => asset.id,
    );
    if (candidates.isEmpty) {
      _logger.info("No new backup candidates found, finishing background upload");
      return 0;
    }

    final budget = UploadBatchBudget(
      freeBytes: await ForkNative.freeBytes(),
      queuedFiles: queued.ids.length,
      queuedBytes: queued.bytes,
    );
    _logger.info(
      "Found ${candidates.length} backup candidates, ${queued.ids.length} already queued, free: ${budget.freeBytes}",
    );

    const chunkSize = 20;
    var enqueued = 0;
    final List<UploadTask> chunk = [];
    for (final asset in candidates) {
      if (shouldAbortQueuingTasks || budget.isFull) {
        break;
      }
      final task = await getUploadTask(asset);
      if (task == null) {
        continue;
      }
      final size = await _fileSize(task);
      if (!budget.tryAdd(size)) {
        await _deleteTaskFile(task);
        break;
      }
      chunk.add(task);
      if (chunk.length >= chunkSize) {
        enqueued += await _enqueueChunk(chunk);
      }
    }
    enqueued += await _enqueueChunk(chunk);
    _logger.info("Enqueued $enqueued background upload tasks (${budget.files} files, ${budget.bytes} bytes queued)");
    return enqueued;
  }

  Future<int> _enqueueChunk(List<UploadTask> chunk) async {
    if (chunk.isEmpty) {
      return 0;
    }
    final tasks = List<UploadTask>.of(chunk);
    chunk.clear();
    if (shouldAbortQueuingTasks) {
      await Future.wait(tasks.map(_deleteTaskFile));
      return 0;
    }
    final results = await enqueueTasks(tasks);
    return results.where((ok) => ok).length;
  }

  /// Ids and file bytes of the backup tasks iOS still holds
  Future<({Set<String> ids, int bytes})> _queuedState() async {
    final tasks = [
      ...await _uploadRepository.getActiveTasks(kBackupGroup),
      ...await _uploadRepository.getActiveTasks(kBackupLivePhotoGroup),
    ];
    var bytes = 0;
    for (final task in tasks) {
      if (task is UploadTask) {
        bytes += await _fileSize(task);
      }
    }
    return (ids: tasks.map((t) => t.taskId).toSet(), bytes: bytes);
  }

  /// Assets the session uploaded in the last 12 h; the remote sync may not have seen them yet.
  Future<Set<String>> _recentlyCompletedIds() async {
    try {
      final records = await _uploadRepository.getTaskRecords(kBackupGroup);
      final cutoff = DateTime.now().subtract(const Duration(hours: 12));
      return records
          .where((r) => r.status == TaskStatus.complete && r.task.creationTime.isAfter(cutoff))
          .map((r) => r.taskId)
          .toSet();
    } catch (error) {
      _logger.warning("Could not read upload records: $error");
      return {};
    }
  }

  /// Number of backup tasks (both groups) iOS still holds
  Future<int> queuedCount() async {
    final queued = await _queuedState();
    return queued.ids.length;
  }

  Future<int> _fileSize(UploadTask task) async {
    try {
      return await File(await task.filePath()).length();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _deleteTaskFile(UploadTask task) async {
    if (!CurrentPlatform.isIOS) {
      return;
    }
    try {
      await File(await task.filePath()).delete();
    } catch (_) {}
  }

  /// Cancel all ongoing background uploads and reset the upload queue
  ///
  /// Returns the number of tasks left in the queue
  Future<int> cancel() async {
    shouldAbortQueuingTasks = true;
    _chainUserId = null;

    await _storageRepository.clearCache();
    await _uploadRepository.reset(kBackupGroup);
    await _uploadRepository.deleteDatabaseRecords(kBackupGroup);

    final activeTasks = await _uploadRepository.getActiveTasks(kBackupGroup);
    return activeTasks.length;
  }

  /// Resume background backup processing
  Future<void> resume() {
    return _uploadRepository.start();
  }

  Future<void> _handleTaskStatusUpdate(TaskStatusUpdate update) async {
    if (update.status.isFinalState && update.task.group == kBackupGroup) {
      _scheduleChainedBatch();
    }
    await _recordRetryOutcome(update);
    switch (update.status) {
      case TaskStatus.complete:
        unawaited(_handleLivePhoto(update));
        unawaited(_stackEditedAsset(update));

        if (CurrentPlatform.isIOS) {
          try {
            final path = await update.task.filePath();
            await File(path).delete();
          } catch (e) {
            _logger.severe('Error deleting file path for iOS: $e');
          }
        }

      default:
        break;
    }
  }

  /// Fork: feeds URLSession outcomes into the retry book, so failed assets back off and a still that
  /// went up without its motion part gets the motion part retried later.
  Future<void> _recordRetryOutcome(TaskStatusUpdate update) async {
    if (!update.status.isFinalState || update.task.metaData.isEmpty) {
      return;
    }
    try {
      final metadata = UploadTaskMetadata.fromJson(update.task.metaData);
      final retry = UploadRetryTracker.instance;
      final assetId = metadata.localAssetId;
      switch (update.status) {
        case TaskStatus.complete:
          if (metadata.isLivePhotos) {
            return; // the still follows; its outcome decides
          }
          String? remoteId;
          try {
            remoteId = jsonDecode(update.responseBody ?? '')['id'] as String?;
          } catch (_) {}
          if (metadata.livePhotoVideoId == kStillWithoutMotion) {
            await retry.motionPending(assetId, 'motion part not fetchable', stillRemoteId: remoteId);
          } else if (!retry.isMotionPending(assetId)) {
            await retry.succeeded(assetId);
          }
        case TaskStatus.failed || TaskStatus.notFound:
          await retry.failed(
            assetId,
            'background upload ${update.status.name}: ${update.exception?.description ?? update.responseStatusCode ?? ''}',
          );
        default:
          break;
      }
    } catch (error) {
      dPrint(() => "Error recording upload outcome: $error");
    }
  }

  Future<void> _handleLivePhoto(TaskStatusUpdate update) async {
    try {
      if (update.task.metaData.isEmpty || update.task.metaData == '') {
        return;
      }

      final metadata = UploadTaskMetadata.fromJson(update.task.metaData);
      if (!metadata.isLivePhotos) {
        return;
      }

      if (update.responseBody == null || update.responseBody!.isEmpty) {
        return;
      }
      final response = jsonDecode(update.responseBody!);

      final localAsset = await _localAssetRepository.getById(metadata.localAssetId);
      if (localAsset == null) {
        return;
      }

      final uploadTask = await getLivePhotoUploadTask(localAsset, response['id'] as String);

      if (uploadTask == null) {
        return;
      }

      await enqueueTasks([uploadTask]);
    } catch (error, stackTrace) {
      dPrint(() => "Error handling live photo upload task: $error $stackTrace");
    }
  }

  Future<void> _stackEditedAsset(TaskStatusUpdate update) async {
    try {
      if (update.task.metaData.isEmpty || update.responseBody == null || update.responseBody!.isEmpty) {
        return;
      }

      final metadata = UploadTaskMetadata.fromJson(update.task.metaData);
      // The video half of a live photo carries isLivePhotos; the still that follows is the final asset
      if (metadata.isLivePhotos) {
        return;
      }

      await _assetService.stackEditedUpload(
        metadata.localAssetId,
        jsonDecode(update.responseBody!)['id'] as String,
        metadata.checksum,
      );
    } catch (error, stackTrace) {
      dPrint(() => "Error stacking edited asset upload: $error $stackTrace");
    }
  }

  @visibleForTesting
  Future<UploadTask?> getUploadTask(LocalAsset asset, {String group = kBackupGroup, int? priority}) async {
    final entity = await _storageRepository.getAssetEntityForAsset(asset);
    if (entity == null) {
      _logger.warning("Asset entity not found for ${asset.id} - ${asset.name}");
      return null;
    }

    // Fork (11 Nov): never download originals from iCloud (photo_manager's file export allows the network).
    if (CurrentPlatform.isIOS && !await _storageRepository.isAssetAvailableLocally(asset.id)) {
      _logger.info("Skipping iCloud-only asset ${asset.id} - ${asset.name} (no iCloud downloads)");
      if (group == kBackupGroup) {
        await UploadRetryTracker.instance.failed(asset.id, 'iCloud-only original (not downloaded)');
      }
      return null;
    }

    File? file;
    final retry = UploadRetryTracker.instance;
    // Fork: a Live Photo whose motion part cannot be fetched (or is waiting for its retry time) goes up as
    // a still alone; the motion part is recorded as pending when the still completes.
    var isLivePhoto = entity.isLivePhoto;
    var stillWithoutMotion = false;

    /// iOS LivePhoto has two files: a photo and a video.
    /// They are uploaded separately, with video file being upload first, then returned with the assetId
    /// The assetId is then used as a metadata for the photo file upload task.
    ///
    /// We implement two separate upload groups for this, the normal one for the video file
    /// and the higher priority group for the photo file because the video file is already uploaded.
    ///
    /// The cancel operation will only cancel the video group (normal group), the photo group will not
    /// be touched, as the video file is already uploaded.

    if (isLivePhoto && group == kBackupGroup) {
      file = retry.shouldFetchMotion(asset.id) ? await _storageRepository.getMotionFileForAsset(asset) : null;
      if (file == null) {
        _logger.warning("Motion part of ${asset.id} - ${asset.name} not fetchable; queuing the still alone");
        isLivePhoto = false;
        stillWithoutMotion = true;
        file = await _storageRepository.getFileForAsset(asset.id);
      }
    } else if (isLivePhoto) {
      file = await _storageRepository.getMotionFileForAsset(asset);
    } else {
      file = await _storageRepository.getFileForAsset(asset.id);
    }

    if (file == null) {
      _logger.warning("Failed to get file for asset ${asset.id} - ${asset.name}");
      if (group == kBackupGroup) {
        await retry.failed(asset.id, 'original not fetchable');
      }
      return null;
    }

    final fileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;
    // Some apps (e.g. DJI/Fusion) return names without an extension; fall back to the asset name for those.
    final extension = p.extension(file.path).isNotEmpty ? p.extension(file.path) : p.extension(asset.name);
    final originalFileName = p.setExtension(fileName, extension);

    final String metadata = UploadTaskMetadata(
      localAssetId: asset.id,
      isLivePhotos: isLivePhoto,
      livePhotoVideoId: stillWithoutMotion ? kStillWithoutMotion : '',
      checksum: asset.checksum,
    ).toJson();

    final requiresWiFi = _shouldRequireWiFi(asset);

    return buildUploadTask(
      file,
      createdAt: asset.createdAt,
      modifiedAt: asset.updatedAt,
      originalFileName: originalFileName,
      deviceAssetId: asset.id,
      metadata: metadata,
      group: group,
      priority: priority,
      isFavorite: asset.isFavorite,
      requiresWiFi: requiresWiFi,
      // Visibility hidden on upload to prevent the server from running regular jobs on the live photo asset
      fields: isLivePhoto ? {'visibility': api.AssetVisibility.hidden.toString()} : null,
      cloudId: isLivePhoto ? null : asset.cloudId,
      adjustmentTime: isLivePhoto ? null : asset.adjustmentTime?.toIso8601String(),
      latitude: isLivePhoto ? null : asset.latitude?.toString(),
      longitude: isLivePhoto ? null : asset.longitude?.toString(),
    );
  }

  @visibleForTesting
  Future<UploadTask?> getLivePhotoUploadTask(LocalAsset asset, String livePhotoVideoId) async {
    final entity = await _storageRepository.getAssetEntityForAsset(asset);
    if (entity == null) {
      return null;
    }

    final file = await _storageRepository.getFileForAsset(asset.id);
    if (file == null) {
      return null;
    }

    final fields = {'livePhotoVideoId': livePhotoVideoId};

    final requiresWiFi = _shouldRequireWiFi(asset);
    final originalFileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;

    return buildUploadTask(
      file,
      createdAt: asset.createdAt,
      modifiedAt: asset.updatedAt,
      originalFileName: originalFileName,
      deviceAssetId: asset.id,
      metadata: UploadTaskMetadata(
        localAssetId: asset.id,
        isLivePhotos: false,
        livePhotoVideoId: livePhotoVideoId,
        checksum: asset.checksum,
      ).toJson(),
      fields: fields,
      group: kBackupLivePhotoGroup,
      priority: 0, // Highest priority to get upload immediately
      isFavorite: asset.isFavorite,
      requiresWiFi: requiresWiFi,
      cloudId: asset.cloudId,
      adjustmentTime: asset.adjustmentTime?.toIso8601String(),
      latitude: asset.latitude?.toString(),
      longitude: asset.longitude?.toString(),
    );
  }

  bool _shouldRequireWiFi(LocalAsset asset) {
    final backup = SettingsRepository.instance.appConfig.backup;
    if (asset.isVideo && backup.useCellularForVideos) {
      return false;
    }
    if (!asset.isVideo && backup.useCellularForPhotos) {
      return false;
    }
    return true;
  }

  Future<UploadTask> buildUploadTask(
    File file, {
    required String group,
    required DateTime createdAt,
    required DateTime modifiedAt,
    Map<String, String>? fields,
    String? originalFileName,
    String? deviceAssetId,
    String? metadata,
    int? priority,
    bool? isFavorite,
    bool requiresWiFi = true,
    String? cloudId,
    String? adjustmentTime,
    String? latitude,
    String? longitude,
  }) async {
    final serverEndpoint = Store.get(StoreKey.serverEndpoint);
    final url = Uri.parse('$serverEndpoint/assets').toString();
    final headers = ApiService.getRequestHeaders();
    final deviceId = Store.get(StoreKey.deviceId);
    final (baseDirectory, directory, filename) = await Task.split(filePath: file.path);
    final fieldsMap = {
      'filename': originalFileName ?? filename,
      // deviceAssetId/deviceId required by server v2.7.5 and below (drop in v4.0 per #27818).
      'deviceAssetId': deviceAssetId ?? '',
      'deviceId': deviceId,
      'fileCreatedAt': createdAt.toUtc().toIso8601String(),
      'fileModifiedAt': modifiedAt.toUtc().toIso8601String(),
      'isFavorite': isFavorite?.toString() ?? 'false',
      'duration': '0',
      ...?fields,
      if (CurrentPlatform.isIOS && cloudId != null)
        'metadata': jsonEncode([
          RemoteAssetMetadataItem(
            key: RemoteAssetMetadataKey.mobileApp,
            value: RemoteAssetMobileAppMetadata(
              cloudId: cloudId,
              createdAt: createdAt.toIso8601String(),
              adjustmentTime: adjustmentTime,
              latitude: latitude,
              longitude: longitude,
            ),
          ),
        ]),
    };

    return UploadTask(
      taskId: deviceAssetId,
      displayName: originalFileName ?? filename,
      httpRequestMethod: 'POST',
      url: url,
      headers: headers,
      filename: filename,
      fields: fieldsMap,
      baseDirectory: baseDirectory,
      directory: directory,
      fileField: 'assetData',
      metaData: metadata ?? '',
      group: group,
      requiresWiFi: requiresWiFi,
      priority: priority ?? 5,
      updates: Updates.statusAndProgress,
      retries: 3,
    );
  }
}
