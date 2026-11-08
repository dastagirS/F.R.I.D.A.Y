import AVFoundation
import Foundation

// Plays decoded buffers as they arrive so audio starts long before the whole
// utterance is rendered. Everything is 48 kHz float mono by the time it lands
// here, because ChunkDecoder already normalised it.
final class Speaker {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
  private var started = false
  private var pendingBuffers = 0
  private var totalBuffers = 0
  private var synthesisDone = false
  private var stopped = false
  private(set) var framesEnqueued = 0
  // Set when AVAudioEngine refuses to start; the caller turns this into exit code 9
  // instead of reporting a successful utterance that made no sound.
  private(set) var startupFailure: Error?
  private let lock = NSLock()
  let drained = DispatchSemaphore(value: 0)

  init() {
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
  }

  func enqueue(_ buffer: AVAudioPCMBuffer) {
    guard buffer.frameLength > 0 else { return }
    lock.lock()
    if stopped {
      lock.unlock()
      return
    }
    pendingBuffers += 1
    totalBuffers += 1
    framesEnqueued += Int(buffer.frameLength)
    lock.unlock()
    startEngineIfNeeded()
    node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      guard let self else { return }
      self.lock.lock()
      self.pendingBuffers -= 1
      let shouldSignal = self.synthesisDone && self.pendingBuffers == 0
      self.lock.unlock()
      if shouldSignal { self.drained.signal() }
    }
  }

  private func startEngineIfNeeded() {
    guard !started else { return }
    started = true
    do {
      engine.prepare()
      try engine.start()
      node.play()
    } catch {
      lock.lock()
      startupFailure = error
      stopped = true
      lock.unlock()
      Debug.stage("playback", "audio engine failed to start: \(error)")
      FileHandle.standardError.write("friday: audio engine failed to start: \(error)\n".data(using: .utf8)!)
      // Without this the caller waits for a drain that can never arrive.
      drained.signal()
    }
  }

  // Barge-in: drop whatever is queued and unblock the waiter immediately.
  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
    node.stop()
    drained.signal()
  }

  func finish() {
    lock.lock()
    synthesisDone = true
    let isEmpty = totalBuffers == 0
    let shouldSignal = pendingBuffers == 0
    lock.unlock()
    if isEmpty || shouldSignal { drained.signal() }
  }
}
