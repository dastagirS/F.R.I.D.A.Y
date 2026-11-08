import Foundation
import XCTest

@testable import friday

// Shared helpers: locate and drive the built binary, talk HTTP, and read WAV fields.

let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()  // FridayTests
  .deletingLastPathComponent()  // Tests
  .deletingLastPathComponent()  // package root
  .path

/// The shipped binary: `build.sh` writes it to the package root, and an explicit
/// `FRIDAY_BINARY` wins so the suite can also be pointed at an installed copy.
func fridayBinary() -> String? {
  if let override = ProcessInfo.processInfo.environment["FRIDAY_BINARY"], !override.isEmpty {
    return override
  }
  let candidate = repositoryRoot + "/friday"
  return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
}

struct CommandResult {
  let status: Int32
  let standardOutput: String
  let standardError: String
}

/// Runs the binary. Output goes to temporary files rather than pipes: a child that
/// writes more than the pipe buffer would otherwise deadlock against a parent that is
/// waiting for it to exit.
@discardableResult
func runFriday(
  _ arguments: [String],
  standardInput: Data? = nil,
  environment: [String: String] = [:],
  timeout: TimeInterval = 180
) throws -> CommandResult {
  guard let binary = fridayBinary() else {
    throw XCTSkip("built binary missing — run ./build.sh first")
  }
  let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("friday-test-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: scratch) }
  let outputURL = scratch.appendingPathComponent("stdout")
  let errorURL = scratch.appendingPathComponent("stderr")
  FileManager.default.createFile(atPath: outputURL.path, contents: nil)
  FileManager.default.createFile(atPath: errorURL.path, contents: nil)

  let process = Process()
  process.executableURL = URL(fileURLWithPath: binary)
  process.arguments = arguments
  process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
  let outputHandle = try FileHandle(forWritingTo: outputURL)
  let errorHandle = try FileHandle(forWritingTo: errorURL)
  defer {
    try? outputHandle.close()
    try? errorHandle.close()
  }
  process.standardOutput = outputHandle
  process.standardError = errorHandle

  var inputPipe: Pipe?
  if standardInput != nil {
    let pipe = Pipe()
    process.standardInput = pipe
    inputPipe = pipe
  } else {
    process.standardInput = FileHandle.nullDevice
  }

  try process.run()
  if let inputPipe, let standardInput {
    inputPipe.fileHandleForWriting.write(standardInput)
    try? inputPipe.fileHandleForWriting.close()
  }

  let deadline = Date().addingTimeInterval(timeout)
  while process.isRunning && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.02)
  }
  if process.isRunning {
    XCTFail("friday \(arguments.joined(separator: " ")) exceeded \(Int(timeout))s")
    process.terminate()
  }
  process.waitUntilExit()

  outputHandle.synchronizeFile()
  errorHandle.synchronizeFile()
  let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
  let error = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
  return CommandResult(status: process.terminationStatus, standardOutput: output, standardError: error)
}

/// A running `friday serve`, torn down when the test ends.
final class ServeHandle {
  let process: Process
  let port: Int
  let scratch: URL
  private var outputHandle: FileHandle?
  private var errorHandle: FileHandle?

  init(environment: [String: String] = [:], extraArguments: [String] = []) throws {
    guard let binary = fridayBinary() else { throw XCTSkip("built binary missing") }
    port = try Self.freePort()
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("friday-serve-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

    let outputURL = scratch.appendingPathComponent("stdout")
    let errorURL = scratch.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: outputURL)
    let errors = try FileHandle(forWritingTo: errorURL)
    outputHandle = output
    errorHandle = errors

    process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["serve", "--port", String(port)] + extraArguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
    process.standardOutput = output
    process.standardError = errors
    try process.run()

    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      if let response = try? get(path: "/healthz", port: port), response.status == 200 || response.status == 401 { break }
      if !process.isRunning { break }
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

  func stop() {
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
    try? outputHandle?.close()
    try? errorHandle?.close()
    try? FileManager.default.removeItem(at: scratch)
  }

  deinit { stop() }

  private static func freePort() throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw XCTSkip("cannot open a socket") }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
    }
    guard bound == 0 else { throw XCTSkip("cannot bind a probe socket") }
    var actual = sockaddr_in()
    var actualSize = size
    let named = withUnsafeMutablePointer(to: &actual) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &actualSize) }
    }
    guard named == 0 else { throw XCTSkip("cannot read a free port") }
    return Int(UInt16(bigEndian: actual.sin_port))
  }
}

struct HTTPResult {
  let status: Int
  let headers: [String: String]
  let body: Data

  var bodyText: String { String(decoding: body, as: UTF8.self) }

  /// The OpenAI-shaped error envelope this project emits.
  func errorCode() -> String? {
    guard
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
      let error = object["error"] as? [String: Any]
    else { return nil }
    return error["code"] as? String
  }
}

func get(path: String, port: Int, headers: [String: String] = [:]) throws -> HTTPResult {
  try request(method: "GET", path: path, port: port, headers: headers)
}

