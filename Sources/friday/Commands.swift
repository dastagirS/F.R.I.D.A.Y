import Foundation
import SiriTTSService

func runServe(_ arguments: [String], config: FridayConfig) throws -> Never {
  var port: UInt16 = 8787
  var host = "127.0.0.1"
  var tokenEnvironmentName: String?
  var prewarmOnStart = false
  var iterator = arguments.makeIterator()
  while let argument = iterator.next() {
    switch argument {
    case "--port":
      guard let value = iterator.next(), let parsed = UInt16(value) else {
        throw FridayError.usage("--port needs a number")
      }
      port = parsed
    case "--host":
      host = iterator.next() ?? host
    case "--auth-token-env":
      tokenEnvironmentName = iterator.next()
    case "--prewarm":
      prewarmOnStart = true
    case "--debug":
      Debug.enable()
    case "-h", "--help":
      print(usageText)
      exit(0)
    default:
      throw FridayError.usage("unknown option for serve: \(argument)")
    }
  }
  let token = tokenEnvironmentName.flatMap { ProcessInfo.processInfo.environment[$0] }
  let catalog = try VoiceCatalog.open()
  let synthesizer = Synthesizer(catalog: catalog)
  if prewarmOnStart {
    let voice = try catalog.resolve(name: config.defaultVoice, language: nil, config: config)
    let generation = catalog.generation(requested: nil, for: voice, config: config,
                                        forceStandard: false, forceExpressive: false,
                                        voiceWasExplicit: config.defaultVoice != nil,
                                        usingBuiltInDefault: config.defaultVoice == nil)
    let seconds = try synthesizer.prewarm(voice: voice, generation: generation,
                                          pace: config.pace ?? 3, expressivity: config.expressivity ?? 3)
    FileHandle.standardError.write(String(format: "prewarmed %@ in %.2fs\n", voice.name ?? "-", seconds).data(using: .utf8)!)
  }
  let server = HTTPServer(port: port, host: host, token: token, synthesizer: synthesizer, catalog: catalog, config: config)
  try server.run()
}

