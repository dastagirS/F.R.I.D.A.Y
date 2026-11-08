import CoreAudioTypes
import Foundation

// Checks for the logic that needs no SiriTTS daemon: sentence splitting, streaming
// buffering, the error taxonomy, config coding and WAV output. Compiled together with
// Sources/FridayCore so the code under test is the code that ships.
//
// Not XCTest: the active toolchain here is Command Line Tools, which ships neither
// XCTest nor Testing, so `swift test` cannot build a test bundle on this machine.

var checkCount = 0
var failures: [String] = []

func checkTrue(_ condition: Bool, _ description: String, line: UInt = #line) {
  checkCount += 1
  if !condition { failures.append("line \(line): \(description)") }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ description: String, line: UInt = #line) {
  checkCount += 1
  if actual != expected {
    failures.append("line \(line): \(description)\n         expected: \(expected)\n         actual:   \(actual)")
  }
}

@discardableResult
func checkThrows(_ description: String, line: UInt = #line, _ body: () throws -> Void) -> Error? {
  checkCount += 1
  do {
    try body()
    failures.append("line \(line): \(description) — nothing was thrown")
    return nil
  } catch {
    return error
  }
}

func chunkTexts(_ text: String) -> [String] {
  TextChunker.chunks(from: text).map(\.text)
}

// MARK: - Whole-string splitting

checkEqual(chunkTexts(""), [], "empty text produces no chunks")
checkEqual(chunkTexts("   \n\t "), [], "whitespace-only text produces no chunks")
checkEqual(chunkTexts("Hello there."), ["Hello there."], "single sentence stays one chunk")
checkEqual(chunkTexts("One. Two. Three."), ["One.", "Two.", "Three."], "three sentences split three ways")
checkEqual(
  chunkTexts("Dr. Rao arrived at 9:45 a.m. Then we left."),
  ["Dr. Rao arrived at 9:45 a.m.", "Then we left."],
  "titles are not sentence ends, a.m. is when a capital follows"
)
checkEqual(
  chunkTexts("We met at 9:45 a.m. on Tuesday."),
  ["We met at 9:45 a.m. on Tuesday."],
  "a.m. followed by a lowercase word does not end a sentence"
)
checkEqual(
  chunkTexts("The U.S. Army moved. It rained."),
  ["The U.S. Army moved.", "It rained."],
  "dotted initialism stays inside its sentence"
)
checkEqual(
  chunkTexts("Pi is 3.14 and it rounds. Next one."),
  ["Pi is 3.14 and it rounds.", "Next one."],
  "decimal point is not a sentence end"
)
checkEqual(
  chunkTexts("He said \"stop.\" Then he left."),
  ["He said \"stop.\"", "Then he left."],
  "closing quote belongs to the sentence it closes"
)
checkEqual(chunkTexts("Wait... What?"), ["Wait...", "What?"], "ellipsis ends a sentence once")
checkEqual(
  chunkTexts("Done.\nNext line."),
  ["Done.", "Next line."],
  "newline after a terminator splits"
)
checkEqual(
  chunkTexts("a run on sentence with no ending"),
  ["a run on sentence with no ending"],
  "text without a terminator is one tail chunk"
)

let indented = TextChunker.chunks(from: "  First. Second.")
checkEqual(indented.map(\.text), ["First.", "Second."], "leading whitespace is trimmed")
checkEqual(indented.map(\.utf16Location), [2, 9], "chunk offsets point at the first visible character")

let astral = TextChunker.chunks(from: "😀 Hi. Next.")
checkEqual(astral.map(\.text), ["😀 Hi.", "Next."], "astral characters split normally")
checkEqual(astral.last?.utf16Location, 7, "offset is in UTF-16 units, not characters")

checkEqual(
  TextChunker.chunks(from: String(repeating: "a", count: TextChunker.maximumTextLength + 1)).count,
  0,
  "text over the length bound is left to the caller's single-request path"
)
checkEqual(
  TextChunker.chunks(from: String(repeating: "A. ", count: TextChunker.maximumChunks + 1)).count,
  0,
  "more sentences than the chunk bound is left to the caller's single-request path"
)

checkTrue(TextChunker.endsWithSentenceEnd("Hello."), "period ends a sentence")
checkTrue(TextChunker.endsWithSentenceEnd("Hello.\""), "a terminator before a closing quote still counts")
checkTrue(TextChunker.endsWithSentenceEnd("Really?"), "question mark ends a sentence")
checkTrue(!TextChunker.endsWithSentenceEnd("Hello"), "a bare word does not end a sentence")
checkTrue(!TextChunker.endsWithSentenceEnd(""), "empty text does not end a sentence")

