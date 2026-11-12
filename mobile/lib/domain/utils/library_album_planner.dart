// Fork (mandeep/photos), 12 Nov (photos-v4): which phone albums go to which server albums during "Link library".
// Pure logic (no Flutter, Drift or PhotoKit) so it can be unit tested.
//
//  - Every phone album is considered: regular, shared (iCloud), synced from a computer, imported, and the
//    smart albums in [kSmartAlbumsSynced]. Recents/All Photos, Favourites (own sync), Hidden, Recently Deleted,
//    Recently Added and any other smart album are excluded and reported as such.
//  - Target: an OWNED server album with the same name (exact name first, then case-insensitive; with several,
//    the one holding most of the matched photos, then the largest), else one remembered from an earlier
//    interrupted run, else a new album is created.
//  - Only matched server assets are added, never removed. Assets already in the target are not re-sent.
//  - Every album gets a report line; nothing is skipped silently.
import 'package:immich_mobile/domain/utils/library_link_matcher.dart';

/// Smart albums copied to the server (keys produced by MirrorApiImpl.swift).
const Set<String> kSmartAlbumsSynced = {
  'selfies',
  'portraits',
  'panoramas',
  'screenshots',
  'livePhotos',
  'videos',
  'slomo',
  'timelapses',
  'bursts',
  'cinematic',
};

/// Smart albums never copied (named so the report can say why).
const Set<String> kSmartAlbumsExcluded = {'recents', 'favorites', 'hidden', 'recentlyDeleted', 'recentlyAdded'};

class PhoneAlbumMeta {
  final String id;
  final String name;

  /// 'regular', 'shared', 'synced', 'imported', 'smart' (anything else is treated like 'regular').
  final String kind;

  /// Smart album key (see [kSmartAlbumsSynced]) when [kind] == 'smart'.
  final String? smart;
  final List<String> assetIds;

  const PhoneAlbumMeta({
    required this.id,
    required this.name,
    this.kind = 'regular',
    this.smart,
    this.assetIds = const [],
  });

  static PhoneAlbumMeta? fromMap(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final id = raw['id'];
    if (id is! String) {
      return null;
    }
    return PhoneAlbumMeta(
      id: id,
      name: (raw['name'] is String ? raw['name'] as String : '').trim(),
      kind: raw['kind'] is String ? raw['kind'] as String : 'regular',
      smart: raw['smart'] is String ? raw['smart'] as String : null,
      assetIds: (raw['assets'] as List<dynamic>? ?? const []).whereType<String>().toList(),
    );
  }
}

class ServerAlbumRef {
  final String id;
  final String name;
  final Set<String> assetIds;

  const ServerAlbumRef({required this.id, required this.name, this.assetIds = const {}});
}

class AlbumPlan {
  final PhoneAlbumMeta album;

  /// Lower-cased trimmed name: phone albums with the same key share one server album.
  final String targetKey;

  /// Existing server album to extend; null = create one (unless [skipReason] is set).
  final String? serverAlbumId;
  final bool reused;

  /// Server asset ids to add (matched, not already in the target, not added by an earlier plan for the same target).
  final List<String> toAdd;
  final int onPhone;
  final int matched;
  final int alreadyThere;
  final int iCloudOnly;
  final int ambiguous;
  final int notInLibrary;
  final int noMatch;

  /// Why nothing is sent: 'excluded', 'empty', 'no matches', 'iCloud-only', 'ambiguous', 'not in library'.
  final String? skipReason;

  const AlbumPlan({
    required this.album,
    required this.targetKey,
    this.serverAlbumId,
    this.reused = false,
    this.toAdd = const [],
    this.onPhone = 0,
    this.matched = 0,
    this.alreadyThere = 0,
    this.iCloudOnly = 0,
    this.ambiguous = 0,
    this.notInLibrary = 0,
    this.noMatch = 0,
    this.skipReason,
  });

  bool get skipped => skipReason != null;

  bool get creates => !skipped && serverAlbumId == null && toAdd.isNotEmpty;

