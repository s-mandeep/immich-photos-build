// Fork (mandeep/photos): pair phone assets with server assets WITHOUT hashing.
// Pure logic (no Flutter, Drift or PhotoKit) so it can be unit tested.
//
// A phone asset is paired with a server asset only when the match is exact and unique:
//  - same original file name (case-insensitive) and same media type (image/video)
//  - same capture time to the second; a whole-quarter-hour timezone shift (up to 14 h) is accepted only
//    when it is the single candidate AND the file sizes are known on both sides and equal
//  - pixel dimensions equal (either orientation) and file size equal, wherever both sides know them
//  - no other phone asset claims the same server asset
// Everything else is reported (unmatched / ambiguous) and never paired.

class PhoneAssetMeta {
  final String id;
  final String? name;

  /// PHAssetMediaType: 1 image, 2 video (same numbers as AssetType.image/.video).
  final int type;

  /// Capture time, whole seconds since the epoch (UTC).
  final int? createdSec;
  final int width;
  final int height;
  final int? size;
  final bool favorite;

  /// Whether the original is on the phone (false = iCloud-only, null = unknown).
  final bool? local;

  const PhoneAssetMeta({
    required this.id,
    required this.name,
    required this.type,
    required this.createdSec,
    this.width = 0,
    this.height = 0,
    this.size,
    this.favorite = false,
    this.local,
  });

  static PhoneAssetMeta? fromMap(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final id = raw['id'];
    if (id is! String) {
      return null;
    }
    int? asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
    return PhoneAssetMeta(
      id: id,
      name: raw['name'] is String ? raw['name'] as String : null,
      type: asInt(raw['type']) ?? 0,
      createdSec: asInt(raw['t']),
      width: asInt(raw['w']) ?? 0,
      height: asInt(raw['h']) ?? 0,
      size: asInt(raw['size']),
      favorite: raw['fav'] == true,
      local: raw['local'] is bool ? raw['local'] as bool : null,
    );
  }
}

class ServerAssetMeta {
  final String id;
  final String name;

  /// AssetType index: 1 image, 2 video.
  final int type;
  final int? createdSec;

  /// EXIF DateTimeOriginal when the server has it (may differ from fileCreatedAt).
  final int? altCreatedSec;
  final int? width;
  final int? height;
  final int? size;
  final String checksum;
  final bool favorite;

  const ServerAssetMeta({
    required this.id,
    required this.name,
    required this.type,
    required this.createdSec,
    required this.checksum,
    this.altCreatedSec,
    this.width,
    this.height,
    this.size,
    this.favorite = false,
  });
}

class LinkMatch {
  final String phoneId;
  final ServerAssetMeta server;

  /// True when the pair was accepted through the timezone-shift rule.
  final bool shifted;

  const LinkMatch(this.phoneId, this.server, {this.shifted = false});
}

class LinkResult {
  final List<LinkMatch> matches = [];

  /// Phone id -> reason ('no-name', 'no-date', 'no-candidate').
  final Map<String, String> unmatched = {};

  /// Phone id -> candidate server ids.
  final Map<String, List<String>> ambiguous = {};
}

const int _kQuarterHour = 900;
const int _kMaxShift = 14 * 3600;

Set<int> _times(ServerAssetMeta s) => {?s.createdSec, ?s.altCreatedSec};

bool _dimsOk(PhoneAssetMeta p, ServerAssetMeta s) {
  // Equal byte size is the stronger proof; the phone reports the CURRENT (possibly cropped) dimensions.
  if (_sizeKnown(p, s)) {
    return true;
  }
  final sw = s.width ?? 0;
  final sh = s.height ?? 0;
  if (p.width <= 0 || p.height <= 0 || sw <= 0 || sh <= 0) {
    return true; // not known on one side
  }
  return (p.width == sw && p.height == sh) || (p.width == sh && p.height == sw);
}

bool _sizeKnown(PhoneAssetMeta p, ServerAssetMeta s) => (p.size ?? 0) > 0 && (s.size ?? 0) > 0;

bool _sizeOk(PhoneAssetMeta p, ServerAssetMeta s) => !_sizeKnown(p, s) || p.size == s.size;

LinkResult matchLibrary(List<PhoneAssetMeta> phone, List<ServerAssetMeta> server) {
  final result = LinkResult();
  final byName = <String, List<ServerAssetMeta>>{};
  for (final s in server) {
    byName.putIfAbsent(s.name.toLowerCase(), () => []).add(s);
  }

  final tentative = <String, LinkMatch>{};
  for (final p in phone) {
    final name = p.name;
    if (name == null || name.isEmpty) {
      result.unmatched[p.id] = 'no-name';
      continue;
    }
    final created = p.createdSec;
    if (created == null) {
      result.unmatched[p.id] = 'no-date';
      continue;
    }
    final candidates = (byName[name.toLowerCase()] ?? const <ServerAssetMeta>[])
        .where((s) => s.type == p.type && _times(s).isNotEmpty && _dimsOk(p, s) && _sizeOk(p, s))
        .toList();
    final exact = candidates.where((s) => _times(s).contains(created)).toList();
    if (exact.length == 1) {
      tentative[p.id] = LinkMatch(p.id, exact.first);
      continue;
    }
    if (exact.length > 1) {
      result.ambiguous[p.id] = exact.map((s) => s.id).toList();
      continue;
    }
    final shifted = candidates.where((s) {
      if (!_sizeKnown(p, s)) {
        return false;
      }
      return _times(s).any((t) {
        final diff = (t - created).abs();
        return diff != 0 && diff <= _kMaxShift && diff % _kQuarterHour == 0;
      });
    }).toList();
    if (shifted.length == 1) {
      tentative[p.id] = LinkMatch(p.id, shifted.first, shifted: true);
    } else if (shifted.length > 1) {
      result.ambiguous[p.id] = shifted.map((s) => s.id).toList();
    } else {
      result.unmatched[p.id] = 'no-candidate';
    }
  }

  // A server asset claimed by more than one phone asset pairs with none of them.
  final claims = <String, List<String>>{};
  for (final m in tentative.values) {
    claims.putIfAbsent(m.server.id, () => []).add(m.phoneId);
  }
  for (final m in tentative.values) {
    final claimants = claims[m.server.id]!;
    if (claimants.length == 1) {
      result.matches.add(m);
    } else {
      result.ambiguous[m.phoneId] = [m.server.id];
    }
  }
  return result;
}

/// Outcome of the hash check on a sample of metadata pairs (only originals already on the phone).
enum LinkGateStatus { pending, passed, failed }

const int kLinkGateSample = 100;

LinkGateStatus evaluateLinkGate({required int sampled, required int equal}) {
  if (sampled > equal) {
    return LinkGateStatus.failed;
  }
  if (sampled >= kLinkGateSample) {
    return LinkGateStatus.passed;
  }
  return LinkGateStatus.pending;
}