func request(
  method: String,
  path: String,
  port: Int,
  body: Data? = nil,
  headers: [String: String] = [:],
  timeout: TimeInterval = 180
) throws -> HTTPResult {
  var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
  request.httpMethod = method
  request.timeoutInterval = timeout
  if let body { request.httpBody = body }
  for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

  let semaphore = DispatchSemaphore(value: 0)
  var result: HTTPResult?
  var failure: Error?
  URLSession.shared.dataTask(with: request) { data, response, error in
    if let error { failure = error }
    if let http = response as? HTTPURLResponse {
      var collected: [String: String] = [:]
      for (key, value) in http.allHeaderFields {
        collected[String(describing: key).lowercased()] = String(describing: value)
      }
      result = HTTPResult(status: http.statusCode, headers: collected, body: data ?? Data())
    }
    semaphore.signal()
  }.resume()
  guard semaphore.wait(timeout: .now() + timeout) == .success else {
    throw NSError(domain: "friday-tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "HTTP request timed out"])
  }
  if let failure { throw failure }
  guard let result else {
    throw NSError(domain: "friday-tests", code: 3, userInfo: [NSLocalizedDescriptionKey: "no HTTP response"])
  }
  return result
}

// MARK: - WAV field readers

func int16Sample(_ data: Data, _ index: Int) -> Int16 {
  let offset = data.startIndex + index * 2
  return Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
}

func uint16Field(_ data: Data, _ offset: Int) -> UInt16 {
  UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
}

func uint32Field(_ data: Data, _ offset: Int) -> UInt32 {
  (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[data.startIndex + offset + $1]) << (8 * UInt32($1))) }
}

func asciiField(_ data: Data, _ offset: Int, _ count: Int) -> String {
  String(decoding: data[data.startIndex + offset ..< data.startIndex + offset + count], as: UTF8.self)
}

/// Peak and RMS as fractions of full scale, for "did the voice stay clean" checks.
func audioLevels(wav: Data) -> (sampleRate: Int, channels: Int, bits: Int, frames: Int, peak: Double, rms: Double) {
  let sampleRate = Int(uint32Field(wav, 24))
  let channels = Int(uint16Field(wav, 22))
  let bits = Int(uint16Field(wav, 34))
  let dataStart = wav.startIndex + 44
  let sampleCount = (wav.count - 44) / 2
  var peak = 0
  var sumOfSquares = 0.0
  for index in 0..<max(0, sampleCount) {
    let offset = dataStart + index * 2
    let value = Int16(bitPattern: UInt16(wav[offset]) | (UInt16(wav[offset + 1]) << 8))
    peak = max(peak, abs(Int(value)))
    sumOfSquares += Double(value) * Double(value)
  }
  let rms = sampleCount > 0 ? (sumOfSquares / Double(sampleCount)).squareRoot() / 32768.0 : 0
  return (sampleRate, channels, bits, sampleCount / max(1, channels), Double(peak) / 32768.0, rms)
}

func chunkTexts(_ text: String) -> [String] {
  TextChunker.chunks(from: text).map(\.text)
}

// MARK: - Raw HTTP client

/// A minimal TCP client for the tests that need to control chunk framing themselves:
/// URLSession decides its own chunk sizes, which cannot exercise a single large chunk.
final class RawHTTPClient {
  private var descriptor: Int32 = -1

  init(port: Int, timeout: TimeInterval = 180) throws {
    descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw XCTSkip("cannot open a socket") }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = UInt16(port).bigEndian
    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, size)
      }
    }
    guard connected == 0 else {
      Darwin.close(descriptor)
      throw XCTSkip("cannot connect to the test server")
    }
    var receiveTimeout = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
  }

  deinit { close() }

  func close() {
    if descriptor >= 0 {
      Darwin.close(descriptor)
      descriptor = -1
    }
  }

  func write(_ data: Data) throws {
    try data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var sent = 0
      while sent < raw.count {
        let written = send(descriptor, base.advanced(by: sent), raw.count - sent, 0)
        guard written > 0 else {
          throw NSError(domain: "friday-tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket write failed"])
        }
        sent += written
      }
    }
  }

  func readToEnd() throws -> Data {
    var collected = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      let received = recv(descriptor, &buffer, buffer.count, 0)
      if received <= 0 { break }
      collected.append(contentsOf: buffer[0..<received])
    }
    return collected
  }

  /// Sends one chunked request and returns the whole raw response.
  func chunkedRequest(path: String, first: Data, second: Data = Data(), delayBeforeSecond: TimeInterval = 0) throws -> Data {
    var head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    head += "Transfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n"
    try write(Data(head.utf8))
    try write(Data(String(first.count, radix: 16).utf8) + Data("\r\n".utf8) + first + Data("\r\n".utf8))
    if !second.isEmpty {
      if delayBeforeSecond > 0 { Thread.sleep(forTimeInterval: delayBeforeSecond) }
      try write(Data(String(second.count, radix: 16).utf8) + Data("\r\n".utf8) + second + Data("\r\n".utf8))
    }
    try write(Data("0\r\n\r\n".utf8))
    return try readToEnd()
  }
}
