import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/asset_metadata.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart' hide AssetVisibility;
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/network_capability_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/upload_retry.tracker.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart' show PMProgressHandler;

/// Callbacks for upload progress and status updates
class UploadCallbacks {
  final void Function(String id, String filename, int bytes, int totalBytes)? onProgress;
  final void Function(String localId, String remoteId)? onSuccess;
  final void Function(String id, String errorMessage)? onError;
  final void Function(String id, double progress)? onICloudProgress;

  const UploadCallbacks({this.onProgress, this.onSuccess, this.onError, this.onICloudProgress});
}

final foregroundUploadServiceProvider = Provider((ref) {
  // ignore: dispose-provided-instances
  return ForegroundUploadService(
    ref.watch(uploadRepositoryProvider),
    ref.watch(storageRepositoryProvider),
    ref.watch(driftProvider).backupRepository,
    ref.watch(connectivityApiProvider),
    ref.watch(assetMediaRepositoryProvider),
    ref.watch(assetServiceProvider),
  );
});

/// Service for handling foreground HTTP uploads
///
/// This service handles synchronous uploads using HTTP client with
/// concurrent worker pools. Used for manual backups, auto backups
/// (foreground mode), and share intent uploads.
class ForegroundUploadService {
  ForegroundUploadService(
    this._uploadRepository,
    this._storageRepository,
    this._backupRepository,
    this._connectivityApi,
    this._assetMediaRepository,
    this._assetService,
  );

  final UploadRepository _uploadRepository;
  final StorageRepository _storageRepository;
  final BackupRepository _backupRepository;
  final ConnectivityApi _connectivityApi;
  final AssetMediaRepository _assetMediaRepository;
  final AssetService _assetService;
  final Logger _logger = Logger('ForegroundUploadService');

  bool shouldAbortUpload = false;

  /// Fork: on iOS the temp dir also holds the files of uploads queued with the background URLSession;
  /// clearing it under them would fail those uploads.
  Future<void> _clearCacheUnlessQueued() async {
    if (CurrentPlatform.isIOS) {
      try {
        for (final group in [kBackupGroup, kBackupLivePhotoGroup]) {
          if ((await _uploadRepository.getActiveTasks(group)).isNotEmpty) {
            return;
          }
        }
      } catch (_) {
        return;
      }
    }
    await _storageRepository.clearCache();
  }

  Future<({int total, int remainder, int processing})> getBackupCounts(String userId) {
    return _backupRepository.getAllCounts(userId);
  }

  Future<List<LocalAsset>> getBackupCandidates(String userId, {bool onlyHashed = true}) {
    return _backupRepository.getCandidates(userId, onlyHashed: onlyHashed);
  }

  /// Bulk upload of backup candidates from selected albums
  Future<void> uploadCandidates(
    String userId,
    Completer<void> cancelToken, {
    UploadCallbacks callbacks = const UploadCallbacks(),
    bool useSequentialUpload = false,
  }) async {
    var candidates = await _backupRepository.getCandidates(userId);
    if (candidates.isEmpty) {
      return;
    }

    // Fork: skip assets the background URLSession still has queued from a hand-off.
    if (CurrentPlatform.isIOS) {
      try {
        final queued = {
          for (final group in [kBackupGroup, kBackupLivePhotoGroup])
            ...(await _uploadRepository.getActiveTasks(group)).map((t) => t.taskId),
        };
        candidates = candidates.where((asset) => !queued.contains(asset.id)).toList();
      } catch (error) {
        _logger.warning('Could not read the background upload queue: $error');
      }
    }

    // Fork: assets that failed recently wait for their retry time instead of taking a worker.
    final retry = UploadRetryTracker.instance..reload();
    candidates = retry.due(candidates, (asset) => asset.id);

    final networkCapabilities = await _connectivityApi.getCapabilities();
    final hasWifi = networkCapabilities.isUnmetered;
    _logger.info('Network capabilities: $networkCapabilities, hasWifi/isUnmetered: $hasWifi');

    if (useSequentialUpload) {
      await _uploadSequentially(items: candidates, cancelToken: cancelToken, hasWifi: hasWifi, callbacks: callbacks);
    } else {
      await _executeWithWorkerPool<LocalAsset>(
        items: candidates,
        cancelToken: cancelToken,
        shouldSkip: (asset) {
          final requireWifi = _shouldRequireWiFi(asset);
          return requireWifi && !hasWifi;
        },
        processItem: (asset) => uploadSingleAsset(asset, cancelToken, callbacks: callbacks),
      );
    }
    if (!cancelToken.isCompleted) {
      await retryPendingMotionParts(cancelToken);
    }
  }

