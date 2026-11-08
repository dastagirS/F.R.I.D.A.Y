import XCTest

// Black-box checks: what the shipped binary does, with no audio hardware and no need
// for the daemon to synthesise anything.

final class CommandLineTests: XCTestCase {
  func testHelpSucceedsAndDocumentsExitCodes() throws {
    let result = try runFriday(["--help"])
    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(result.standardOutput.contains("130"), "the exit-code table is in --help")
    XCTAssertTrue(result.standardOutput.contains("--completions"))
    XCTAssertTrue(result.standardOutput.contains("--man"))
  }

  func testUnknownOptionIsRefusedWithARecoveryHint() throws {
    let result = try runFriday(["--nonsense"])
    XCTAssertEqual(result.status, 2)
    XCTAssertTrue(result.standardError.contains("friday --help"))
  }

  func testTypoIsNotSpokenAloudAsText() throws {
    XCTAssertEqual(try runFriday(["--verbos"]).status, 2)
  }

  func testEmptyStdinIsAUsageError() throws {
    let result = try runFriday(["-"], standardInput: Data())
    XCTAssertEqual(result.status, 2)
    XCTAssertTrue(result.standardError.contains("friday \"text\""))
  }

  func testBadFlagValuesAreRefused() throws {
    XCTAssertEqual(try runFriday(["--pace", "99", "hi"]).status, 2)
    XCTAssertEqual(try runFriday(["--volume", "nope", "hi"]).status, 2)
    XCTAssertEqual(try runFriday(["--completions", "tcsh"]).status, 2)
  }

  func testKnownGenerationIsAccepted() throws {
    XCTAssertEqual(try runFriday(["--generation", "standard", "--list"]).status, 0)
  }

  func testUnknownGenerationIsCurrentlyIgnored() throws {
    // Known gap (#43): the value should exit 2 like --pace and --volume do. Pinned as
    // today's silent behaviour so the gap stays visible; flip to 2 when #43 lands.
    XCTAssertEqual(try runFriday(["--generation", "theatrical", "--list"]).status, 0)
  }

  func testGeneratedDocuments() throws {
    for shell in ["zsh", "bash", "fish"] {
      let result = try runFriday(["--completions", shell])
      XCTAssertEqual(result.status, 0, "completions for \(shell)")
      XCTAssertFalse(result.standardOutput.isEmpty)
    }
    let skill = try runFriday(["--skill"])
    XCTAssertEqual(skill.status, 0)
    XCTAssertTrue(skill.standardOutput.contains("name:"))
    XCTAssertTrue(skill.standardOutput.lowercased().contains("exit"))

    let man = try runFriday(["--man"])
    XCTAssertEqual(man.status, 0)
    XCTAssertTrue(man.standardOutput.contains(".TH FRIDAY"))
    XCTAssertTrue(man.standardOutput.contains("EXIT STATUS"))
  }
}

final class ConfigFileTests: XCTestCase {
  private func withConfig<T>(_ body: (String) throws -> T) throws -> T {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("friday-config-\(UUID().uuidString).json").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    return try body(path)
  }

  func testConfigPrintsEffectiveSettings() throws {
    try withConfig { path in
      let result = try runFriday(["config"], environment: ["FRIDAY_CONFIG": path])
      XCTAssertEqual(result.status, 0)
      XCTAssertTrue(result.standardOutput.contains("simone"))
    }
  }

  func testSetAndUnsetRoundTrip() throws {
    try withConfig { path in
      let environment = ["FRIDAY_CONFIG": path]
      XCTAssertEqual(try runFriday(["config", "set", "lossless", "off"], environment: environment).status, 0)
      let shown = try runFriday(["config"], environment: environment)
      XCTAssertTrue(shown.standardOutput.contains("lossless"))
      XCTAssertEqual(try runFriday(["config", "unset", "lossless"], environment: environment).status, 0)
      XCTAssertEqual(try runFriday(["config", "set", "sentence-chunking", "on"], environment: environment).status, 0)
      XCTAssertEqual(try runFriday(["config", "unset", "sentence-chunking"], environment: environment).status, 0)
    }
  }

  func testBadConfigInvocationsAreRefused() throws {
    try withConfig { path in
      let environment = ["FRIDAY_CONFIG": path]
      XCTAssertEqual(try runFriday(["config", "set", "nosuchkey", "on"], environment: environment).status, 2)
      XCTAssertEqual(try runFriday(["config", "set", "lossless"], environment: environment).status, 2)
      XCTAssertEqual(try runFriday(["config", "show"], environment: environment).status, 2)
    }
  }

