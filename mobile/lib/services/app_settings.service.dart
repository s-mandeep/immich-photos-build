import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';

enum AppSettingsEnum<T> {
  advancedTroubleshooting<bool>(StoreKey.advancedTroubleshooting, false),
  manageLocalMediaAndroid<bool>(StoreKey.manageLocalMediaAndroid, false),
  enableHapticFeedback<bool>(StoreKey.enableHapticFeedback, true),
  readonlyModeEnabled<bool>(StoreKey.readonlyModeEnabled, false),
  // Fork (mandeep/photos): iOS two-way mirror, each on by default
  mirrorServerDeletes<bool>(StoreKey.mirrorServerDeletes, true),
  mirrorPhoneDeletes<bool>(StoreKey.mirrorPhoneDeletes, false), // unused since 11 Nov (never propagated),
  mirrorFavorites<bool>(StoreKey.mirrorFavorites, true);

  const AppSettingsEnum(this.storeKey, this.defaultValue);

  final StoreKey<T> storeKey;
  final T defaultValue;
}

class AppSettingsService {
  const AppSettingsService();
  T getSetting<T>(AppSettingsEnum<T> setting) {
    return Store.get(setting.storeKey, setting.defaultValue);
  }

  Future<void> setSetting<T>(AppSettingsEnum<T> setting, T value) {
    return Store.put(setting.storeKey, value);
  }
}
