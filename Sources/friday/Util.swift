import CoreAudioTypes
import Foundation

func pumpRunLoop(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if semaphore.wait(timeout: .now()) == .success { return true }
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
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

enum FridayError: Error, CustomStringConvertible {
  case daemonUnavailable
  case unknownVoice(String)
  case synthesisFailed(String)
  case timeout
  case nothingCaptured
  case usage(String)
  case config(String)
  case cancelled

  var description: String {
    switch self {
    case .daemonUnavailable: return "sirittsd is not available on this system"
    case .unknownVoice(let name): return "no installed voice matches '\(name)'; run 'friday voices'"
    case .synthesisFailed(let reason): return "synthesis failed: \(reason)"
    case .timeout: return "synthesis timed out"
    case .nothingCaptured: return "no audio captured"
    case .usage(let text): return text
    case .config(let text): return text
    case .cancelled: return "cancelled"
    }
  }

  var exitCode: Int32 {
    switch self {
    case .usage, .config: return 2
    case .daemonUnavailable: return 3
    case .unknownVoice: return 4
    case .synthesisFailed: return 6
    case .timeout: return 7
    case .nothingCaptured: return 8
    case .cancelled: return 130
    }
  }
}

// 48 kHz 16-bit mono WAV, the format everything downstream expects.
func wavData(samples: [Float], sampleRate: Double) throws -> Data {
  guard sampleRate >= 8000, sampleRate <= 192000 else {
    throw FridayError.config("implausible sample rate: \(sampleRate)")
  }
  guard !samples.isEmpty else { throw FridayError.nothingCaptured }
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