  /// Fork: uploads the motion parts of Live Photos whose stills went up alone, once their retry time has
  /// come, and links each to its still on the server. A failure backs off further.
  Future<void> retryPendingMotionParts(Completer<void>? cancelToken) async {
    final retry = UploadRetryTracker.instance;
    for (final assetId in retry.motionRetriesDue()) {
      if (shouldAbortUpload || (cancelToken?.isCompleted ?? false)) {
        return;
      }
      final stillRemoteId = retry.stillRemoteIdFor(assetId);
      File? motionFile;
      try {
        final asset = await _assetService.getLocalAsset(assetId);
        if (asset == null || stillRemoteId == null) {
          await retry.succeeded(assetId); // gone from the phone: nothing left to do
          continue;
        }
        motionFile = await _fetchMotionFile(asset);
        if (motionFile == null) {
          await retry.motionPending(assetId, 'motion part still not fetchable');
          continue;
        }
        final fileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;
        final result = await _uploadRepository.uploadFile(
          file: motionFile,
          originalFileName: p.setExtension(fileName, p.extension(motionFile.path)),
          fields: {
            'deviceAssetId': asset.id,
            'deviceId': Store.get(StoreKey.deviceId),
            'fileCreatedAt': asset.createdAt.toUtc().toIso8601String(),
            'fileModifiedAt': asset.updatedAt.toUtc().toIso8601String(),
            'isFavorite': 'false',
            'duration': '0',
            'visibility': AssetVisibility.hidden.toString(),
          },
          cancelToken: cancelToken,
          logContext: 'livePhotoVideoRetry[$assetId]',
        );
        if (result.isCancelled) {
          return;
        }
        if (result.isSuccess &&
            result.remoteAssetId != null &&
            await _uploadRepository.linkLivePhotoVideo(stillRemoteId, result.remoteAssetId!)) {
          _logger.info('Motion part of Live Photo $assetId uploaded and linked');
          await retry.succeeded(assetId);
        } else {
          await retry.motionPending(assetId, 'motion upload or link failed: ${result.errorMessage ?? 'link'}');
        }
      } catch (error) {
        await retry.motionPending(assetId, 'motion retry error: $error');
      } finally {
        if (Platform.isIOS) {
          try {
            await motionFile?.delete();
          } catch (_) {}
        }
      }
    }
  }

  /// Fork: the Live Photo motion file, or null if it cannot be fetched in time (e.g. PHPhotosErrorDomain
  /// 3169: original not fetchable from iCloud). Bounded so it never holds a worker for minutes.
  Future<File?> _fetchMotionFile(LocalAsset asset) async {
    try {
      final local = await _storageRepository.isAssetAvailableLocally(asset.id);
      if (!local) {
        return null; // Fork (11 Nov): no iCloud downloads
      }
      final future = _storageRepository.getMotionFileForAsset(asset);
      final file = await future.timeout(const Duration(seconds: 90), onTimeout: () => null);
      return file;
    } catch (error) {
      _logger.warning('Motion part of ${asset.id} not fetchable: $error');
      return null;
    }
  }

  /// Sequential upload - used for background isolate where concurrent HTTP clients may cause issues
  Future<void> _uploadSequentially({
    required List<LocalAsset> items,
    required Completer<void> cancelToken,
    required bool hasWifi,
    required UploadCallbacks callbacks,
  }) async {
    await _clearCacheUnlessQueued();
    shouldAbortUpload = false;

    for (final asset in items) {
      if (shouldAbortUpload || cancelToken.isCompleted) {
        break;
      }

      final requireWifi = _shouldRequireWiFi(asset);
      if (requireWifi && !hasWifi) {
        _logger.warning('Skipping upload for ${asset.id} because it requires WiFi');
        continue;
      }

      await uploadSingleAsset(asset, cancelToken, callbacks: callbacks);
    }
  }

