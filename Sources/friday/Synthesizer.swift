import AVFoundation
import Foundation
import SiriTTSService

struct SynthesisOutcome {
  let voiceName: String
  let language: String
  let generation: String
  let sourceFormat: String
  let firstAudioMilliseconds: Double
  let synthesisSeconds: Double
  let audioSeconds: Double
  let samples: [Float]
  let timings: TimingReport
  let chunkCount: Int
}

// Owns every synthesis so the CLI, the prewarmer and the HTTP server share one
// code path. Exactly one synthesis runs at a time, because sirittsd serialises
// per session anyway and interleaved audio would be unusable.
final class Synthesizer {
  private let catalog: VoiceCatalog
  private let workLock = NSLock()
  private let stateLock = NSLock()
  private var activeSession: DaemonSession?
  private var activeRequest: BaseRequest?
  private var activeSpeaker: Speaker?
  private var activeFinish: DispatchSemaphore?
  private var cancelled = false
  private var lastSpeaker: Speaker?

  init(catalog: VoiceCatalog) {
    self.catalog = catalog
  }

  // Barge-in: cancel the daemon request, drop queued audio, unblock the waiter.
  func cancelActive() {
    stateLock.lock()
    cancelled = true
    let session = activeSession
    let request = activeRequest
    let speaker = activeSpeaker ?? lastSpeaker
    let finish = activeFinish
    stateLock.unlock()
    if let session, let request { session.cancel(request: request) }
    speaker?.stop()
    finish?.signal()
  }

  func prewarm(voice: SynthesisVoice, generation: String, pace: Int, expressivity: Int) throws -> Double {
    workLock.lock()
    defer { workLock.unlock() }
    let session = try sessionFor(generation: generation, voice: voice, pace: pace, expressivity: expressivity)
    let request = SynthesisRequest(text: "prewarm", voice: voice)
    if generation == "expressive" { try applyExpressivePresets(to: request, pace: pace, expressivity: expressivity) }
    let start = Date()
    let finish = DispatchSemaphore(value: 0)
    var failure: Error?
    session.prewarm(request: request) { error in
      failure = error
      finish.signal()
    }
    guard pumpRunLoop(finish, timeout: 120) else {
      throw FridayError.timeout(stage: "the prewarm request", seconds: 120)
    }
    if let failure { throw FridayError.synthesisFailed("\(failure)") }
    return Date().timeIntervalSince(start)
  }

  private func sessionFor(generation: String, voice: SynthesisVoice, pace: Int, expressivity: Int) throws -> DaemonSession {
    guard generation == "expressive" else { return catalog.session }
    let session = DaemonSession()
    session.keepActive = true
    // Expressive voices only engage for the daemon's expressive client identity;
    // without it the daemon quietly substitutes a generic legacy render.
    session._clientId = "com.apple.siritts-tool"
    guard session.invokeDaemon() else { throw FridayError.daemonUnavailable }
    return session
  }

  private func applyExpressivePresets(to request: SynthesisRequest, pace: Int, expressivity: Int) throws {
    guard (1...5).contains(pace), (1...5).contains(expressivity) else {
      throw FridayError.usage("pace and expressivity must be 1 through 5")
    }
    for (key, value) in [("voicePacePreset", pace), ("voiceExpressivityPreset", expressivity)] {
      let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
      guard request.synthesisContext.responds(to: NSSelectorFromString(setter)) else {
        throw FridayError.config("this macOS build does not expose \(key)")
      }
      request.synthesisContext.setValue(value, forKey: key)
    }
  }

