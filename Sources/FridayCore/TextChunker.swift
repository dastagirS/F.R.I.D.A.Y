import Foundation

// A slice of the caller's text, carrying where it started in UTF-16 units so
// word timings can be reported against the original string rather than the slice.
struct TextChunk {
  let text: String
  let utf16Location: Int
}

// sirittsd picks its encoder per request and will not be told which to use: it
// returns lossless 48 kHz PCM sometimes and ~50 kbps Opus other times for the same
// text, flipping with internal state (a hot daemon answers lossless, an idle one
// answered lossy in testing). Smaller requests were observed to land on the
// lossless encoder far more often than whole paragraphs, and one sentence per
// request also lets the first word play while later sentences are still rendering.
enum TextChunker {
  // Bounded so a pathological input cannot turn into hundreds of daemon round
  // trips. Beyond either limit the caller keeps its single-request behaviour.
  static let maximumChunks = 200
  static let maximumTextLength = 20_000

  // Words whose trailing period is part of the word, not the end of a sentence.
  private static let abbreviations: Set<String> = [
    "al", "approx", "ca", "cf", "co", "dept", "dr", "eg", "est", "etc", "fig",
    "ie", "inc", "jr", "ltd", "mr", "mrs", "ms", "no", "prof", "sr", "st", "vs"
  ]

  // Dotted forms that can close a sentence when a capital follows: "we met at
  // 9:45 a.m. The next item...". Everything else dotted ("U.S.", "e.g.") never
  // ends a sentence in ordinary prose, so those stay attached.
  private static let sentenceClosingAbbreviations: Set<String> = ["a.m", "p.m"]

  private static let closingMarks: Set<Character> = ["\"", "'", "”", "’", ")", "]", "}"]
  private static let openingMarks: Set<Character> = ["\"", "'", "“", "‘", "(", "["]

  // Returns [] when splitting is not worth it, so callers can fall back.
  static func chunks(from text: String) -> [TextChunk] {
    guard text.utf16.count <= maximumTextLength else { return [] }
    let characters = Array(text)
    guard !characters.isEmpty else { return [] }

    var utf16Start: [Int] = []
    utf16Start.reserveCapacity(characters.count + 1)
    var offset = 0
    for character in characters {
      utf16Start.append(offset)
      offset += String(character).utf16.count
    }
    utf16Start.append(offset)

    var chunks: [TextChunk] = []
    var chunkStart = 0
    var index = 0
    while index < characters.count {
      guard isTerminator(characters[index]) else {
        index += 1
        continue
      }
      // A run such as "?!" or "..." ends the sentence once, not three times.
      var terminatorEnd = index
      while terminatorEnd + 1 < characters.count && isTerminator(characters[terminatorEnd + 1]) {
        terminatorEnd += 1
      }
      // Trailing quotes and brackets belong to the sentence they close.
      while terminatorEnd + 1 < characters.count && closingMarks.contains(characters[terminatorEnd + 1]) {
        terminatorEnd += 1
      }

      let endsSentence = isBoundary(at: terminatorEnd, in: characters)
        && !endsWithAbbreviation(
          before: terminatorEnd,
          in: characters,
          nextWordIsLowercase: nextWordIsLowercase(after: terminatorEnd, in: characters)
        )
      guard endsSentence else {
        index = terminatorEnd + 1
        continue
      }

      if let chunk = makeChunk(characters: characters, utf16Start: utf16Start, from: chunkStart, to: terminatorEnd) {
        guard chunks.count < maximumChunks else { return [] }
        chunks.append(chunk)
      }
      var next = terminatorEnd + 1
      while next < characters.count && characters[next].isWhitespace {
        next += 1
      }
      chunkStart = next
      index = next
    }

    if chunkStart < characters.count,
       let tail = makeChunk(characters: characters, utf16Start: utf16Start, from: chunkStart, to: characters.count - 1) {
      guard chunks.count < maximumChunks else { return [] }
      chunks.append(tail)
    }
    return chunks
  }

  private static func isTerminator(_ character: Character) -> Bool {
    character == "." || character == "!" || character == "?" || character == "…"
  }

  // True when a finished-looking sentence ends in a terminator, quotes and brackets
  // aside. The streaming splitter uses this to stop waiting for more input.
  static func endsWithSentenceEnd(_ text: String) -> Bool {
    var characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
    while let last = characters.last, closingMarks.contains(last) { characters.removeLast() }
    guard let last = characters.last else { return false }
    return isTerminator(last)
  }

  // A sentence ends only when what follows looks like the start of a new one:
  // "a.m. on Tuesday" stays whole, "Done. Next" splits.
  private static func isBoundary(at index: Int, in characters: [Character]) -> Bool {
    var next = index + 1
    guard next < characters.count else { return false }
    if characters[next].isNewline { return true }
    // No whitespace after the terminator means it is inside a token, not between
    // sentences: "18.5", "a.m", "v2.0".
    guard characters[next].isWhitespace else { return false }
    while next < characters.count && (characters[next] == " " || characters[next] == "\t") {
      next += 1
    }
    guard next < characters.count else { return false }
    let starter = characters[next]
    if starter.isUppercase || starter.isNumber { return true }
    if openingMarks.contains(starter) { return true }
    return false
  }

