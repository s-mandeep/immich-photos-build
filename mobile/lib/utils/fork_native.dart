// Fork (mandeep/photos): small native helpers for iOS background backup, on the fork's method channel
// (MirrorApiImpl.swift). Every call fails soft: off iOS or without the channel it returns null.
import 'package:flutter/services.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';

class ForkNative {
  static const _channel = MethodChannel('immich.fork/mirror');

  /// Free storage in bytes (volumeAvailableCapacityForImportantUsage), or null if unknown.
  static Future<int?> freeBytes() async {
    if (!CurrentPlatform.isIOS) {
      return null;
    }
    try {
      return await _channel.invokeMethod<int>('freeBytes');
    } catch (_) {
      return null;
    }
  }

  /// Runs [action] inside a UIApplication background task, so iOS gives the app about 30 s to finish
  /// it after the app is sent to the background or woken by the background URLSession.
  static Future<T> withBackgroundTime<T>(Future<T> Function() action) async {
    int? id;
    if (CurrentPlatform.isIOS) {
      try {
        id = await _channel.invokeMethod<int>('beginBackgroundTask');
      } catch (_) {}
    }
    try {
      return await action();
    } finally {
      if (id != null) {
        try {
          await _channel.invokeMethod('endBackgroundTask', id);
        } catch (_) {}
      }
    }
  }
}
