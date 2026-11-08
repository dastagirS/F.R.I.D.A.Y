import AVFoundation
import CoreAudioTypes
import Foundation
import SiriTTSService

// The daemon picks its own wire format per request: integer LPCM for the
// standard path, 32-bit float LPCM for expressive short text, and Opus packets
// once an expressive utterance gets long. Writing those bytes straight into a
// WAV is what makes playback sound shredded, so everything is normalised here
// to 48 kHz float mono.
final class ChunkDecoder {
  let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
  private var converter: AVAudioConverter?
  private var sourceFormat: AVAudioFormat?
  private(set) var describedFormat = "none"

  func decode(_ chunk: AudioData) -> AVAudioPCMBuffer? {
    var asbd = chunk.asbd
    guard isPlausibleFormat(asbd), let source = AVAudioFormat(streamDescription: &asbd) else { return nil }
    if sourceFormat != source {
      sourceFormat = source
      converter = AVAudioConverter(from: source, to: outputFormat)
      describedFormat = "\(fourCharacterCode(asbd.mFormatID)) \(Int(asbd.mSampleRate))Hz"
    }
    guard let converter else { return nil }

    let input: AVAudioBuffer?
    if asbd.mFormatID == kAudioFormatLinearPCM {
      input = makePCMInput(chunk: chunk, format: source, asbd: asbd)
    } else {
      input = makeCompressedInput(chunk: chunk, format: source, asbd: asbd)
    }
    guard let input else { return nil }

    let framesPerPacket = max(Int(asbd.mFramesPerPacket), 1)
    let packetCount = max(Int(chunk.packetCount), 1)
    let estimatedFrames = Double(packetCount * framesPerPacket) * outputFormat.sampleRate / max(asbd.mSampleRate, 1)
    let capacity = max(AVAudioFrameCount(estimatedFrames.rounded(.up)) + 8192, 8192)
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
    var supplied = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
      if supplied {
        outStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      outStatus.pointee = .haveData
      return input
    }
    guard status != .error, output.frameLength > 0 else { return nil }
    return output
  }

  private func makePCMInput(chunk: AudioData, format: AVAudioFormat, asbd: AudioStreamBasicDescription) -> AVAudioPCMBuffer? {
    guard asbd.mChannelsPerFrame == 1 else { return nil }
    let bytesPerFrame = Int(asbd.mBytesPerFrame) > 0
      ? Int(asbd.mBytesPerFrame)
      : max(Int(asbd.mBitsPerChannel), 8) / 8
    let frameCount = chunk.audioData.count / max(bytesPerFrame, 1)
    guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    if let destination = buffer.audioBufferList.pointee.mBuffers.mData {
      chunk.audioData.withUnsafeBytes { raw in
        if let base = raw.baseAddress {
          memcpy(destination, base, min(raw.count, frameCount * bytesPerFrame))
        }
      }
    }
    return buffer
  }

  private func makeCompressedInput(chunk: AudioData, format: AVAudioFormat, asbd: AudioStreamBasicDescription) -> AVAudioCompressedBuffer? {
    let packetCount = AVAudioPacketCount(chunk.packetCount)
    guard packetCount > 0, !chunk.audioData.isEmpty else { return nil }
    var maximumPacketSize = chunk.audioData.count / Int(packetCount)
    if !chunk.packetDescriptions.isEmpty {
      maximumPacketSize = 0
      chunk.packetDescriptions.withUnsafeBytes { raw in
        let stride = MemoryLayout<AudioStreamPacketDescription>.stride
        for index in 0..<(raw.count / stride) {
          let description = raw.load(fromByteOffset: index * stride, as: AudioStreamPacketDescription.self)
          maximumPacketSize = max(maximumPacketSize, Int(description.mDataByteSize))
        }
      }
    }
    guard maximumPacketSize > 0 else { return nil }
    let compressed = AVAudioCompressedBuffer(format: format, packetCapacity: packetCount, maximumPacketSize: maximumPacketSize)
    compressed.byteLength = UInt32(chunk.audioData.count)
    compressed.packetCount = packetCount
    chunk.audioData.withUnsafeBytes { raw in
      if let base = raw.baseAddress { memcpy(compressed.data, base, chunk.audioData.count) }
    }
    if !chunk.packetDescriptions.isEmpty {
      chunk.packetDescriptions.withUnsafeBytes { raw in
        if let base = raw.baseAddress, let destination = compressed.packetDescriptions {
          memcpy(destination, base, raw.count)
        }
      }
    }
    return compressed
  }
}