  /// Manually upload picked local assets
  Future<void> uploadManual(
    List<LocalAsset> localAssets, {
    Completer<void>? cancelToken,
    UploadCallbacks callbacks = const UploadCallbacks(),
  }) async {
    if (localAssets.isEmpty) {
      return;
    }

    await _executeWithWorkerPool<LocalAsset>(
      items: localAssets,
      cancelToken: cancelToken,
      processItem: (asset) => uploadSingleAsset(asset, cancelToken, callbacks: callbacks),
    );
  }

  /// Upload files from shared intent
  Future<void> uploadShareIntent(
    List<File> files, {
    Completer<void>? cancelToken,
    void Function(String fileId, int bytes, int totalBytes)? onProgress,
    void Function(String fileId, String remoteAssetId)? onSuccess,
    void Function(String fileId, String errorMessage)? onError,
  }) async {
    if (files.isEmpty) {
      return;
    }
    await _executeWithWorkerPool<File>(
      items: files,
      cancelToken: cancelToken,
      processItem: (file) async {
        final fileId = p.hash(file.path).toString();

        final result = await _uploadSingleFile(
          file,
          deviceAssetId: fileId,
          cancelToken: cancelToken,
          onProgress: (bytes, totalBytes) => onProgress?.call(fileId, bytes, totalBytes),
        );

        if (result.isSuccess) {
          onSuccess?.call(fileId, result.remoteAssetId!);
        } else if (!result.isCancelled && result.errorMessage != null) {
          onError?.call(fileId, result.errorMessage!);
        }
      },
    );
  }

  void cancel() {
    shouldAbortUpload = true;
  }

  /// Generic worker pool for concurrent uploads
  ///
  /// [items] - List of items to process
  /// [cancelToken] - Token to cancel the operation
  /// [processItem] - Function to process each item with an HTTP client
  /// [shouldSkip] - Optional function to skip items (e.g., WiFi requirement check)
  /// [concurrentWorkers] - Number of concurrent workers (default: 3)
  Future<void> _executeWithWorkerPool<T>({
    required List<T> items,
    required Completer<void>? cancelToken,
    required Future<void> Function(T item) processItem,
    bool Function(T item)? shouldSkip,
    int concurrentWorkers = 3,
  }) async {
    await _clearCacheUnlessQueued();
    shouldAbortUpload = false;

    int currentIndex = 0;

    Future<void> worker() async {
      while (true) {
        if (shouldAbortUpload || (cancelToken != null && cancelToken.isCompleted)) {
          break;
        }

        final index = currentIndex;
        if (index >= items.length) {
          break;
        }
        currentIndex++;

        final item = items[index];

        if (shouldSkip?.call(item) ?? false) {
          continue;
        }

        await processItem(item);
      }
    }

    final workerFutures = <Future<void>>[];
    for (int i = 0; i < concurrentWorkers; i++) {
      workerFutures.add(worker());
    }

    await Future.wait(workerFutures);
  }