func runVoices(_ arguments: [String], config: FridayConfig) throws {
  var action = "list"
  var target: String?
  var language: String?
  var waitForInstall = false
  var timeoutSeconds: TimeInterval = 300
  var force = false
  var dryRun = false
  var generationFlag: String?
  var iterator = arguments.makeIterator()
  while let argument = iterator.next() {
    switch argument {
    case "--debug": Debug.enable()
    case "--status": action = "status"; target = iterator.next()
    case "--install": action = "install"; target = iterator.next()
    case "--available": action = "available"
    case "--purge": action = "purge"; target = iterator.next()
    case "--force": force = true
    case "--dry-run": dryRun = true
    case "--standard", "--legacy": generationFlag = "standard"
    case "--expressive": generationFlag = "expressive"
    case "--manage": action = "manage"
    case "--default": action = "default"; target = iterator.next()
    case "--language": language = iterator.next()
    case "--wait": waitForInstall = true
    case "--timeout":
      guard let value = iterator.next(), let parsed = Double(value) else {
        throw FridayError.usage("--timeout needs seconds")
      }
      timeoutSeconds = parsed
    case "-h", "--help":
      print(voicesUsageText)
      return
    default:
      throw FridayError.usage("unknown option for voices: \(argument)")
    }
  }

  let catalog = try VoiceCatalog.open()
  switch action {
  case "list":
    catalog.printList()

  case "status":
    guard let target else { throw FridayError.usage("--status needs a voice name") }
    let voices = catalog.refresh()
    let match = voices.first(where: { ($0.name ?? "") == target || $0.assetKey == target }) ?? catalog.find(name: target)
    guard let match else {
      print("not-installed\t\(target)")
      return
    }
    // Asset nature and the render path that would actually be used are different
    // questions, and printing only the first is misleading for a voice like
    // simone, whose asset is expressive but whose default render is standard.
    // "Would a bare `friday` speak with this voice?" decides the render path shown
    // here, which means the configured default, else the built-in default.
    let isDefaultSelection: Bool
    if let configured = config.defaultVoice {
      isDefaultSelection = configured == match.name
    } else {
      isDefaultSelection = match.name == FridayConfig.builtInVoice
    }
    let render = catalog.generation(requested: nil, for: match, config: config,
                                    forceStandard: false, forceExpressive: false,
                                    voiceWasExplicit: !isDefaultSelection,
                                    usingBuiltInDefault: isDefaultSelection && config.defaultVoice == nil)
    print("installed\t\(match.language)\t\(match.name ?? "-")\tasset=\(VoiceCatalog.generation(match))\tdefault-render=\(render)\t\(match.assetKey)")

  case "available":
    let assets = try listCatalogAssets()
    let local = localAssetSpecifiers()
    for asset in assets.sorted(by: { ($0.language, $0.name) < ($1.language, $1.name) }) {
      let installed = local[asset.specifier] != nil || asset.locallyAvailable
      let size = asset.downloadBytes > 0 ? String(format: "%.0fMB", Double(asset.downloadBytes) / 1_048_576.0) : "?"
      print("\(installed ? "installed" : "available")\t\(asset.language)\t\(asset.name)\t\(asset.technology)/\(asset.quality)\t\(size)\t\(asset.specifier)")
    }
    if assets.isEmpty { print("the catalog returned no assets") }

  case "purge":
    guard let target else { throw FridayError.usage("--purge needs a voice name") }
    // Purging is not undoable by re-running the command, so the ABI is validated
    // before anything else can go wrong.
    try validateEliminationABI()
    let assets = try listCatalogAssets()
    var matches = assets.filter { $0.name == target || $0.identifier == target || $0.specifier == target }
    if matches.isEmpty { matches = assets.filter { $0.name.lowercased() == target.lowercased() } }
    guard !matches.isEmpty else {
      throw FridayError.config("no catalog asset matches '\(target)'; run 'friday voices --available'")
    }
    // Deleting the wrong bundle is not recoverable by re-running the command, so
    // an ambiguous name is refused rather than guessed at.
    guard matches.count == 1 else {
      throw FridayError.usage("\(matches.count) catalog assets match '\(target)'; refusing to guess. Use a full specifier.")
    }
    let asset = matches[0]
    let specifier = asset.specifier
    guard let version = localAssetSpecifiers()[specifier] else {
      print("not-installed\t\(specifier)")
      return
    }
    guard force, !dryRun else {
      print("would-remove\t\(specifier)\tversion \(version)")
      if !force { print("pass --force to actually delete it") }
      return
    }
    try eliminateAsset(specifier: specifier)
    if localAssetSpecifiers()[specifier] == nil {
      print("removed\t\(specifier)")
    } else {
      print("still-present\t\(specifier)")
      throw FridayError.config("elimination did not remove the asset; the filesystem is the source of truth")
    }

  case "install":
    guard let target else { throw FridayError.usage("--install needs a voice name") }
    if let existing = catalog.find(name: target) {
      print("already-installed\t\(existing.language)\t\(existing.name ?? "-")\t\(existing.assetKey)")
      return
    }
    guard let language else {
      throw FridayError.usage("--install needs --language for a voice that is not installed yet, e.g. --language en-GB")
    }
    let voice = SynthesisVoice(language: language, name: target)
    let subscribeDone = DispatchSemaphore(value: 0)
    var subscribeError: Error?
    catalog.session.subscribe(voices: [voice]) { error in
      subscribeError = error
      subscribeDone.signal()
    }
    guard pumpRunLoop(subscribeDone, timeout: 30) else {
      throw FridayError.timeout(stage: "a voice download request", seconds: 30)
    }
    if let subscribeError { throw FridayError.synthesisFailed("\(subscribeError)") }
    print("requested\t\(language)\t\(target)\t(download is asynchronous)")
    guard waitForInstall else { return }
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
      if catalog.refresh().contains(where: { ($0.name ?? "") == target }) {
        print("installed\t\(language)\t\(target)")
        return
      }
      Thread.sleep(forTimeInterval: 2)
    }
    throw FridayError.timeout(
      stage: "'\(target)' to finish downloading", seconds: timeoutSeconds
    )

  case "manage":
    let url = "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url]
    do {
      try process.run()
    } catch {
      throw FridayError.audioOutput("cannot open System Settings: \(error.localizedDescription); open it manually: \(url)")
    }
    print("opened System Settings -> Accessibility -> Spoken Content")

  case "default":
    guard let target else { throw FridayError.usage("--default needs a voice name") }
    guard let match = catalog.find(name: target) else {
      throw FridayError.unknownVoice(target, suggestion: catalog.suggestion(for: target))
    }
    var updated = config
    updated.defaultVoice = match.name ?? target
    // Without an explicit flag the asset's own nature decides, but passing
    // --standard is how you say "this voice, on the calm path".
    updated.defaultGeneration = generationFlag ?? (VoiceCatalog.isExpressive(match) ? "expressive" : "standard")
    try updated.save()
    print("default voice: \(updated.defaultVoice!) (\(updated.defaultGeneration!))  -> \(FridayConfig.fileURL.path)")

  default:
    throw FridayError.usage("unknown voices action")
  }
}