  // Guards "Dr. Rao", "e.g. This", and dotted initialisms such as "U.S. Army".
  private static func nextWordIsLowercase(after terminatorEnd: Int, in characters: [Character]) -> Bool {
    var next = terminatorEnd + 1
    while next < characters.count && characters[next].isWhitespace { next += 1 }
    guard next < characters.count else { return true }
    return characters[next].isLowercase || characters[next].isNumber
  }

  private static func endsWithAbbreviation(
    before terminatorEnd: Int,
    in characters: [Character],
    nextWordIsLowercase: Bool
  ) -> Bool {
    guard characters[terminatorEnd] == "." else { return false }
    var wordStart = terminatorEnd
    while wordStart > 0 {
      let previous = characters[wordStart - 1]
      guard previous.isLetter || previous == "." else { break }
      wordStart -= 1
    }
    let word = String(characters[wordStart..<terminatorEnd]).lowercased()
    if abbreviations.contains(word) { return true }
    if sentenceClosingAbbreviations.contains(word) { return nextWordIsLowercase }
    // Any other dotted single-letter run is an initialism: "U.S.", "e.g.".
    let pieces = word.split(separator: ".", omittingEmptySubsequences: false)
    return pieces.count > 1 && pieces.allSatisfy { $0.count == 1 }
  }

  private static func makeChunk(characters: [Character], utf16Start: [Int], from: Int, to: Int) -> TextChunk? {
    guard from <= to, to < characters.count else { return nil }
    var firstVisible = from
    while firstVisible <= to && characters[firstVisible].isWhitespace { firstVisible += 1 }
    guard firstVisible <= to else { return nil }
    let slice = String(characters[firstVisible...to]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !slice.isEmpty else { return nil }
    return TextChunk(text: slice, utf16Location: utf16Start[firstVisible])
  }
}


// Sentence splitting for text that is still arriving. The whole-string splitter can
// look ahead at the word after a period; a stream can only judge what it has, so the
// tail is held back until a boundary is followed by a complete word. Everything else
// (abbreviations, decimals, quoted endings) reuses the same rules through chunks(from:).
struct StreamingSentenceSplitter {
  // Beyond this the tail is flushed at a word boundary. 800 characters is roughly
  // half a minute of speech: long enough to keep normal prose intact, short enough
  // that a run-on paragraph is never rendered as one enormous utterance.
  static let maximumTailLength = 800

  private(set) var buffered = ""

  mutating func append(_ text: String) {
    buffered += text
  }

  // Complete sentences only. A trailing fragment is held back because it may be half
  // a word, but a final chunk that already ends in a terminator is finished: waiting
  // for the next sentence to arrive would add that entire pause to the latency.
  mutating func takeSentences() -> [String] {
    var sentences: [String] = []
    // A run-on with no punctuation must not wait for a boundary that never comes.
    while buffered.count > Self.maximumTailLength, sentences.count < 4 {
      let head = String(buffered.prefix(Self.maximumTailLength))
      guard let cut = head.lastIndex(of: " ") else { break }
      let piece = String(head[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
      buffered = String(buffered.dropFirst(head.distance(from: head.startIndex, to: cut) + 1))
      if !piece.isEmpty { sentences.append(piece) }
    }
    let chunks = TextChunker.chunks(from: buffered)
    guard let last = chunks.last else { return sentences }
    let source = buffered as NSString
    let tailStart = last.utf16Location + (last.text as NSString).length
    let tail = tailStart <= source.length ? source.substring(from: tailStart) : ""
    let finished = tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && TextChunker.endsWithSentenceEnd(last.text)
    if finished {
      buffered = ""
      sentences.append(contentsOf: chunks.map(\.text))
    } else {
      buffered = source.substring(from: last.utf16Location)
      sentences.append(contentsOf: chunks.dropLast().map(\.text))
    }
    return sentences
  }

  // End of input: whatever is left is spoken, split at word boundaries so an
  // unpunctuated tail does not become a single multi-minute utterance.
  mutating func flush() -> [String] {
    var pieces: [String] = []
    while true {
      let remainder = buffered.trimmingCharacters(in: .whitespacesAndNewlines)
      buffered = ""
      guard !remainder.isEmpty else { break }
      if remainder.count <= Self.maximumTailLength || pieces.count >= 25 {
        pieces.append(remainder)
        break
      }
      let head = String(remainder.prefix(Self.maximumTailLength))
      guard let cut = head.lastIndex(of: " ") else {
        pieces.append(remainder)
        break
      }
      pieces.append(String(head[..<cut]))
      buffered = String(remainder[remainder.index(after: cut)...])
    }
    return pieces
  }
}
