import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart' hide Store;
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/library_link.service.dart';
import 'package:immich_mobile/domain/services/sync_linked_album.service.dart';
import 'package:immich_mobile/domain/utils/mirror_sync_planner.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:immich_mobile/utils/fork_native.dart';
import 'package:immich_mobile/utils/hooks/app_settings_update_hook.dart';
import 'package:immich_ui/immich_ui.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Fork (mandeep/photos): "Back up photos from" date. Older assets are never uploaded.
class _BackupFromDateSetting extends HookWidget {
  const _BackupFromDateSetting();

  @override
  Widget build(BuildContext context) {
    final fromMs = useState<int>(Store.get(StoreKey.backupFromDateMs, 0));

    Future<void> save(int value) async {
      fromMs.value = value;
      await Store.put(StoreKey.backupFromDateMs, value);
    }

    final from = fromMs.value > 0 ? DateTime.fromMillisecondsSinceEpoch(fromMs.value) : null;
    final label = from == null
        ? 'All photos (no date filter)'
        : '${from.year}-${from.month.toString().padLeft(2, '0')}-${from.day.toString().padLeft(2, '0')} onwards';

    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: Column(
        children: [
          SettingListTile(
            title: label,
            subtitle: 'Photos and videos taken before this date are not uploaded.',
            onTap: () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: from ?? startOfYear(now),
                firstDate: DateTime(1990),
                lastDate: now,
              );
              if (picked != null) {
                await save(DateTime(picked.year, picked.month, picked.day).millisecondsSinceEpoch);
              }
            },
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => save(startOfYear(DateTime.now()).millisecondsSinceEpoch),
                child: const Text('Only this year'),
              ),
              TextButton(onPressed: () => save(0), child: const Text('Clear')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Fork (mandeep/photos): iOS two-way mirror switches.
class _MirrorSettings extends HookWidget {
  const _MirrorSettings();

  @override
  Widget build(BuildContext context) {
    final serverDeletes = useAppSettingsState(AppSettingsEnum.mirrorServerDeletes);
    final favorites = useAppSettingsState(AppSettingsEnum.mirrorFavorites);
    return Column(
      children: [
        SettingsSwitchListTile(
          valueNotifier: serverDeletes,
          title: 'Server deletes reach this iPhone',
          subtitle: 'Asks once, then removes the photos (they go to Recently Deleted).',
        ),
        const ListTile(
          title: Text('Deleting in the iPhone Photos app'),
          subtitle: Text(
            'Only frees space on this iPhone. Server and archive copies stay. Delete in this app to remove a photo everywhere.',
          ),
        ),
        const _LinkLibraryTile(),
        SettingsSwitchListTile(
          valueNotifier: favorites,
          title: 'Sync favourites both ways',
          subtitle: 'The latest favourite change on either side wins.',
        ),
      ],
    );
  }
}

/// Fork (mandeep/photos), 11 Nov: pair the iPhone library with the server by metadata (no hashing, no iCloud
/// downloads), then copy phone albums and Favourites to the server. Backup is not touched.
class _LinkLibraryTile extends HookConsumerWidget {
  const _LinkLibraryTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = useState(false);
    final status = useState('');
    final gate = useState('');

    Future<void> refresh() async {
      final user = Store.tryGet(StoreKey.currentUser);
      if (user == null) {
        return;
      }
      final state = await LibraryLinkService.loadState(user.id);
      gate.value = state.gateText;
      if (status.value.isEmpty) {
        status.value = state.summary;
      }
    }

    useEffect(() {
      unawaited(refresh());
      return null;
    }, const []);

    Future<void> run() async {
      running.value = true;
      // photos-v4: keep the screen from auto-locking while linking, and ask iOS for background time if the
      // phone is locked or the app is left anyway. The pass is additive and remembers created albums, so if
      // iOS still stops it, tapping Link library again resumes without duplicates.
      unawaited(WakelockPlus.enable());
      try {
        // Make sure the app's copy of the server and phone libraries is current first.
        status.value = 'Syncing with the server...';
        final sync = ref.read(backgroundSyncProvider);
        await sync.syncLocal();
        await sync.syncRemote();
        await ForkNative.withBackgroundTime(() => ref.read(libraryLinkServiceProvider).link((s) => status.value = s));
      } catch (e) {
        status.value = 'Link failed: $e (tap Link library again to resume; nothing is duplicated)';
      } finally {
        unawaited(WakelockPlus.disable());
        running.value = false;
        await refresh();
      }
    }

    Future<void> share() async {
      final file = await LibraryLinkService.reportFile();
      if (!file.existsSync() || !context.mounted) {
        return;
      }
      final size = MediaQuery.of(context).size;
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Immich link report',
        sharePositionOrigin: Rect.fromPoints(Offset.zero, Offset(size.width / 3, size.height)),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Link library', style: TextStyle(fontWeight: FontWeight.bold)),
          const Text(
            'Pairs this iPhone\'s photos with the server copies by name, date and size (no downloads, '
            'Backup stays off), then copies all your albums (own, shared, synced, Selfies, Screenshots, Videos...) and Favourites to the server. (photos-v4)',
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              ElevatedButton(
                onPressed: running.value ? null : run,
                child: Text(running.value ? 'Linking...' : 'Link library'),
              ),
              const SizedBox(width: 12),
              TextButton(onPressed: running.value ? null : share, child: const Text('Share report')),
            ],
          ),
          if (status.value.isNotEmpty) Text(status.value),
          if (gate.value.isNotEmpty) Text(gate.value, style: const TextStyle(fontStyle: FontStyle.italic)),
        ],
      ),
    );
  }
}

