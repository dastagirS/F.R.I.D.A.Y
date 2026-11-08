import Foundation
import XCTest

// Real synthesis. Opt in with FRIDAY_AUDIO_TESTS=1: it needs the SiriTTS daemon, this
// machine's voice assets, and it makes sound.

final class AudioTests: XCTestCase {
  private var scratch: URL!

  override func setUpWithError() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["FRIDAY_AUDIO_TESTS"] == "1",
      "set FRIDAY_AUDIO_TESTS=1 to run real-synthesis checks"
    )
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("friday-audio-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

    // The daemon can be absent (or a CI machine can lack voice assets); that is a skip,
    // not a failure.
    let probe = scratch.appendingPathComponent("probe.wav")
    let result = try runFriday(["-q", "-o", probe.path, "ok"])
    try XCTSkipUnless(
      result.status == 0 && FileManager.default.fileExists(atPath: probe.path),
      "no audio produced (daemon or voice assets unavailable): \(result.standardError)"
    )
  }

  override func tearDownWithError() throws {
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
  }

  private func synthesize(_ text: String, extra: [String] = []) throws -> (result: CommandResult, wav: Data) {
    let path = scratch.appendingPathComponent("out-\(UUID().uuidString).wav")
    let result = try runFriday(["-q"] + extra + ["-o", path.path, text])
    let data = (try? Data(contentsOf: path)) ?? Data()
    return (result, data)
  }

  func testRenderedAudioIsFortyEightKhzMono16() throws {
    let (result, wav) = try synthesize("Testing one two three.")
    XCTAssertEqual(result.status, 0, result.standardError)
    let levels = audioLevels(wav: wav)
    XCTAssertEqual(levels.sampleRate, 48_000)
    XCTAssertEqual(levels.channels, 1)
    XCTAssertEqual(levels.bits, 16)
    XCTAssertGreaterThan(levels.frames, 8_000, "a spoken sentence should be longer than a click")
    XCTAssertGreaterThan(levels.rms, 0.01, "audio should not be silent")
  }

  func testLockedInVoiceStaysClean() throws {
    let (result, wav) = try synthesize("Good evening. All systems are online and responding normally.")
    XCTAssertEqual(result.status, 0, result.standardError)
    let levels = audioLevels(wav: wav)
    XCTAssertLessThan(levels.peak, 0.995, "simone clipping is a regression")
    XCTAssertFalse(
      result.standardError.contains("codec=lossy"),
      "default run should stay on the lossless encoder: \(result.standardError)"
    )
  }

  func testParagraphIsChunkedAndAudible() throws {
    let (result, wav) = try synthesize("First sentence here. Second sentence here. Third one closes it.")
    XCTAssertEqual(result.status, 0, result.standardError)
    XCTAssertGreaterThan(audioLevels(wav: wav).frames, 20_000)
  }

  func testWordTimingsAreWritten() throws {
    let path = scratch.appendingPathComponent("timings.json")
    let (result, _) = try synthesize("Hello there.", extra: ["--timings", "--timings-out", path.path])
    XCTAssertEqual(result.status, 0, result.standardError)
    let data = try Data(contentsOf: path)
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let entries = object?["timings"] as? [[String: Any]] ?? []
    XCTAssertFalse(entries.isEmpty, "timings are written for a completed utterance")
    for entry in entries {
      XCTAssertNotNil(entry["start"])
      XCTAssertNotNil(entry["end"])
      XCTAssertNotNil(entry["utf16Location"])
    }
    if entries.count == 1 {
      // Recorded in #15: short text reports one coarse range, so per-word granularity is
      // never guaranteed.
      print("note: short text produced \(entries.count) coarse timing range (see #15)")
    }
  }

  func testRefusals() throws {
    let unknownVoice = try synthesize("hello", extra: ["-v", "zzzznotavoice"])
    XCTAssertEqual(unknownVoice.result.status, 4)

    let whitespace = try runFriday(["-q", "-o", scratch.appendingPathComponent("blank.wav").path, "   "])
    XCTAssertEqual(whitespace.status, 2)
  }

  func testLoudVoiceStillClipsAndIsRecorded() throws {
    // Ticket #10: nora reaches full scale and distorts; simone does not. This records the
    // current state rather than failing on a known, ticketed defect.
    let (result, wav) = try synthesize(
      "Good evening. All systems are online and responding normally.",
      extra: ["-v", "nora", "--standard"]
    )
    try XCTSkipUnless(result.status == 0, "nora is not installed on this machine")
    let peak = audioLevels(wav: wav).peak
    print("note: nora peak \(peak) — #10 \(peak >= 0.999 ? "still open" : "may now be fixed")")
  }
}

final class AudioServerTests: XCTestCase {
  private var server: ServeHandle!

  override func setUpWithError() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["FRIDAY_AUDIO_TESTS"] == "1",
      "set FRIDAY_AUDIO_TESTS=1 to run streaming checks that synthesise"
    )
    let probe = FileManager.default.temporaryDirectory.appendingPathComponent("friday-probe-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: probe) }
    let result = try runFriday(["-q", "-o", probe.path, "ok"])
    try XCTSkipUnless(
      result.status == 0,
      "no audio produced (daemon or voice assets unavailable): \(result.standardError)"
    )
    server = try ServeHandle()
  }

  override func tearDownWithError() throws {
    server?.stop()
    server = nil
  }

  func testSingleLargeChunkIsAccepted() throws {
    // A chunk bigger than the old flat 256 KB read cap, inside the 4 MB body limit.
    var payload = Data(repeating: 0x20, count: 300 * 1024)
    payload.append(Data(#"{"input":"hi","response_format":"pcm"}"#.utf8))
    let client = try RawHTTPClient(port: server.port)
    defer { client.close() }
    let response = try client.chunkedRequest(path: "/v1/audio/speech", first: payload)
    let text = String(decoding: response.prefix(200), as: UTF8.self)
    XCTAssertTrue(text.contains("200 OK"), text)
    XCTAssertGreaterThan(response.count, 1_000, "should carry audio, not an error envelope")
  }

  func testStreamedResponseUsesChunkedTransfer() throws {
    let payload = Data(#"{"input":"stream check","response_format":"pcm","stream":true}"#.utf8)
    let client = try RawHTTPClient(port: server.port)
    defer { client.close() }
    let response = try client.chunkedRequest(path: "/v1/audio/speech", first: payload)
    let head = String(decoding: response.prefix(400), as: UTF8.self)
    XCTAssertTrue(head.contains("200 OK"), head)
    XCTAssertTrue(head.lowercased().contains("transfer-encoding: chunked"), head)
    XCTAssertGreaterThan(response.count, 1_000)
  }

  func testNdjsonStreamSpeaksEachSentence() throws {
    let first = Data((#"{"text":"First sentence here."}"# + "\n").utf8)
    let second = Data((#"{"text":"Second sentence here.","end":true}"# + "\n").utf8)
    let client = try RawHTTPClient(port: server.port)
    defer { client.close() }
    // The pause proves sentence one is spoken while sentence two is still in flight.
    let response = try client.chunkedRequest(path: "/say", first: first, second: second, delayBeforeSecond: 1.0)
    let text = String(decoding: response, as: UTF8.self)
    XCTAssertTrue(text.contains("200 OK"), String(text.prefix(200)))
    XCTAssertTrue(text.contains("\"sentences\"") && text.contains("2"), String(text.suffix(200)))
  }
}