// MARK: - Streaming buffer

var splitter = StreamingSentenceSplitter()
splitter.append("Hello wor")
checkEqual(splitter.takeSentences(), [], "a half-typed word is held back")
splitter.append("ld.")
checkEqual(splitter.takeSentences(), ["Hello world."], "a finished sentence is emitted without waiting")
splitter.append(" More")
checkEqual(splitter.takeSentences(), [], "an unfinished second sentence is held")
splitter.append(" text.")
checkEqual(splitter.takeSentences(), ["More text."], "the second sentence arrives when complete")

var holding = StreamingSentenceSplitter()
holding.append("Dr. Rao")
checkEqual(holding.takeSentences(), [], "an abbreviation at the end of input is not a sentence end")
holding.append(" said so.")
checkEqual(holding.takeSentences(), ["Dr. Rao said so."], "the held tail joins the rest of the sentence")

var unfinished = StreamingSentenceSplitter()
unfinished.append("tail without end")
checkEqual(unfinished.takeSentences(), [], "an unterminated tail is not emitted mid-stream")
checkEqual(unfinished.flush(), ["tail without end"], "flush speaks the remaining tail")

// A run-on with no punctuation must be cut at a word boundary rather than growing
// without limit, and the pieces must losslessly rejoin.
let runOnText = String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces)
var runOn = StreamingSentenceSplitter()
runOn.append(runOnText)
let streamedPieces = runOn.takeSentences()
let flushedPieces = runOn.flush()
checkTrue(streamedPieces.count <= 4, "forced splits per append call are bounded, got \(streamedPieces.count)")
for piece in streamedPieces + flushedPieces {
  checkTrue(piece.count <= StreamingSentenceSplitter.maximumTailLength, "piece stays within the tail bound: \(piece.count)")
  checkTrue(!piece.hasSuffix(" "), "piece is trimmed")
  checkTrue(!piece.hasPrefix(" "), "piece does not start with a space")
}
checkEqual(
  (streamedPieces + flushedPieces).joined(separator: " "),
  runOnText,
  "bounded splitting loses no words"
)
checkEqual(runOn.buffered, "", "flush drains the buffer")

var manyShort = StreamingSentenceSplitter()
manyShort.append("One. Two. Three. Four.")
checkEqual(manyShort.takeSentences(), ["One.", "Two.", "Three.", "Four."], "several complete sentences drain at once")
checkEqual(manyShort.buffered, "", "a fully terminated buffer leaves nothing behind")

// MARK: - Error taxonomy

let expectedExitCodes: [(FridayError, Int32, String)] = [
  (FridayError.usage("x"), 2, "usage"),
  (FridayError.daemonUnavailable, 3, "daemon"),
  (FridayError.unknownVoice("x", suggestion: nil), 4, "voice"),
  (FridayError.config("x"), 5, "config"),
  (FridayError.synthesisFailed("x"), 6, "synthesis"),
  (FridayError.timeout(stage: "x", seconds: 1), 7, "timeout"),
  (FridayError.nothingCaptured(chunks: 1, formats: ""), 8, "no audio"),
  (FridayError.emptyInput("x"), 8, "empty input"),
  (FridayError.audioOutput("x"), 9, "output"),
  (FridayError.cancelled, 130, "cancelled"),
]
for (error, expected, label) in expectedExitCodes {
  checkEqual(error.exitCode, expected, "\(label) exits \(expected)")
  checkTrue(!error.description.isEmpty, "\(label) has a message")
}
checkEqual(
  Set(expectedExitCodes.map { $0.0.exitCode }),
  Set<Int32>([2, 3, 4, 5, 6, 7, 8, 9, 130]),
  "the taxonomy covers every documented code and nothing else"
)

let hinted = FridayError.unknownVoice("Riaya", suggestion: "Riya").description
checkTrue(hinted.contains("did you mean 'Riya'?"), "a near-miss voice names the near miss")
checkTrue(hinted.contains("friday voices"), "an unknown voice points at the command that lists voices")
checkTrue(
  !FridayError.unknownVoice("zzz", suggestion: nil).description.contains("did you mean"),
  "no suggestion is offered when there is nothing close"
)

// MARK: - Config

var config = FridayConfig()
config.defaultVoice = "simone"
config.defaultGeneration = "standard"
config.pace = 4
config.expressivity = 2
config.sentenceChunking = true
config.lossless = true
let roundTripped = try JSONDecoder().decode(FridayConfig.self, from: try JSONEncoder().encode(config))
checkEqual(roundTripped.defaultVoice, "simone", "voice survives a round trip")
checkEqual(roundTripped.defaultGeneration, "standard", "generation survives a round trip")
checkEqual(roundTripped.pace, 4, "pace survives a round trip")
checkEqual(roundTripped.expressivity, 2, "expressivity survives a round trip")
checkEqual(roundTripped.sentenceChunking, true, "sentence chunking survives a round trip")
checkEqual(roundTripped.lossless, true, "lossless survives a round trip")

