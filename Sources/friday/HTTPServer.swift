import Foundation
import SiriTTSService

// Minimal HTTP/1.1 server: no dependencies, one request at a time, loopback by
// default. Requests are handled on the main thread, but the daemon answers on its
// own threads and signals a semaphore; the main thread pumps its run loop while it
// waits so that signal sources and timers still fire. Serialisation therefore comes
// from this accept loop, not from thread affinity.
final class HTTPServer {
  private let port: UInt16
  private let host: String
  private let token: String?
  private let synthesizer: Synthesizer
  private let catalog: VoiceCatalog
  private let config: FridayConfig
  private let startedAt = Date()
  // Requests are handled one at a time on the main run loop, so a single current id is
  // sufficient and lets every response and log line agree on it.
  private var currentRequestId = "--------"
  // Kept so a stop can be accepted from inside the wait loop of a running request.
  private var listener: Int32 = -1
  // The most recent request, so a stop that arrives after it finished can still say which
  // one it cancelled (playback outlives the response).
  private var lastRequestId: String?

  init(port: UInt16, host: String, token: String?, synthesizer: Synthesizer, catalog: VoiceCatalog, config: FridayConfig) {
    self.port = port
    self.host = host
    self.token = token
    self.synthesizer = synthesizer
    self.catalog = catalog
    self.config = config
  }

  func run() throws -> Never {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw FridayError.usage("socket() failed") }
    var reuse: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    var resolved = in_addr()
    guard inet_pton(AF_INET, host, &resolved) == 1 else {
      throw FridayError.usage("invalid host '\(host)'")
    }
    address.sin_addr = resolved
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { throw FridayError.usage("cannot bind \(host):\(port)") }
    guard listen(descriptor, 16) == 0 else { throw FridayError.usage("listen() failed") }
    if host != "127.0.0.1", host != "localhost", (token ?? "").isEmpty {
      FileHandle.standardError.write("warning: serving on \(host) without --auth-token-env exposes Siri's voice to your network\n".data(using: .utf8)!)
    }
    FileHandle.standardError.write("friday serving on http://\(host):\(port) (\(catalog.voices.count) voices)\n".data(using: .utf8)!)
    listener = descriptor