  String get kindLabel => album.kind == 'smart' ? 'smart:${album.smart ?? '?'}' : album.kind;

  /// One tab-separated report line; [added] is what the server actually accepted.
  String reportLine({int? added, String? error}) {
    final unmatched = [
      if (iCloudOnly > 0) '$iCloudOnly iCloud-only',
      if (ambiguous > 0) '$ambiguous ambiguous',
      if (notInLibrary > 0) '$notInLibrary not in library',
      if (noMatch > 0) '$noMatch no match',
    ].join(', ');
    final String status;
    if (error != null) {
      status = 'ERROR $error';
    } else if (skipped) {
      status = 'skipped: $skipReason';
    } else if (toAdd.isEmpty) {
      status = 'up to date';
    } else {
      status = serverAlbumId == null ? 'created' : 'reused';
    }
    return [
      album.name.isEmpty ? '(no name)' : album.name,
      kindLabel,
      '$onPhone on phone',
      '$matched matched',
      '${added ?? 0} added',
      '$alreadyThere already there',
      status,
      if (unmatched.isNotEmpty) 'unmatched: $unmatched',
    ].join('\t');
  }
}

bool isAlbumExcluded(PhoneAlbumMeta a) =>
    a.kind == 'smart' &&
    (a.smart == null || kSmartAlbumsExcluded.contains(a.smart) || !kSmartAlbumsSynced.contains(a.smart));

String albumKey(String name) => name.trim().toLowerCase();

/// [remoteOf]: phone asset id -> matched server asset id (library assets and resolved album-only assets).
/// [iCloudOnlyIds]: phone assets whose original is not on the phone. [ambiguousIds]: matcher said ambiguous.
/// [notInLibraryIds]: album-only assets (shared / synced) that could not be resolved.
/// [remembered]: target key -> server album id created by an earlier (possibly interrupted) run.
List<AlbumPlan> planAlbums({
  required List<PhoneAlbumMeta> albums,
  required Map<String, String> remoteOf,
  required List<ServerAlbumRef> serverAlbums,
  Set<String> iCloudOnlyIds = const {},
  Set<String> ambiguousIds = const {},
  Set<String> notInLibraryIds = const {},
  Map<String, String> remembered = const {},
}) {
  final plans = <AlbumPlan>[];
  final serverById = {for (final s in serverAlbums) s.id: s};
  // Per target: ids already planned by an earlier phone album with the same name.
  final planned = <String, Set<String>>{};
  final chosen = <String, String?>{};

  for (final a in albums) {
    final key = albumKey(a.name);
    if (isAlbumExcluded(a)) {
      plans.add(AlbumPlan(album: a, targetKey: key, onPhone: a.assetIds.length, skipReason: 'excluded'));
      continue;
    }
    if (key.isEmpty) {
      plans.add(AlbumPlan(album: a, targetKey: key, onPhone: a.assetIds.length, skipReason: 'no name'));
      continue;
    }
    final phoneIds = a.assetIds.toSet();
    final matchedRemote = <String>{};
    var iCloud = 0;
    var amb = 0;
    var notLib = 0;
    var none = 0;
    for (final id in phoneIds) {
      final r = remoteOf[id];
      if (r != null) {
        matchedRemote.add(r);
      } else if (ambiguousIds.contains(id)) {
        amb++;
      } else if (iCloudOnlyIds.contains(id)) {
        iCloud++;
      } else if (notInLibraryIds.contains(id)) {
        notLib++;
      } else {
        none++;
      }
    }
    final matchedCount = phoneIds.length - iCloud - amb - notLib - none;

    if (matchedRemote.isEmpty) {
      final String reason;
      if (phoneIds.isEmpty) {
        reason = 'empty';
      } else if (iCloud == phoneIds.length) {
        reason = 'iCloud-only';
      } else if (amb == phoneIds.length) {
        reason = 'ambiguous';
      } else if (notLib == phoneIds.length) {
        reason = 'not in library';
      } else {
        reason = 'no matches';
      }
      plans.add(
        AlbumPlan(
          album: a,
          targetKey: key,
          onPhone: phoneIds.length,
          iCloudOnly: iCloud,
          ambiguous: amb,
          notInLibrary: notLib,
          noMatch: none,
          skipReason: reason,
        ),
      );
      continue;
    }

    final String? targetId;
    if (chosen.containsKey(key)) {
      targetId = chosen[key];
    } else {
      targetId = _pickServerAlbum(a.name, matchedRemote, serverAlbums) ?? remembered[key];
      chosen[key] = targetId;
    }
    final existing = targetId == null ? const <String>{} : (serverById[targetId]?.assetIds ?? const <String>{});
    final already = planned.putIfAbsent(key, () => {});
    final toAdd = matchedRemote.where((r) => !existing.contains(r) && !already.contains(r)).toList()..sort();
    already.addAll(toAdd);
    plans.add(
      AlbumPlan(
        album: a,
        targetKey: key,
        serverAlbumId: targetId,
        reused: targetId != null,
        toAdd: toAdd,
        onPhone: phoneIds.length,
        matched: matchedCount,
        alreadyThere: matchedRemote.where(existing.contains).length,
        iCloudOnly: iCloud,
        ambiguous: amb,
        notInLibrary: notLib,
        noMatch: none,
      ),
    );
  }
  return plans;
}

