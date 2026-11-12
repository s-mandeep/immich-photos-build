# PLAN - Mandeep's Immich iOS fork (based on tag v3.3.6, commit 587f549)

Code: `immich/mobile` (Flutter). Branch `mandeep/photos`. iOS only; Android paths untouched.

## What v3.3.6 already has
- Android-only "sync remote deletions" (`StoreKey.manageLocalMediaAndroid`): `SyncStreamService._syncAssetTrashStatus/_syncAssetDeletion`
  and `LocalSyncService._syncTrashedAssets`. Every branch is gated on `CurrentPlatform.isAndroid` and MANAGE_MEDIA permission,
  and it deletes per sync batch with no prompt. Not reusable as-is on iOS (no trash API, no permission, needs a prompt),
  but its pieces are reused: `AssetMediaRepository.deleteAll` (PhotoKit batch delete via photo_manager `deleteWithIds`
  = one iOS confirmation), `LocalAssetRepository.deleteAssets`, `RemoteAssetRepository.trash/updateAssets`,
  `AssetApiRepository.delete(ids, false)` (server trash) and `.update(isFavorite:)` (bulk favourite).
- Favourites: `local_asset_entity.is_favorite` is kept current by the iOS delta sync (PHAsset change -> upsert);
  the server value is in `remote_asset_entity.is_favorite` via the sync stream. Only used at upload time today.
- Custom proxy headers: YES. Settings > Advanced > "Custom proxy headers" (`CustomProxyHeaderSettings`,
  `SettingsKey.networkCustomHeaders`), applied by `NetworkRepository.setHeaders` to every request (Dart and native).
  Feature 5 = documentation only.
- Backup candidates: `BackupRepository.getCandidates` + `getAllCounts` (Dart; used by foreground and background upload).

## Design
One new service, `MirrorSyncService` (lib/domain/services/mirror_sync.service.dart), run on the main isolate after a
successful remote sync + hashing (app resume and cold start), iOS only. Pure decision logic in
`lib/domain/utils/mirror_sync_planner.dart` (unit tested). State = JSON file in app support dir:
per local asset id -> {remoteId, checksum, fav (last agreed favourite)}, plus "declined" ids. No DB schema change
(avoids Drift migrations).

1. Server deletes -> iPhone: linked pairs whose remote is trashed, or state pairs whose remote row is gone while the local
   asset still has the same checksum. One dialog "N photos deleted on the server: remove from this iPhone?"; yes ->
   `deleteAll` (one PhotoKit batch; iOS shows its own confirmation; items go to Recently Deleted). No -> remembered, not re-asked.
2. iPhone deletes -> server: state pairs whose local id vanished from the DB and PhotoKit confirms missing -> server trash
   (`delete(ids, force:false)`). Safety: skipped without full photo access; more than 50 at once asks first.
3. Favourites: per pair compare phone L, server R, last-seen S. L!=S -> push L to server (bulk). R!=S -> set PhotoKit favourite
   (photo_manager `darwin.favoriteAsset`) and update local DB at once so a stale row cannot flip it back. New pair with L!=R -> true wins.
4. Date filter: `StoreKey.backupFromDateMs` (0 = off) used in `getCandidates` and `getAllCounts` (julianday compare).
   Backup settings page: date picker, "Only this year", "Clear".
5. Headers: documented only.
Settings: toggles for 1-3 (default on) in Backup settings, section "iPhone mirror (fork)".

## Risks
- No Flutter/iOS build here beyond analyze; Swift untouched. Codegen (openapi, drift, translations) only runs in CI,
  so new code uses no new codegen (plain strings, no new Drift accessor).
- Wrong deletion detection is the main risk -> conservative rules above + prompt for server deletes + cap for phone deletes.
- PhotoKit favourite change may itself show an iOS prompt per asset (unverified; needs a real iPhone).
- iCloud "Optimise storage" assets are fine (ids stay); limited photo access would look like deletions -> guarded.
