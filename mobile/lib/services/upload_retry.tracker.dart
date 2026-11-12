// Fork (mandeep/photos): persistent retry book for backup uploads, shared by the foreground worker pool
// and the background URLSession path. Decisions live in the pure UploadRetryBook (unit-tested); this
// class loads and saves it in the Store and logs every change.
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/utils/upload_retry_policy.dart';
import 'package:logging/logging.dart';

class UploadRetryTracker {
  UploadRetryTracker._();
  static final UploadRetryTracker instance = UploadRetryTracker._();

  final Logger _log = Logger('UploadRetryTracker');
  UploadRetryBook? _book;

  UploadRetryBook get book {
    var book = _book;
    if (book == null) {
      String? json;
      try {
        json = Store.tryGet(StoreKey.uploadRetryBook);
      } catch (_) {}
      book = _book = UploadRetryBook.fromJson(json);
    }
    return book;
  }

  /// Re-read the book from the Store at the start of a run (another isolate may have changed it).
  void reload() => _book = null;

  Future<void> _save() async {
    try {
      await Store.put(StoreKey.uploadRetryBook, book.toJson());
    } catch (error) {
      _log.warning('Could not save the upload retry book: $error');
    }
  }

  /// [items] without the assets still waiting for their retry time.
  List<T> due<T>(List<T> items, String Function(T) idOf) {
    final now = DateTime.now();
    final result = book.due(items, idOf, now);
    final skipped = items.length - result.length;
    if (skipped > 0) {
      _log.info('Skipping $skipped assets waiting for a retry after an earlier failure');
    }
    return result;
  }

  Future<void> failed(String assetId, String reason) {
    final entry = book.recordFailure(assetId, reason, DateTime.now());
    _log.warning(
      'Upload of $assetId failed (${entry.failures}x): $reason; next retry '
      '${DateTime.fromMillisecondsSinceEpoch(entry.nextRetryMs)}',
    );
    return _save();
  }

  Future<void> succeeded(String assetId) {
    if (!book.entries.containsKey(assetId)) {
      return Future.value();
    }
    book.recordSuccess(assetId);
    return _save();
  }

  Future<void> motionPending(String assetId, String reason, {String? stillRemoteId}) {
    final entry = book.recordMotionPending(assetId, reason, DateTime.now(), stillRemoteId: stillRemoteId);
    _log.warning(
      'Live Photo $assetId uploaded without its motion part (${entry.failures}x): $reason; next retry '
      '${DateTime.fromMillisecondsSinceEpoch(entry.nextRetryMs)}',
    );
    return _save();
  }

  Future<void> setStillRemoteId(String assetId, String stillRemoteId) {
    book.setStillRemoteId(assetId, stillRemoteId);
    return _save();
  }

  bool isMotionPending(String assetId) => book.entries[assetId]?.motionPending ?? false;

  bool shouldFetchMotion(String assetId) => book.shouldFetchMotion(assetId, DateTime.now());

  List<String> motionRetriesDue() => book.motionRetriesDue(DateTime.now());

  String? stillRemoteIdFor(String assetId) => book.entries[assetId]?.stillRemoteId;
}
