// Fork (mandeep/photos): iOS two-way mirror between the iPhone library and the Immich server.
//  1. server trash/delete -> one prompt -> one PhotoKit batch delete (iOS confirms once; Recently Deleted)
//  2. (11 Nov) a delete in the native Photos app only frees phone storage: it never reaches the server.
//     Deleting inside this app trashes on the server and removes the phone copy (upstream delete action).
//  3. favourites both ways, last-seen value per asset so only real changes move
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/library_link.service.dart';
import 'package:immich_mobile/domain/utils/library_link_matcher.dart';
import 'package:immich_mobile/domain/utils/mirror_sync_planner.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/option.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

final mirrorSyncServiceProvider = Provider(
  (ref) => MirrorSyncService(
    db: ref.watch(driftProvider),
    assetApi: ref.watch(assetApiRepositoryProvider),
    media: ref.watch(assetMediaRepositoryProvider),
    contextGetter: () => ref.read(appRouterProvider).navigatorKey.currentContext,
  ),
);

class MirrorSyncService {
  static const _channel = MethodChannel('immich.fork/mirror');
  final Logger _log = Logger('MirrorSyncService');

  final Drift _db;
  final AssetApiRepository _assetApi;
  final AssetMediaRepository _media;
  final BuildContext? Function() _contextGetter;
  bool _running = false;

  MirrorSyncService({required this._db, required this._assetApi, required this._media, required this._contextGetter});

  MirrorOptions get _options => MirrorOptions(
    serverDeletes: Store.get(StoreKey.mirrorServerDeletes, true),
    phoneDeletes: false, // 11 Nov: native Photos deletes never reach the server
    favorites: Store.get(StoreKey.mirrorFavorites, true),
  );

  /// Run after a successful remote sync and hashing, on the main isolate.
  Future<void> run() async {
    if (!CurrentPlatform.isIOS || _running) {
      return;
    }
    final options = _options;
    if (!options.serverDeletes && !options.favorites) {
      return;
    }
    final user = Store.tryGet(StoreKey.currentUser);
    if (user == null) {
      return;
    }
    _running = true;
    try {
      final fullAccess = await _channel.invokeMethod<bool>('fullAccess') ?? false;
      if (!fullAccess) {
        _log.warning('Mirror skipped: no full photo library access');
        return;
      }
      await _run(user.id, options);
    } catch (e, s) {
      _log.severe('Mirror sync failed', e, s);
    } finally {
      _running = false;
    }
  }

  Future<void> _run(String userId, MirrorOptions options) async {
    final state = await _loadState(userId);
    final linked = await _linkedAssets(userId);
    final localRows = await _db.customSelect('SELECT id, checksum FROM local_asset_entity').get();
    final localChecksums = {for (final r in localRows) r.read<String>('id'): r.readNullable<String>('checksum')};
    final remoteRows = await _db
        .customSelect(
          'SELECT id FROM remote_asset_entity WHERE owner_id = ?1',
          variables: [Variable.withString(userId)],
        )
        .get();
    final remoteIds = remoteRows.map((r) => r.read<String>('id')).toSet();

    if (remoteIds.isEmpty && state.pairs.isNotEmpty) {
      _log.warning('Mirror skipped: remote asset table is empty (sync reset?)');
      return;
    }

    final plan = planMirror(
      linked: linked,
      previous: state.pairs,
      localIdsInDb: localChecksums.keys.toSet(),
      localChecksums: localChecksums,
      remoteIdsInDb: remoteIds,
      declined: state.declined,
      options: options,
    );
    final next = Map<String, MirrorPair>.of(plan.nextState);

    // Safety gate: pairs made from metadata (Link library) get server->phone deletes only after the 100-sample
    // hash check passed.
    final link = await LibraryLinkService.loadState(userId);
    if (link.gate != LinkGateStatus.passed && link.linkedLocalIds.isNotEmpty) {
      final held = plan.deleteOnPhone.where(link.linkedLocalIds.contains).length;
      if (held > 0) {
        _log.info('Mirror: $held server deletes held back for metadata-linked photos (hash check not passed)');
        plan.deleteOnPhone.removeWhere(link.linkedLocalIds.contains);
      }
    }

    // 3. Favourites.
    if (plan.serverFavorite.isNotEmpty) {
      await _assetApi.update(plan.serverFavorite, isFavorite: const Option.some(true));
      await _db.remoteAssetRepository.updateAssets(plan.serverFavorite, isFavorite: const Option.some(true));
    }
    if (plan.serverUnfavorite.isNotEmpty) {
      await _assetApi.update(plan.serverUnfavorite, isFavorite: const Option.some(false));
      await _db.remoteAssetRepository.updateAssets(plan.serverUnfavorite, isFavorite: const Option.some(false));
    }
    await _setPhoneFavorite(plan.phoneFavorite, true, next, state.pairs);
    await _setPhoneFavorite(plan.phoneUnfavorite, false, next, state.pairs);

    // 1. Server deletes -> one prompt -> one PhotoKit batch.
    final declined = state.declined.where(localChecksums.containsKey).toSet();
    if (plan.deleteOnPhone.isNotEmpty) {
      final n = plan.deleteOnPhone.length;
      final yes = await _ask('$n ${n == 1 ? 'photo' : 'photos'} deleted on the server: remove from this iPhone?');
      if (yes) {
        final deleted = await _media.deleteAll(plan.deleteOnPhone);
        if (deleted.isNotEmpty) {
          await _db.localAssetRepository.deleteAssets(deleted);
          for (final id in deleted) {
            next.remove(id);
          }
        }
      } else {
        declined.addAll(plan.deleteOnPhone);
      }
    }

    await _saveState(userId, _MirrorState(next, declined));
  }

