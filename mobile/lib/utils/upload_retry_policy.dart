// Fork (mandeep/photos): per-asset retry backoff for backup uploads.
//
// An asset whose export or upload fails (original not fetchable from iCloud, missing Live Photo motion
// part, missing temp file, server error) is recorded with a reason and a next-retry time. The queue skips
// it until then, so one bad asset never holds a worker or blocks the rest of the library. Backoff starts
// at 5 minutes and doubles up to 24 hours.
//
// A Live Photo whose motion part cannot be fetched is uploaded as a still; its motion part is recorded
// as pending and retried on the same backoff, then linked to the still on the server.
import 'dart:convert';
import 'dart:math';

const Duration kUploadRetryFirst = Duration(minutes: 5);
const Duration kUploadRetryMax = Duration(hours: 24);

/// Delay before retry number [failures] (1 = first failure): 5 min, 10 min, 20 min, ... capped at 24 h.
Duration uploadRetryDelay(int failures) {
  if (failures <= 1) {
    return kUploadRetryFirst;
  }
  final factor = pow(2, min(failures - 1, 20)).toInt();
  final ms = kUploadRetryFirst.inMilliseconds * factor;
  return ms >= kUploadRetryMax.inMilliseconds ? kUploadRetryMax : Duration(milliseconds: ms);
}

class UploadRetryEntry {
  final int failures;
  final int nextRetryMs;
  final String reason;

  /// Still uploaded without its motion part; the motion part is retried, then linked to [stillRemoteId].
  final bool motionPending;
  final String? stillRemoteId;

  const UploadRetryEntry({
    required this.failures,
    required this.nextRetryMs,
    required this.reason,
    this.motionPending = false,
    this.stillRemoteId,
  });

  Map<String, dynamic> toMap() => {
    'f': failures,
    'n': nextRetryMs,
    'r': reason,
    if (motionPending) 'm': true,
    if (stillRemoteId != null) 's': stillRemoteId,
  };

  factory UploadRetryEntry.fromMap(Map<String, dynamic> map) => UploadRetryEntry(
    failures: (map['f'] as num?)?.toInt() ?? 1,
    nextRetryMs: (map['n'] as num?)?.toInt() ?? 0,
    reason: map['r'] as String? ?? '',
    motionPending: map['m'] as bool? ?? false,
    stillRemoteId: map['s'] as String?,
  );
}

/// Pure retry book: every decision takes `now` explicitly so it can be unit-tested.
class UploadRetryBook {
  final Map<String, UploadRetryEntry> entries;

  UploadRetryBook([Map<String, UploadRetryEntry>? entries]) : entries = entries ?? {};

  /// Most entries kept; the oldest retry times are dropped first.
  static const int maxEntries = 5000;

  /// Whether the queue must skip [assetId] now: it failed and its retry time has not come.
  /// Assets with only a pending motion part are not skipped (their still is handled normally).
  bool shouldSkip(String assetId, DateTime now) {
    final entry = entries[assetId];
    if (entry == null || entry.motionPending) {
      return false;
    }
    return now.millisecondsSinceEpoch < entry.nextRetryMs;
  }

  /// Whether the Live Photo motion part of [assetId] should be fetched now. False while a pending motion
  /// part waits for its retry time, so the still uploads alone without the slow failing fetch.
  bool shouldFetchMotion(String assetId, DateTime now) {
    final entry = entries[assetId];
    if (entry == null || !entry.motionPending) {
      return true;
    }
    return now.millisecondsSinceEpoch >= entry.nextRetryMs;
  }

  /// Keeps the order of [ids] and drops those [shouldSkip] says to skip.
  List<T> due<T>(List<T> items, String Function(T) idOf, DateTime now) =>
      items.where((item) => !shouldSkip(idOf(item), now)).toList();

  /// Records a failed export or upload and returns the entry with its next retry time.
  UploadRetryEntry recordFailure(String assetId, String reason, DateTime now) {
    final previous = entries[assetId];
    final failures = (previous == null || previous.motionPending ? 0 : previous.failures) + 1;
    final entry = UploadRetryEntry(
      failures: failures,
      nextRetryMs: now.add(uploadRetryDelay(failures)).millisecondsSinceEpoch,
      reason: reason,
    );
    entries[assetId] = entry;
    _trim();
    return entry;
  }

  /// The asset uploaded fully: forget it.
  void recordSuccess(String assetId) => entries.remove(assetId);

  /// The still went up without its motion part. [stillRemoteId] may be filled in later.
  UploadRetryEntry recordMotionPending(String assetId, String reason, DateTime now, {String? stillRemoteId}) {
    final previous = entries[assetId];
    final failures = (previous != null && previous.motionPending ? previous.failures : 0) + 1;
    final entry = UploadRetryEntry(
      failures: failures,
      nextRetryMs: now.add(uploadRetryDelay(failures)).millisecondsSinceEpoch,
      reason: reason,
      motionPending: true,
      stillRemoteId: stillRemoteId ?? previous?.stillRemoteId,
    );
    entries[assetId] = entry;
    _trim();
    return entry;
  }

  /// Fills in the still's server id for a pending motion part.
  void setStillRemoteId(String assetId, String stillRemoteId) {
    final entry = entries[assetId];
    if (entry == null || !entry.motionPending) {
      return;
    }
    entries[assetId] = UploadRetryEntry(
      failures: entry.failures,
      nextRetryMs: entry.nextRetryMs,
      reason: entry.reason,
      motionPending: true,
      stillRemoteId: stillRemoteId,
    );
  }

  /// Pending motion parts whose retry time has come and whose still is on the server.
  List<String> motionRetriesDue(DateTime now) => entries.entries
      .where((e) => e.value.motionPending && e.value.stillRemoteId != null && now.millisecondsSinceEpoch >= e.value.nextRetryMs)
      .map((e) => e.key)
      .toList();

  void _trim() {
    if (entries.length <= maxEntries) {
      return;
    }
    final sorted = entries.entries.toList()..sort((a, b) => a.value.nextRetryMs.compareTo(b.value.nextRetryMs));
    for (final e in sorted.take(entries.length - maxEntries)) {
      entries.remove(e.key);
    }
  }

  String toJson() => jsonEncode(entries.map((k, v) => MapEntry(k, v.toMap())));

  factory UploadRetryBook.fromJson(String? source) {
    if (source == null || source.isEmpty) {
      return UploadRetryBook();
    }
    try {
      final map = jsonDecode(source) as Map<String, dynamic>;
      return UploadRetryBook(
        map.map((k, v) => MapEntry(k, UploadRetryEntry.fromMap(Map<String, dynamic>.from(v as Map)))),
      );
    } catch (_) {
      return UploadRetryBook();
    }
  }
}