  func synthesize(
    text: String,
    voice: SynthesisVoice,
    generation: String,
    pace: Int,
    expressivity: Int,
    rate: Float,
    pitch: Float,
    volume: Float,
    wantsTimings: Bool,
    playback: Bool,
    chunkSentences: Bool,
    lossless: Bool
  ) throws -> SynthesisOutcome {
    workLock.lock()
    defer { workLock.unlock() }

    let session = try sessionFor(generation: generation, voice: voice, pace: pace, expressivity: expressivity)
    // Only worth splitting when it yields more than one utterance; otherwise the
    // original text is sent untouched, which keeps single-sentence renders exactly
    // as they were before chunking existed.
    let plannedChunks = chunkSentences ? TextChunker.chunks(from: text) : []
    let utterances = plannedChunks.count > 1 ? plannedChunks : [TextChunk(text: text, utf16Location: 0)]
    Debug.stage("plan", "\(utterances.count) request(s), \(text.count) chars, chunking=\(chunkSentences), lossless=\(lossless)")

    let decoder = ChunkDecoder()
    let speaker = playback ? Speaker() : nil
    var samples: [Float] = []
    var anchors: [TimingAnchor] = []
    var formats: [String] = []

    // The expressive model returns no word timings at all, so asking is pointless.
    var timingsSupported = false
    let wantsWordTimings = wantsTimings && generation != "expressive"
    if wantsWordTimings {
      let semaphore = DispatchSemaphore(value: 0)
      session.queryWordTimingSupport(voice: voice) { supported in
        timingsSupported = supported
        semaphore.signal()
      }
      _ = pumpRunLoop(semaphore, timeout: 5)
    }

    let start = Date()
    var firstAudioAt: Date?
    var audioSecondsBefore = 0.0
    var wasCancelled = false

    stateLock.lock()
    cancelled = false
    lastSpeaker = speaker
    stateLock.unlock()

    for (index, utterance) in utterances.enumerated() {
      // The daemon answers lossless PCM for the first synthesis after its compiled
      // cache is dropped, then falls back to ~50 kbps Opus. Clearing per request keeps
      // every sentence on the lossless encoder; measured cost is ~0.45 s of synthesis
      // per sentence instead of 0.02 s, paid once before the first audio.
      if lossless {
        session.clearDeviceCache()
        Debug.stage("cache", "cleared device cache before request")
      }
      let request = SynthesisRequest(text: utterance.text, voice: voice)
      request.synthesisContext.rate = rate
      request.synthesisContext.pitch = pitch
      request.synthesisContext.volume = volume
      if generation == "expressive" { try applyExpressivePresets(to: request, pace: pace, expressivity: expressivity) }

      var chunkFrames = 0
      var undecodable = 0
      request.synthesisContext.didGenerateAudio = { chunk in
        // The daemon ends every request with an empty chunk carrying a zeroed
        // description. That is not a failure; counting it would warn on every render.
        guard !chunk.audioData.isEmpty else { return }
        guard let buffer = decoder.decode(chunk) else {
          undecodable += 1
          Debug.stage("decode", "chunk failed: \(chunk.audioData.count) bytes, asbd=\(fourCharacterCode(chunk.asbd.mFormatID)) \(Int(chunk.asbd.mSampleRate))Hz")
          return
        }
        chunkFrames += Int(buffer.frameLength)
        let described = decoder.describedFormat
        if !formats.contains(described) { formats.append(described) }
        if firstAudioAt == nil { firstAudioAt = Date() }
        if let speaker {
          speaker.enqueue(buffer)
        } else if let channel = buffer.floatChannelData?[0] {
          samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
      }
      if wantsWordTimings {
        // The daemon emits timings in batches, so batches are accumulated and
        // de-duplicated by UTF-16 range. Overwriting lost every earlier batch:
        // a 44-word sentence delivered only 16 words. Both the text range and the
        // start time are rebased, otherwise the second sentence collides with the
        // first on the timeline and reuses its offsets.
        let locationBase = utterance.utf16Location
        let timeBase = audioSecondsBefore
        request.synthesisContext.didGenerateWordTimings = { reported in
          for entry in reported {
            let shifted = NSRange(
              location: entry.textRange.location + locationBase,
              length: entry.textRange.length
            )
            guard !anchors.contains(where: {
              $0.textRange.location == shifted.location && $0.textRange.length == shifted.length
            }) else { continue }
            anchors.append(TimingAnchor(textRange: shifted, startTime: entry.startTime + timeBase))
          }
        }
      }

      let finish = DispatchSemaphore(value: 0)
      stateLock.lock()
      activeSession = session
      activeRequest = request
      activeSpeaker = speaker
      activeFinish = finish
      stateLock.unlock()

      var synthesisError: Error?
      session.synthesize(request: request) { error in
        synthesisError = error
        finish.signal()
      }
      let completed = pumpRunLoop(finish, timeout: 120)

      stateLock.lock()
      let cancelledNow = cancelled
      activeSession = nil
      activeRequest = nil
      activeSpeaker = nil
      activeFinish = nil
      stateLock.unlock()

      // A barge-in stops the whole utterance, not just the sentence in flight.
      if cancelledNow { wasCancelled = true; break }
      guard completed else {
        throw FridayError.timeout(
          stage: "synthesis of request \(index + 1) of \(utterances.count) (\(utterance.text.count) characters)",
          seconds: 120
        )
      }
      if let synthesisError {
        throw FridayError.synthesisFailed("\(synthesisError) [request \(index + 1) of \(utterances.count)]")
      }
      if undecodable > 0 {
        // Silent drops used to make this look like a rendering quirk: audio simply had holes.
        FileHandle.standardError.write(
          "friday: warning: \(undecodable) audio chunk(s) from request \(index + 1) could not be decoded and were skipped\n"
            .data(using: .utf8)!)
      }
      Debug.stage("chunk", "\(index + 1)/\(utterances.count) \(utterance.text.count) chars src=\(decoder.describedFormat) frames=\(chunkFrames) undecodable=\(undecodable)")
      audioSecondsBefore += Double(chunkFrames) / 48000.0
    }

    if wasCancelled { throw FridayError.cancelled }

    let synthesisSeconds = Date().timeIntervalSince(start)
    let firstAudioMilliseconds = firstAudioAt.map { $0.timeIntervalSince(start) * 1000 } ?? -1
    if let speaker {
      speaker.finish()
      let drained = pumpRunLoop(speaker.drained, timeout: 900)
      if let failure = speaker.startupFailure {
        throw FridayError.audioOutput("cannot play audio: \(failure.localizedDescription)")
      }
      if !drained {
        throw FridayError.timeout(stage: "playback to finish", seconds: 900)
      }
      Debug.stage("playback", "drained \(speaker.framesEnqueued) frames")
    }
    // Chunked rendering finishes synthesising long before playback ends, so a
    // barge-in usually lands here rather than inside the loop above.
    stateLock.lock()
    let cancelledDuringPlayback = cancelled
    stateLock.unlock()
    if cancelledDuringPlayback { throw FridayError.cancelled }
    let collectedSeconds = Double(samples.count) / 48000.0
    let playedSeconds = Double(speaker?.framesEnqueued ?? 0) / 48000.0
    let audioSeconds = max(collectedSeconds, playedSeconds)
    guard audioSeconds > 0 else {
      throw FridayError.nothingCaptured(
        chunks: utterances.count,
        formats: formats.isEmpty ? decoder.describedFormat : formats.joined(separator: ", ")
      )
    }
    Debug.stage("done", "audio=\(String(format: "%.2f", audioSeconds))s formats=\(formats.joined(separator: ", "))")
    let timings = makeTimingReport(
      voice: voice,
      sourceText: text,
      raw: anchors,
      supported: timingsSupported,
      generation: generation,
      audioSeconds: audioSeconds
    )
    return SynthesisOutcome(
      voiceName: voice.name ?? "-",
      language: voice.language,
      generation: generation,
      sourceFormat: formats.isEmpty ? decoder.describedFormat : formats.joined(separator: "+"),
      firstAudioMilliseconds: firstAudioMilliseconds,
      synthesisSeconds: synthesisSeconds,
      audioSeconds: audioSeconds,
      samples: samples,
      timings: timings,
      chunkCount: utterances.count
    )
  }
}
