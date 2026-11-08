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
    guard let request = readRequest(client) else {
      respond(client, status: 400, reason: "Bad Request", contentType: "application/json",
              body: Data(#"{"error":{"message":"malformed request"}}"#.utf8))
      return
    }
    if let token, !token.isEmpty {
      guard request.headers["authorization"] == "Bearer \(token)" else {
        respond(client, status: 401, reason: "Unauthorized", contentType: "application/json",
                body: Data(#"{"error":{"message":"missing or bad bearer token"}}"#.utf8))
        return
      }
    }
    route(request, client: client)
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
      respondJSON(client, 404, ["error": ["message": "no route for \(request.method) \(request.path)"]])
    }
  }

  private func handleSpeech(_ request: HTTPRequest, client: Int32) {
    guard let body = parseJSON(request.body) else {
      respondJSON(client, 400, ["error": ["message": "body must be JSON"]])
      return
    }
    guard let input = body["input"] as? String, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      respondJSON(client, 400, ["error": ["message": "'input' is required"]])
      return
    }
    let requestedVoice = body["voice"] as? String
    let requestedGeneration = body["generation"] as? String
    let format = (body["response_format"] as? String ?? "wav").lowercased()
    let speed = Float(body["speed"] as? Double ?? 1.0)
    guard format == "wav" || format == "pcm" else {
      respondJSON(client, 400, ["error": ["message": "response_format must be wav or pcm"]])
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
        chunkSentences: config.sentenceChunking ?? FridayConfig.builtInSentenceChunking
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
    guard let body = parseJSON(request.body), let text = body["text"] as? String, !text.isEmpty else {
      respondJSON(client, 400, ["error": ["message": "'text' is required"]])
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
        chunkSentences: config.sentenceChunking ?? FridayConfig.builtInSentenceChunking
      )
      respondJSON(client, 200, ["said": true, "voice": outcome.voiceName, "generation": outcome.generation])
    } catch {
      respondFailure(client, error)
    }
  }

  private func respondFailure(_ client: Int32, _ error: Error) {
    let status: Int
    switch error {
    case FridayError.unknownVoice: status = 404
    case FridayError.usage, FridayError.config: status = 400
    case FridayError.cancelled: status = 409
    default: status = 500
    }
    respondJSON(client, status, ["error": ["message": "\(error)"]])
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

  private func parseJSON(_ data: Data) -> [String: Any]? {
    guard !data.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else { return nil }
    return dictionary
  }

  private func respondJSON(_ client: Int32, _ status: Int, _ payload: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
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
