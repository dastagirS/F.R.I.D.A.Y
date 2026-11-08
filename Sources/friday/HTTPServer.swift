import Foundation

// Minimal HTTP/1.1 server: no dependencies, one request at a time, loopback by
// default. Everything runs on the main thread because sirittsd delivers its
// callbacks on the main run loop.
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

  private func handle(_ client: Int32) {
    currentRequestId = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    let started = Date()
    guard let request = readRequest(client) else {
      Debug.stage("http", "\(currentRequestId) malformed request line or headers")
      respondError(client, status: 400, type: "invalid_request_error",
                   message: "malformed HTTP request", code: "malformed_request")
      return
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
    route(request, client: client)
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
      synthesizer.cancelActive()
      respondJSON(client, 200, ["stopped": true])

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
    do {
      let voice = try catalog.resolve(name: requestedVoice, language: nil, config: config)
      let generation = catalog.generation(
        requested: requestedGeneration, for: voice, config: config,
        forceStandard: false, forceExpressive: false,
        voiceWasExplicit: requestedVoice != nil,
        usingBuiltInDefault: requestedVoice == nil && config.defaultVoice == nil
      )
      let outcome = try synthesizer.synthesize(
        text: input, voice: voice, generation: generation,
        pace: config.pace ?? 3, expressivity: config.expressivity ?? 3,
        rate: max(0.25, min(4.0, speed)), pitch: 1.0, volume: 1.0,
        wantsTimings: false, playback: false,
        chunkSentences: config.sentenceChunking ?? FridayConfig.builtInSentenceChunking,
        lossless: config.lossless ?? FridayConfig.builtInLossless
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
      let voice = try catalog.resolve(name: body["voice"] as? String, language: nil, config: config)
      let generation = catalog.generation(
        requested: body["generation"] as? String, for: voice, config: config,
        forceStandard: false, forceExpressive: false,
        voiceWasExplicit: (body["voice"] as? String) != nil,
        usingBuiltInDefault: (body["voice"] as? String) == nil && config.defaultVoice == nil
      )
      let outcome = try synthesizer.synthesize(
        text: text, voice: voice, generation: generation,
        pace: config.pace ?? 3, expressivity: config.expressivity ?? 3,
        rate: 1.0, pitch: 1.0, volume: 1.0,
        wantsTimings: false, playback: true,
        chunkSentences: config.sentenceChunking ?? FridayConfig.builtInSentenceChunking,
        lossless: config.lossless ?? FridayConfig.builtInLossless
      )
      respondJSON(client, 200, ["said": true, "voice": outcome.voiceName, "generation": outcome.generation])
    } catch {
      respondFailure(client, error)
    }
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
    code: String? = nil
  ) {
    var body: [String: Any] = ["message": message, "type": type]
    body["param"] = param ?? NSNull()
    body["code"] = code ?? NSNull()
    respondJSON(client, status, ["error": body])
  }

  // MARK: - HTTP plumbing

  private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
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
    let expected = Int(headers["content-length"] ?? "0") ?? 0
    if expected > 1024 * 1024 { return nil }
    while body.count < expected {
      let received = recv(client, &chunk, chunk.count, 0)
      if received <= 0 { break }
      body.append(contentsOf: chunk[0..<received])
    }
    return HTTPRequest(method: method, path: path, headers: headers, body: body)
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

  private func respondJSON(_ client: Int32, _ status: Int, _ payload: [String: Any]) {
    let data: Data
    do {
      data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    } catch {
      Debug.stage("http", "\(currentRequestId) cannot encode response: \(error)")
      let fallback = #"{"error":{"message":"cannot encode response","type":"server_error"}}"#
      respond(client, status: 500, reason: reason(for: 500), contentType: "application/json", body: Data(fallback.utf8))
      return
    }
    respond(client, status: status, reason: reason(for: status), contentType: "application/json", body: data)
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

  private func respond(_ client: Int32, status: Int, reason: String, contentType: String, body: Data, extraHeaders: [String: String] = [:]) {
    var head = "HTTP/1.1 \(status) \(reason)\r\n"
    head += "Content-Type: \(contentType)\r\n"
    head += "X-Request-Id: \(currentRequestId)\r\n"
    head += "Content-Length: \(body.count)\r\n"
    head += "Connection: close\r\n"
    for (key, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
      head += "\(key): \(value)\r\n"
    }
    head += "\r\n"
    var payload = Data(head.utf8)
    payload.append(body)
    payload.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var sent = 0
      while sent < raw.count {
        let written = send(client, base.advanced(by: sent), raw.count - sent, 0)
        if written <= 0 { return }
        sent += written
      }
    }
  }
}
