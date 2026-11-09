import CoreAudioTypes
import Foundation

// Waiting on the main thread is also the only chance to service things that arrive while
// a request runs, so `tick` is called on every slice (used by the server to answer /stop).
func pumpRunLoop(
  _ semaphore: DispatchSemaphore,
  timeout: TimeInterval,
  tick: (() -> Void)? = nil
) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if semaphore.wait(timeout: .now()) == .success { return true }
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    tick?()
  }
  return false
}

func parseOnOff(_ raw: String) -> Bool? {
  switch raw.lowercased() {
  case "on", "true", "yes", "1": return true
  case "off", "false", "no", "0": return false
  default: return nil
  }
}

func fourCharacterCode(_ value: UInt32) -> String {
  let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
  return String(bytes: bytes, encoding: .ascii) ?? "?"
}

// Chunks occasionally carry an all-zero format description, and compressed
// formats legitimately report zero bits per channel, so only sample rate,
// channel count and (for PCM) bit depth can be sanity checked here.
func isPlausibleFormat(_ asbd: AudioStreamBasicDescription) -> Bool {
  guard asbd.mSampleRate >= 8000, asbd.mSampleRate <= 192000 else { return false }
  guard (1...8).contains(Int(asbd.mChannelsPerFrame)) else { return false }
  if asbd.mFormatID == kAudioFormatLinearPCM {
    return asbd.mBitsPerChannel == 8 || asbd.mBitsPerChannel == 16 || asbd.mBitsPerChannel == 32
  }
  return true
}

// One code per class of thing you would debug differently. 0 is success and 130 is the
// shell convention for SIGINT; 1 stays reserved for a failure we did not anticipate.
// The command-line guidelines ask for non-zero codes mapped to the important failure
// modes rather than one generic error, which is what this does.
enum FridayError: Error, CustomStringConvertible {
  case daemonUnavailable
  case serverUnreachable(String)
  case unknownVoice(String, suggestion: String?)
  case synthesisFailed(String)
  case timeout(stage: String, seconds: Double)
  case nothingCaptured(chunks: Int, formats: String)
  case emptyInput(String)
  case audioOutput(String)
  case usage(String)
  case config(String)
  case cancelled

  var description: String {
    switch self {
    case .daemonUnavailable:
      return "cannot reach sirittsd (SiriTTSService); check: launchctl print gui/\(getuid())/com.apple.sirittsd"
    case .serverUnreachable(let detail):
      return "cannot reach the friday server: \(detail); is 'friday serve' running?"
    case .unknownVoice(let name, let suggestion):
      let hint = suggestion.map { "; did you mean '\($0)'?" } ?? ""
      return "no installed voice matches '\(name)'\(hint); run 'friday voices' for the list"
    case .synthesisFailed(let reason): return "synthesis failed: \(reason)"
    case .timeout(let stage, let seconds):
      return "timed out after \(Int(seconds))s waiting for \(stage)"
    case .nothingCaptured(let chunks, let formats):
      return "produced no audio from \(chunks) request(s); daemon formats seen: \(formats.isEmpty ? "none" : formats)"
    case .emptyInput(let reason):
      return "no audio produced: \(reason)"
    case .audioOutput(let reason): return reason
    case .usage(let text): return text
    case .config(let text): return text
    case .cancelled: return "cancelled"
    }
  }

  var exitCode: Int32 {
    switch self {
    case .usage: return 2
    case .daemonUnavailable, .serverUnreachable: return 3
    case .unknownVoice: return 4
    case .config: return 5
    case .synthesisFailed: return 6
    case .timeout: return 7
    case .nothingCaptured, .emptyInput: return 8
    case .audioOutput: return 9
    case .cancelled: return 130
    }
  }
}

// 48 kHz 16-bit mono WAV, the format everything downstream expects.
func wavData(samples: [Float], sampleRate: Double) throws -> Data {
  guard sampleRate >= 8000, sampleRate <= 192000 else {
    throw FridayError.config("implausible sample rate: \(sampleRate)")
  }
  guard !samples.isEmpty else {
    throw FridayError.nothingCaptured(chunks: 0, formats: "")
  }
  let pcm = pcmData(samples: samples)
  let integerRate = Int(sampleRate)
  let blockAlign = 2
  var header = Data()
  func le32(_ value: Int) -> Data { var v = UInt32(value); return Data(bytes: &v, count: 4) }
  func le16(_ value: Int) -> Data { var v = UInt16(value); return Data(bytes: &v, count: 2) }
  header.append("RIFF".data(using: .ascii)!); header.append(le32(36 + pcm.count))
  header.append("WAVEfmt ".data(using: .ascii)!); header.append(le32(16)); header.append(le16(1))
  header.append(le16(1)); header.append(le32(integerRate)); header.append(le32(integerRate * blockAlign))
  header.append(le16(blockAlign)); header.append(le16(16))
  header.append("data".data(using: .ascii)!); header.append(le32(pcm.count))
  return header + pcm
}

func pcmData(samples: [Float]) -> Data {
  var converted = [Int16](repeating: 0, count: samples.count)
  for (index, sample) in samples.enumerated() {
    converted[index] = Int16((max(-1.0, min(1.0, sample)) * 32767.0).rounded())
  }
  return converted.withUnsafeBufferPointer { Data(buffer: $0) }
}