let partial = try JSONDecoder().decode(FridayConfig.self, from: Data(#"{"defaultVoice":"Riya"}"#.utf8))
checkEqual(partial.defaultVoice, "Riya", "a partial config decodes")
checkEqual(partial.pace, nil, "unset keys stay nil so built-ins apply")

let emptyObject = try JSONDecoder().decode(FridayConfig.self, from: Data("{}".utf8))
checkEqual(emptyObject.defaultVoice, nil, "an empty object decodes to defaults")
checkEqual(FridayConfig.builtInVoice, "simone", "the locked-in voice is simone")
checkEqual(FridayConfig.builtInGeneration, "standard", "the locked-in generation is standard")
checkTrue(FridayConfig.builtInSentenceChunking, "sentence chunking is on by default")
checkTrue(FridayConfig.builtInLossless, "lossless is on by default")

checkEqual(FridayConfig.normalizeGeneration("STANDARD"), "standard", "generation parsing ignores case")
checkEqual(FridayConfig.normalizeGeneration("calm"), "standard", "calm selects the standard path")
checkEqual(FridayConfig.normalizeGeneration("3b"), "expressive", "3b selects the expressive path")
checkEqual(FridayConfig.normalizeGeneration("model"), "expressive", "model selects the expressive path")
checkEqual(FridayConfig.normalizeGeneration("theatrical"), nil, "an unknown generation is rejected")

checkEqual(parseOnOff("on"), true, "on means on")
checkEqual(parseOnOff("TRUE"), true, "true means on")
checkEqual(parseOnOff("yes"), true, "yes means on")
checkEqual(parseOnOff("1"), true, "1 means on")
checkEqual(parseOnOff("off"), false, "off means off")
checkEqual(parseOnOff("No"), false, "no means off")
checkEqual(parseOnOff("0"), false, "0 means off")
checkEqual(parseOnOff("maybe"), nil, "an unclear value is rejected rather than guessed")

// MARK: - Audio formatting

checkEqual(fourCharacterCode(0x6C7063_6D), "lpcm", "format ids render as four characters")
checkEqual(fourCharacterCode(0x6F7075_73), "opus", "compressed format ids render too")

var pcmFormat = AudioStreamBasicDescription()
pcmFormat.mSampleRate = 48_000
pcmFormat.mChannelsPerFrame = 1
pcmFormat.mFormatID = kAudioFormatLinearPCM
pcmFormat.mBitsPerChannel = 16
checkTrue(isPlausibleFormat(pcmFormat), "48 kHz mono 16-bit PCM is plausible")

pcmFormat.mSampleRate = 1_000
checkTrue(!isPlausibleFormat(pcmFormat), "an absurd sample rate is rejected")

pcmFormat.mSampleRate = 48_000
pcmFormat.mChannelsPerFrame = 0
checkTrue(!isPlausibleFormat(pcmFormat), "zero channels is rejected")

pcmFormat.mChannelsPerFrame = 1
pcmFormat.mBitsPerChannel = 16
pcmFormat.mFormatID = 0
checkTrue(isPlausibleFormat(pcmFormat), "a compressed format with zero bit depth stays plausible")

let samples: [Float] = [-1.0, -0.5, 0.0, 0.5, 1.0]
let pcm = pcmData(samples: samples)
checkEqual(pcm.count, samples.count * 2, "16-bit mono is two bytes per sample")

func int16(_ data: Data, at index: Int) -> Int16 {
  Int16(bitPattern: UInt16(data[data.startIndex + index * 2]) | (UInt16(data[data.startIndex + index * 2 + 1]) << 8))
}
checkEqual(int16(pcm, at: 0), -32767, "negative full scale maps to -32767, not -32768")
checkEqual(int16(pcm, at: 1), -16384, "half negative scale maps with rounding")
checkEqual(int16(pcm, at: 2), 0, "silence maps to zero")
checkEqual(int16(pcm, at: 3), 16384, "half scale maps with rounding")
checkEqual(int16(pcm, at: 4), 32767, "positive full scale maps to 32767")
checkEqual(int16(pcmData(samples: [2.0, -2.0]), at: 0), 32767, "out-of-range positive samples clamp")
checkEqual(int16(pcmData(samples: [2.0, -2.0]), at: 1), -32767, "out-of-range negative samples clamp")

func uint32(_ data: Data, at offset: Int) -> UInt32 {
  (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[data.startIndex + offset + $1]) << (8 * UInt32($1))) }
}
func uint16(_ data: Data, at offset: Int) -> UInt16 {
  UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
}
func ascii(_ data: Data, at offset: Int, count: Int) -> String {
  String(decoding: data[data.startIndex + offset ..< data.startIndex + offset + count], as: UTF8.self)
}

