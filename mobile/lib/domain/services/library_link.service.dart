// Fork (mandeep/photos), 11 Nov: "Link library" - pair the iPhone library with the cable-imported server
// assets WITHOUT hashing and WITHOUT any iCloud download, then copy phone albums and Favourites to the server.
//
//  1. PhotoKit metadata only (native libraryMeta: localIdentifier, original file name, creation date,
//     pixel size, resource fileSize, local availability, isFavorite, user albums). No data request.
//  2. Exact, unique matches (library_link_matcher.dart). Ambiguous / unmatched / iCloud-only are listed in a report.
//  3. Matched pairs: the server checksum is written into local_asset_entity.checksum. The app links local and
//     remote assets ONLY by checksum (backup candidates, timeline merge, mirror_sync _linkedAssets), so the
//     pair now counts as backed up and the mirror can pair it.
//  4. Server albums named like the phone albums get the matched assets (create if missing; add only).
//     Server Favourites are set from phone Favourites (add only). Nothing is ever removed from the server.
//  5. Safety gate: automatic server->phone deletes for these pairs stay OFF until 100 pairs whose original is on
//     the phone hash (networkAccessAllowed=false) to exactly the server checksum.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/utils/library_album_planner.dart';
import 'package:immich_mobile/domain/utils/library_link_matcher.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/repositories/album_api_repository.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/utils/option.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

final libraryLinkServiceProvider = Provider(
  (ref) => LibraryLinkService(
    db: ref.watch(driftProvider),
    assetApi: ref.watch(assetApiRepositoryProvider),
    albumApi: ref.watch(albumApiRepositoryProvider),
  ),
);

/// Saved state of the link pass (per user), read by the mirror and the settings page.
class LibraryLinkState {
  final Set<String> linkedLocalIds;
  final int sampled;
  final int equal;
  final String summary;
  final DateTime? linkedAt;

  /// Album name key -> server album id created by Link library (so an interrupted run never creates twice).
  final Map<String, String> createdAlbums;

  const LibraryLinkState({
    this.createdAlbums = const {},
    this.linkedLocalIds = const {},
    this.sampled = 0,
    this.equal = 0,
    this.summary = '',
    this.linkedAt,
  });

  LinkGateStatus get gate => evaluateLinkGate(sampled: sampled, equal: equal);

  String get gateText => switch (gate) {
    LinkGateStatus.passed => 'Hash check PASSED ($equal/$sampled equal): deletes enabled for linked photos',
    LinkGateStatus.failed => 'Hash check FAILED (${sampled - equal} of $sampled differ): deletes stay OFF',
    LinkGateStatus.pending =>
      sampled == 0 && linkedLocalIds.isEmpty
          ? 'Not linked yet'
          : 'Hash check pending ($equal/$kLinkGateSample on-phone samples): deletes stay OFF',
  };

  Map<String, Object?> toJson() => {
    'linked': linkedLocalIds.toList(),
    'sampled': sampled,
    'equal': equal,
    'summary': summary,
    'linkedAt': linkedAt?.toIso8601String(),
    'createdAlbums': createdAlbums,
  };

  LibraryLinkState copyWith({Set<String>? linkedLocalIds, Map<String, String>? createdAlbums}) => LibraryLinkState(
    linkedLocalIds: linkedLocalIds ?? this.linkedLocalIds,
    sampled: sampled,
    equal: equal,
    summary: summary,
    linkedAt: linkedAt,
    createdAlbums: createdAlbums ?? this.createdAlbums,
  );

  static LibraryLinkState fromJson(Map<String, dynamic> json) => LibraryLinkState(
    linkedLocalIds: (json['linked'] as List<dynamic>? ?? []).whereType<String>().toSet(),
    sampled: json['sampled'] as int? ?? 0,
    equal: json['equal'] as int? ?? 0,
    summary: json['summary'] as String? ?? '',
    linkedAt: DateTime.tryParse(json['linkedAt'] as String? ?? ''),
    createdAlbums: {
      for (final e in (json['createdAlbums'] as Map<String, dynamic>? ?? const {}).entries)
        if (e.value is String) e.key: e.value as String,
    },
  );
}

