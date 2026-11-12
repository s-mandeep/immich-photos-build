import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/utils/library_album_planner.dart';
import 'package:immich_mobile/domain/utils/library_link_matcher.dart';

PhoneAlbumMeta _a(String id, String name, List<String> assets, {String kind = 'regular', String? smart}) =>
    PhoneAlbumMeta(id: id, name: name, kind: kind, smart: smart, assetIds: assets);

void main() {
  group('planAlbums', () {
    test('reuses an owned server album with the same name and adds only what is missing', () {
      final plans = planAlbums(
        albums: [
          _a('p1', 'Instagram', ['l1', 'l2', 'l3']),
        ],
        remoteOf: {'l1': 'r1', 'l2': 'r2', 'l3': 'r3'},
        serverAlbums: [
          const ServerAlbumRef(id: 'sa', name: 'Instagram', assetIds: {'r1', 'r9'}),
        ],
      );
      expect(plans.single.serverAlbumId, 'sa');
      expect(plans.single.reused, isTrue);
      expect(plans.single.toAdd, ['r2', 'r3']);
      expect(plans.single.alreadyThere, 1);
      expect(plans.single.skipped, isFalse);
    });

    test('creates when no server album has the name; matches names case-insensitively when not exact', () {
      final plans = planAlbums(
        albums: [
          _a('p1', 'Goa 2024', ['l1']),
          _a('p2', 'family', ['l2']),
        ],
        remoteOf: {'l1': 'r1', 'l2': 'r2'},
        serverAlbums: [const ServerAlbumRef(id: 'sf', name: 'Family')],
      );
      expect(plans[0].serverAlbumId, isNull);
      expect(plans[0].creates, isTrue);
      expect(plans[0].toAdd, ['r1']);
      expect(plans[1].serverAlbumId, 'sf');
    });

    test('with several same-name server albums, picks the one holding most matched photos', () {
      final plans = planAlbums(
        albums: [
          _a('p1', 'Trip', ['l1', 'l2']),
        ],
        remoteOf: {'l1': 'r1', 'l2': 'r2'},
        serverAlbums: [
          const ServerAlbumRef(id: 'big', name: 'Trip', assetIds: {'x1', 'x2', 'x3'}),
          const ServerAlbumRef(id: 'mine', name: 'Trip', assetIds: {'r1'}),
        ],
      );
      expect(plans.single.serverAlbumId, 'mine');
      expect(plans.single.toAdd, ['r2']);
    });

    test('additive only: never plans removals and is idempotent when everything is already there', () {
      final plans = planAlbums(
        albums: [
          _a('p1', 'Screenshots', ['l1'], kind: 'smart', smart: 'screenshots'),
        ],
        remoteOf: {'l1': 'r1'},
        serverAlbums: [
          const ServerAlbumRef(id: 's', name: 'Screenshots', assetIds: {'r1', 'r2', 'r3'}),
        ],
      );
      expect(plans.single.toAdd, isEmpty);
      expect(plans.single.skipped, isFalse);
      expect(plans.single.reportLine(added: 0), contains('up to date'));
    });

    test('skip reasons: empty, no matches, iCloud-only, ambiguous, not in library; never silent', () {
      final plans = planAlbums(
        albums: [
          _a('e', 'Empty', []),
          _a('n', 'Nothing', ['u1']),
          _a('i', 'Cloud', ['c1', 'c2']),
          _a('m', 'Amb', ['a1']),
          _a('s', 'Shared stream', ['o1'], kind: 'shared'),
        ],
        remoteOf: const {},
        serverAlbums: const [],
        iCloudOnlyIds: {'c1', 'c2'},
        ambiguousIds: {'a1'},
        notInLibraryIds: {'o1'},
      );
      expect(plans.map((p) => p.skipReason), ['empty', 'no matches', 'iCloud-only', 'ambiguous', 'not in library']);
      expect(plans.length, 5);
      for (final p in plans) {
        expect(p.reportLine(), contains('skipped: ${p.skipReason}'));
      }
    });

    test('mixed album reports the unmatched breakdown and still adds the matched ones', () {
      final plan = planAlbums(
        albums: [
          _a('p', 'Mixed', ['l1', 'c1', 'a1', 'u1']),
        ],
        remoteOf: {'l1': 'r1'},
        serverAlbums: const [],
        iCloudOnlyIds: {'c1'},
        ambiguousIds: {'a1'},
      ).single;
      expect(plan.matched, 1);
      expect(plan.toAdd, ['r1']);
      final line = plan.reportLine(added: 1);
      expect(line, contains('1 iCloud-only'));
      expect(line, contains('1 ambiguous'));
      expect(line, contains('1 no match'));
      expect(line, contains('created'));
    });

    test(
      'excluded smart albums (Recents, Favourites, Hidden, Recently Deleted/Added, unknown) are reported, not sent',
      () {
        final plans = planAlbums(
          albums: [
            for (final k in ['recents', 'favorites', 'hidden', 'recentlyDeleted', 'recentlyAdded', 'other214'])
              _a(k, k, ['l1'], kind: 'smart', smart: k),
            _a('sel', 'Selfies', ['l1'], kind: 'smart', smart: 'selfies'),
          ],
          remoteOf: {'l1': 'r1'},
          serverAlbums: const [],
        );
        expect(plans.take(6).every((p) => p.skipReason == 'excluded'), isTrue);
        expect(plans.last.skipped, isFalse);
        expect(plans.last.toAdd, ['r1']);
        for (final k in kSmartAlbumsSynced) {
          expect(isAlbumExcluded(_a(k, k, const [], kind: 'smart', smart: k)), isFalse);
        }
      },
    );

    test('shared and synced albums are planned like regular ones', () {
      final plans = planAlbums(
        albums: [
          _a('s', 'Family share', ['l1'], kind: 'shared'),
          _a('y', 'From Mac', ['l2'], kind: 'synced'),
        ],
        remoteOf: {'l1': 'r1', 'l2': 'r2'},
        serverAlbums: const [],
      );
      expect(plans.every((p) => p.creates), isTrue);
    });

    test('two phone albums with the same name share one target without duplicate adds', () {
      final plans = planAlbums(
        albums: [
          _a('p1', 'Trip', ['l1', 'l2']),
          _a('p2', 'trip ', ['l2', 'l3'], kind: 'shared'),
        ],
        remoteOf: {'l1': 'r1', 'l2': 'r2', 'l3': 'r3'},
        serverAlbums: const [],
      );
      expect(plans[0].toAdd, ['r1', 'r2']);
      expect(plans[1].toAdd, ['r3']);
      expect(plans[0].targetKey, plans[1].targetKey);
    });

    test('resumes: an album created by an interrupted run is reused, not created again', () {
      final plans = planAlbums(
        albums: [
          _a('p1', 'New album', ['l1', 'l2']),
        ],
        remoteOf: {'l1': 'r1', 'l2': 'r2'},
        serverAlbums: [
          const ServerAlbumRef(id: 'made', name: 'Renamed later', assetIds: {'r1'}),
        ],
        remembered: {'new album': 'made'},
      );
      expect(plans.single.serverAlbumId, 'made');
      expect(plans.single.toAdd, ['r2']);
    });

    test('PhoneAlbumMeta.fromMap reads the native fields', () {
      final a = PhoneAlbumMeta.fromMap({
        'id': 'x',
        'name': ' Selfies ',
        'kind': 'smart',
        'smart': 'selfies',
        'assets': ['a', 1, 'b'],
      })!;
      expect(a.name, 'Selfies');
      expect(a.smart, 'selfies');
      expect(a.assetIds, ['a', 'b']);
      expect(PhoneAlbumMeta.fromMap({'name': 'x'}), isNull);
    });
  });

  group('resolveAlbumOnlyAssets', () {
    PhoneAssetMeta p(String id, String name, int t) =>
        PhoneAssetMeta(id: id, name: name, type: 1, createdSec: t, local: true);
    ServerAssetMeta s(String id, String name, int t) =>
        ServerAssetMeta(id: id, name: name, type: 1, createdSec: t, checksum: 'c$id');

    test('via the unique library twin, else the unique server asset; ambiguous stays unresolved', () {
      final out = resolveAlbumOnlyAssets(
        albumOnly: [p('x1', 'IMG_1.JPG', 100), p('x2', 'IMG_2.JPG', 200), p('x3', 'IMG_3.JPG', 300)],
        library: [p('l1', 'img_1.jpg', 100)],
        remoteOf: {'l1': 'r1'},
        server: [
          s('r1', 'IMG_1.JPG', 100),
          s('r2', 'IMG_2.JPG', 200),
          s('r3a', 'IMG_3.JPG', 300),
          s('r3b', 'IMG_3.JPG', 300),
        ],
      );
      expect(out, {'x1': 'r1', 'x2': 'r2'});
    });
  });
}