  Future<void> _setPhoneFavorite(
    List<String> localIds,
    bool favorite,
    Map<String, MirrorPair> next,
    Map<String, MirrorPair> previous,
  ) async {
    if (localIds.isEmpty) {
      return;
    }
    final changed =
        (await _channel.invokeListMethod<String>('setFavorite', {'ids': localIds, 'favorite': favorite}) ?? []).toSet();
    await _db.batch((batch) {
      for (final id in changed) {
        batch.customStatement('UPDATE local_asset_entity SET is_favorite = ? WHERE id = ?', [favorite ? 1 : 0, id]);
      }
    });
    // Not applied (user refused or error): keep the old agreed value so it is retried, never flipped.
    for (final id in localIds.where((id) => !changed.contains(id))) {
      final old = previous[id];
      final cur = next[id];
      if (cur != null) {
        next[id] = cur.copyWith(favorite: old?.favorite ?? !favorite);
      }
    }
  }

  Future<List<LinkedAsset>> _linkedAssets(String userId) async {
    final rows = await _db
        .customSelect(
          '''
          SELECT lae.id AS local_id, rae.id AS remote_id, lae.checksum AS checksum,
                 lae.is_favorite AS local_fav, rae.is_favorite AS remote_fav,
                 rae.deleted_at IS NOT NULL AS trashed
          FROM local_asset_entity lae
          INNER JOIN remote_asset_entity rae ON rae.checksum = lae.checksum AND rae.owner_id = ?1
          WHERE lae.checksum IS NOT NULL
          ''',
          // 11 Nov: any phone asset with a checksum (hashed, or linked by Link library) is mirrored; Backup
          // album selection is no longer required, so Backup can stay off.
          variables: [Variable.withString(userId)],
        )
        .get();
    return rows
        .map(
          (r) => LinkedAsset(
            localId: r.read<String>('local_id'),
            remoteId: r.read<String>('remote_id'),
            checksum: r.read<String>('checksum'),
            localFavorite: r.read<bool>('local_fav'),
            remoteFavorite: r.read<bool>('remote_fav'),
            remoteTrashed: r.read<bool>('trashed'),
          ),
        )
        .toList();
  }

  Future<bool> _ask(String message) async {
    final context = _contextGetter();
    if (context == null || !context.mounted) {
      return false;
    }
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Immich'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    return result ?? false;
  }

  Future<File> _stateFile(String userId) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/mirror_state_$userId.json');
  }

  Future<_MirrorState> _loadState(String userId) async {
    try {
      final file = await _stateFile(userId);
      if (!file.existsSync()) {
        return _MirrorState({}, {});
      }
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final pairs = <String, MirrorPair>{};
      (json['pairs'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
        final p = MirrorPair.fromJson(k, v);
        if (p != null) {
          pairs[k] = p;
        }
      });
      final declined = (json['declined'] as List<dynamic>? ?? []).whereType<String>().toSet();
      return _MirrorState(pairs, declined);
    } catch (e) {
      _log.warning('Mirror state unreadable, starting fresh', e);
      return _MirrorState({}, {});
    }
  }

  Future<void> _saveState(String userId, _MirrorState state) async {
    final file = await _stateFile(userId);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'pairs': {for (final p in state.pairs.values) p.localId: p.toJson()},
        'declined': state.declined.toList(),
      }),
    );
    await tmp.rename(file.path);
  }
}

class _MirrorState {
  final Map<String, MirrorPair> pairs;
  final Set<String> declined;

  _MirrorState(this.pairs, this.declined);
}
