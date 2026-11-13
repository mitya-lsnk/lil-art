import Darwin
import Foundation
import MediaGenerationKit
import Network
import SwiftUI

/// Makes sure a continuation is resumed exactly once.
private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var used = false
  func take() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if used { return false }
    used = true
    return true
  }
}

/// Downloads one file to a chosen place and reports how much has arrived.
///
/// The delegate form is used because it is the one that reports bytes as they come in;
/// `URLSession.download(from:)` only hands over the finished file, so a progress bar could
/// never move.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let destination: URL
  private let onProgress: @Sendable (Double) -> Void
  private let lock = NSLock()
  private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
  private var task: URLSessionDownloadTask?
  private var cancelled = false
  private var moveFailure: Error?
  // touched only from the session's serial delegate queue
  private var lastReported = -1.0

  init(to destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
    self.destination = destination
    self.onProgress = onProgress
  }

  /// Returns the server's response; the file is at `destination` only when the status was 2xx.
  func run(_ url: URL) async throws -> HTTPURLResponse {
    let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    // the session keeps its delegate alive until it is invalidated
    defer { session.finishTasksAndInvalidate() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (c: CheckedContinuation<HTTPURLResponse, Error>) in
        self.lock.lock()
        if self.cancelled {
          self.lock.unlock()
          c.resume(throwing: CancellationError())
          return
        }
        self.continuation = c
        let t = session.downloadTask(with: url)
        self.task = t
        self.lock.unlock()
        t.resume()
      }
    } onCancel: {
      self.lock.lock()
      self.cancelled = true
      let t = self.task
      self.lock.unlock()
      t?.cancel()
    }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesExpectedToWrite > 0 else { return }
    let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    // thousands of small callbacks arrive; the screen only needs a new value every half percent
    if fraction - lastReported >= 0.005 || fraction >= 1 {
      lastReported = fraction
      onProgress(fraction)
    }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
  ) {
    // The temporary file is deleted when this returns, so it has to be moved right here.
    // An error page (rate limit, 404) is not worth keeping.
    guard let http = downloadTask.response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
    else { return }
    do {
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: location, to: destination)
    } catch {
      lock.lock()
      moveFailure = error
      lock.unlock()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let c = continuation
    continuation = nil
    let failure = moveFailure
    lock.unlock()
    if let error {
      c?.resume(throwing: error)
    } else if let failure {
      c?.resume(throwing: failure)
    } else if let http = task.response as? HTTPURLResponse {
      c?.resume(returning: http)
    } else {
      c?.resume(throwing: URLError(.badServerResponse))
    }
  }
}

/// The engine is a separate program, not part of this app.
///
/// It is downloaded once and then updates on its own schedule: when they publish a new
/// build, this app picks it up without being rebuilt or re-released. That is the whole
/// point of keeping it outside — the same arrangement ffmpeg and yt-dlp use.
///
/// It runs on this machine and listens on 127.0.0.1, which never leaves the computer.
@available(macOS 26, *)
@MainActor
final class EngineHost: ObservableObject {
  @Published var host = "127.0.0.1" {
    didSet { UserDefaults.standard.set(host, forKey: "engine.host") }
  }
  @Published var port = 7859 {
    didSet {
      // a port outside 1...65535 cannot be listened on, and would crash the readiness check
      guard (1...65535).contains(port) else {
        port = 7859
        return
      }
      UserDefaults.standard.set(port, forKey: "engine.port")
    }
  }

  @Published var installedTag = UserDefaults.standard.string(forKey: "engine.tag") ?? ""
  @Published var latestTag = ""
  @Published var latestSizeMB = 0.0
  @Published var status = ""
  @Published var busy = false
  @Published var progress = 0.0
  @Published var running = false
  /// The engine answered and is ready to generate.
  @Published var ready = false

  private var process: Process?
  /// Between start() and the moment the process really exists: old copies are being cleared.
  private var launching: Task<Void, Never>?
  /// The latest clean-up of old processes; a new engine waits for it so it cannot be killed by it.
  private var cleanup: Task<Void, Never>?