class LibraryLinkService {
  static const _channel = MethodChannel('immich.fork/mirror');
  final Logger _log = Logger('LibraryLinkService');

  final Drift _db;
  final AssetApiRepository _assetApi;
  final AlbumApiRepository _albumApi;
  bool _running = false;

  LibraryLinkService({required this._db, required this._assetApi, required this._albumApi});

  static Future<File> _file(String userId, String suffix) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/library_link_$userId.$suffix');
  }

  static Future<File> reportFile() async {
    final user = Store.tryGet(StoreKey.currentUser);
    return _file(user?.id ?? 'none', 'report.txt');
  }

  static Future<LibraryLinkState> loadState(String userId) async {
    try {
      final f = await _file(userId, 'json');
      if (!f.existsSync()) {
        return const LibraryLinkState();
      }
      return LibraryLinkState.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return const LibraryLinkState();
    }
  }

  static Future<void> _saveState(String userId, LibraryLinkState state) async {
    final f = await _file(userId, 'json');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(state.toJson()));
    await tmp.rename(f.path);
  }

  /// Runs the whole pass. [progress] gets short status lines for the settings page.
  Future<LibraryLinkState> link(void Function(String) progress) async {
    final user = Store.tryGet(StoreKey.currentUser);
    if (user == null) {
      throw StateError('Not logged in');
    }
    if (_running) {
      throw StateError('Already running');
    }
    _running = true;
    try {
      final fullAccess = await _channel.invokeMethod<bool>('fullAccess') ?? false;
      if (!fullAccess) {
        throw StateError('Needs full photo library access (Settings > Privacy > Photos > Immich > Full Access)');
      }
      return await _link(user, progress);
    } finally {
      _running = false;
    }
  }

  Future<LibraryLinkState> _link(UserDto user, void Function(String) progress) async {
    final String userId = user.id;
    final previous = await loadState(userId);
    final sw = Stopwatch()..start();

    progress('Reading the iPhone library (metadata only, no downloads)...');
    final raw = await _channel.invokeMapMethod<String, dynamic>('libraryMeta') ?? {};
    final phone = (raw['assets'] as List<dynamic>? ?? []).map(PhoneAssetMeta.fromMap).nonNulls.toList();
    final phoneAlbums = (raw['albums'] as List<dynamic>? ?? []).map(PhoneAlbumMeta.fromMap).nonNulls.toList();
    final iCloudOnly = phone.where((p) => p.local == false).toList();
    _log.info('Link: ${phone.length} phone assets, ${phoneAlbums.length} albums, ${iCloudOnly.length} iCloud-only');

    progress('Reading ${phone.length} phone / server records...');
    final serverRows = await _db
        .customSelect(
          '''
          SELECT rae.id AS id, rae.name AS name, rae.type AS type, rae.created_at AS created_at,
                 rae.width AS width, rae.height AS height, rae.checksum AS checksum, rae.is_favorite AS fav,
                 rex.file_size AS file_size, rex.date_time_original AS dto
          FROM remote_asset_entity rae
          LEFT JOIN remote_exif_entity rex ON rex.asset_id = rae.id
          WHERE rae.owner_id = ?1 AND rae.deleted_at IS NULL
          ''',
          variables: [Variable.withString(userId)],
          readsFrom: {_db.remoteAssetEntity, _db.remoteExifEntity},
        )
        .get();
    if (serverRows.isEmpty) {
      throw StateError('No server assets in the app yet: wait for the sync to finish, then try again');
    }
    int? sec(DateTime? d) => d == null ? null : d.millisecondsSinceEpoch ~/ 1000;
    final server = serverRows
        .map(
          (r) => ServerAssetMeta(
            id: r.read<String>('id'),
            name: r.read<String>('name'),
            type: r.read<int>('type'),
            createdSec: sec(r.readNullable<DateTime>('created_at')),
            altCreatedSec: sec(r.readNullable<DateTime>('dto')),
            width: r.readNullable<int>('width'),
            height: r.readNullable<int>('height'),
            size: r.readNullable<int>('file_size'),
            checksum: r.read<String>('checksum'),
            favorite: r.read<bool>('fav'),
          ),
        )
        .toList();

    // Already paired by a real hash (the earlier backups): leave those alone on both sides.
    final localRows = await _db.customSelect('SELECT id, checksum FROM local_asset_entity').get();
    final localChecksum = {for (final r in localRows) r.read<String>('id'): r.readNullable<String>('checksum')};
    final usedChecksums = localChecksum.values.nonNulls.toSet();
    final phoneToMatch = phone.where((p) => localChecksum.containsKey(p.id) && localChecksum[p.id] == null).toList();
    final notInAppDb = phone.where((p) => !localChecksum.containsKey(p.id)).length;
    final serverToMatch = server.where((s) => !usedChecksums.contains(s.checksum)).toList();

    progress('Matching ${phoneToMatch.length} phone assets against ${serverToMatch.length} server assets...');
    final result = matchLibrary(phoneToMatch, serverToMatch);

    // 3. Write the server checksum into the phone asset records.
    final hashes = {for (final m in result.matches) m.phoneId: m.server.checksum};
    await _db.localAssetRepository.updateHashes(hashes);
    final linked = {...previous.linkedLocalIds.where(localChecksum.containsKey), ...hashes.keys};
    // Saved at once (photos-v4): if iOS stops the run after this point, the new metadata pairs are still held
    // back from server->phone deletes by the hash gate.
    var progressState = previous.copyWith(linkedLocalIds: linked);
    await _saveState(userId, progressState);

    // remote id per local id, for every pair (new metadata pairs + earlier hash pairs).
    final remoteByChecksum = {for (final s in server) s.checksum: s};
    final remoteOf = <String, ServerAssetMeta>{};
    for (final p in phone) {
      final c = hashes[p.id] ?? localChecksum[p.id];
      final s = c == null ? null : remoteByChecksum[c];
      if (s != null) {
        remoteOf[p.id] = s;
      }
    }

    // 4a. Favourites: phone favourite -> server favourite (add only).
    final toFavorite = phone
        .where((p) => p.favorite)
        .map((p) => remoteOf[p.id])
        .nonNulls
        .where((s) => !s.favorite)
        .map((s) => s.id)
        .toList();
    progress('Setting ${toFavorite.length} server Favourites...');
    for (var i = 0; i < toFavorite.length; i += 500) {
      final chunk = toFavorite.sublist(i, min(i + 500, toFavorite.length));
      await _assetApi.update(chunk, isFavorite: const Option.some(true));
      await _db.remoteAssetRepository.updateAssets(chunk, isFavorite: const Option.some(true));
    }

    // 4b. Albums (photos-v4): every phone album (regular, shared, synced, media-type smart albums) -> owned
    // server album of the same name (reused) or a new one; matched photos only; add only; every album reported.
    final albumOnly = (raw['albumOnly'] as List<dynamic>? ?? []).map(PhoneAssetMeta.fromMap).nonNulls.toList();
    final remoteIdOf = {for (final e in remoteOf.entries) e.key: e.value.id};
    final resolved = resolveAlbumOnlyAssets(albumOnly: albumOnly, library: phone, remoteOf: remoteIdOf, server: server);
    remoteIdOf.addAll(resolved);
    final albumOnlyICloud = {
      for (final p in albumOnly)
        if (p.local == false && !resolved.containsKey(p.id)) p.id,
    };
    final ownedRows = await _db
        .customSelect(
          '''
          SELECT ra.id AS id, ra.name AS name, raa.asset_id AS asset_id FROM remote_album_entity ra
          INNER JOIN remote_album_user_entity rau ON rau.album_id = ra.id AND rau.user_id = ?1 AND rau.role = ?2
          LEFT JOIN remote_album_asset_entity raa ON raa.album_id = ra.id
          ''',
          variables: [Variable.withString(userId), Variable.withInt(2)], // AlbumUserRole.owner
        )
        .get();
    final serverAlbumNames = <String, String>{};
    final serverAlbumAssets = <String, Set<String>>{};
    for (final r in ownedRows) {
      final id = r.read<String>('id');
      serverAlbumNames[id] = r.read<String>('name');
      final assetId = r.readNullable<String>('asset_id');
      final set = serverAlbumAssets.putIfAbsent(id, () => {});
      if (assetId != null) {
        set.add(assetId);
      }
    }
    final serverAlbums = [
      for (final e in serverAlbumNames.entries)
        ServerAlbumRef(id: e.key, name: e.value, assetIds: serverAlbumAssets[e.key] ?? const {}),
    ];
    // Albums this feature created earlier and that still exist (even if renamed on the server): reused, never
    // created twice. One deleted on the server is created again.
    final remembered = {
      for (final e in previous.createdAlbums.entries)
        if (serverAlbumNames.containsKey(e.value)) e.key: e.value,
    };
    final plans = planAlbums(
      albums: phoneAlbums,
      remoteOf: remoteIdOf,
      serverAlbums: serverAlbums,
      iCloudOnlyIds: {...iCloudOnly.map((p) => p.id), ...albumOnlyICloud},
      ambiguousIds: result.ambiguous.keys.toSet(),
      notInLibraryIds: {
        for (final p in albumOnly)
          if (!resolved.containsKey(p.id) && !albumOnlyICloud.contains(p.id)) p.id,
      },
      remembered: remembered,
    );
    final createdAlbums = {...previous.createdAlbums};
    final targetIdByKey = <String, String>{};
    final albumLines = <String>[];
    var albumAdds = 0;
    var albumsCreated = 0;
    var albumsReused = 0;
    for (final plan in plans) {
      if (plan.skipped) {
        albumLines.add(plan.reportLine());
        continue;
      }
      progress('Album "${plan.album.name}": ${plan.toAdd.length} to add (${plan.matched} of ${plan.onPhone} matched)');
      var added = 0;
      try {
        var albumId = plan.serverAlbumId ?? targetIdByKey[plan.targetKey];
        var start = 0;
        if (albumId == null && plan.toAdd.isNotEmpty) {
          final created = await _albumApi.createDriftAlbum(
            plan.album.name.trim(),
            user,
            assetIds: plan.toAdd.take(1000),
          );
          final String newId = created.id;
          albumId = newId;
          start = min(1000, plan.toAdd.length);
          added += start;
          albumsCreated++;
          createdAlbums[plan.targetKey] = newId;
          // Saved at once so an interrupted run reuses this album instead of creating a second one.
          progressState = progressState.copyWith(createdAlbums: {...createdAlbums});
          await _saveState(userId, progressState);
        } else if (albumId != null && plan.toAdd.isNotEmpty) {
          albumsReused++;
        }
        if (albumId != null) {
          targetIdByKey[plan.targetKey] = albumId;
        }
        for (var i = start; albumId != null && i < plan.toAdd.length; i += 1000) {
          final res = await _albumApi.addAssets(albumId, plan.toAdd.sublist(i, min(i + 1000, plan.toAdd.length)));
          added += res.added.length;
        }
        albumAdds += added;
        albumLines.add(plan.reportLine(added: added));
      } catch (e) {
        _log.warning('Album "${plan.album.name}" failed: $e');
        albumAdds += added;
        albumLines.add(plan.reportLine(added: added, error: '$e'.replaceAll(RegExp(r'\s+'), ' ')));
      }
    }
    final albumsSkipped = plans.where((p) => p.skipped && p.skipReason != 'excluded').length;
    final albumsExcluded = plans.where((p) => p.skipReason == 'excluded').length;

    // 5. Hash gate: 100 linked pairs whose original is on the phone; networkAccessAllowed=false.
    var sampled = previous.sampled;
    var equal = previous.equal;
    if (evaluateLinkGate(sampled: sampled, equal: equal) != LinkGateStatus.passed) {
      final onPhone = {
        for (final p in phone)
          if (p.local == true) p.id,
      };
      final candidates = result.matches.where((m) => onPhone.contains(m.phoneId)).toList()..shuffle(Random());
      final sample = candidates.take(kLinkGateSample).toList();
      progress('Hash check on ${sample.length} on-phone originals (no downloads)...');
      final got =
          await _channel.invokeMapMethod<String, String>('hashOriginals', {
            'ids': sample.map((m) => m.phoneId).toList(),
          }) ??
          {};
      final hashed = sample.where((m) => got.containsKey(m.phoneId)).toList();
      final same = hashed.where((m) => got[m.phoneId] == m.server.checksum).length;
      sampled = hashed.length;
      equal = same;
      for (final m in hashed.where((m) => got[m.phoneId] != m.server.checksum)) {
        _log.warning('Hash check mismatch: ${m.phoneId} -> ${m.server.id} ${m.server.name}');
      }
    }

    final shifted = result.matches.where((m) => m.shifted).length;
    final summary = [
      'Linked ${DateTime.now().toString().substring(0, 16)} in ${sw.elapsed.inSeconds}s',
      'Phone assets: ${phone.length} (iCloud-only originals: ${iCloudOnly.length}, never downloaded)',
      'Newly linked: ${result.matches.length} ($shifted via timezone shift); already backed up: ${phone.length - phoneToMatch.length - notInAppDb}',
      'Unmatched: ${result.unmatched.length}; ambiguous: ${result.ambiguous.length}; not yet in app DB: $notInAppDb',
      'Server Favourites set: ${toFavorite.length}',
      'Albums on phone: ${plans.length} ($albumsExcluded excluded smart albums); created: $albumsCreated; reused: $albumsReused; skipped: $albumsSkipped; photos added to albums: $albumAdds',
    ].join('\n');
    final state = LibraryLinkState(
      linkedLocalIds: linked,
      sampled: sampled,
      equal: equal,
      summary: summary,
      linkedAt: DateTime.now(),
      createdAlbums: createdAlbums,
    );
    await _saveState(userId, state);

    // Report (shareable from settings).
    final byId = {for (final p in phone) p.id: p};
    String describe(String id) {
      final p = byId[id];
      if (p == null) {
        return id;
      }
      final t = p.createdSec == null
          ? '-'
          : DateTime.fromMillisecondsSinceEpoch(p.createdSec! * 1000, isUtc: true).toIso8601String();
      return '${p.name}\t$t\t${p.width}x${p.height}\t${p.size ?? '-'}\t${p.local == false ? 'iCloud-only' : 'on phone'}';
    }

    final report = StringBuffer()
      ..writeln(summary)
      ..writeln(state.gateText)
      ..writeln('\n# ALBUMS (name, kind, on phone, matched, added, already there, status, unmatched)')
      ..writeAll(albumLines.map((l) => '$l\n'))
      ..writeln('\n# UNMATCHED (reason, name, time UTC, size px, bytes, where)')
      ..writeAll(result.unmatched.entries.map((e) => '${e.value}\t${describe(e.key)}\n'))
      ..writeln('\n# AMBIGUOUS (name, time, px, bytes, where, server candidates)')
      ..writeAll(result.ambiguous.entries.map((e) => '${describe(e.key)}\t${e.value.join(',')}\n'))
      ..writeln('\n# iCLOUD-ONLY ORIGINALS (not downloaded)')
      ..writeAll(iCloudOnly.map((p) => '${describe(p.id)}\n'));
    await (await _file(userId, 'report.txt')).writeAsString(report.toString());
    progress(summary);
    return state;
  }
}
