import CryptoKit
import Foundation
import os

/// Downloads, verifies, stores and deletes whisper models.
///
/// Files live in ~/Library/Application Support/NotchPilot/Models (excluded from Time
/// Machine; they can be downloaded again). A download only starts when the person asks
/// for it, goes to huggingface.co, and is accepted only if its size and SHA-256 match the
/// values pinned in `SpeechModel.catalog`. The file is hashed once, while it is still in
/// a staging name next to its final place; it is then renamed into place atomically, so a
/// file under the final name is always a verified one and launch checks only its size.
///
/// `installStates` hands every caller its own stream (the app and Settings both observe
/// it); each one starts with the current snapshot and keeps only the newest.
///
/// `@unchecked Sendable` invariant: all mutable state lives in `state`, guarded by its
/// lock. The URLSession delegate runs on the session's own serial operation queue and
/// only stages the finished file there; hashing runs on `verifyQueue`, never on the
/// delegate queue (which would stall other downloads) or the caller's executor.
public final class SpeechModelStore: SpeechModelManaging, @unchecked Sendable {
    public enum StoreError: Error, Equatable, LocalizedError {
        case notInCatalog
        case alreadyDownloading
        case httpStatus(Int)
        case verificationFailed
        case fileSystem(String)

        public var errorDescription: String? {
            switch self {
            case .notInCatalog: "This model isn’t one NotchPilot knows."
            case .alreadyDownloading: "This model is already downloading."
            case .httpStatus(let status): "The download failed (HTTP \(status)). Try again later."
            case .verificationFailed: "The downloaded file didn’t match its checksum and was deleted. Try again."
            case .fileSystem(let detail): "The model couldn’t be saved: \(detail)"
            }
        }
    }

    public let directory: URL
    private let catalog: [SpeechModel]
    private let session: URLSession
    private let delegate: DownloadDelegate
    private let verifyQueue = DispatchQueue(label: "app.notchpilot.models.verify", qos: .utility)

    private struct State {
        var installStates: [SpeechModel.ID: SpeechModelInstallState] = [:]
        var subscribers: [UUID: AsyncStream<[SpeechModel.ID: SpeechModelInstallState]>.Continuation] = [:]
        var tasks: [SpeechModel.ID: URLSessionDownloadTask] = [:]
        /// Models whose download `delete` cancelled; checked right before the final rename
        /// so a download already past the network stage can't bring the file back.
        var cancelled: Set<SpeechModel.ID> = []
        /// Tests only: runs on `verifyQueue` after the hash check, before the final rename.
        var beforeInstall: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// ~/Library/Application Support/NotchPilot/Models
    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "NotchPilot", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
    }