// Streaming stdin: speak each sentence as soon as its boundary is proven, so the first
// words play while the producer is still writing. The tail is spoken on EOF or when a
// forced split bounds it. Ctrl-C cancels the sentence in flight and also ends the wait
// for more input, so a stalled producer cannot make the process unstoppable.
func runStreamingStdin(
  voice: SynthesisVoice,
  generation: String,
  pace: Int,
  expressivity: Int,
  rate: Float,
  pitch: Float,
  volume: Float,
  chunkSentences: Bool,
  lossless: Bool,
  quiet: Bool
) throws {
  let synthesizer = Synthesizer(catalog: try VoiceCatalog.open())
  // One request from the session's point of view: the cancel flag is cleared here, so a
  // Ctrl-C during one sentence ends the whole stream instead of being cleared by the next
  // synthesis.
  synthesizer.beginRequest()
  // Ctrl-C while waiting for input cancels nothing in flight, so the wait itself has to
  // end: without this flag the loop keeps polling a producer that will never speak.
  var interrupted = false
  signal(SIGINT, SIG_IGN)
  let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
  interruptSource.setEventHandler {
    interrupted = true
    synthesizer.cancelActive()
  }
  interruptSource.resume()

  var splitter = StreamingSentenceSplitter()
  var spoken = 0
  var audioSeconds = 0.0
  var firstAudioMilliseconds = -1.0
  var failure: Error?
  var finishedReading = false
  let started = Date()

  func speak(_ sentence: String) {
    guard failure == nil else { return }
    do {
      let outcome = try synthesizer.synthesize(
        text: sentence, voice: voice, generation: generation,
        pace: pace, expressivity: expressivity, rate: rate, pitch: pitch, volume: volume,
        wantsTimings: false, playback: true,
        // Each piece is already a sentence, so splitting again would only add round trips.
        chunkSentences: false, lossless: lossless
      )
      spoken += 1
      audioSeconds += outcome.audioSeconds
      if firstAudioMilliseconds < 0 { firstAudioMilliseconds = outcome.firstAudioMilliseconds }
      Debug.stage("stream", "spoke \(spoken) (\(sentence.count) chars) at \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000))ms")
    } catch {
      failure = error
    }
  }

  func consume(_ text: String) {
    guard failure == nil, !text.isEmpty else { return }
    splitter.append(text)
    for sentence in splitter.takeSentences() { speak(sentence) }
  }

  // Reads happen off the main thread. `availableData` blocks until bytes exist, and a
  // stalled producer would otherwise freeze the run loop that delivers Ctrl-C, leaving
  // a process no signal could stop. Decoded text hops back to main so synthesis stays
  // on the thread sirittsd expects.
  let reading = DispatchQueue(label: "friday.stdin")
  reading.async {
    var decoder = IncrementalUTF8Decoder()
    while true {
      let data = FileHandle.standardInput.availableData
      if data.isEmpty {
        let tail = decoder.finish()
        DispatchQueue.main.async {
          consume(tail)
          finishedReading = true
        }
        return
      }
      let text = decoder.append(data)
      guard !text.isEmpty else { continue }
      DispatchQueue.main.async { consume(text) }
    }
  }

  // Pumping the run loop is what lets the SIGINT source fire between reads.
  while !finishedReading && failure == nil && !interrupted {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
  }
  if let failure { throw failure }
  if interrupted { throw FridayError.cancelled }
  for sentence in splitter.flush() { speak(sentence) }
  if let failure { throw failure }

  guard spoken > 0 else {
    throw FridayError.emptyInput("stdin closed before a complete sentence arrived")
  }
  if !quiet {
    FileHandle.standardError.write(String(
      format: "streamed=%d audio=%.2fs first_audio=%.0fms wall=%.2fs\n",
      spoken, audioSeconds, firstAudioMilliseconds, Date().timeIntervalSince(started)
    ).data(using: .utf8)!)
  }
}