  var binary: URL {
    ProjectRoot.places.engineBinary
  }
  var installed: Bool { FileManager.default.fileExists(atPath: binary.path) }
  /// For the memory readout: the engine is a separate process with memory of its own.
  var pid: Int32? { process?.processIdentifier }

  var backend: MediaGenerationPipeline.Backend {
    .remote(.init(host: host, port: port))
  }

  init() {
    // quitting the app takes the engine with it, so it never lingers holding memory
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.process?.terminate() }
    }
    let d = UserDefaults.standard
    if let h = d.string(forKey: "engine.host"), !h.isEmpty { host = h }
    let p = d.integer(forKey: "engine.port")
    port = (1...65535).contains(p) ? p : 7859
  }

  // MARK: updates

  /// What a failed answer from GitHub means for the person reading the status line.
  private static func describe(httpStatus code: Int) -> String {
    switch code {
    case 403, 429: return "гитхаб временно ограничил запросы, попробуйте позже"
    case 404: return "на гитхабе такого нет (404)"
    default: return "гитхаб ответил \(code)"
    }
  }

  func checkLatest() async {
    // a second check on top of a running download would reset `busy` under it
    guard !busy else { return }
    busy = true
    status = "спрашиваю у гитхаба"
    defer { busy = false }
    guard
      let url = URL(
        string: "https://api.github.com/repos/drawthingsai/draw-things-community/releases/latest")
    else {
      status = "не удалось спросить гитхаб о выпусках"
      return
    }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      status = "не удалось спросить гитхаб: \(error.localizedDescription)"
      return
    }
    // a rate limit comes back as an error page, which must not read as "no releases"
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      status = EngineHost.describe(httpStatus: http.statusCode)
      return
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      status = "не удалось прочитать ответ гитхаба"
      return
    }
    latestTag = (json["tag_name"] as? String) ?? ""
    if let assets = json["assets"] as? [[String: Any]],
      let asset = assets.first(where: { ($0["name"] as? String) == "gRPCServerCLI-macOS" }),
      let size = asset["size"] as? Int
    {
      latestSizeMB = Double(size) / 1e6
    }
    if latestTag.isEmpty {
      status = "на гитхабе не нашёлся ни один выпуск"
    } else if latestTag == installedTag {
      status = "у вас последний: \(latestTag)"
    } else if installed {
      status = "есть новее: \(latestTag), у вас \(installedTag.isEmpty ? "неизвестно" : installedTag)"
    } else {
      status = "доступен \(latestTag)"
    }
  }

  func install() async {
    // a double click must not start a second download over the first
    guard !busy else { return }
    if latestTag.isEmpty {
      await checkLatest()
      if latestTag.isEmpty { return }
    }
    busy = true
    progress = 0
    status = "качаю движок"
    defer { busy = false }

    let address =
      "https://github.com/drawthingsai/draw-things-community/releases/download/"
      + "\(latestTag)/gRPCServerCLI-macOS"
    guard let url = URL(string: address) else {
      status = "ссылка на выпуск получилась неверной"
      return
    }
    // Next to the real file, so the final swap stays on one volume and is a single step.
    let directory = binary.deletingLastPathComponent()
    let staging = directory.appendingPathComponent("gRPCServerCLI-macOS.download")
    defer { try? FileManager.default.removeItem(at: staging) }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let download = FileDownload(to: staging) { [weak self] fraction in
        Task { @MainActor in
          // late callbacks must not overwrite what the end of the install has already said
          guard let self, fraction > self.progress else { return }
          self.progress = fraction
          self.status = "качаю движок, \(Int(fraction * 100))%"
        }
      }
      let response = try await download.run(url)
      guard (200..<300).contains(response.statusCode) else {
        status = EngineHost.describe(httpStatus: response.statusCode)
        return
      }
      // The new file becomes runnable before it takes the old one's place, and the swap is
      // atomic, so a failure at any step leaves the working engine in place.
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: staging.path)
      if installed {
        _ = try FileManager.default.replaceItemAt(binary, withItemAt: staging)
      } else {
        try FileManager.default.moveItem(at: staging, to: binary)
      }
      // replacing may carry over the old file's attributes; the engine must stay runnable
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: binary.path)
      progress = 1
      installedTag = latestTag
      UserDefaults.standard.set(latestTag, forKey: "engine.tag")
      status = "поставлен \(latestTag)"
    } catch is CancellationError {
      status = "скачивание прервано"
    } catch let error as URLError where error.code == .cancelled {
      status = "скачивание прервано"
    } catch {
      status = "движок не скачался: \(error.localizedDescription)"
    }
  }

  // MARK: running it

  /// Called at launch: if the engine is here, bring it up without asking.
  func autoStart(modelsDir: URL) {
    guard installed, process == nil else { return }
    start(modelsDir: modelsDir)
  }

  /// Returns at once; the engine appears a moment later, after any old copy has gone.
  func start(modelsDir: URL) {
    guard installed, process == nil, launching == nil else { return }
    // The engine makes its folder when it is missing, which under /Volumes would be a fake
    // folder on the Mac in place of the unplugged disk.
    if let message = ModelsFolder.unavailableMessage(modelsDir) {
      status = message
      return
    }
    // Shown as running right away so callers that look at `running` right after this call
    // keep waiting for the engine instead of concluding it never started.
    running = true
    ready = false
    status = "движок поднимается"
    let path = binary.path
    let previous = cleanup
    launching = Task { [weak self] in
      // An engine left behind by an earlier run of the app still holds the port and its memory.
      // Clearing it takes a few seconds at worst and happens off the main thread.
      await previous?.value
      await EngineHost.killStrays(path: path)
      guard let self, !Task.isCancelled else { return }
      self.launching = nil
      self.launch(modelsDir: modelsDir)
    }
  }

  private func launch(modelsDir: URL) {
    let p = Process()
    p.executableURL = binary
    // The engine binds to every network interface unless told otherwise, which would let
    // anyone on the same Wi-Fi use this Mac's GPU without a password.
    var arguments = [modelsDir.path, "--address", "127.0.0.1", "--port", String(port)]
    let cache = Int(UserDefaults.standard.double(forKey: "engine.cacheGB").rounded())
    if cache > 0 { arguments += ["--weights-cache", String(cache)] }
    p.arguments = arguments
    let log = openLog()
    if let log {
      p.standardOutput = log
      p.standardError = log
    }
    p.terminationHandler = { [weak self] ended in
      let code = ended.terminationStatus
      let signaled = ended.terminationReason == .uncaughtSignal
      Task { @MainActor in
        // A deliberate stop or a restart has already replaced `process`; only the engine we
        // are still holding dying on its own is news.
        guard let self, self.process === ended else { return }
        self.running = false
        self.ready = false
        self.process = nil
        self.status = EngineHost.exitMessage(code: code, signaled: signaled)
      }
    }
    do {
      try p.run()
      // the engine has its own copy of the file descriptor now
      try? log?.close()
      process = p
      running = true
      ready = false
      status = "движок поднимается"
      Task { await waitUntilReady(for: p) }
    } catch {
      try? log?.close()
      running = false
      status = "движок не запустился: \(error.localizedDescription)"
    }
  }

  func stop() {
    // a start() still clearing old copies must not go on to launch
    launching?.cancel()
    launching = nil
    let known = process?.processIdentifier
    process?.terminate()
    process = nil
    running = false
    ready = false
    status = "движок остановлен"
    // SIGTERM is only a request: finish the job in the background (SIGKILL if it hangs) so the
    // port and memory do come free. The next start() waits for this.
    let path = binary.path
    let previous = cleanup
    cleanup = Task.detached(priority: .utility) {
      await previous?.value
      await EngineHost.killStrays(path: path, alsoPid: known)
    }
  }

  private static func exitMessage(code: Int32, signaled: Bool) -> String {
    let hint = ", подробности в engine.log в папке проекта"
    if signaled {
      if code == SIGKILL {
        return "система оборвала движок (сигнал 9), возможно не хватило памяти" + hint
      }
      return "движок упал (сигнал \(code))" + hint
    }
    return "движок остановился (код \(code))" + hint
  }

  /// The engine's own output, kept where the person can find it when something goes wrong.
  private func openLog() -> FileHandle? {
    let url = ProjectRoot.places.engineLog
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    // checked once per start, which is enough to keep it from growing without limit
    var flags = O_WRONLY | O_CREAT | O_APPEND
    if size > 5 * 1_048_576 { flags |= O_TRUNC }
    let fd = open(url.path, flags, 0o644)
    guard fd >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
    try? handle.write(contentsOf: Data("\n--- запуск \(stamp) ---\n".utf8))
    return handle
  }

  /// Process ids whose executable is exactly `path`. Matching the whole command line instead
  /// would also catch an editor or a shell that merely mentions the path.
  private nonisolated static func pids(running path: String) -> Set<pid_t> {
    // the system reports the executable's real location, which differs if a folder is a link
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let size = Int32(MemoryLayout<pid_t>.size)
    let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    guard needed > 0 else { return [] }
    // room for processes that appear between the two calls
    var list = [pid_t](repeating: 0, count: Int(needed / size) + 64)
    let capacity = Int32(list.count) * size
    let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &list, capacity)
    guard filled > 0 else { return [] }
    // PROC_PIDPATHINFO_MAXSIZE, which Swift does not import
    var buffer = [UInt8](repeating: 0, count: 4096)
    let room = UInt32(buffer.count)
    var found: Set<pid_t> = []
    for pid in list.prefix(Int(filled / size)) where pid > 0 {
      let length = proc_pidpath(pid, &buffer, room)
      guard length > 0 else { continue }
      let running = String(decoding: buffer[0..<Int(length)], as: UTF8.self)
      if running == path || running == resolved { found.insert(pid) }
    }
    return found
  }

  /// Ends every copy of the engine binary: a polite request first, then SIGKILL after about
  /// three seconds, and waits until they are gone so the port and the memory are free.
  /// Runs on a background thread; callers only await it.
  private nonisolated static func killStrays(path: String, alsoPid: pid_t? = nil) async {
    await Task.detached(priority: .utility) {
      // our own child may no longer show up by path (its file can have been replaced meanwhile)
      func alive() -> Set<pid_t> {
        var found = pids(running: path)
        if let alsoPid, kill(alsoPid, 0) == 0 { found.insert(alsoPid) }
        return found
      }
      var remaining = alive()
      guard !remaining.isEmpty else { return }
      for pid in remaining { kill(pid, SIGTERM) }
      var waited = 0
      while !remaining.isEmpty, waited < 30 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        waited += 1
        remaining.formIntersection(alive())
      }
      guard !remaining.isEmpty else { return }
      for pid in remaining { kill(pid, SIGKILL) }
      // SIGKILL cannot be ignored, but the kernel still needs a moment to free the port
      for _ in 0..<20 {
        try? await Task.sleep(nanoseconds: 100_000_000)
        remaining.formIntersection(alive())
        if remaining.isEmpty { return }
      }
    }.value
  }

  /// The process is up long before it can answer, so wait for it to actually respond.
  private func waitUntilReady(for p: Process) async {
    for attempt in 1...25 {
      try? await Task.sleep(nanoseconds: 800_000_000)
      // stopped, replaced or dead: whoever did that has already set the status
      guard process === p else { return }
      let answered = await ping()
      guard process === p else { return }
      if answered {
        ready = true
        status = "движок готов, порт \(port)"
        return
      }
      status = "движок поднимается (\(attempt))"
    }
    status = "движок не ответил, попробуйте запустить заново"
  }

  /// A plain TCP knock: the port is open once the server is listening.
  private func ping() async -> Bool {
    await withCheckedContinuation { continuation in
      // the port is validated when set, but a trap here would take the whole app down
      guard let number = UInt16(exactly: port), let nwPort = NWEndpoint.Port(rawValue: number)
      else {
        continuation.resume(returning: false)
        return
      }
      let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
      let done = LockedFlag()
      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if done.take() {
            connection.cancel()
            continuation.resume(returning: true)
          }
        case .failed, .cancelled:
          if done.take() { continuation.resume(returning: false) }
        default:
          break
        }
      }
      connection.start(queue: .global())
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        if done.take() {
          connection.cancel()
          continuation.resume(returning: false)
        }
      }
    }
  }
}