    /// Ephemeral, with no URL cache and no cookie storage: nothing about a download is
    /// kept beyond the model file itself.
    public static var downloadConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return configuration
    }

    /// - Parameters:
    ///   - directory: where model files live (tests pass a temporary directory).
    ///   - configuration: session configuration (tests register a `URLProtocol` stub).
    ///   - catalog: the models this store manages.
    public init(directory: URL = SpeechModelStore.defaultDirectory,
                configuration: URLSessionConfiguration = SpeechModelStore.downloadConfiguration,
                catalog: [SpeechModel] = SpeechModel.catalog) {
        self.directory = directory
        self.catalog = catalog
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "app.notchpilot.models"
        delegate = DownloadDelegate()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
        Self.removeStagingLeftovers(in: directory)
        let initial = Dictionary(uniqueKeysWithValues: catalog.map { model in
            (model.id, Self.fileIsInstalled(model, in: directory) ? SpeechModelInstallState.installed : .notInstalled)
        })
        state.withLock { $0.installStates = initial }
    }

    deinit {
        session.invalidateAndCancel()
        state.withLock { $0.subscribers.values.forEach { $0.finish() } }
    }

    public var installStates: AsyncStream<[SpeechModel.ID: SpeechModelInstallState]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [SpeechModel.ID: SpeechModelInstallState].self,
                                                            bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { state in
            state.subscribers[id] = continuation
            continuation.yield(state.installStates)
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    public func installedFileURL(for model: SpeechModel) -> URL? {
        Self.fileIsInstalled(model, in: directory) ? fileURL(for: model) : nil
    }

    public func download(_ model: SpeechModel) async throws {
        guard let model = catalog.first(where: { $0.id == model.id }) else { throw StoreError.notInCatalog }
        if installedFileURL(for: model) != nil {
            publish(model.id, .installed)
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directory
            try? mutableDirectory.setResourceValues(values)
        } catch {
            publish(model.id, .failed(StoreError.fileSystem(error.localizedDescription).errorDescription ?? ""))
            throw StoreError.fileSystem(error.localizedDescription)
        }

        try Task.checkCancellation()
        let task = session.downloadTask(with: model.downloadURL)
        let claimed = state.withLock { state -> Bool in
            guard state.tasks[model.id] == nil else { return false }
            state.tasks[model.id] = task
            state.cancelled.remove(model.id)
            return true
        }
        guard claimed else { throw StoreError.alreadyDownloading }
        publish(model.id, .downloading(fraction: 0))

        var staging: URL?
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        do {
            staging = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    delegate.register(task, job: .init(
                        progress: { [weak self] fraction in self?.publish(model.id, .downloading(fraction: fraction)) },
                        stage: { [directory] location in try Self.stage(location, as: model, in: directory) },
                        completion: { continuation.resume(with: $0) },
                        expectedBytes: model.sizeBytes))
                    task.resume()
                    // `onCancel` may have run before the task was resumed, which a suspended
                    // task can ignore; cancelling again now that it runs always completes it.
                    if Task.isCancelled { task.cancel() }
                }
            } onCancel: {
                task.cancel()
            }
            if let staging { try await verifyAndInstall(staging, as: model, task: task) }
            releaseTask(task, for: model.id)
            publish(model.id, .installed)
        } catch {
            releaseTask(task, for: model.id)
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                publish(model.id, .notInstalled)
                throw CancellationError()
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            publish(model.id, .failed(message))
            throw error
        }
    }

    public func delete(_ model: SpeechModel) throws {
        guard let model = catalog.first(where: { $0.id == model.id }) else { throw StoreError.notInCatalog }
        let task = state.withLock { state -> URLSessionDownloadTask? in
            let task = state.tasks.removeValue(forKey: model.id)
            if task != nil { state.cancelled.insert(model.id) }
            return task
        }
        task?.cancel()
        let url = fileURL(for: model)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: url)
        }
        publish(model.id, .notInstalled)
    }

    /// Tests only: see `State.beforeInstall`.
    func setBeforeInstallHook(_ hook: (@Sendable () -> Void)?) {
        state.withLock { $0.beforeInstall = hook }
    }

    // MARK: - Private

    private func fileURL(for model: SpeechModel) -> URL {
        directory.appending(path: model.fileName, directoryHint: .notDirectory)
    }

    /// Deletes staging files (`.<file>.<uuid>.partial`) left behind if the app quit or
    /// crashed mid-verification. Runs once at init, before any download can start.
    private static func removeStagingLeftovers(in directory: URL) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return }
        for name in names where name.hasPrefix(".") && name.hasSuffix(".partial") {
            try? fileManager.removeItem(at: directory.appending(path: name, directoryHint: .notDirectory))
        }
    }

    private static func fileIsInstalled(_ model: SpeechModel, in directory: URL) -> Bool {
        let path = directory.appending(path: model.fileName, directoryHint: .notDirectory).path(percentEncoded: false)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber else { return false }
        return size.int64Value == model.sizeBytes
    }

    private func publish(_ id: SpeechModel.ID, _ installState: SpeechModelInstallState) {
        state.withLock { state in
            guard state.installStates[id] != installState else { return }
            state.installStates[id] = installState
            for continuation in state.subscribers.values { continuation.yield(state.installStates) }
        }
    }

    /// Forgets `task` unless a newer download of the same model has replaced it.
    private func releaseTask(_ task: URLSessionDownloadTask, for id: SpeechModel.ID) {
        state.withLock { state in
            if state.tasks[id] === task { state.tasks[id] = nil }
        }
    }

    /// Runs on the delegate queue with the system's temporary file, which is deleted as soon
    /// as the delegate callback returns: moves it to a staging name beside the target.
    private static func stage(_ location: URL, as model: SpeechModel, in directory: URL) throws -> URL {
        let staging = directory.appending(path: ".\(model.fileName).\(UUID().uuidString).partial", directoryHint: .notDirectory)
        do {
            try FileManager.default.moveItem(at: location, to: staging)
        } catch {
            throw StoreError.fileSystem(error.localizedDescription)
        }
        return staging
    }

    /// Checks size and hash on `verifyQueue`, then renames the staged file into place. The
    /// rename happens under the state lock, after checking that `delete` hasn't cancelled
    /// this download meanwhile, so the two can't interleave.
    private func verifyAndInstall(_ staging: URL, as model: SpeechModel, task: URLSessionDownloadTask) async throws {
        let target = fileURL(for: model)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            verifyQueue.async { [self] in
                continuation.resume(with: Result {
                    guard let size = (try? FileManager.default.attributesOfItem(atPath: staging.path(percentEncoded: false)))?[.size] as? NSNumber,
                          size.int64Value == model.sizeBytes,
                          try Self.sha256Hex(of: staging) == model.sha256 else {
                        throw StoreError.verificationFailed
                    }
                    state.withLock { $0.beforeInstall }?()
                    try state.withLock { state in
                        guard state.tasks[model.id] === task, !state.cancelled.contains(model.id) else {
                            throw CancellationError()
                        }
                        do {
                            let fileManager = FileManager.default   // not Sendable; don't capture it
                            if fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
                                try fileManager.removeItem(at: target)
                            }
                            try fileManager.moveItem(at: staging, to: target)
                        } catch {
                            throw StoreError.fileSystem(error.localizedDescription)
                        }
                    }
                })
            }
        }
    }

    /// Streams the file through SHA-256 in 1 MiB chunks; never holds the whole model in memory.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Session delegate: routes per-task callbacks to the job registered for the task.
