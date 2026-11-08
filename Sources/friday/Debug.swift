import Foundation

// Stage logging on stderr, off unless asked for.
//
// The command-line guidelines say diagnostics belong on stderr and that a
// program should not print creator-facing detail by default; they also suggest
// writing debug output to a file rather than burying the terminal in it, which
// is what FRIDAY_DEBUG_LOG is for. Lines are single-line and greppable so a
// failing render can be traced by reading top to bottom.
enum Debug {
  private static let started = Date()
  private static let lock = NSLock()
  private static var logHandle: FileHandle?

  private(set) static var isEnabled = false
  private(set) static var sinkDescription = "stderr"

  static func enable() {
    guard !isEnabled else { return }
    isEnabled = true
    // FRIDAY_DEBUG_LOG keeps the terminal clean while still capturing a trace.
    if let path = ProcessInfo.processInfo.environment["FRIDAY_DEBUG_LOG"], !path.isEmpty {
      let url = URL(fileURLWithPath: path)
      FileManager.default.createFile(atPath: url.path, contents: nil)
      if let handle = try? FileHandle(forWritingTo: url) {
        logHandle = handle
        sinkDescription = url.path
      }
    }
  }

  static func enableFromEnvironment() {
    guard let raw = ProcessInfo.processInfo.environment["FRIDAY_DEBUG"] else { return }
    if parseOnOff(raw) ?? (raw != "0" && !raw.isEmpty) { enable() }
  }

  static func stage(_ name: String, _ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    let elapsed = String(format: "%8.1fms", Date().timeIntervalSince(started) * 1000)
    let padded = name.padding(toLength: 12, withPad: " ", startingAt: 0)
    let line = "friday[debug] \(elapsed) \(padded) \(message())\n"
    guard let data = line.data(using: .utf8) else { return }
    lock.lock()
    defer { lock.unlock() }
    if let logHandle {
      logHandle.write(data)
    } else {
      FileHandle.standardError.write(data)
    }
  }
}