// Barge-in for a request someone else started: a server, a script, a UI. The server
// serves this while a request is in flight, so it does not queue behind the answer it
// is cancelling.
func runStop(_ arguments: [String]) throws {
  var port: UInt16 = 8787
  var host = "127.0.0.1"
  var requestId: String?
  var tokenEnvironmentName: String?
  var iterator = arguments.makeIterator()
  while let argument = iterator.next() {
    switch argument {
    case "--port":
      guard let value = iterator.next(), let parsed = UInt16(value) else {
        throw FridayError.usage("--port needs a number")
      }
      port = parsed
    case "--host":
      guard let value = iterator.next() else { throw FridayError.usage("--host needs a value") }
      host = value
    case "--request-id":
      guard let value = iterator.next() else { throw FridayError.usage("--request-id needs a value") }
      requestId = value
    case "--auth-token-env":
      guard let value = iterator.next() else { throw FridayError.usage("--auth-token-env needs a name") }
      tokenEnvironmentName = value
    case "--debug":
      Debug.enable()
    case "-h", "--help":
      print(usageText)
      exit(0)
    default:
      throw FridayError.usage("unknown option for stop: \(argument)")
    }
  }

  guard let url = URL(string: "http://\(host):\(port)/stop") else {
    throw FridayError.usage("invalid host '\(host)'")
  }
  var request = URLRequest(url: url)
  request.httpMethod = "POST"
  request.timeoutInterval = 10
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  var payload: [String: Any] = [:]
  if let requestId { payload["request_id"] = requestId }
  request.httpBody = try JSONSerialization.data(withJSONObject: payload)
  if let tokenEnvironmentName, let token = ProcessInfo.processInfo.environment[tokenEnvironmentName] {
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
  }

  let finished = DispatchSemaphore(value: 0)
  var response: (status: Int, body: Data)?
  var transportError: Error?
  URLSession.shared.dataTask(with: request) { data, urlResponse, error in
    transportError = error
    if let http = urlResponse as? HTTPURLResponse {
      response = (http.statusCode, data ?? Data())
    }
    finished.signal()
  }.resume()

  guard pumpRunLoop(finished, timeout: 15) else {
    throw FridayError.timeout(stage: "the friday server to answer /stop", seconds: 15)
  }
  if let transportError {
    throw FridayError.serverUnreachable("\(host):\(port) (\(transportError.localizedDescription))")
  }
  guard let response else {
    throw FridayError.serverUnreachable("\(host):\(port) (no response)")
  }
  let text = String(decoding: response.body, as: UTF8.self)
  guard response.status == 200 else {
    throw FridayError.usage("the server refused the stop (\(response.status)): \(text)")
  }
  print(text)
}

