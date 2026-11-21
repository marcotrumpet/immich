import ExtensionFoundation
import Foundation
import Photos
import UniformTypeIdentifiers
import os.lock

@main
enum BackgroundUploadEntryPoint {
  static func main() throws {
    if #available(iOS 27.0, *) {
      try BackgroundUploadExtension.main()
    } else {
      try LegacyBackgroundUploadExtension.main()
    }
  }
}

@available(iOS 27.0, *)
final class BackgroundUploadExtension: PHBackgroundResourceUploadJobExtension {
  private let core = BackgroundUploadCore()

  required init() {}

  func processJobs() async -> PHBackgroundResourceUploadProcessingResult {
    core.run()
  }

  func willTerminate() async {
    core.cancel()
  }
}

@available(iOS, introduced: 26.1, obsoleted: 27.0)
final class LegacyBackgroundUploadExtension: PHBackgroundResourceUploadExtension {
  private let core = BackgroundUploadCore()

  required init() {}

  func process() -> PHBackgroundResourceUploadProcessingResult {
    core.run()
  }

  func notifyTermination() {
    core.cancel()
  }
}

struct BackgroundUploadConfig {
  static let baselineKey = "immich.background_upload.baseline"
  static let accessTokenCookie = "immich_access_token"

  let groupId: String
  let endpoint: URL
  let token: String
  let baseline: Date

  static func load() -> BackgroundUploadConfig? {
    guard let groupId = Bundle.main.object(forInfoDictionaryKey: "AppGroupId") as? String,
          let server = Bundle.main.object(forInfoDictionaryKey: "ImmichBackgroundUploadServer") as? String,
          let serverUrl = URL(string: server),
          let host = serverUrl.host, !host.isEmpty,
          let defaults = UserDefaults(suiteName: groupId),
          defaults.object(forKey: baselineKey) != nil,
          let token = accessToken(groupId: groupId, host: host)
    else {
      return nil
    }

    return BackgroundUploadConfig(
      groupId: groupId,
      endpoint: serverUrl.appending(path: "api/assets/background"),
      token: token,
      baseline: Date(timeIntervalSince1970: defaults.double(forKey: baselineKey))
    )
  }

  private static func accessToken(groupId: String, host: String) -> String? {
    let now = Date()
    let candidates = (HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: groupId).cookies ?? [])
      .filter { $0.name == accessTokenCookie && ($0.expiresDate.map { $0 > now } ?? true) }
    let normalizedHost = host.lowercased()
    let matching = candidates.first {
      $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == normalizedHost
    }
    return (matching ?? candidates.first)?.value
  }
}

struct BackgroundUploadState: Codable {
  var uploaded: Set<String> = []
  var inflight: Set<String> = []
}

struct BackgroundUploadStateStore {
  private let fileUrl: URL

  init?(groupId: String) {
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId) else {
      return nil
    }
    fileUrl = container.appending(path: "background-upload-state.json")
  }

  func load() -> BackgroundUploadState {
    guard let data = try? Data(contentsOf: fileUrl),
          let state = try? JSONDecoder().decode(BackgroundUploadState.self, from: data)
    else {
      return BackgroundUploadState()
    }
    return state
  }

  func save(_ state: BackgroundUploadState) {
    guard let data = try? JSONEncoder().encode(state) else { return }
    try? data.write(to: fileUrl, options: .atomic)
  }
}

final class BackgroundUploadCore {
  private static let resourceKeyHeader = "X-Device-Asset-Id"
  private static let maxUploadBytes: Int64 = 95 * 1024 * 1024
  private static let fallbackJobLimit = 50
  private static let uploadableTypes: Set<PHAssetResourceType> = [.photo, .video, .pairedVideo]

  private let cancelled = OSAllocatedUnfairLock(initialState: false)

  private var isCancelled: Bool { cancelled.withLock { $0 } }

  func cancel() {
    cancelled.withLock { $0 = true }
  }

  func run() -> PHBackgroundResourceUploadProcessingResult {
    cancelled.withLock { $0 = false }

    guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
          let config = BackgroundUploadConfig.load(),
          let store = BackgroundUploadStateStore(groupId: config.groupId)
    else {
      return .completed
    }

    var state = store.load()
    defer { store.save(state) }

    do {
      try retryFailedJobs(config: config)
      try acknowledgeFinishedJobs(state: &state)
      reconcileInflight(state: &state)
      guard !isCancelled else { return .processing }

      let created = try createJobs(config: config, state: &state)
      return created > 0 || !state.inflight.isEmpty ? .processing : .completed
    } catch let error as NSError
      where error.domain == PHPhotosErrorDomain && error.code == PHPhotosError.limitExceeded.rawValue
    {
      return .processing
    } catch {
      return .failure
    }
  }

  private func retryFailedJobs(config: BackgroundUploadConfig) throws {
    let jobs = PHAssetResourceUploadJob.fetchJobs(action: .retry, options: nil)
    guard jobs.count > 0 else { return }

    try PHPhotoLibrary.shared().performChangesAndWait {
      jobs.enumerateObjects { job, _, stop in
        if self.isCancelled {
          stop.pointee = true
          return
        }
        var destination = job.destination
        destination.url = config.endpoint
        destination.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        PHAssetResourceUploadJobChangeRequest(for: job)?.retry(destination: destination)
      }
    }
  }