    while true {
      let client = accept(descriptor, nil, nil)
      guard client >= 0 else {
        // A broken or descriptor-exhausted socket would otherwise spin this loop
        // at full CPU with no way to notice.
        Thread.sleep(forTimeInterval: 0.05)
        continue
      }
      var timeout = timeval(tv_sec: 10, tv_usec: 0)
      setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      handle(client)
      close(client)
    }
  }

  // Nothing is in flight here (the accept loop is free), so this only reaches playback
  // that outlived its response. A request id, when given, still has to match.
  private func handleStop(_ request: HTTPRequest, client: Int32, last: String?) {
    var requested: String?
    if request.isChunked {
      let reader = ChunkedBodyReader(client: client, initial: request.body, limit: 4096, requestId: currentRequestId)
      guard let buffered = reader.readAll() else {
        respondError(client, status: 400, type: "invalid_request_error",
                     message: "stop body could not be read", code: "invalid_body")
        return
      }
      requested = stopTarget(in: buffered)
    } else {
      requested = stopTarget(in: request.body)
    }
    guard let last else {
      respondJSON(client, 200, ["stopped": false, "reason": "no request has run yet"])
      return
    }
    if let requested, requested != last {
      respondError(
        client, status: 409, type: "invalid_request_error",
        message: "request '\(requested)' is not the most recent one (last: '\(last)')",
        param: "request_id", code: "request_mismatch"
      )
      return
    }
    synthesizer.cancelActive()
    respondJSON(client, 200, ["stopped": true, "request_id": last])
    Debug.stage("http", "\(currentRequestId) stop accepted for finished request \(last)")
  }

  // A request can take minutes, so a stop cannot queue behind the accept loop it is meant
  // to interrupt. The listener is polled on each slice of the wait loop a running request
  // spends blocked, which keeps this on one thread: no chasing the main thread, and no
  // window where a fast follow-up request is refused because the previous one is still
  // finishing its bookkeeping.
  private func pollForControl() {
    guard listener >= 0 else { return }
    var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    guard poll(&descriptor, 1, 0) > 0 else { return }
    let control = accept(listener, nil, nil)
    guard control >= 0 else { return }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(control, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    handleControl(control)
    close(control)
  }

  // Only POST /stop is served while a request is in flight; anything else gets 503
  // instead of waiting in the backlog for the current answer to finish.
  private func handleControl(_ client: Int32) {
    let identifier = currentRequestId
    // The answer's own id: reporting the running request's id on a 503 would make the
    // log read as if that request had produced the error.
    let controlId = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    guard let request = readRequest(client) else {
      respondError(client, status: 400, type: "invalid_request_error",
                   message: "malformed HTTP request", code: "malformed_request", requestId: controlId)
      return
    }
    if let token, !token.isEmpty, request.headers["authorization"] != "Bearer \(token)" {
      respondError(client, status: 401, type: "invalid_request_error",
                   message: "missing or invalid bearer token; set Authorization: Bearer $TOKEN",
                   code: "invalid_token", requestId: controlId)
      return
    }
    guard request.method == "POST", request.path == "/stop" else {
      respondError(
        client, status: 503, type: "server_error",
        message: "busy with request \(identifier); only POST /stop is served while a request runs",
        code: "busy", requestId: controlId
      )
      return
    }

    var requested: String?
    if request.isChunked {
      let reader = ChunkedBodyReader(client: client, initial: request.body, limit: 4096, requestId: identifier)
      guard let buffered = reader.readAll() else {
        respondError(client, status: 400, type: "invalid_request_error",
                     message: "stop body could not be read", code: "invalid_body", requestId: controlId)
        return
      }
      requested = stopTarget(in: buffered)
    } else {
      requested = stopTarget(in: request.body)
    }
    if let requested, requested != identifier {
      respondError(
        client, status: 409, type: "invalid_request_error",
        message: "request '\(requested)' is not in flight (active: '\(identifier)')",
        param: "request_id", code: "request_mismatch", requestId: controlId
      )
      return
    }

    synthesizer.cancelActive()
    Debug.stage("http", "\(identifier) stop accepted")
    respondJSON(client, 200, ["stopped": true, "request_id": identifier], requestId: controlId)
    FileHandle.standardError.write("friday: stopped request \(identifier)\n".data(using: .utf8)!)
  }

  private func stopTarget(in body: Data) -> String? {
    guard !body.isEmpty, case .ok(let object) = parseJSON(body) else { return nil }
    return object["request_id"] as? String
  }

  private func handle(_ client: Int32) {
    currentRequestId = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    let started = Date()
    guard let request = readRequest(client) else {
      Debug.stage("http", "\(currentRequestId) malformed request line or headers")
      respondError(client, status: 400, type: "invalid_request_error",
                   message: "malformed HTTP request", code: "malformed_request")
      return
    }
    // Only routes that produce audio are worth remembering: a stop addresses speech, and a
    // health check or the stop itself would otherwise shadow the id it is trying to name.
    if request.path == "/v1/audio/speech" || request.path == "/say" {
      lastRequestId = currentRequestId
      synthesizer.beginRequest()
    }
    if let token, !token.isEmpty {
      guard request.headers["authorization"] == "Bearer \(token)" else {
        Debug.stage("http", "\(currentRequestId) \(request.method) \(request.path) 401 bad token")
        respondError(client, status: 401, type: "invalid_request_error",
                     message: "missing or invalid bearer token; set Authorization: Bearer $TOKEN",
                     code: "invalid_token")
        return
      }
    }
    if request.isChunked {
      let reader = ChunkedBodyReader(
        client: client, initial: request.body, limit: 4 * 1024 * 1024, requestId: currentRequestId,
        tick: { [weak self] in self?.pollForControl() }
      )
      if request.method == "POST", request.path == "/say" {
        handleSayStreaming(reader, client: client)
      } else {
        guard let buffered = reader.readAll() else {
          respondError(client, status: 400, type: "invalid_request_error",
                       message: "chunked request body could not be read", code: "invalid_body")
          return
        }
        let complete = HTTPRequest(
          method: request.method, path: request.path, headers: request.headers,
          body: buffered, isChunked: false
        )
        route(complete, client: client)
      }
    } else {
      route(request, client: client)
    }
    let elapsed = String(format: "%.1fms", Date().timeIntervalSince(started) * 1000)
    Debug.stage("http", "\(currentRequestId) \(request.method) \(request.path) done in \(elapsed)")
  }

  private func route(_ request: HTTPRequest, client: Int32) {
    switch (request.method, request.path) {
    case ("GET", "/healthz"):
      let payload: [String: Any] = [
        "status": "ok",
        "voices": catalog.voices.count,
        "defaultVoice": config.defaultVoice ?? FridayConfig.builtInVoice,
        "defaultGeneration": config.defaultGeneration ?? "standard",
        "uptimeSeconds": Int(Date().timeIntervalSince(startedAt)),
      ]
      respondJSON(client, 200, payload)

    case ("GET", "/v1/models"):
      let models = catalog.voices.sorted { ($0.language, $0.name ?? "") < ($1.language, $1.name ?? "") }.map { voice -> [String: Any] in
        [
          "id": voice.name ?? voice.assetKey,
          "object": "model",
          "owned_by": "local-macos",
          "language": voice.language,
          "generation": VoiceCatalog.generation(voice),
          "asset_key": voice.assetKey,
        ]
      }
      respondJSON(client, 200, ["object": "list", "data": models])

    case ("POST", "/v1/audio/speech"):
      handleSpeech(request, client: client)

    case ("POST", "/stop"):
      handleStop(request, client: client, last: lastRequestId)

    case ("POST", "/say"):
      handleSay(request, client: client)

    default:
      respondError(client, status: 404, type: "invalid_request_error",
                   message: "no route for \(request.method) \(request.path)",
                   code: "no_route")
    }
  }

  private func handleSpeech(_ request: HTTPRequest, client: Int32) {
    let body: [String: Any]
    switch parseJSON(request.body) {
    case .ok(let parsed):
      body = parsed
    case .rejected(let reason):
      Debug.stage("http", "\(currentRequestId) body rejected: \(reason)")
      respondError(client, status: 400, type: "invalid_request_error",
                   message: "body rejected: \(reason)", code: "invalid_json")
      return
    }
    guard let input = body["input"] as? String, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      respondError(client, status: 400, type: "invalid_request_error",
                   message: "'input' is required and must be a non-empty string",
                   param: "input", code: "missing_required_parameter")
      return
    }
    let requestedVoice = body["voice"] as? String
    let requestedGeneration = body["generation"] as? String
    let format = (body["response_format"] as? String ?? "wav").lowercased()
    let speed = Float(body["speed"] as? Double ?? 1.0)
    guard format == "wav" || format == "pcm" else {
      respondError(client, status: 400, type: "invalid_request_error",
                   message: "response_format must be 'wav' or 'pcm', got '\(format)'",
                   param: "response_format", code: "invalid_value")
      return
    }
    // Streaming response: raw 48 kHz mono signed-16 PCM, framed in HTTP chunks so the
    // client can play the first audio instead of waiting for the whole render. WAV is
    // refused because it needs a length in its header, which streaming cannot provide.
    let wantsStream = (body["stream"] as? Bool) ?? false
    if wantsStream, format != "pcm" {
      respondError(client, status: 400, type: "invalid_request_error",
                   message: "streaming needs response_format 'pcm' (raw 48 kHz mono s16le); wav requires a known length",
                   param: "response_format", code: "invalid_value")
      return
    }
    do {
      let (voice, generation) = try resolveVoiceAndGeneration(
        voiceName: requestedVoice, generationName: requestedGeneration
      )
      if wantsStream {
        handleSpeechStream(client: client, input: input, voice: voice, generation: generation, speed: speed)
        return
      }
      let outcome = try synthesizer.synthesize(
        text: input, voice: voice, generation: generation,
        pace: config.pace ?? 3, expressivity: config.expressivity ?? 3,
        rate: max(0.25, min(4.0, speed)), pitch: 1.0, volume: 1.0,
        wantsTimings: false, playback: false,
        chunkSentences: config.sentenceChunking ?? FridayConfig.builtInSentenceChunking,
        lossless: config.lossless ?? FridayConfig.builtInLossless,
        whileWaiting: { [weak self] in self?.pollForControl() }
      )
      let body = format == "wav"
        ? try wavData(samples: outcome.samples, sampleRate: 48000)
        : pcmData(samples: outcome.samples)
      respond(
        client,
        status: 200,
        reason: "OK",
        contentType: format == "wav" ? "audio/wav" : "application/octet-stream",
        body: body,
        extraHeaders: [
          "X-Friday-Voice": outcome.voiceName,
          "X-Friday-Generation": outcome.generation,
          "X-Friday-Source": outcome.sourceFormat,
        ]
      )
    } catch {
      respondFailure(client, error)
    }
  }

  // Synthesis is synchronous: this returns once the audio has been generated and
  // handed to the player, which then keeps sounding. It is not fire-and-forget.
  private func handleSay(_ request: HTTPRequest, client: Int32) {
    let body: [String: Any]
    switch parseJSON(request.body) {
    case .ok(let parsed):
      body = parsed
    case .rejected(let reason):
      Debug.stage("http", "\(currentRequestId) body rejected: \(reason)")
      respondError(client, status: 400, type: "invalid_request_error",
                   message: "body rejected: \(reason)", code: "invalid_json")
      return
    }
    guard let text = body["text"] as? String, !text.isEmpty else {
      respondError(client, status: 400, type: "invalid_request_error",
                   message: "'text' is required and must be a non-empty string",
                   param: "text", code: "missing_required_parameter")
      return
    }
    do {
      let outcome = try speakOne(
        text: text,
        voiceName: body["voice"] as? String,
        generationName: body["generation"] as? String
      )
      respondJSON(client, 200, ["said": true, "voice": outcome.voiceName, "generation": outcome.generation])
    } catch {
      respondFailure(client, error)
    }
  }

  private func handleSpeechStream(
    client: Int32,
    input: String,
    voice: SynthesisVoice,
    generation: String,
    speed: Float
  ) {
    beginChunkedResponse(client, status: 200, contentType: "audio/pcm", extraHeaders: [
      "X-Friday-Voice": voice.name ?? "-",
      "X-Friday-Generation": generation,
      "X-Friday-Sample-Rate": "48000",
      "X-Friday-Audio-Format": "s16le-mono",
    ])
    Debug.stage("http", "\(currentRequestId) streaming pcm for \(input.count) chars")
    var framesWritten = 0
    do {
      let outcome = try synthesizer.synthesize(
        text: input, voice: voice, generation: generation,
        pace: config.pace ?? 3, expressivity: config.expressivity ?? 3,
        rate: max(0.25, min(4.0, speed)), pitch: 1.0, volume: 1.0,
        wantsTimings: false, playback: false,
        chunkSentences: config.sentenceChunking ?? FridayConfig.builtInSentenceChunking,
        lossless: config.lossless ?? FridayConfig.builtInLossless,
        whileWaiting: { [weak self] in self?.pollForControl() },
        onAudio: { buffer in
          guard let channel = buffer.floatChannelData?[0] else { return }
          let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
          framesWritten += Int(buffer.frameLength)
          self.writeChunk(client, pcmData(samples: Array(samples)))
        }
      )
      endChunkedResponse(client)
      Debug.stage("http", "\(currentRequestId) stream complete: \(framesWritten) frames, \(String(format: "%.2f", outcome.audioSeconds))s audio")
    } catch {
      if let friday = error as? FridayError, case .cancelled = friday {
        // A stop is not a failure: end the body properly so the client sees a valid,
        // shorter response instead of a truncation it cannot tell from a crash.
        endChunkedResponse(client)
        Debug.stage("http", "\(currentRequestId) stopped after \(framesWritten) frames")
        return
      }
      // The status line is already on the wire, so the honest signal left is a
      // truncated body: no terminating chunk means the client knows it was cut off.
      Debug.stage("http", "\(currentRequestId) stream aborted after \(framesWritten) frames: \(error)")
      FileHandle.standardError.write(
        "friday: request \(currentRequestId) stream failed after \(framesWritten) frames: \(error)\n".data(using: .utf8)!)
    }
  }

  // A requested voice and the render path it lands on. Both request shapes resolve them
  // identically, and the config-level path must not override a voice asked for by name.
  private func resolveVoiceAndGeneration(
    voiceName: String?,
    generationName: String?
  ) throws -> (SynthesisVoice, String) {
    let voice = try catalog.resolve(name: voiceName, language: nil, config: config)
    let generation = catalog.generation(
      requested: generationName, for: voice, config: config,
      forceStandard: false, forceExpressive: false,
      voiceWasExplicit: voiceName != nil,
      usingBuiltInDefault: voiceName == nil && config.defaultVoice == nil
    )
    return (voice, generation)
  }

  // One utterance, played through the speakers. Shared by the buffered and streaming
  // /say forms so both resolve voices and render identically.
  private func speakOne(text: String, voiceName: String?, generationName: String?) throws -> SynthesisOutcome {
    let (voice, generation) = try resolveVoiceAndGeneration(voiceName: voiceName, generationName: generationName)
    return try synthesizer.synthesize(
      text: text, voice: voice, generation: generation,
      pace: config.pace ?? 3, expressivity: config.expressivity ?? 3,
      rate: 1.0, pitch: 1.0, volume: 1.0,
      wantsTimings: false, playback: true,
      chunkSentences: config.sentenceChunking ?? FridayConfig.builtInSentenceChunking,
      lossless: config.lossless ?? FridayConfig.builtInLossless,
      whileWaiting: { [weak self] in self?.pollForControl() }
    )
  }

  // Text that is still arriving: newline-delimited JSON, one object per line.
  //   {"text": "..."}   append text; every complete sentence is spoken immediately
  //   {"flush": true}   speak whatever is buffered, even mid-sentence
  //   {"voice": "nora"} voice for the rest of the stream
  //   {"end": true}     finish and respond
  // Sentence boundaries are proven by the same rules as the whole-string splitter, so
  // "Dr.", "18.5" and quoted endings survive; anything unfinished is spoken on end.
  private func handleSayStreaming(_ reader: ChunkedBodyReader, client: Int32) {
    var splitter = StreamingSentenceSplitter()
    var lineBuffer = Data()
    var spoken = 0
    var voiceName: String?
    var generationName: String?
    let started = Date()
    let maximumSentences = 500
    let maximumText = 20_000
    var textSeen = 0
    var ended = false

    func speak(_ sentences: [String]) -> Error? {
      for sentence in sentences {
        guard spoken < maximumSentences else {
          return FridayError.usage("stream exceeds \(maximumSentences) sentences; split the request")
        }
        do {
          _ = try speakOne(text: sentence, voiceName: voiceName, generationName: generationName)
          spoken += 1
        } catch {
          return error
        }
      }
      return nil
    }

    while !ended, let piece = reader.next() {
      lineBuffer.append(piece)
      while let newline = lineBuffer.firstIndex(of: 0x0A) {
        let line = Data(lineBuffer[lineBuffer.startIndex..<newline])
        lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
        let trimmed = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        guard case .ok(let object) = parseJSON(Data(trimmed.utf8)) else {
          let message = "line is not a JSON object: \(trimmed.prefix(120))"
          Debug.stage("http", "\(currentRequestId) \(message)")
          respondError(client, status: 400, type: "invalid_request_error",
                       message: message, code: "invalid_json")
          return
        }
        if let text = object["text"] as? String {
          textSeen += text.count
          guard textSeen <= maximumText else {
            respondError(client, status: 400, type: "invalid_request_error",
                         message: "stream exceeds \(maximumText) characters; split the request",
                         code: "request_too_large")
            return
          }
          splitter.append(text)
          if let failure = speak(splitter.takeSentences()) { respondFailure(client, failure); return }
        }
        if let voice = object["voice"] as? String {
          voiceName = voice
          generationName = object["generation"] as? String
        }
        let flushValue = object["flush"]
        let wantsFlush = (flushValue as? Bool)
          ?? (flushValue.flatMap { parseOnOff(String(describing: $0)) } ?? false)
        if wantsFlush {
          if let failure = speak(splitter.flush()) { respondFailure(client, failure); return }
        }
        if (object["end"] as? Bool) ?? false || (object["done"] as? Bool) ?? false {
          ended = true
          break
        }
      }
    }
    if lineBuffer.count > 0 {
      let trailing = String(decoding: lineBuffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      if !trailing.isEmpty, case .ok(let object) = parseJSON(Data(trailing.utf8)), let text = object["text"] as? String {
        splitter.append(text)
      }
    }
    // A stream that stops without saying so still gets its tail spoken.
    if let failure = speak(splitter.flush()) { respondFailure(client, failure); return }
    let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
    Debug.stage("http", "\(currentRequestId) stream finished: \(spoken) sentence(s) in \(seconds)s, \(reader.totalRead) bytes in")
    respondJSON(client, 200, [
      "said": true,
      "sentences": spoken,
      "inputBytes": reader.totalRead,
      "seconds": Date().timeIntervalSince(started),
    ])
  }

  // Errors follow the OpenAI envelope because this endpoint imitates that API, so
  // existing client libraries surface the message instead of raw JSON.
  private func respondFailure(_ client: Int32, _ error: Error) {
    let status: Int
    let type: String
    var param: String?
    var code: String
    switch error {
    case FridayError.unknownVoice(_, let suggestion):
      status = 400
      type = "invalid_request_error"
      param = "voice"
      code = "unknown_voice"
      if let suggestion { Debug.stage("http", "\(currentRequestId) unknown voice, nearest is '\(suggestion)'") }
    case FridayError.usage:
      status = 400
      type = "invalid_request_error"
      code = "invalid_request"
    case FridayError.config:
      status = 500
      type = "server_error"
      code = "config_error"
    case FridayError.daemonUnavailable:
      status = 503
      type = "server_error"
      code = "daemon_unavailable"
    case FridayError.timeout:
      status = 504
      type = "server_error"
      code = "timeout"
    case FridayError.nothingCaptured:
      status = 500
      type = "server_error"
      code = "no_audio"
    case FridayError.audioOutput:
      status = 500
      type = "server_error"
      code = "audio_output_failed"
    case FridayError.voiceSubstituted(_, _, _):
      // The request was well formed and the daemon said yes; the machine cannot render
      // this voice. Distinguishable from a bad request so a client can offer advice.
      status = 500
      type = "server_error"
      param = "voice"
      code = "voice_substituted"
    case FridayError.cancelled:
      status = 409
      type = "invalid_request_error"
      code = "cancelled"
    default:
      status = 500
      type = "server_error"
      code = "internal_error"
    }
    Debug.stage("http", "\(currentRequestId) failing \(status) \(code): \(error)")
    respondError(client, status: status, type: type, message: "\(error)", param: param, code: code)
  }

  private func respondError(
    _ client: Int32,
    status: Int,
    type: String,
    message: String,
    param: String? = nil,
    code: String? = nil,
    requestId: String? = nil
  ) {
    var body: [String: Any] = ["message": message, "type": type]
    body["param"] = param ?? NSNull()
    body["code"] = code ?? NSNull()
    respondJSON(client, status, ["error": body], requestId: requestId)
  }

  // MARK: - HTTP plumbing

  private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    // True when the body uses Transfer-Encoding: chunked and is still on the socket.
    let isChunked: Bool
  }

  // Reads a chunked body straight off the socket. Bounded in both total size and
  // buffered size so a hostile or broken client cannot grow this without limit.
  private final class ChunkedBodyReader {
    private let client: Int32
    private let limit: Int
    private var buffer: Data
    private var finished = false
    private var scratch = [UInt8](repeating: 0, count: 8192)
    private(set) var totalRead = 0

    private let requestId: String
    // Called between receive attempts so a stop stays answerable while this request is
    // blocked waiting for its next chunk.
    private let tick: (() -> Void)?
    private var idleDeadline = Date()

    private static let sliceTimeout = timeval(tv_sec: 0, tv_usec: 200_000)
    private static let idleTimeout: TimeInterval = 300

    init(client: Int32, initial: Data, limit: Int, requestId: String, tick: (() -> Void)? = nil) {
      self.client = client
      self.buffer = initial
      self.limit = limit
      self.requestId = requestId
      self.tick = tick
      if tick != nil {
        var slice = ChunkedBodyReader.sliceTimeout
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &slice, socklen_t(MemoryLayout<timeval>.size))
      }
      idleDeadline = Date().addingTimeInterval(ChunkedBodyReader.idleTimeout)
    }

    // nil means "no more chunks": either a clean end or a protocol failure, which
    // `finished` and the return of readAll() distinguish.
    func next() -> Data? {
      while true {
        if let lineEnd = buffer.range(of: Data("\r\n".utf8)) {
          let sizeText = String(decoding: buffer[..<lineEnd.lowerBound], as: UTF8.self)
          // Size may carry chunk extensions after a semicolon; they are ignorable.
          let sizePart = sizeText.split(separator: ";").first.map(String.init) ?? sizeText
          guard let size = Int(sizePart.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
            Debug.stage("http", "\(requestId) bad chunk size '\(sizePart)'")
            finished = true
            return nil
          }
          if size == 0 {
            finished = true
            return nil
          }
          let needed = lineEnd.upperBound + size + 2
          guard needed <= buffer.count else {
            guard fill() else { finished = true; return nil }
            continue
          }
          guard totalRead + size <= limit else {
            Debug.stage("http", "\(requestId) chunked body exceeds \(limit) bytes")
            finished = true
            return nil
          }
          let start = lineEnd.upperBound
          let payload = buffer.subdata(in: start..<(start + size))
          buffer.removeSubrange(buffer.startIndex..<(start + size + 2))
          totalRead += size
          return payload
        }
        guard fill() else { finished = true; return nil }
      }
    }

    // Everything, for endpoints whose body must be complete before it means anything.
    func readAll() -> Data? {
      var out = Data()
      while let chunk = next() { out.append(chunk) }
      return finished ? out : nil
    }

    private func fill() -> Bool {
      // Bounded by the body limit plus framing slack, not a flat 256 KB: a client is
      // allowed to send one large chunk, and refusing to buffer past 256 KB reset the
      // connection while readAll() still advertised 4 MB.
      if buffer.count > limit + 64 * 1024 { return false }
      while true {
        let received = recv(client, &scratch, scratch.count, 0)
        if received > 0 {
          buffer.append(contentsOf: scratch[0..<received])
          idleDeadline = Date().addingTimeInterval(ChunkedBodyReader.idleTimeout)
          return true
        }
        // A timed-out receive means the producer paused, not that it is gone: keep the
        // request alive, but only for a bounded idle period.
        if received < 0, errno == EAGAIN, tick != nil {
          guard Date() < idleDeadline else {
            Debug.stage("http", "\(requestId) chunked body idle for \(Int(ChunkedBodyReader.idleTimeout))s")
            return false
          }
          tick?()
          continue
        }
        return false
      }
    }
  }

  private func readRequest(_ client: Int32) -> HTTPRequest? {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 8192)
    let headerTerminator = Data("\r\n\r\n".utf8)
    while buffer.range(of: headerTerminator) == nil {
      let received = recv(client, &chunk, chunk.count, 0)
      if received <= 0 { return nil }
      buffer.append(contentsOf: chunk[0..<received])
      if buffer.count > 256 * 1024 { return nil }
    }
    guard let headerRange = buffer.range(of: headerTerminator),
          let headerText = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
    var lines = headerText.components(separatedBy: "\r\n")
    guard !lines.isEmpty else { return nil }
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return nil }
    let method = String(requestLine[0]).uppercased()
    let path = String(requestLine[1]).split(separator: "?").first.map(String.init) ?? String(requestLine[1])
    var headers: [String: String] = [:]
    for line in lines {
      guard let separator = line.firstIndex(of: ":") else { continue }
      let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      headers[key] = value
    }
    var body = Data(buffer[buffer.index(headerRange.lowerBound, offsetBy: headerTerminator.count)...])
    if (headers["transfer-encoding"] ?? "").lowercased().contains("chunked") {
      // `body` here holds whatever arrived past the header block. It must travel with
      // the request: dropping it eats the first chunk and wrecks the framing.
      return HTTPRequest(method: method, path: path, headers: headers, body: body, isChunked: true)
    }
    let expected = Int(headers["content-length"] ?? "0") ?? 0
    if expected > 1024 * 1024 { return nil }
    while body.count < expected {
      let received = recv(client, &chunk, chunk.count, 0)
      if received <= 0 { break }
      body.append(contentsOf: chunk[0..<received])
    }
    return HTTPRequest(method: method, path: path, headers: headers, body: body, isChunked: false)
  }

  // Result needs an Error failure type; a plain enum carries the reason without
  // inventing an error type for a message that is only ever shown to the client.
  private enum BodyParse {
    case ok([String: Any])
    case rejected(String)
  }

  private func parseJSON(_ data: Data) -> BodyParse {
    guard !data.isEmpty else { return .rejected("body is empty") }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      return .rejected("invalid JSON: \(error.localizedDescription)")
    }
    guard let dictionary = object as? [String: Any] else {
      return .rejected("body must be a JSON object, got \(type(of: object))")
    }
    return .ok(dictionary)
  }

  private func respondJSON(_ client: Int32, _ status: Int, _ payload: [String: Any], requestId: String? = nil) {
    let data: Data
    do {
      data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    } catch {
      Debug.stage("http", "\(requestId ?? currentRequestId) cannot encode response: \(error)")
      let fallback = #"{"error":{"message":"cannot encode response","type":"server_error"}}"#
      respond(client, status: 500, reason: reason(for: 500), contentType: "application/json", body: Data(fallback.utf8))
      return
    }
    respond(
      client, status: status, reason: reason(for: status),
      contentType: "application/json", body: data, requestId: requestId
    )
  }

  private func reason(for status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 404: return "Not Found"
    case 409: return "Conflict"
    default: return "Internal Server Error"
    }
  }

  private func sendAll(_ client: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var sent = 0
      while sent < raw.count {
        let written = send(client, base.advanced(by: sent), raw.count - sent, 0)
        if written <= 0 { return }
        sent += written
      }
    }
  }

  // Streaming response: no Content-Length, so the body is framed in chunks and the
  // client can act on the first one instead of waiting for the whole render.
  private func beginChunkedResponse(
    _ client: Int32,
    status: Int,
    contentType: String,
    extraHeaders: [String: String] = [:]
  ) {
    var head = "HTTP/1.1 \(status) \(reason(for: status))\r\n"
    head += "Content-Type: \(contentType)\r\n"
    head += "Transfer-Encoding: chunked\r\n"
    head += "Connection: close\r\n"
    head += "X-Request-Id: \(currentRequestId)\r\n"
    for (key, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
      head += "\(key): \(value)\r\n"
    }
    head += "\r\n"
    sendAll(client, Data(head.utf8))
  }

  private func writeChunk(_ client: Int32, _ data: Data) {
    guard !data.isEmpty else { return }
    var frame = Data(String(data.count, radix: 16).utf8)
    frame.append(Data("\r\n".utf8))
    frame.append(data)
    frame.append(Data("\r\n".utf8))
    sendAll(client, frame)
  }

  private func endChunkedResponse(_ client: Int32) {
    sendAll(client, Data("0\r\n\r\n".utf8))
  }

  // `requestId` is only passed while a request runs, when a stop is answered mid-flight
  // and must not borrow the running request's id for its own reply.
  private func respond(
    _ client: Int32,
    status: Int,
    reason: String,
    contentType: String,
    body: Data,
    extraHeaders: [String: String] = [:],
    requestId: String? = nil
  ) {
    var head = "HTTP/1.1 \(status) \(reason)\r\n"
    head += "Content-Type: \(contentType)\r\n"
    head += "X-Request-Id: \(requestId ?? currentRequestId)\r\n"
    head += "Content-Length: \(body.count)\r\n"
    head += "Connection: close\r\n"
    for (key, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
      head += "\(key): \(value)\r\n"
    }
    head += "\r\n"
    var payload = Data(head.utf8)
    payload.append(body)
    sendAll(client, payload)
  }
}
