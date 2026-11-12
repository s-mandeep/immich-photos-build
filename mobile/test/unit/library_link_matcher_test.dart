import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/utils/library_link_matcher.dart';

const _t = 1700000000; // capture time, seconds

PhoneAssetMeta _p(String id, String name, {int t = _t, int type = 1, int w = 4032, int h = 3024, int? size = 1000}) =>
    PhoneAssetMeta(id: id, name: name, type: type, createdSec: t, width: w, height: h, size: size, local: true);

ServerAssetMeta _s(
  String id,
  String name, {
  int? t = _t,
  int? alt,
  int type = 1,
  int? w = 4032,
  int? h = 3024,
  int? size = 1000,
}) => ServerAssetMeta(
  id: id,
  name: name,
  type: type,
  createdSec: t,
  altCreatedSec: alt,
  width: w,
  height: h,
  size: size,
  checksum: 'c$id',
);

void main() {
  test('exact name + time + size + dims: matched', () {
    final r = matchLibrary([_p('a', 'IMG_0001.HEIC')], [_s('1', 'IMG_0001.HEIC'), _s('2', 'IMG_0002.HEIC')]);
    expect(r.matches.single.server.id, '1');
    expect(r.unmatched, isEmpty);
  });

  test('name is case-insensitive; rotated dimensions accepted', () {
    final r = matchLibrary([_p('a', 'img_0001.heic', w: 3024, h: 4032, size: null)], [_s('1', 'IMG_0001.HEIC')]);
    expect(r.matches.single.server.id, '1');
  });

  test('size differs: not matched', () {
    final r = matchLibrary([_p('a', 'IMG_0001.HEIC', size: 999)], [_s('1', 'IMG_0001.HEIC')]);
    expect(r.matches, isEmpty);
    expect(r.unmatched['a'], 'no-candidate');
  });

  test('time off by 1 s: not matched', () {
    final r = matchLibrary([_p('a', 'IMG_0001.HEIC', t: _t + 1)], [_s('1', 'IMG_0001.HEIC')]);
    expect(r.matches, isEmpty);
  });

  test('EXIF original time matches when file time differs', () {
    final r = matchLibrary([_p('a', 'IMG_0001.HEIC')], [_s('1', 'IMG_0001.HEIC', t: _t + 50, alt: _t)]);
    expect(r.matches.single.server.id, '1');
  });

  test('timezone shift (5h30) accepted only with equal known size and a single candidate', () {
    final shift = 5 * 3600 + 1800;
    final ok = matchLibrary([_p('a', 'IMG_0001.HEIC')], [_s('1', 'IMG_0001.HEIC', t: _t + shift)]);
    expect(ok.matches.single.shifted, isTrue);

    final noSize = matchLibrary([_p('a', 'IMG_0001.HEIC', size: null)], [_s('1', 'IMG_0001.HEIC', t: _t + shift)]);
    expect(noSize.matches, isEmpty);

    final two = matchLibrary(
      [_p('a', 'IMG_0001.HEIC')],
      [_s('1', 'IMG_0001.HEIC', t: _t + shift), _s('2', 'IMG_0001.HEIC', t: _t - 3600)],
    );
    expect(two.matches, isEmpty);
    expect(two.ambiguous['a'], containsAll(['1', '2']));
  });

  test('two server candidates with the same name and time: ambiguous', () {
    final r = matchLibrary([_p('a', 'IMG_0001.HEIC')], [_s('1', 'IMG_0001.HEIC'), _s('2', 'IMG_0001.HEIC')]);
    expect(r.matches, isEmpty);
    expect(r.ambiguous['a'], ['1', '2']);
  });

  test('two phone assets claiming one server asset: neither is paired', () {
    final r = matchLibrary([_p('a', 'IMG_0001.HEIC'), _p('b', 'IMG_0001.HEIC')], [_s('1', 'IMG_0001.HEIC')]);
    expect(r.matches, isEmpty);
    expect(r.ambiguous.keys, containsAll(['a', 'b']));
  });

  test('photo never matches a video of the same name', () {
    final r = matchLibrary([_p('a', 'IMG_0001.MOV', type: 2)], [_s('1', 'IMG_0001.MOV')]);
    expect(r.matches, isEmpty);
  });

  test('missing name or date: unmatched with a reason', () {
    final r = matchLibrary(
      [
        const PhoneAssetMeta(id: 'a', name: null, type: 1, createdSec: _t),
        const PhoneAssetMeta(id: 'b', name: 'X.JPG', type: 1, createdSec: null),
      ],
      [_s('1', 'X.JPG')],
    );
    expect(r.unmatched, {'a': 'no-name', 'b': 'no-date'});
  });

  test('fromMap reads the native channel payload', () {
    final p = PhoneAssetMeta.fromMap({
      'id': 'x',
      'name': 'IMG.HEIC',
      'type': 1,
      't': _t,
      'w': 10,
      'h': 20,
      'size': 30,
      'fav': true,
      'local': false,
    })!;
    expect(
      [p.id, p.name, p.type, p.createdSec, p.width, p.height, p.size, p.favorite, p.local],
      ['x', 'IMG.HEIC', 1, _t, 10, 20, 30, true, false],
    );
  });

  group('hash gate', () {
    test('pending below 100, passed at 100 all equal, failed on any mismatch', () {
      expect(evaluateLinkGate(sampled: 0, equal: 0), LinkGateStatus.pending);
      expect(evaluateLinkGate(sampled: 99, equal: 99), LinkGateStatus.pending);
      expect(evaluateLinkGate(sampled: 100, equal: 100), LinkGateStatus.passed);
      expect(evaluateLinkGate(sampled: 100, equal: 99), LinkGateStatus.failed);
      expect(evaluateLinkGate(sampled: 5, equal: 4), LinkGateStatus.failed);
    });
  });
}
