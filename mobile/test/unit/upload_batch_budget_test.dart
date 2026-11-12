import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/upload_batch_budget.dart';

const int mb = 1024 * 1024;
const int gb = 1024 * mb;

void main() {
  group('UploadBatchBudget', () {
    test('stops at 300 files', () {
      final budget = UploadBatchBudget(freeBytes: 100 * gb);
      var added = 0;
      while (budget.tryAdd(1 * mb)) {
        added++;
      }
      expect(added, 300);
      expect(budget.isFull, isTrue);
    });

    test('stops at 2 GB of files', () {
      final budget = UploadBatchBudget(freeBytes: 100 * gb);
      var added = 0;
      while (budget.tryAdd(100 * mb)) {
        added++;
      }
      expect(added, 20); // 20 x 100 MB = 2000 MB; the 21st would pass 2048 MB
      expect(budget.bytes, 2000 * mb);
    });

    test('counts files already queued with the session', () {
      final budget = UploadBatchBudget(freeBytes: 100 * gb, queuedFiles: 295, queuedBytes: 1 * gb);
      var added = 0;
      while (budget.tryAdd(1 * mb)) {
        added++;
      }
      expect(added, 5);
    });

    test('a full queue takes nothing', () {
      final budget = UploadBatchBudget(freeBytes: 100 * gb, queuedFiles: 10, queuedBytes: 2 * gb);
      expect(budget.isFull, isTrue);
      expect(budget.tryAdd(1), isFalse);
    });

    test('keeps the temporary copies under 25% of free storage', () {
      // 4 GB free -> 1 GB allowance; each file needs 2 copies -> at most 512 MB of files
      final budget = UploadBatchBudget(freeBytes: 4 * gb);
      var added = 0;
      while (budget.tryAdd(100 * mb)) {
        added++;
      }
      expect(added, 5);
      expect(budget.bytes, 500 * mb);
    });

    test('lets one oversized file go alone when storage allows', () {
      final budget = UploadBatchBudget(freeBytes: 100 * gb);
      expect(budget.tryAdd(3 * gb), isTrue);
      expect(budget.tryAdd(1 * mb), isFalse);
    });

    test('an oversized file does not join a started batch', () {
      final budget = UploadBatchBudget(freeBytes: 100 * gb);
      expect(budget.tryAdd(1 * mb), isTrue);
      expect(budget.tryAdd(3 * gb), isFalse);
      expect(budget.files, 1);
    });

    test('an oversized file is refused when storage is short', () {
      final budget = UploadBatchBudget(freeBytes: 8 * gb);
      expect(budget.tryAdd(3 * gb), isFalse); // 6 GB of copies > 2 GB allowance
    });

    test('a refused file leaves the budget unchanged and a smaller one still fits', () {
      final budget = UploadBatchBudget(freeBytes: 1 * gb); // 256 MB allowance
      expect(budget.tryAdd(100 * mb), isTrue);
      expect(budget.tryAdd(100 * mb), isFalse);
      expect(budget.bytes, 100 * mb);
      expect(budget.tryAdd(20 * mb), isTrue);
    });

    test('unknown free storage falls back to the count and byte caps', () {
      final budget = UploadBatchBudget();
      expect(budget.tryAdd(1 * gb), isTrue);
      expect(budget.tryAdd(1 * gb), isTrue);
      expect(budget.tryAdd(1), isFalse);
    });

    test('no free storage takes nothing', () {
      final budget = UploadBatchBudget(freeBytes: 0);
      expect(budget.isFull, isTrue);
      expect(budget.tryAdd(1), isFalse);
    });
  });
}
