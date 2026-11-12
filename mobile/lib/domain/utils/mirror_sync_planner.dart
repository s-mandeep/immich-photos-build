// Fork (mandeep/photos): pure decision logic for the iOS two-way mirror.
// Kept free of Flutter, Drift and PhotoKit so it can be unit tested.

/// What the mirror remembers about one phone asset that was linked to a server asset.
class MirrorPair {
  final String localId;
  final String remoteId;
  final String checksum;

  /// Last favourite value both sides agreed on.
  final bool favorite;

  const MirrorPair({required this.localId, required this.remoteId, required this.checksum, required this.favorite});

  MirrorPair copyWith({bool? favorite}) =>
      MirrorPair(localId: localId, remoteId: remoteId, checksum: checksum, favorite: favorite ?? this.favorite);

  Map<String, Object?> toJson() => {'r': remoteId, 'c': checksum, 'f': favorite};

  static MirrorPair? fromJson(String localId, Object? json) {
    if (json is! Map) {
      return null;
    }
    final remoteId = json['r'];
    final checksum = json['c'];
    final favorite = json['f'];
    if (remoteId is! String || checksum is! String || favorite is! bool) {
      return null;
    }
    return MirrorPair(localId: localId, remoteId: remoteId, checksum: checksum, favorite: favorite);
  }
}

/// A phone asset currently linked (same checksum) to one of the user's server assets.
class LinkedAsset {
  final String localId;
  final String remoteId;
  final String checksum;
  final bool localFavorite;
  final bool remoteFavorite;
  final bool remoteTrashed;

  const LinkedAsset({
    required this.localId,
    required this.remoteId,
    required this.checksum,
    required this.localFavorite,
    required this.remoteFavorite,
    required this.remoteTrashed,
  });
}

class MirrorPlan {
  /// Phone assets whose server copy is trashed or gone: ask, then delete from the phone.
  final List<String> deleteOnPhone = [];

  /// Always empty since 11 Nov (Mandeep's rule: deleting in the native Photos app only frees phone storage;
  /// the server and HDD copies stay). Kept so callers and tests can assert it.
  final List<String> trashOnServer = [];

  /// Remote ids to favourite / unfavourite on the server.
  final List<String> serverFavorite = [];
  final List<String> serverUnfavorite = [];

  /// Local ids to favourite / unfavourite on the phone.
  final List<String> phoneFavorite = [];
  final List<String> phoneUnfavorite = [];

  /// The state to save once the plan has been applied (pairs keyed by local id).
  final Map<String, MirrorPair> nextState = {};

  bool get isEmpty =>
      deleteOnPhone.isEmpty &&
      trashOnServer.isEmpty &&
      serverFavorite.isEmpty &&
      serverUnfavorite.isEmpty &&
      phoneFavorite.isEmpty &&
      phoneUnfavorite.isEmpty;
}

class MirrorOptions {
  final bool serverDeletes;

  /// Ignored by the planner since 11 Nov: a phone-side disappearance never reaches the server.
  final bool phoneDeletes;
  final bool favorites;

  const MirrorOptions({this.serverDeletes = true, this.phoneDeletes = false, this.favorites = true});
}

/// Builds the plan.
///
/// [linked] - current phone/server links (phone asset still in the local DB, server asset still in the remote DB).
/// [previous] - the saved state from the last run, keyed by local id.
/// [localIdsInDb] - every local asset id currently in the local DB.
/// [localChecksums] - checksum per local id currently in the local DB (null when not hashed yet).
/// [remoteIdsInDb] - every server asset id of this user currently in the remote DB (trashed included).
/// [declined] - local ids the user already said "keep" for; never asked again.
MirrorPlan planMirror({
  required List<LinkedAsset> linked,
  required Map<String, MirrorPair> previous,
  required Set<String> localIdsInDb,
  required Map<String, String?> localChecksums,
  required Set<String> remoteIdsInDb,
  required Set<String> declined,
  MirrorOptions options = const MirrorOptions(),
}) {
  final plan = MirrorPlan();
  final linkedByLocal = <String, LinkedAsset>{};
  for (final asset in linked) {
    linkedByLocal.putIfAbsent(asset.localId, () => asset);
  }

  // 1. Pairs we knew about last time that are no longer linked.
  for (final pair in previous.values) {
    if (linkedByLocal.containsKey(pair.localId)) {
      continue;
    }
    final localPresent = localIdsInDb.contains(pair.localId);
    final remotePresent = remoteIdsInDb.contains(pair.remoteId);

    if (!localPresent && remotePresent) {
      // Deleted in the native Photos app: only frees phone storage. The server copy stays; forget the pair.
      continue;
    }

    if (localPresent && !remotePresent) {
      // Gone from the server (permanently deleted). Only act if the phone asset is unchanged.
      final checksum = localChecksums[pair.localId];
      if (checksum == pair.checksum && options.serverDeletes && !declined.contains(pair.localId)) {
        plan.deleteOnPhone.add(pair.localId);
        plan.nextState[pair.localId] = pair; // keep until the phone copy is really gone
      }
      continue;
    }
    // Both gone, or both present but unlinked (edited photo, new checksum): forget the pair.
  }

  // 2. Current links.
  for (final asset in linkedByLocal.values) {
    if (asset.remoteTrashed) {
      if (options.serverDeletes && !declined.contains(asset.localId)) {
        plan.deleteOnPhone.add(asset.localId);
      }
      // Keep the pair so a restore on the server is a no-op and a later purge is still recognised.
      final old = previous[asset.localId];
      plan.nextState[asset.localId] = MirrorPair(
        localId: asset.localId,
        remoteId: asset.remoteId,
        checksum: asset.checksum,
        favorite: old?.favorite ?? asset.localFavorite,
      );
      continue;
    }

    final old = previous[asset.localId];
    bool agreed;
    if (!options.favorites) {
      agreed = old?.favorite ?? asset.localFavorite;
    } else if (old == null || old.remoteId != asset.remoteId) {
      // First time we see this pair: a favourite on either side wins.
      agreed = asset.localFavorite || asset.remoteFavorite;
      _push(plan, asset, agreed);
    } else {
      final phoneChanged = asset.localFavorite != old.favorite;
      final serverChanged = asset.remoteFavorite != old.favorite;
      if (phoneChanged) {
        // Phone change wins when both changed (we cannot tell which was later; the phone is in hand).
        agreed = asset.localFavorite;
      } else if (serverChanged) {
        agreed = asset.remoteFavorite;
      } else {
        agreed = old.favorite;
      }
      _push(plan, asset, agreed);
    }

    plan.nextState[asset.localId] = MirrorPair(
      localId: asset.localId,
      remoteId: asset.remoteId,
      checksum: asset.checksum,
      favorite: agreed,
    );
  }

  return plan;
}

void _push(MirrorPlan plan, LinkedAsset asset, bool agreed) {
  if (asset.remoteFavorite != agreed) {
    (agreed ? plan.serverFavorite : plan.serverUnfavorite).add(asset.remoteId);
  }
  if (asset.localFavorite != agreed) {
    (agreed ? plan.phoneFavorite : plan.phoneUnfavorite).add(asset.localId);
  }
}

/// Start of the current year in local time, for the "only this year" shortcut.
DateTime startOfYear(DateTime now) => DateTime(now.year);
