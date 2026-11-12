import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/upload_retry_policy.dart';

void main() {
  final t0 = DateTime(2026, 11, 6, 15);

  group('uploadRetryDelay', () {
    test('starts at 5 minutes and doubles', () {
      expect(uploadRetryDelay(1), const Duration(minutes: 5));
      expect(uploadRetryDelay(2), const Duration(minutes: 10));
      expect(uploadRetryDelay(3), const Duration(minutes: 20));
      expect(uploadRetryDelay(5), const Duration(minutes: 80));
    });

    test('caps at 24 hours', () {
      expect(uploadRetryDelay(10), const Duration(hours: 24));
      expect(uploadRetryDelay(1000), const Duration(hours: 24));
    });
  });

  group('UploadRetryBook', () {
    test('an asset without failures is never skipped', () {
      expect(UploadRetryBook().shouldSkip('a', t0), isFalse);
    });

    test('a failed asset is skipped until its retry time, then due again', () {
      final book = UploadRetryBook();
      book.recordFailure('a', 'PHPhotosErrorDomain 3169', t0);
      expect(book.shouldSkip('a', t0), isTrue);
      expect(book.shouldSkip('a', t0.add(const Duration(minutes: 4, seconds: 59))), isTrue);
      expect(book.shouldSkip('a', t0.add(const Duration(minutes: 5))), isFalse);
      expect(book.entries['a']!.reason, 'PHPhotosErrorDomain 3169');
    });

    test('repeated failures double the wait', () {
      final book = UploadRetryBook();
      var now = t0;
      for (final minutes in [5, 10, 20, 40]) {
        final entry = book.recordFailure('a', 'x', now);
        expect(entry.nextRetryMs, now.add(Duration(minutes: minutes)).millisecondsSinceEpoch);
        now = DateTime.fromMillisecondsSinceEpoch(entry.nextRetryMs);
      }
      expect(book.entries['a']!.failures, 4);
    });

    test('success clears the record', () {
      final book = UploadRetryBook()..recordFailure('a', 'x', t0);
      book.recordSuccess('a');
      expect(book.shouldSkip('a', t0), isFalse);
      expect(book.entries, isEmpty);
    });

    test('the queue moves past failed assets in order', () {
      // the log's case: three Live Photos fail on every run and must not block the rest
      final book = UploadRetryBook()
        ..recordFailure('live1', 'x', t0)
        ..recordFailure('live2', 'x', t0)
        ..recordFailure('live3', 'x', t0);
      final queue = ['live1', 'live2', 'live3', 'p4', 'p5', 'p6'];
      expect(book.due(queue, (id) => id, t0.add(const Duration(minutes: 1))), ['p4', 'p5', 'p6']);
      expect(book.due(queue, (id) => id, t0.add(const Duration(minutes: 5))), queue);
    });

    test('a pending motion part does not skip the asset but skips the motion fetch until due', () {
      final book = UploadRetryBook()..recordMotionPending('a', 'motion 3169', t0);
      expect(book.shouldSkip('a', t0), isFalse);
      expect(book.shouldFetchMotion('a', t0), isFalse);
      expect(book.shouldFetchMotion('a', t0.add(const Duration(minutes: 5))), isTrue);
      expect(book.shouldFetchMotion('other', t0), isTrue);
    });

    test('pending motion parts are retried only when due and the still is on the server', () {
      final book = UploadRetryBook()
        ..recordMotionPending('a', 'x', t0, stillRemoteId: 'remote-a')
        ..recordMotionPending('b', 'x', t0);
      expect(book.motionRetriesDue(t0), isEmpty);
      final later = t0.add(const Duration(minutes: 5));
      expect(book.motionRetriesDue(later), ['a']);
      book.setStillRemoteId('b', 'remote-b');
      expect(book.motionRetriesDue(later), containsAll(['a', 'b']));
    });

    test('a failed motion retry backs off further and keeps the still id', () {
      final book = UploadRetryBook()..recordMotionPending('a', 'x', t0, stillRemoteId: 'r');
      final entry = book.recordMotionPending('a', 'y', t0);
      expect(entry.failures, 2);
      expect(entry.stillRemoteId, 'r');
      expect(entry.nextRetryMs, t0.add(const Duration(minutes: 10)).millisecondsSinceEpoch);
    });

    test('survives a JSON round trip, and bad JSON gives an empty book', () {
      final book = UploadRetryBook()
        ..recordFailure('a', 'server 500', t0)
        ..recordMotionPending('b', 'motion', t0, stillRemoteId: 'rb');
      final copy = UploadRetryBook.fromJson(book.toJson());
      expect(copy.shouldSkip('a', t0), isTrue);
      expect(copy.entries['b']!.motionPending, isTrue);
      expect(copy.entries['b']!.stillRemoteId, 'rb');
      expect(UploadRetryBook.fromJson('not json').entries, isEmpty);
      expect(UploadRetryBook.fromJson(null).entries, isEmpty);
    });
  });
}