  @visibleForTesting
  Future<void> uploadSingleAsset(
    LocalAsset asset,
    Completer<void>? cancelToken, {
    required UploadCallbacks callbacks,
  }) async {
    final t = StaticTranslations.instance;
    final assetNotFoundOnDevice = CurrentPlatform.isAndroid
        ? t.asset_not_found_on_device_android
        : t.asset_not_found_on_device_ios;
    File? file;
    File? livePhotoFile;
    final retry = UploadRetryTracker.instance;
    var motionMissing = false;

    try {
      final remoteId = (await _assetService.getLocalAsset(asset.id))?.remoteId;
      if (remoteId != null) {
        await _handleUploadSuccess(asset, remoteId, callbacks);
        return;
      }

      final entity = await _storageRepository.getAssetEntityForAsset(asset);
      if (entity == null) {
        callbacks.onError?.call(asset.localId!, assetNotFoundOnDevice);
        await retry.failed(asset.id, 'asset not found on device');
        return;
      }

      final isAvailableLocally = await _storageRepository.isAssetAvailableLocally(asset.id);
      // Fork: a Live Photo whose motion part failed earlier uploads its still alone until the retry time.
      final fetchMotion = entity.isLivePhoto && retry.shouldFetchMotion(asset.id);

      if (!isAvailableLocally && CurrentPlatform.isIOS) {
        // Fork (11 Nov): never download originals from iCloud. Skip and record; listed for a later decision.
        _logger.info("Skipping iCloud-only asset ${asset.id} - ${asset.name} (no iCloud downloads)");
        await retry.failed(asset.id, 'iCloud-only original (not downloaded)');
        return;
      }
      if (!isAvailableLocally && CurrentPlatform.isIOS) {
        _logger.info("Loading iCloud asset ${asset.id} - ${asset.name}");

        // Create progress handler for iCloud download
        PMProgressHandler? progressHandler;
        StreamSubscription? progressSubscription;

        progressHandler = PMProgressHandler();
        progressSubscription = progressHandler.stream.listen((event) {
          callbacks.onICloudProgress?.call(asset.localId!, event.progress);
        });

        try {
          file = await _storageRepository.loadFileFromCloud(asset.id, progressHandler: progressHandler);
          if (fetchMotion && file != null) {
            livePhotoFile = await _fetchMotionFile(asset);
            motionMissing = livePhotoFile == null;
          }
        } finally {
          await progressSubscription.cancel();
        }
      } else {
        // Get files locally
        file = await _storageRepository.getFileForAsset(asset.id);
        if (file == null) {
          _logger.warning("Failed to get file ${asset.id} - ${asset.name}");
          callbacks.onError?.call(asset.localId!, assetNotFoundOnDevice);
          await retry.failed(asset.id, 'original not fetchable');
          return;
        }

        // For live photos, get the motion video file
        if (fetchMotion) {
          livePhotoFile = await _fetchMotionFile(asset);
          if (livePhotoFile == null) {
            // Fork: upload the still alone; the motion part is retried later with backoff.
            _logger.warning("Failed to obtain motion part of the livePhoto - ${asset.name}; uploading the still alone");
            motionMissing = true;
          }
        }
      }

      if (file == null) {
        _logger.warning("Failed to obtain file from iCloud for asset ${asset.id} - ${asset.name}");
        callbacks.onError?.call(asset.localId!, t.asset_not_found_on_icloud);
        await retry.failed(asset.id, 'original not fetchable from iCloud');
        return;
      }

      final fileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;
      // Some apps (e.g. DJI/Fusion) return names without an extension; fall back to the asset name for those.
      final extension = p.extension(file.path).isNotEmpty ? p.extension(file.path) : p.extension(asset.name);
      final originalFileName = p.setExtension(fileName, extension);
      final deviceId = Store.get(StoreKey.deviceId);

      final fields = {
        // deviceAssetId/deviceId required by server v2.7.5 and below (drop in v4.0 per #27818).
        'deviceAssetId': asset.localId!,
        'deviceId': deviceId,
        'fileCreatedAt': asset.createdAt.toUtc().toIso8601String(),
        'fileModifiedAt': asset.updatedAt.toUtc().toIso8601String(),
        'isFavorite': asset.isFavorite.toString(),
        'duration': (asset.durationMs ?? 0).toString(),
      };

      // Upload live photo video first if available
      String? livePhotoVideoId;
      if (entity.isLivePhoto && livePhotoFile != null) {
        final livePhotoTitle = p.setExtension(originalFileName, p.extension(livePhotoFile.path));

        final onProgress = callbacks.onProgress;
        final livePhotoResult = await _uploadRepository.uploadFile(
          file: livePhotoFile,
          originalFileName: livePhotoTitle,
          // Visibility hidden on upload to prevent the server from running regular jobs on the live photo asset
          fields: {...fields, 'visibility': AssetVisibility.hidden.toString()},
          cancelToken: cancelToken,
          onProgress: onProgress != null
              ? (bytes, totalBytes) => onProgress(asset.localId!, livePhotoTitle, bytes, totalBytes)
              : null,
          logContext: 'livePhotoVideo[${asset.localId}]',
        );

        if (livePhotoResult.isSuccess && livePhotoResult.remoteAssetId != null) {
          livePhotoVideoId = livePhotoResult.remoteAssetId;
        } else if (livePhotoResult.isCancelled) {
          shouldAbortUpload = true;
          return;
        } else {
          // Fork: still goes up alone; the motion part is retried later.
          motionMissing = true;
        }
      }

      if (livePhotoVideoId != null) {
        fields['livePhotoVideoId'] = livePhotoVideoId;
      }

      // Add cloudId metadata only to the still image, not the motion video, becasue when the sync id happens, the motion video can get associated with the wrong still image.
      if (CurrentPlatform.isIOS && asset.cloudId != null) {
        fields['metadata'] = jsonEncode([
          RemoteAssetMetadataItem(
            key: RemoteAssetMetadataKey.mobileApp,
            value: RemoteAssetMobileAppMetadata(
              cloudId: asset.cloudId,
              createdAt: asset.createdAt.toIso8601String(),
              adjustmentTime: asset.adjustmentTime?.toIso8601String(),
              latitude: asset.latitude?.toString(),
              longitude: asset.longitude?.toString(),
            ),
          ),
        ]);
      }

      final onProgress = callbacks.onProgress;
      final result = await _uploadRepository.uploadFile(
        file: file,
        originalFileName: originalFileName,
        fields: fields,
        cancelToken: cancelToken,
        onProgress: onProgress != null
            ? (bytes, totalBytes) => onProgress(asset.localId!, originalFileName, bytes, totalBytes)
            : null,
        logContext: 'asset[${asset.localId}]',
      );

      if (result.isSuccess && result.remoteAssetId != null) {
        if (motionMissing) {
          await retry.motionPending(asset.id, 'motion part not fetchable', stillRemoteId: result.remoteAssetId);
        } else if (!retry.isMotionPending(asset.id)) {
          await retry.succeeded(asset.id);
        }
        await _handleUploadSuccess(asset, result.remoteAssetId!, callbacks);
      } else if (result.isCancelled) {
        shouldAbortUpload = true;
      } else if (result.errorMessage != null) {
        _logger.severe(
          () =>
              "Error(${result.statusCode}) uploading ${asset.localId} | $originalFileName | Created on ${asset.createdAt} | ${result.errorMessage}",
        );

        callbacks.onError?.call(asset.localId!, result.errorMessage!);
        await retry.failed(asset.id, 'upload error ${result.statusCode ?? ''}: ${result.errorMessage}');

        if (result.errorMessage == "Quota has been exceeded!") {
          shouldAbortUpload = true;
        }
      }
    } catch (error, stackTrace) {
      _logger.severe(() => "Error backup asset: $error", stackTrace);
      callbacks.onError?.call(asset.localId!, error.toString());
      await retry.failed(asset.id, error.toString());
    } finally {
      if (Platform.isIOS) {
        try {
          await file?.delete();
          await livePhotoFile?.delete();
        } catch (error, stackTrace) {
          _logger.severe(() => "ERROR deleting file: $error", stackTrace);
        }
      }
    }
  }