class BackupSettings extends StatelessWidget {
  const BackupSettings({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsSubPageScaffold(
      settings: [
        SettingGroupTitle(title: context.t.network_requirements, icon: Icons.cell_tower),
        const _UseCellularForVideosButton(),
        const _UseCellularForPhotosButton(),
        if (CurrentPlatform.isAndroid) ...[
          const Divider(),
          SettingGroupTitle(title: context.t.background_options, icon: Icons.charging_station_rounded),
          const _BackupOnlyWhenChargingButton(),
          const _BackupDelaySlider(),
        ],
        const Divider(),
        SettingGroupTitle(title: context.t.backup_albums_sync, icon: Icons.sync),
        const _AlbumSyncActionButton(),
        // Fork (mandeep/photos)
        const Divider(),
        const SettingGroupTitle(title: 'Back up photos from', icon: Icons.date_range),
        const _BackupFromDateSetting(),
        if (CurrentPlatform.isIOS) ...[
          const Divider(),
          const SettingGroupTitle(title: 'iPhone mirror', icon: Icons.sync_alt),
          const _MirrorSettings(),
        ],
      ],
    );
  }
}

class _AlbumSyncActionButton extends ConsumerStatefulWidget {
  const _AlbumSyncActionButton();

  @override
  ConsumerState<_AlbumSyncActionButton> createState() => _AlbumSyncActionButtonState();
}

class _AlbumSyncActionButtonState extends ConsumerState<_AlbumSyncActionButton> {
  bool isAlbumSyncInProgress = false;

  Future<void> _manualSyncAlbums() async {
    setState(() {
      isAlbumSyncInProgress = true;
    });

    try {
      final backgroundSync = ref.read(backgroundSyncProvider);
      await backgroundSync.syncLinkedAlbum();
      await backgroundSync.syncRemote();
    } catch (_) {
    } finally {
      Future.delayed(const Duration(seconds: 1), () {
        if (!mounted) {
          return;
        }
        setState(() {
          isAlbumSyncInProgress = false;
        });
      });
    }
  }

  Future<void> _manageLinkedAlbums() async {
    final currentUser = ref.read(currentUserProvider);
    if (currentUser == null) {
      return;
    }
    final localAlbums = ref.read(backupAlbumProvider);
    final selectedBackupAlbums = localAlbums
        .where((album) => album.backupSelection == BackupSelection.selected)
        .toList();

    await ref.read(syncLinkedAlbumServiceProvider).manageLinkedAlbums(selectedBackupAlbums, currentUser.id);
  }

