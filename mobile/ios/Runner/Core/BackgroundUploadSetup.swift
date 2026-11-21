import Foundation
import Photos

enum BackgroundUploadSetup {
  private static let baselineKey = "immich.background_upload.baseline"

  static var isConfigured: Bool {
    guard let server = Bundle.main.object(forInfoDictionaryKey: "ImmichBackgroundUploadServer") as? String,
          let host = URL(string: server)?.host
    else {
      return false
    }
    return !host.isEmpty
  }

  static func enableIfPossible() {
    guard #available(iOS 26.1, *), isConfigured,
          PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    else {
      return
    }

    if UserDefaults.group.object(forKey: baselineKey) == nil {
      UserDefaults.group.set(Date().timeIntervalSince1970, forKey: baselineKey)
    }

    let library = PHPhotoLibrary.shared()
    guard !library.uploadJobExtensionEnabled else { return }
    do {
      try library.setUploadJobExtensionEnabled(true)
    } catch {
      print("BackgroundUploadSetup: failed to enable the upload extension: \(error)")
    }
  }
}
