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
    guard pumpRunLoop(finish, timeout: 120) else { throw FridayError.timeout }
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
    playback: Bool
  ) throws -> SynthesisOutcome {
    workLock.lock()
    defer { workLock.unlock() }

    let session = try sessionFor(generation: generation, voice: voice, pace: pace, expressivity: expressivity)
    let request = SynthesisRequest(text: text, voice: voice)
    request.synthesisContext.rate = rate
    request.synthesisContext.pitch = pitch
    request.synthesisContext.volume = volume
    if generation == "expressive" { try applyExpressivePresets(to: request, pace: pace, expressivity: expressivity) }

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

    let decoder = ChunkDecoder()
    let speaker = playback ? Speaker() : nil
    var samples: [Float] = []
    var rawTimings: [WordTimingInfo] = []
    let start = Date()
    var firstAudioAt: Date?

    request.synthesisContext.didGenerateAudio = { chunk in
      guard let buffer = decoder.decode(chunk) else { return }
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
      // a 44-word sentence delivered only 16 words.
      request.synthesisContext.didGenerateWordTimings = { reported in
        for entry in reported where !rawTimings.contains(where: {
          $0.textRange.location == entry.textRange.location && $0.textRange.length == entry.textRange.length
        }) {
          rawTimings.append(entry)
        }
      }
    }

    let finish = DispatchSemaphore(value: 0)
    stateLock.lock()
    cancelled = false
    activeSession = session
    activeRequest = request
    activeSpeaker = speaker
    lastSpeaker = speaker
    activeFinish = finish
    stateLock.unlock()

    var synthesisError: Error?
    session.synthesize(request: request) { error in
      synthesisError = error
      finish.signal()
    }
    let completed = pumpRunLoop(finish, timeout: 120)

    stateLock.lock()
    let wasCancelled = cancelled
    activeSession = nil
    activeRequest = nil
    activeSpeaker = nil
    activeFinish = nil
    stateLock.unlock()

    if wasCancelled { throw FridayError.cancelled }
    guard completed else { throw FridayError.timeout }
    if let synthesisError { throw FridayError.synthesisFailed("\(synthesisError)") }

    let synthesisSeconds = Date().timeIntervalSince(start)
    let firstAudioMilliseconds = firstAudioAt.map { $0.timeIntervalSince(start) * 1000 } ?? -1
    if let speaker {
      speaker.finish()
      _ = pumpRunLoop(speaker.drained, timeout: 900)
    }
    let collectedSeconds = Double(samples.count) / 48000.0
    let playedSeconds = Double(speaker?.framesEnqueued ?? 0) / 48000.0
    let audioSeconds = max(collectedSeconds, playedSeconds)
    let timings = makeTimingReport(
      voice: voice,
      sourceText: text,
      raw: rawTimings,
      supported: timingsSupported,
      generation: generation,
      audioSeconds: audioSeconds
    )
    return SynthesisOutcome(
      voiceName: voice.name ?? "-",
      language: voice.language,
      generation: generation,
      sourceFormat: decoder.describedFormat,
      firstAudioMilliseconds: firstAudioMilliseconds,
      synthesisSeconds: synthesisSeconds,
      audioSeconds: audioSeconds,
      samples: samples,
      timings: timings
    )
  }
}
