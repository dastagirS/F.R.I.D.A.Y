import Foundation

// Decodes UTF-8 that arrives in pieces. `String(decoding:)` alone is lossy: a character
// straddling two reads becomes U+FFFD, so an emoji or a Devanagari syllable piped in
// slowly gets spoken as garbage. Holding the incomplete tail until the rest arrives
// makes streamed text identical to reading the whole buffer at once.
struct IncrementalUTF8Decoder {
  private var pending: [UInt8] = []

  @discardableResult
  mutating func append(_ data: Data) -> String {
    pending.append(contentsOf: data)
    let complete = Self.completePrefixLength(in: pending)
    guard complete > 0 else { return "" }
    let text = String(decoding: pending[0..<complete], as: UTF8.self)
    pending.removeFirst(complete)
    return text
  }

  // Whatever is left at end of input cannot complete, so decode it lossily rather than
  // dropping the bytes: a truncated character is better than a missing word.
  @discardableResult
  mutating func finish() -> String {
    let text = String(decoding: pending, as: UTF8.self)
    pending = []
    return text
  }

  // Returns how many leading bytes form whole characters; the rest is held back.
  private static func completePrefixLength(in bytes: [UInt8]) -> Int {
    guard !bytes.isEmpty else { return 0 }
    var index = bytes.count - 1
    var walked = 0
    // A UTF-8 character is at most four bytes, so four steps is enough to find its lead.
    while index >= 0 && walked < 4 {
      let byte = bytes[index]
      if byte & 0xC0 == 0x80 {
        index -= 1
        walked += 1
        continue
      }
      let expected: Int
      switch byte {
      case 0x00...0x7F: expected = 1
      case 0xC0...0xDF: expected = 2
      case 0xE0...0xEF: expected = 3
      case 0xF0...0xF7: expected = 4
      default: expected = 1
      }
      let available = bytes.count - index
      return available >= expected ? bytes.count : index
    }
    return bytes.count
  }
}
