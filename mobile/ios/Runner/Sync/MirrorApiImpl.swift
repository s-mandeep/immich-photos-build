import CryptoKit
import Flutter
import Photos

/// Fork (mandeep/photos): small PhotoKit helpers for the two-way mirror.
/// Plain method channel so no Pigeon codegen is needed.
///  - fullAccess -> Bool: whether the app has full (not limited) photo library access
///  - existing {ids: [String]} -> [String]: the ids that still exist in the library
///  - setFavorite {ids: [String], favorite: Bool} -> [String]: ids changed, in ONE performChanges
///    block so iOS asks at most once for the whole batch.
class MirrorApiImpl: NSObject {
  static let channelName = "immich.fork/mirror"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "fullAccess":
        result(PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized)
      case "existing":
        let args = call.arguments as? [String: Any]
        let ids = args?["ids"] as? [String] ?? []
        DispatchQueue.global(qos: .utility).async {
          let found = MirrorApiImpl.existing(ids: ids)
          DispatchQueue.main.async { result(found) }
        }
      case "setFavorite":
        let args = call.arguments as? [String: Any]
        let ids = args?["ids"] as? [String] ?? []
        let favorite = args?["favorite"] as? Bool ?? false
        MirrorApiImpl.setFavorite(ids: ids, favorite: favorite) { changed in
          DispatchQueue.main.async { result(changed) }
        }
      // Fork background backup: free storage for batch sizing, and background time for the hand-off
      // to the background URLSession when the app leaves the foreground.
      case "freeBytes":
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        result(values?.volumeAvailableCapacityForImportantUsage.map { Int($0) })
      case "beginBackgroundTask":
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: "immich.fork.backup") {
          UIApplication.shared.endBackgroundTask(taskId)
        }
        result(taskId.rawValue)
      case "endBackgroundTask":
        if let raw = call.arguments as? Int, raw != UIBackgroundTaskIdentifier.invalid.rawValue {
          UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: raw))
        }
        result(nil)
      // Fork library link (11 Nov): metadata only, never downloads from iCloud.
      case "libraryMeta":
        DispatchQueue.global(qos: .userInitiated).async {
          let meta = MirrorApiImpl.libraryMeta()
          DispatchQueue.main.async { result(meta) }
        }
      case "hashOriginals":
        let args = call.arguments as? [String: Any]
        let ids = args?["ids"] as? [String] ?? []
        DispatchQueue.global(qos: .userInitiated).async {
          let hashes = MirrorApiImpl.hashOriginals(ids: ids)
          DispatchQueue.main.async { result(hashes) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// The original (unedited) resource: what a cable import copies off the phone.
  static func originalResource(for asset: PHAsset) -> PHAssetResource? {
    let resources = PHAssetResource.assetResources(for: asset)
    let wanted: [PHAssetResourceType] = asset.mediaType == .video ? [.video] : [.photo]
    if let r = resources.first(where: { wanted.contains($0.type) }) { return r }
    return asset.getResource()
  }

  /// Every asset's metadata plus the user's own albums. Reads PhotoKit's local database only:
  /// file size and local availability come from the resource's stored properties, no data request.
  private static func libraryMeta() -> [String: Any] {
    let options = PHFetchOptions()
    options.includeHiddenAssets = false
    let fetch = PHAsset.fetchAssets(with: options)
    var assets: [[String: Any]] = []
    assets.reserveCapacity(fetch.count)
    fetch.enumerateObjects { asset, _, _ in
      autoreleasepool {
        var m: [String: Any] = [
          "id": asset.localIdentifier,
          "type": asset.mediaType.rawValue,
          "w": asset.pixelWidth,
          "h": asset.pixelHeight,
          "fav": asset.isFavorite,
        ]
        if let d = asset.creationDate { m["t"] = Int64(floor(d.timeIntervalSince1970)) }
        if let r = MirrorApiImpl.originalResource(for: asset) {
          m["name"] = r.originalFilename
          if let size = r.value(forKey: "fileSize") as? NSNumber { m["size"] = size.int64Value }
          if let local = r.value(forKey: "locallyAvailable") as? NSNumber { m["local"] = local.boolValue }
        }
        assets.append(m)
      }
    }
    // photos-v4 (12 Nov): every album, like the stock app (.album and .smartAlbum, subtype .any): regular,
    // shared (iCloud), synced from a computer, imported, plus the media-type smart albums. Excluded smart albums
    // are still listed (kind "smart", their key) so the report can say why; their members are not read.
    var libraryIds = Set<String>()
    for m in assets { if let id = m["id"] as? String { libraryIds.insert(id) } }
    var albumOnly: [String: PHAsset] = [:]
    var albums: [[String: Any]] = []
    let memberOptions = PHFetchOptions()
    memberOptions.includeHiddenAssets = false
    for type in [PHAssetCollectionType.album, PHAssetCollectionType.smartAlbum] {
      let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
      collections.enumerateObjects { collection, _, _ in
        autoreleasepool {
          let (kind, smart) = MirrorApiImpl.albumKind(collection)
          var entry: [String: Any] = [
            "id": collection.localIdentifier,
            "name": collection.localizedTitle ?? "",
            "kind": kind,
          ]
          if let smart = smart { entry["smart"] = smart }
          var ids: [String] = []
          if kind != "smart" || MirrorApiImpl.syncedSmartKeys.contains(smart ?? "") {
            PHAsset.fetchAssets(in: collection, options: memberOptions).enumerateObjects { a, _, _ in
              ids.append(a.localIdentifier)
              if !libraryIds.contains(a.localIdentifier) && albumOnly[a.localIdentifier] == nil {
                albumOnly[a.localIdentifier] = a
              }
            }
          }
          entry["assets"] = ids
          albums.append(entry)
        }
      }
    }
    // Assets that live only in a shared / synced album (not in the library fetch): metadata only.
    var extra: [[String: Any]] = []
    for (_, asset) in albumOnly {
      autoreleasepool {
        var m: [String: Any] = [
          "id": asset.localIdentifier,
          "type": asset.mediaType.rawValue,
          "w": asset.pixelWidth,
          "h": asset.pixelHeight,
          "fav": false,
        ]
        if let d = asset.creationDate { m["t"] = Int64(floor(d.timeIntervalSince1970)) }
        if let r = MirrorApiImpl.originalResource(for: asset) {
          m["name"] = r.originalFilename
          if let size = r.value(forKey: "fileSize") as? NSNumber { m["size"] = size.int64Value }
          if let local = r.value(forKey: "locallyAvailable") as? NSNumber { m["local"] = local.boolValue }
        }
        extra.append(m)
      }
    }
    return ["assets": assets, "albums": albums, "albumOnly": extra]
  }

  /// Smart albums copied to the server (keys match library_album_planner.dart).
  static let syncedSmartKeys: Set<String> = [
    "selfies", "portraits", "panoramas", "screenshots", "livePhotos", "videos", "slomo", "timelapses",
    "bursts", "cinematic",
  ]

  /// (kind, smart key). Raw values so the code builds with any SDK (218 = smartAlbumCinematicVideos, iOS 16;
  /// 1000000201 = Recently Deleted and 1000000219 = Recovered are private subtypes).
  static func albumKind(_ c: PHAssetCollection) -> (String, String?) {
    let raw = c.assetCollectionSubtype.rawValue
    if c.assetCollectionType == .smartAlbum {
      switch raw {
      case 210: return ("smart", "selfies")
      case 212: return ("smart", "portraits")
      case 201: return ("smart", "panoramas")
      case 211: return ("smart", "screenshots")
      case 213: return ("smart", "livePhotos")
      case 202: return ("smart", "videos")
      case 208: return ("smart", "slomo")
      case 204: return ("smart", "timelapses")
      case 207: return ("smart", "bursts")
      case 218: return ("smart", "cinematic")
      case 209: return ("smart", "recents")
      case 203: return ("smart", "favorites")
      case 205: return ("smart", "hidden")
      case 206: return ("smart", "recentlyAdded")
      case 1000000201: return ("smart", "recentlyDeleted")
      default: return ("smart", "other\(raw)")
      }
    }
    switch raw {
    case 2: return ("regular", nil)  // albumRegular
    case 3, 4, 5, 6: return ("synced", nil)  // syncedEvent, syncedFaces, syncedAlbum, imported
    case 100, 101: return ("shared", nil)  // albumMyPhotoStream, albumCloudShared
    case 1000000219: return ("smart", "recovered")
    default: return ("regular", nil)
    }
  }

  /// SHA-1 (base64, like the server checksum) of each asset's ORIGINAL resource, only when it is on the phone:
  /// isNetworkAccessAllowed = false, so an iCloud-only original fails instead of downloading.
  private static func hashOriginals(ids: [String]) -> [String: String] {
    var out: [String: String] = [:]
    if ids.isEmpty { return out }
    let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
    var assets: [PHAsset] = []
    fetch.enumerateObjects { a, _, _ in assets.append(a) }
    for asset in assets {
      guard let resource = originalResource(for: asset) else { continue }
      let options = PHAssetResourceRequestOptions()
      options.isNetworkAccessAllowed = false
      let sem = DispatchSemaphore(value: 0)
      var hasher = Insecure.SHA1()
      var failed = false
      PHAssetResourceManager.default().requestData(
        for: resource, options: options,
        dataReceivedHandler: { data in hasher.update(data: data) },
        completionHandler: { error in
          failed = error != nil
          sem.signal()
        })
      if sem.wait(timeout: .now() + 120) == .timedOut { continue }
      if !failed { out[asset.localIdentifier] = Data(hasher.finalize()).base64EncodedString() }
    }
    return out
  }

  private static func existing(ids: [String]) -> [String] {
    if ids.isEmpty { return [] }
    let options = PHFetchOptions()
    options.includeHiddenAssets = true
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
    var found: [String] = []
    assets.enumerateObjects { asset, _, _ in found.append(asset.localIdentifier) }
    return found
  }

  private static func setFavorite(ids: [String], favorite: Bool, completion: @escaping ([String]) -> Void) {
    if ids.isEmpty { completion([]); return }
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
    var toChange: [PHAsset] = []
    assets.enumerateObjects { asset, _, _ in
      if asset.isFavorite != favorite { toChange.append(asset) }
    }
    if toChange.isEmpty { completion(ids); return }
    PHPhotoLibrary.shared().performChanges({
      for asset in toChange {
        PHAssetChangeRequest(for: asset).isFavorite = favorite
      }
    }) { success, error in
      if let error = error {
        print("MirrorApiImpl::setFavorite failed: \(error)")
      }
      completion(success ? ids : [])
    }
  }
}