/// Runs on the store's serial delegate queue; `jobs` is guarded by its lock because
/// `register` is called from the downloading task's executor.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Job {
        var progress: @Sendable (Double) -> Void
        /// Called with the temporary file; returns where it was moved, or throws to fail.
        var stage: @Sendable (URL) throws -> URL
        var completion: @Sendable (Result<URL, Error>) -> Void
        var expectedBytes: Int64
        var finishResult: Result<URL, Error>?
        var lastReported: Double = -1
    }

    private let jobs = OSAllocatedUnfairLock(initialState: [Int: Job]())

    func register(_ task: URLSessionTask, job: Job) {
        jobs.withLock { $0[task.taskIdentifier] = job }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let report = jobs.withLock { jobs -> (@Sendable (Double) -> Void, Double)? in
            guard var job = jobs[downloadTask.taskIdentifier] else { return nil }
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : job.expectedBytes
            let fraction = total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : 0
            // Publish in 1 % steps; a 500 MB download otherwise reports thousands of times.
            guard fraction - job.lastReported >= 0.01 || fraction >= 1 else { return nil }
            job.lastReported = fraction
            jobs[downloadTask.taskIdentifier] = job
            return (job.progress, fraction)
        }
        if let (progress, fraction) = report { progress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = jobs.withLock({ $0[downloadTask.taskIdentifier] }) else { return }
        let result: Result<URL, Error>
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            result = .failure(SpeechModelStore.StoreError.httpStatus(http.statusCode))
        } else {
            result = Result { try job.stage(location) }
        }
        jobs.withLock { $0[downloadTask.taskIdentifier]?.finishResult = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = jobs.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error {
            job.completion(.failure(error))
        } else {
            job.completion(job.finishResult ?? .failure(URLError(.badServerResponse)))
        }
    }
}
