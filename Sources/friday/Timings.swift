import Foundation
import SiriTTSService

struct WordTiming: Codable {
  let text: String
  let start: Double
  let end: Double
  let endDerived: Bool
  let utf16Location: Int
  let utf16Length: Int
}

struct TimingReport: Codable {
  let schemaVersion: Int
  let voice: String
  let assetKey: String
  let language: String
  let generation: String
  let timingsSupported: Bool
  let timings: [WordTiming]

  func json() -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)) ?? Data("{}".utf8)
  }
}

// The daemon reports start times and UTF-16 ranges only. End times are derived
// from the next word's start, and the final word ends at the audio duration,
// which is why every entry carries endDerived.
func makeTimingReport(
  voice: SynthesisVoice,
  sourceText: String,
  raw: [WordTimingInfo],
  supported: Bool,
  generation: String,
  audioSeconds: Double
) -> TimingReport {
  let nsText = sourceText as NSString
  let sorted = raw.sorted { $0.startTime < $1.startTime }
  var timings: [WordTiming] = []
  for (index, entry) in sorted.enumerated() {
    let location = entry.textRange.location
    let length = entry.textRange.length
    guard location >= 0, length > 0, location + length <= nsText.length else { continue }
    let word = nsText.substring(with: NSRange(location: location, length: length))
    let isLast = index == sorted.count - 1
    let end = isLast ? max(entry.startTime, audioSeconds) : sorted[index + 1].startTime
    timings.append(WordTiming(
      text: word,
      start: entry.startTime,
      end: end,
      endDerived: true,
      utf16Location: location,
      utf16Length: length
    ))
  }
  return TimingReport(
    schemaVersion: 1,
    voice: voice.name ?? "-",
    assetKey: voice.assetKey,
    language: voice.language,
    generation: generation,
    // queryWordTimingSupport under-reports on this build (it answers false while
    // still delivering timings), so the delivered set is what decides.
    timingsSupported: !timings.isEmpty,
    timings: timings
  )
}