  private func acknowledgeFinishedJobs(state: inout BackgroundUploadState) throws {
    let jobs = PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil)
    guard jobs.count > 0 else { return }

    var finished: [(key: String?, succeeded: Bool)] = []
    try PHPhotoLibrary.shared().performChangesAndWait {
      jobs.enumerateObjects { job, _, stop in
        if self.isCancelled {
          stop.pointee = true
          return
        }
        guard let request = PHAssetResourceUploadJobChangeRequest(for: job) else { return }
        finished.append((Self.resourceKey(for: job), job.state == .succeeded))
        request.acknowledge()
      }
    }

    for entry in finished {
      guard let key = entry.key else { continue }
      state.inflight.remove(key)
      if entry.succeeded {
        state.uploaded.insert(key)
      }
    }
  }

  private func reconcileInflight(state: inout BackgroundUploadState) {
    var tracked = Set<String>()
    for action in [PHAssetResourceUploadJob.Action.process, .acknowledge, .retry] {
      PHAssetResourceUploadJob.fetchJobs(action: action, options: nil).enumerateObjects { job, _, _ in
        if let key = Self.resourceKey(for: job) {
          tracked.insert(key)
        }
      }
    }
    state.inflight.formIntersection(tracked)
  }

  private func createJobs(config: BackgroundUploadConfig, state: inout BackgroundUploadState) throws -> Int {
    var capacity = jobCapacity()
    guard capacity > 0 else { return 0 }

    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "creationDate > %@", config.baseline as NSDate)
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    options.includeHiddenAssets = false
    let assets = PHAsset.fetchAssets(with: options)

    var pending: [(key: String, resource: PHAssetResource, destination: URLRequest)] = []
    assets.enumerateObjects { asset, _, stop in
      if self.isCancelled || capacity <= 0 {
        stop.pointee = true
        return
      }
      for resource in PHAssetResource.assetResources(for: asset) where Self.uploadableTypes.contains(resource.type) {
        let key = Self.resourceKey(assetId: asset.localIdentifier, resource: resource)
        guard !state.uploaded.contains(key), !state.inflight.contains(key), Self.fitsUploadLimit(resource) else {
          continue
        }
        pending.append((key, resource, Self.destination(for: asset, resource: resource, key: key, config: config)))
        capacity -= 1
        if capacity <= 0 { break }
      }
    }
    guard !pending.isEmpty else { return 0 }

    try PHPhotoLibrary.shared().performChangesAndWait {
      for job in pending {
        if #available(iOS 26.4, *) {
          _ = PHAssetResourceUploadJobChangeRequest.creationRequestForJob(destination: job.destination, resource: job.resource)
        } else {
          PHAssetResourceUploadJobChangeRequest.createJob(destination: job.destination, resource: job.resource)
        }
      }
    }

    state.inflight.formUnion(pending.map(\.key))
    return pending.count
  }

  private func jobCapacity() -> Int {
    let unacknowledged = PHAssetResourceUploadJob.fetchJobs(action: .process, options: nil).count
      + PHAssetResourceUploadJob.fetchJobs(action: .acknowledge, options: nil).count
    if #available(iOS 26.5, *) {
      return max(0, PHAssetResourceUploadJob.jobLimit - unacknowledged)
    }
    return max(0, Self.fallbackJobLimit - unacknowledged)
  }

  private static func fitsUploadLimit(_ resource: PHAssetResource) -> Bool {
    guard let size = resource.value(forKey: "fileSize") as? Int64 else { return true }
    return size <= maxUploadBytes
  }

  private static func resourceKey(assetId: String, resource: PHAssetResource) -> String {
    "\(assetId)|\(resource.type.rawValue)"
  }

  private static func resourceKey(for job: PHAssetResourceUploadJob) -> String? {
    job.destination.value(forHTTPHeaderField: resourceKeyHeader)
  }

  private static func destination(
    for asset: PHAsset,
    resource: PHAssetResource,
    key: String,
    config: BackgroundUploadConfig
  ) -> URLRequest {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withTimeZone]
    let created = asset.creationDate ?? Date()
    let modified = asset.modificationDate ?? created
    let mimeType = UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream"

    var request = URLRequest(url: config.endpoint)
    request.httpMethod = "POST"
    request.allowsCellularAccess = false
    request.allowsExpensiveNetworkAccess = false
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    request.setValue(key, forHTTPHeaderField: resourceKeyHeader)
    request.setValue("ios-background-upload", forHTTPHeaderField: "X-Device-Id")
    request.setValue(formatter.string(from: created), forHTTPHeaderField: "X-File-Created-At")
    request.setValue(formatter.string(from: modified), forHTTPHeaderField: "X-File-Modified-At")
    request.setValue(asset.isFavorite ? "true" : "false", forHTTPHeaderField: "X-Is-Favorite")
    request.setValue(resource.originalFilename, forHTTPHeaderField: "X-Filename")
    request.setValue(mimeType, forHTTPHeaderField: "X-Content-Type")
    if let location = asset.location {
      request.setValue(String(location.coordinate.latitude), forHTTPHeaderField: "X-Latitude")
      request.setValue(String(location.coordinate.longitude), forHTTPHeaderField: "X-Longitude")
    }
    return request
  }
}