  @override
  Widget build(BuildContext context) {
    final albumSyncEnable = ref.watch(appConfigProvider.select((c) => c.backup.syncAlbums));
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: ListView(
        shrinkWrap: true,
        children: [
          Column(
            children: [
              SettingListTile(
                title: context.t.sync_albums,
                subtitle: context.t.sync_upload_album_setting_subtitle,
                trailing: Switch(
                  value: albumSyncEnable,
                  onChanged: (bool newValue) async {
                    await ref.read(settingsProvider).write(.backupSyncAlbums, newValue);

                    if (newValue == true) {
                      await _manageLinkedAlbums();
                    }
                  },
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: albumSyncEnable ? 1.0 : 0.0,
                  child: albumSyncEnable
                      ? SettingListTile(
                          onTap: _manualSyncAlbums,
                          contentPadding: const EdgeInsets.only(left: 32, right: 16),
                          title: context.t.organize_into_albums,
                          subtitle: context.t.organize_into_albums_description,
                          trailing: isAlbumSyncInProgress
                              ? const SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                                )
                              : IconButton(
                                  onPressed: _manualSyncAlbums,
                                  icon: const Icon(Icons.sync_rounded),
                                  color: context.colorScheme.onSurface.withValues(alpha: 0.7),
                                  iconSize: 20,
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BackupSwitchTile extends ConsumerWidget {
  final SettingsKey<bool> metadataKey;
  final bool Function(AppConfig) selector;
  final String title;
  final String subtitle;
  final void Function(bool)? onChanged;

  const _BackupSwitchTile({
    required this.metadataKey,
    required this.selector,
    required this.title,
    required this.subtitle,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(appConfigProvider.select(selector));
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: SettingListTile(
        title: title,
        subtitle: subtitle,
        trailing: Switch(
          value: value,
          onChanged: (bool newValue) async {
            await ref.read(settingsProvider).write(metadataKey, newValue);
            onChanged?.call(newValue);
          },
        ),
      ),
    );
  }
}

class _UseCellularForVideosButton extends StatelessWidget {
  const _UseCellularForVideosButton();

  @override
  Widget build(BuildContext context) {
    return _BackupSwitchTile(
      metadataKey: SettingsKey.backupUseCellularForVideos,
      selector: (c) => c.backup.useCellularForVideos,
      title: context.t.videos,
      subtitle: context.t.network_requirement_videos_upload,
    );
  }
}

class _UseCellularForPhotosButton extends StatelessWidget {
  const _UseCellularForPhotosButton();

  @override
  Widget build(BuildContext context) {
    return _BackupSwitchTile(
      metadataKey: SettingsKey.backupUseCellularForPhotos,
      selector: (c) => c.backup.useCellularForPhotos,
      title: context.t.photos,
      subtitle: context.t.network_requirement_photos_upload,
    );
  }
}

class _BackupOnlyWhenChargingButton extends ConsumerWidget {
  const _BackupOnlyWhenChargingButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fgService = ref.watch(backgroundWorkerFgServiceProvider);
    return _BackupSwitchTile(
      metadataKey: SettingsKey.backupRequireCharging,
      selector: (c) => c.backup.requireCharging,
      title: context.t.charging,
      subtitle: context.t.charging_requirement_mobile_backup,
      onChanged: (value) {
        unawaited(fgService.configure(requireCharging: value));
      },
    );
  }
}

class _BackupDelaySlider extends ConsumerWidget {
  const _BackupDelaySlider();

  static int backupDelayToSliderValue(int ms) => switch (ms) {
    5 => 0,
    30 => 1,
    120 => 2,
    _ => 3,
  };

  static int backupDelayToSeconds(int v) => switch (v) {
    0 => 5,
    1 => 30,
    2 => 120,
    _ => 600,
  };

  static String formatBackupDelaySliderValue(BuildContext context, int v) => switch (v) {
    0 => context.t.setting_notifications_notify_seconds(count: 5),
    1 => context.t.setting_notifications_notify_seconds(count: 30),
    2 => context.t.setting_notifications_notify_minutes(count: 2),
    _ => context.t.setting_notifications_notify_minutes(count: 10),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final triggerDelay = ref.watch(appConfigProvider.select((c) => c.backup.triggerDelay));
    final currentValue = backupDelayToSliderValue(triggerDelay);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 24.0, top: 8.0),
          child: Text(
            context.t.backup_controller_page_background_delay(
              duration: formatBackupDelaySliderValue(context, currentValue),
            ),
            style: context.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
          ),
        ),
        Slider(
          value: currentValue.toDouble(),
          onChanged: (double v) async {
            final seconds = backupDelayToSeconds(v.toInt());
            await ref.read(settingsProvider).write(SettingsKey.backupTriggerDelay, seconds);
          },
          onChangeEnd: (double v) async {
            final seconds = backupDelayToSeconds(v.toInt());
            await ref.read(settingsProvider).write(SettingsKey.backupTriggerDelay, seconds);
          },
          max: 3.0,
          min: 0.0,
          divisions: 3,
          label: formatBackupDelaySliderValue(context, currentValue),
        ),
      ],
    );
  }
}