func runConfig(_ arguments: [String], config: FridayConfig) throws {
  var updated = config
  var iterator = arguments.makeIterator()
  var verbs: [String] = []
  var generationFlag: String?
  while let argument = iterator.next() {
    switch argument {
    case "--debug": Debug.enable()
    case "--standard", "--legacy": generationFlag = "standard"
    case "--expressive": generationFlag = "expressive"
    case "-h", "--help":
      print(configUsageText)
      return
    default: verbs.append(argument)
    }
  }

  func save() throws {
    try updated.save()
    print("wrote \(FridayConfig.fileURL.path)")
  }

  switch verbs.first {
  case nil:
    print("file\t\(FridayConfig.fileURL.path)\(FileManager.default.fileExists(atPath: FridayConfig.fileURL.path) ? "" : " (missing, using built-ins)")")
    print("default-voice\t\(updated.defaultVoice ?? "\(FridayConfig.builtInVoice) (built-in)")")
    print("default-generation\t\(updated.defaultGeneration ?? "standard (built-in)")")
    print("pace\t\(updated.pace.map(String.init) ?? "3 (built-in)")")
    print("expressivity\t\(updated.expressivity.map(String.init) ?? "3 (built-in)")")
    let chunking = updated.sentenceChunking ?? FridayConfig.builtInSentenceChunking
    print("sentence-chunking\t\(chunking ? "on" : "off")\(updated.sentenceChunking == nil ? " (built-in)" : "")")
    let lossless = updated.lossless ?? FridayConfig.builtInLossless
    print("lossless\t\(lossless ? "on" : "off")\(updated.lossless == nil ? " (built-in)" : "")")

  case "set":
    guard verbs.count >= 3 else { throw FridayError.usage("config set needs a key and a value") }
    let key = verbs[1]
    let value = verbs[2...].joined(separator: " ")
    switch key {
    case "default-voice":
      // Validate against installed voices so a typo cannot silently persist.
      let catalog = try VoiceCatalog.open()
      guard let match = catalog.find(name: value) else {
        throw FridayError.unknownVoice(value, suggestion: catalog.suggestion(for: value))
      }
      updated.defaultVoice = match.name ?? value
      if let generationFlag {
        updated.defaultGeneration = generationFlag
      } else {
        updated.defaultGeneration = VoiceCatalog.isExpressive(match) ? "expressive" : "standard"
      }
      try save()
    case "default-generation":
      guard let normalized = FridayConfig.normalizeGeneration(value) else {
        throw FridayError.usage("default-generation must be standard or expressive")
      }
      updated.defaultGeneration = normalized
      try save()
    case "sentence-chunking":
      guard let parsed = parseOnOff(value) else {
        throw FridayError.usage("sentence-chunking must be on or off")
      }
      updated.sentenceChunking = parsed
      try save()
    case "lossless":
      guard let parsed = parseOnOff(value) else {
        throw FridayError.usage("lossless must be on or off")
      }
      updated.lossless = parsed
      try save()
    case "pace", "expressivity":
      guard let number = Int(value), (1...5).contains(number) else {
        throw FridayError.usage("\(key) must be 1 through 5")
      }
      if key == "pace" { updated.pace = number } else { updated.expressivity = number }
      try save()
    default:
      throw FridayError.usage("unknown key '\(key)'; use default-voice, default-generation, sentence-chunking, lossless, pace, expressivity")
    }

  case "unset":
    guard verbs.count >= 2 else { throw FridayError.usage("config unset needs a key") }
    switch verbs[1] {
    case "default-voice":
      updated.defaultVoice = nil
      // default-generation was derived from the voice that chose it, so it goes too.
      updated.defaultGeneration = nil
    case "default-generation": updated.defaultGeneration = nil
    case "sentence-chunking": updated.sentenceChunking = nil
    case "lossless": updated.lossless = nil
    case "pace": updated.pace = nil
    case "expressivity": updated.expressivity = nil
    default: throw FridayError.usage("unknown key '\(verbs[1])'")
    }
    try save()

  case "reset":
    updated = FridayConfig()
    try save()

  default:
    throw FridayError.usage("unknown config action '\(verbs.first!)'")
  }
}