  Future<void> _handleUploadSuccess(LocalAsset asset, String remoteId, UploadCallbacks callbacks) async {
    callbacks.onSuccess?.call(asset.localId!, remoteId);
    try {
      await _assetService.stackEditedUpload(asset.localId!, remoteId, asset.checksum);
    } catch (error) {
      _logger.warning("Failed to stack the upload of ${asset.localId}: $error");
    }
  }

  Future<UploadResult> _uploadSingleFile(
    File file, {
    required String deviceAssetId,
    required Completer<void>? cancelToken,
    void Function(int bytes, int totalBytes)? onProgress,
  }) async {
    try {
      // ignore: avoid_slow_async_io
      final stats = await file.stat();
      final fileCreatedAt = stats.changed;
      final fileModifiedAt = stats.modified;
      final filename = p.basename(file.path);

      final fields = {
        // deviceAssetId/deviceId required by server v2.7.5 and below (drop in v4.0 per #27818).
        'deviceAssetId': deviceAssetId,
        'deviceId': Store.get(StoreKey.deviceId),
        'fileCreatedAt': fileCreatedAt.toUtc().toIso8601String(),
        'fileModifiedAt': fileModifiedAt.toUtc().toIso8601String(),
        'isFavorite': 'false',
        'duration': '0',
      };

      return await _uploadRepository.uploadFile(
        file: file,
        originalFileName: filename,
        fields: fields,
        cancelToken: cancelToken,
        onProgress: onProgress,
        logContext: 'shareIntent[$deviceAssetId]',
      );
    } catch (e) {
      return UploadResult.error(errorMessage: e.toString());
    }
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
}
