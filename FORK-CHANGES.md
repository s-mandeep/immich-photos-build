# CHANGES - branch mandeep/photos (fork of immich v3.3.6, mobile app, iOS)

Built 5 Nov 2026 by Manu (subagent), about 55 minutes. Not pushed anywhere; GitHub workflow not run.

## Features
1. **Server deletes reach the iPhone** (setting "Server deletes reach this iPhone", default on).
   After each successful sync + hashing (app start and resume), backed-up phone photos whose server copy is in
   the trash, or was permanently deleted while the phone copy is unchanged, are collected. One app dialog:
   "N photos deleted on the server: remove from this iPhone?". Remove -> one PhotoKit batch delete
   (`AssetMediaRepository.deleteAll`, existing code; iOS shows its own single confirmation, items go to Recently
   Deleted). Keep -> remembered, never asked again for those photos.
   v3.3.6 has this for Android only (`manageLocalMediaAndroid`, no prompt, needs MANAGE_MEDIA); its pieces were reused, its gates left alone.
2. **iPhone deletes reach the server** (setting "iPhone deletes reach the server", default on).
   Pairs remembered from the previous run whose phone asset disappeared (and PhotoKit confirms it is gone) are moved
   to the server trash (`AssetApiRepository.delete(ids, force: false)`, existing). More than 50 at once asks first.
   Skipped entirely without full photo-library access (limited access would look like mass deletion).
3. **Favourites both ways on every sync** (setting "Sync favourites both ways", default on).
   Per pair the last agreed favourite is stored. Phone changed -> server (bulk `update(isFavorite)`); server changed ->
   PhotoKit `isFavorite` for the whole batch in ONE `performChanges` block; both changed -> phone wins.
   First sighting: favourite on either side wins. Unrelated edits never flip a favourite (only a change from the
   stored value counts). If iOS refuses the change, the stored value is kept so it is retried, not reversed.
4. **"Back up photos from" date** (Backup settings): date picker, "Only this year", "Clear". Applied in
   `BackupRepository.getCandidates` (all foreground and background uploads) and `getAllCounts` (the counters).
5. **Secret header**: already in v3.3.6, nothing built. Settings > Advanced > Custom proxy headers; the headers are
   sent on every request (Dart and native URLSession, via `NetworkRepository.setHeaders`).

State for 1-3 lives in `mirror_state_USERID.json` in the app support folder (no database migration).

## Files
- new `mobile/lib/domain/utils/mirror_sync_planner.dart` - pure decision logic
- new `mobile/lib/domain/services/mirror_sync.service.dart` - runs the plan, dialogs, state file
- new `mobile/ios/Runner/Sync/MirrorApiImpl.swift` - method channel `immich.fork/mirror`: fullAccess, existing, setFavorite (batched)
- new `mobile/lib/utils/backup_date_filter.dart`, `mobile/test/unit/mirror_sync_planner_test.dart`
- new `.github/workflows/ios-unsigned.yml` - manual; mise + codegen, unit test, `flutter build ios --release --no-codesign`, zip Payload/Runner.app into `Runner-unsigned.ipa`, upload artifact
- changed `ios/Runner/AppDelegate.swift` (register channel), `domain/models/store.model.dart` (4 keys, ids 9001-9004),
  `services/app_settings.service.dart`, `infrastructure/repositories/backup.repository.dart`,
  `widgets/settings/backup_settings/backup_settings.dart`, `providers/app_life_cycle.provider.dart`,
  `pages/common/splash_screen.page.dart` (run the mirror after hashing)

## Checks done here (Windows VM, Flutter 3.47.2 in C:\flutter-sdk)
- `flutter pub get`: OK (with a placeholder for the generated openapi package).
- `flutter test test/unit/mirror_sync_planner_test.dart`: 15/15 passed (planner + date filter).
- `dart analyze` on changed files: no lint or type errors in the new code apart from those caused by code
  generation not being run here (Drift `.drift.dart`, freezed, translations, openapi need build_runner and the Java
  openapi generator). So the service, repository and settings code is NOT fully type-checked. `dart format`: clean.
- Swift not compiled (no Mac).

## Unverified - first CI run and a real iPhone needed
- Whole app compile (Dart with codegen, Swift) - first run of the workflow will tell. `macos-15` runner and
  `jdx/mise-action` choice is mine; upstream uses a private `xcode-27` runner, so Xcode version may need pinning.
- `navigatorKey.currentContext` for the dialog (auto_route root navigator).
- julianday() comparison on Drift's text dates in the date filter.
- iPhone: the single iOS delete confirmation; whether the favourite batch shows an iOS prompt; Recently Deleted;
  that iPhone deletes reach the server trash on next app open; favourites in both directions; date filter counts.
- Runs only when the app is opened/resumed (not in iOS background refresh).
- Suggested first test: a test album with 5 photos, back up, then trash 1 on the server, delete 1 on the phone,
  favourite 1 each side, reopen the app.