  func testCorruptConfigNamesTheFileAndExitsFive() throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("friday-broken-\(UUID().uuidString).json").path
    try Data("{nope".utf8).write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: path) }

    let result = try runFriday(["hi"], environment: ["FRIDAY_CONFIG": path])
    XCTAssertEqual(result.status, 5)
    XCTAssertTrue(result.standardError.contains(path))
  }

  func testEmptyConfigFileIsAllowed() throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("friday-empty-\(UUID().uuidString).json").path
    try Data().write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: path) }

    XCTAssertEqual(try runFriday(["config"], environment: ["FRIDAY_CONFIG": path]).status, 0)
  }
}

final class ServerTests: XCTestCase {
  func testHealthAndModels() throws {
    let server = try ServeHandle()
    defer { server.stop() }

    let health = try get(path: "/healthz", port: server.port)
    XCTAssertEqual(health.status, 200)
    XCTAssertTrue(health.bodyText.contains("\"status\""), health.bodyText)
    XCTAssertTrue(health.bodyText.contains("ok"))

    let models = try get(path: "/v1/models", port: server.port)
    XCTAssertEqual(models.status, 200)
    XCTAssertTrue(models.bodyText.contains("\"data\""))
  }

  func testErrorEnvelopeAndRequestId() throws {
    let server = try ServeHandle()
    defer { server.stop() }

    let missing = try get(path: "/nope", port: server.port)
    XCTAssertEqual(missing.status, 404)
    XCTAssertEqual(missing.errorCode(), "no_route")

    let wrongMethod = try get(path: "/v1/audio/speech", port: server.port)
    XCTAssertEqual(wrongMethod.status, 404, "GET is not a route on a POST-only path")

    let malformed = try request(method: "POST", path: "/v1/audio/speech", port: server.port, body: Data("not json".utf8))
    XCTAssertEqual(malformed.errorCode(), "invalid_json")

    let empty = try request(method: "POST", path: "/v1/audio/speech", port: server.port, body: Data(#"{"input":""}"#.utf8))
    XCTAssertEqual(empty.errorCode(), "missing_required_parameter")

    let badFormat = try request(
      method: "POST", path: "/v1/audio/speech", port: server.port,
      body: Data(#"{"input":"hi","response_format":"mp3"}"#.utf8)
    )
    XCTAssertEqual(badFormat.errorCode(), "invalid_value")

    let wavStream = try request(
      method: "POST", path: "/v1/audio/speech", port: server.port,
      body: Data(#"{"input":"hi","response_format":"wav","stream":true}"#.utf8)
    )
    XCTAssertEqual(wavStream.errorCode(), "invalid_value")

    let header = try request(method: "POST", path: "/v1/audio/speech", port: server.port, body: Data(#"{"input":""}"#.utf8))
    XCTAssertNotNil(header.headers["x-request-id"], "every response carries a request id")
  }

  func testBearerAuthIsRequiredForEveryRoute() throws {
    let server = try ServeHandle(
      environment: ["FRIDAY_TEST_TOKEN": "sekrit"],
      extraArguments: ["--auth-token-env", "FRIDAY_TEST_TOKEN"]
    )
    defer { server.stop() }

    XCTAssertEqual(try get(path: "/healthz", port: server.port).status, 401)
    XCTAssertEqual(
      try get(path: "/healthz", port: server.port, headers: ["Authorization": "Bearer wrong"]).status, 401)
    XCTAssertEqual(
      try get(path: "/healthz", port: server.port, headers: ["Authorization": "Bearer sekrit"]).status, 200)
    let missing = try get(path: "/healthz", port: server.port)
    XCTAssertEqual(missing.errorCode(), "invalid_token")
  }
}

final class InterruptTests: XCTestCase {
  func testStreamingStdinStopsOnSigintWhileBlockedOnInput() throws {
    guard let binary = fridayBinary() else { throw XCTSkip("built binary missing") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["--stream", "-q", "-"]
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning { process.terminate() }
      try? input.fileHandleForWriting.close()
    }

    // The pipe stays open with no data: a blocking read used to own the main thread,
    // which made the signal source unreachable and the process unstoppable.
    Thread.sleep(forTimeInterval: 1.2)
    XCTAssertTrue(process.isRunning, "streaming should still be waiting for input")

    process.interrupt()
    let deadline = Date().addingTimeInterval(6)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if process.isRunning {
      process.terminate()
      XCTFail("SIGINT did not stop --stream while blocked on stdin")
      return
    }
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 130)
  }
}
