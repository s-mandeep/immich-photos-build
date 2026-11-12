import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/utils/mirror_sync_planner.dart';
import 'package:immich_mobile/utils/backup_date_filter.dart';

LinkedAsset _linked(String id, {bool lf = false, bool rf = false, bool trashed = false, String? checksum}) =>
    LinkedAsset(
      localId: id,
      remoteId: 'r$id',
      checksum: checksum ?? 'c$id',
      localFavorite: lf,
      remoteFavorite: rf,
      remoteTrashed: trashed,
    );

MirrorPair _pair(String id, {bool fav = false, String? checksum}) =>
    MirrorPair(localId: id, remoteId: 'r$id', checksum: checksum ?? 'c$id', favorite: fav);

MirrorPlan _plan({
  List<LinkedAsset> linked = const [],
  List<MirrorPair> previous = const [],
  Set<String>? local,
  Map<String, String?>? checksums,
  Set<String>? remote,
  Set<String> declined = const {},
  MirrorOptions options = const MirrorOptions(),
}) {
  final localIds = local ?? linked.map((e) => e.localId).toSet();
  return planMirror(
    linked: linked,
    previous: {for (final p in previous) p.localId: p},
    localIdsInDb: localIds,
    localChecksums: checksums ?? {for (final l in linked) l.localId: l.checksum},
    remoteIdsInDb: remote ?? linked.map((e) => e.remoteId).toSet(),
    declined: declined,
    options: options,
  );
}

void main() {
  group('favourites', () {
    test('first sight: a favourite on either side wins', () {
      final plan = _plan(linked: [_linked('1', lf: true), _linked('2', rf: true), _linked('3')]);
      expect(plan.serverFavorite, ['r1']);
      expect(plan.phoneFavorite, ['2']);
      expect(plan.nextState['1']!.favorite, isTrue);
      expect(plan.nextState['2']!.favorite, isTrue);
      expect(plan.nextState['3']!.favorite, isFalse);
    });

    test('phone change goes to the server', () {
      final plan = _plan(linked: [_linked('1', lf: false, rf: true)], previous: [_pair('1', fav: true)]);
      expect(plan.serverUnfavorite, ['r1']);
      expect(plan.phoneFavorite, isEmpty);
      expect(plan.nextState['1']!.favorite, isFalse);
    });

    test('server change goes to the phone', () {
      final plan = _plan(linked: [_linked('1', lf: false, rf: true)], previous: [_pair('1', fav: false)]);
      expect(plan.phoneFavorite, ['1']);
      expect(plan.serverFavorite, isEmpty);
      expect(plan.nextState['1']!.favorite, isTrue);
    });

    test('unchanged pair produces no work', () {
      final plan = _plan(linked: [_linked('1', lf: true, rf: true)], previous: [_pair('1', fav: true)]);
      expect(plan.isEmpty, isTrue);
    });

    test('disabled: nothing pushed, state kept', () {
      final plan = _plan(
        linked: [_linked('1', lf: true, rf: false)],
        previous: [_pair('1', fav: false)],
        options: const MirrorOptions(favorites: false),
      );
      expect(plan.isEmpty, isTrue);
      expect(plan.nextState['1']!.favorite, isFalse);
    });
  });

  group('deletes', () {
    test('server trash asks to delete on the phone', () {
      final plan = _plan(linked: [_linked('1', trashed: true)], previous: [_pair('1')]);
      expect(plan.deleteOnPhone, ['1']);
      expect(plan.nextState.containsKey('1'), isTrue);
    });

    test('declined server trash is not asked again', () {
      final plan = _plan(linked: [_linked('1', trashed: true)], previous: [_pair('1')], declined: {'1'});
      expect(plan.deleteOnPhone, isEmpty);
    });

    test('permanent server delete with unchanged phone copy asks to delete', () {
      final plan = _plan(previous: [_pair('1')], local: {'1'}, checksums: {'1': 'c1'}, remote: {});
      expect(plan.deleteOnPhone, ['1']);
    });

    test('permanent server delete of an edited phone copy is ignored', () {
      final plan = _plan(previous: [_pair('1')], local: {'1'}, checksums: {'1': 'other'}, remote: {});
      expect(plan.deleteOnPhone, isEmpty);
      expect(plan.nextState, isEmpty);
    });

    test('native Photos delete never reaches the server (pair forgotten)', () {
      final plan = _plan(previous: [_pair('1')], local: {}, remote: {'r1'});
      expect(plan.trashOnServer, isEmpty);
      expect(plan.deleteOnPhone, isEmpty);
      expect(plan.isEmpty, isTrue);
      expect(plan.nextState, isEmpty);
    });

    test('native Photos delete ignored even with the old phoneDeletes option on', () {
      final plan = _plan(
        previous: [_pair('1'), _pair('2')],
        local: {},
        remote: {'r1', 'r2'},
        options: const MirrorOptions(phoneDeletes: true),
      );
      expect(plan.trashOnServer, isEmpty);
      expect(plan.isEmpty, isTrue);
    });

    test('phoneDeletes defaults to off', () {
      expect(const MirrorOptions().phoneDeletes, isFalse);
    });

    test('asset never paired is never deleted anywhere', () {
      final plan = _plan(local: {'9'}, checksums: {'9': 'c9'}, remote: {'r8'});
      expect(plan.isEmpty, isTrue);
    });
  });

  group('backup date filter', () {
    test('0 means no filter', () {
      expect(passesBackupDateFilter(DateTime(2001), 0), isTrue);
    });

    test('older assets are filtered out', () {
      final from = DateTime(2026).millisecondsSinceEpoch;
      expect(passesBackupDateFilter(DateTime(2025, 12, 31), from), isFalse);
      expect(passesBackupDateFilter(DateTime(2026, 1, 1), from), isTrue);
    });

    test('startOfYear', () {
      expect(startOfYear(DateTime(2026, 11, 5, 22)), DateTime(2026));
    });
  });
}