String? _pickServerAlbum(String name, Set<String> matched, List<ServerAlbumRef> serverAlbums) {
  final trimmed = name.trim();
  var candidates = serverAlbums.where((s) => s.name.trim() == trimmed).toList();
  if (candidates.isEmpty) {
    candidates = serverAlbums.where((s) => albumKey(s.name) == albumKey(trimmed)).toList();
  }
  if (candidates.isEmpty) {
    return null;
  }
  int overlap(ServerAlbumRef s) => matched.where(s.assetIds.contains).length;
  candidates.sort((x, y) {
    final o = overlap(y).compareTo(overlap(x));
    if (o != 0) {
      return o;
    }
    final n = y.assetIds.length.compareTo(x.assetIds.length);
    return n != 0 ? n : x.id.compareTo(y.id);
  });
  return candidates.first.id;
}

/// Album-only assets (in shared or computer-synced albums, not in the library fetch) have their own ids and
/// re-encoded files, so they are resolved by original file name + media type + capture second only, and only
/// when exactly one library asset (already matched) or exactly one server asset fits. Returns phone id -> server id.
Map<String, String> resolveAlbumOnlyAssets({
  required List<PhoneAssetMeta> albumOnly,
  required List<PhoneAssetMeta> library,
  required Map<String, String> remoteOf,
  required List<ServerAssetMeta> server,
}) {
  String? keyOf(String? name, int type, int? t) =>
      name == null || name.isEmpty || t == null ? null : '${name.toLowerCase()}|$type|$t';
  final libByKey = <String, List<PhoneAssetMeta>>{};
  for (final p in library) {
    final k = keyOf(p.name, p.type, p.createdSec);
    if (k != null) {
      libByKey.putIfAbsent(k, () => []).add(p);
    }
  }
  final serverByKey = <String, Set<String>>{};
  for (final s in server) {
    for (final t in {?s.createdSec, ?s.altCreatedSec}) {
      serverByKey.putIfAbsent('${s.name.toLowerCase()}|${s.type}|$t', () => {}).add(s.id);
    }
  }
  final out = <String, String>{};
  for (final p in albumOnly) {
    final k = keyOf(p.name, p.type, p.createdSec);
    if (k == null) {
      continue;
    }
    final libs = libByKey[k] ?? const [];
    if (libs.length == 1 && remoteOf[libs.first.id] != null) {
      out[p.id] = remoteOf[libs.first.id]!;
      continue;
    }
    if (libs.length > 1) {
      continue;
    }
    final srv = serverByKey[k] ?? const {};
    if (srv.length == 1) {
      out[p.id] = srv.first;
    }
  }
  return out;
}