let wav = try wavData(samples: samples, sampleRate: 48_000)
checkEqual(wav.count, 44 + samples.count * 2, "WAV is a 44-byte header plus the PCM body")
checkEqual(ascii(wav, at: 0, count: 4), "RIFF", "WAV starts with RIFF")
checkEqual(uint32(wav, at: 4), UInt32(wav.count - 8), "RIFF size covers everything after itself")
checkEqual(ascii(wav, at: 8, count: 4), "WAVE", "WAV declares the WAVE form")
checkEqual(ascii(wav, at: 12, count: 4), "fmt ", "WAV carries a fmt chunk")
checkEqual(uint32(wav, at: 16), 16, "fmt chunk is the PCM layout")
checkEqual(uint16(wav, at: 20), 1, "audio format is linear PCM, not float")
checkEqual(uint16(wav, at: 22), 1, "mono")
checkEqual(uint32(wav, at: 24), 48_000, "sample rate is the requested one")
checkEqual(uint32(wav, at: 28), 96_000, "byte rate matches 16-bit mono at 48 kHz")
checkEqual(uint16(wav, at: 32), 2, "block alignment is two bytes")
checkEqual(uint16(wav, at: 34), 16, "16 bits per sample")
checkEqual(ascii(wav, at: 36, count: 4), "data", "data chunk follows the format")
checkEqual(uint32(wav, at: 40), UInt32(samples.count * 2), "data chunk size matches the body")

checkThrows("an empty sample buffer is rejected") { _ = try wavData(samples: [], sampleRate: 48_000) }
checkThrows("an implausible sample rate is rejected") { _ = try wavData(samples: [0.5], sampleRate: 1_000) }
checkTrue(
  (try? wavData(samples: [1.0], sampleRate: 44_100)).map { uint32($0, at: 24) } == 44_100,
  "a 44.1 kHz request is honoured rather than silently resampled"
)

// MARK: - Incremental UTF-8 decoding

var emojiDecoder = IncrementalUTF8Decoder()
let emojiBytes = Array("😀".utf8)
checkEqual(emojiBytes.count, 4, "the test character really is four bytes")
checkEqual(emojiDecoder.append(Data(emojiBytes.prefix(2))), "", "half a character decodes to nothing")
checkEqual(emojiDecoder.append(Data(emojiBytes.suffix(2))), "😀", "the rest of the character completes it")
checkEqual(emojiDecoder.finish(), "", "nothing is left after a complete character")

var asciiDecoder = IncrementalUTF8Decoder()
checkEqual(asciiDecoder.append(Data("hello ".utf8)), "hello ", "ascii passes straight through")
var emptyDecoder = IncrementalUTF8Decoder()
checkEqual(emptyDecoder.append(Data()), "", "an empty read adds nothing")

var mixedDecoder = IncrementalUTF8Decoder()
let foldBytes = Array("🙏".utf8)
checkEqual(mixedDecoder.append(Data([0x41] + foldBytes.prefix(1))), "A", "the complete byte is emitted, the lead byte held")
checkEqual(mixedDecoder.append(Data(foldBytes.dropFirst() + [0x42])), "🙏B", "the held bytes complete once the rest arrives")

// One byte per read is the worst case for splitting: nothing may be lost or replaced.
var byteAtATime = IncrementalUTF8Decoder()
let devanagari = "नमस्ते"
var reassembled = ""
for byte in Array(devanagari.utf8) { reassembled += byteAtATime.append(Data([byte])) }
reassembled += byteAtATime.finish()
checkEqual(reassembled, devanagari, "a multi-byte script survives one byte per read")

var truncatedDecoder = IncrementalUTF8Decoder()
checkEqual(truncatedDecoder.append(Data([0x41])), "A", "a lone ascii byte decodes")
_ = truncatedDecoder.append(Data([0xF0]))
checkEqual(truncatedDecoder.finish(), "\u{FFFD}", "an unterminated tail degrades to one replacement, not a dropped word")

// MARK: - Report

if failures.isEmpty {
  print("core: \(checkCount) checks passed")
  exit(0)
}
print("core: \(failures.count) of \(checkCount) checks failed")
for failure in failures { print("  ✗ \(failure)") }
exit(1)
