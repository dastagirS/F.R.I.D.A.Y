import CoreAudioTypes
import XCTest

@testable import friday

// Checks for the logic that needs no SiriTTS daemon: sentence splitting, streaming
// buffering, the error taxonomy, config coding, WAV output and incremental decoding.

final class ChunkingTests: XCTestCase {
  func testEmptyInputProducesNoChunks() {
    XCTAssertEqual(chunkTexts(""), [])
    XCTAssertEqual(chunkTexts("   \n\t "), [])
  }

  func testSingleSentenceStaysWhole() {
    XCTAssertEqual(chunkTexts("Hello there."), ["Hello there."])
  }

  func testThreeSentencesSplitThreeWays() {
    XCTAssertEqual(chunkTexts("One. Two. Three."), ["One.", "Two.", "Three."])
  }

  func testTitleIsNotASentenceEnd() {
    XCTAssertEqual(
      chunkTexts("Dr. Rao arrived at 9:45 a.m. Then we left."),
      ["Dr. Rao arrived at 9:45 a.m.", "Then we left."]
    )
  }

  func testClockMeridiemNeedsACapitalToCloseASentence() {
    XCTAssertEqual(chunkTexts("We met at 9:45 a.m. on Tuesday."), ["We met at 9:45 a.m. on Tuesday."])
  }

  func testDottedInitialismStaysInsideItsSentence() {
    XCTAssertEqual(chunkTexts("The U.S. Army moved. It rained."), ["The U.S. Army moved.", "It rained."])
  }

  func testDecimalPointIsNotASentenceEnd() {
    XCTAssertEqual(chunkTexts("Pi is 3.14 and it rounds. Next one."), ["Pi is 3.14 and it rounds.", "Next one."])
  }

  func testClosingQuoteBelongsToItsSentence() {
    XCTAssertEqual(chunkTexts("He said \"stop.\" Then he left."), ["He said \"stop.\"", "Then he left."])
  }

  func testEllipsisEndsASentenceOnce() {
    XCTAssertEqual(chunkTexts("Wait... What?"), ["Wait...", "What?"])
  }

  func testNewlineAfterTerminatorSplits() {
    XCTAssertEqual(chunkTexts("Done.\nNext line."), ["Done.", "Next line."])
  }

  func testTextWithoutTerminatorIsOneTailChunk() {
    XCTAssertEqual(chunkTexts("a run on sentence with no ending"), ["a run on sentence with no ending"])
  }

  func testLeadingWhitespaceIsTrimmedAndOffsetsPointAtVisibleText() {
    let chunks = TextChunker.chunks(from: "  First. Second.")
    XCTAssertEqual(chunks.map(\.text), ["First.", "Second."])
    XCTAssertEqual(chunks.map(\.utf16Location), [2, 9])
  }

  func testAstralCharactersKeepUtf16Offsets() {
    let chunks = TextChunker.chunks(from: "😀 Hi. Next.")
    XCTAssertEqual(chunks.map(\.text), ["😀 Hi.", "Next."])
    XCTAssertEqual(chunks.last?.utf16Location, 7)
  }

  func testBoundsFallBackToTheCallersSingleRequestPath() {
    XCTAssertEqual(
      TextChunker.chunks(from: String(repeating: "a", count: TextChunker.maximumTextLength + 1)).count, 0)
    XCTAssertEqual(
      TextChunker.chunks(from: String(repeating: "A. ", count: TextChunker.maximumChunks + 1)).count, 0)
  }

  func testSentenceEndDetection() {
    XCTAssertTrue(TextChunker.endsWithSentenceEnd("Hello."))
    XCTAssertTrue(TextChunker.endsWithSentenceEnd("Hello.\""))
    XCTAssertTrue(TextChunker.endsWithSentenceEnd("Really?"))
    XCTAssertFalse(TextChunker.endsWithSentenceEnd("Hello"))
    XCTAssertFalse(TextChunker.endsWithSentenceEnd(""))
  }
}

final class StreamingSplitterTests: XCTestCase {
  func testHalfTypedWordIsHeldBackUntilItCompletes() {
    var splitter = StreamingSentenceSplitter()
    splitter.append("Hello wor")
    XCTAssertEqual(splitter.takeSentences(), [])
    splitter.append("ld.")
    XCTAssertEqual(splitter.takeSentences(), ["Hello world."])
  }

  func testUnfinishedSecondSentenceIsHeld() {
    var splitter = StreamingSentenceSplitter()
    splitter.append("More")
    XCTAssertEqual(splitter.takeSentences(), [])
    splitter.append(" text.")
    XCTAssertEqual(splitter.takeSentences(), ["More text."])
  }

  func testAbbreviationAtEndOfInputDoesNotCompleteASentence() {
    var splitter = StreamingSentenceSplitter()
    splitter.append("Dr. Rao")
    XCTAssertEqual(splitter.takeSentences(), [])
    splitter.append(" said so.")
    XCTAssertEqual(splitter.takeSentences(), ["Dr. Rao said so."])
  }

  func testUnterminatedTailIsSpokenOnFlush() {
    var splitter = StreamingSentenceSplitter()
    splitter.append("tail without end")
    XCTAssertEqual(splitter.takeSentences(), [])
    XCTAssertEqual(splitter.flush(), ["tail without end"])
  }

  func testRunOnIsCutAtWordBoundariesWithoutLosingWords() {
    let source = String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces)
    var splitter = StreamingSentenceSplitter()
    splitter.append(source)
    let streamed = splitter.takeSentences()
    let flushed = splitter.flush()
    XCTAssertLessThanOrEqual(streamed.count, 4, "forced splits per call are bounded")
    for piece in streamed + flushed {
      XCTAssertLessThanOrEqual(piece.count, StreamingSentenceSplitter.maximumTailLength)
      XCTAssertFalse(piece.hasSuffix(" "))
      XCTAssertFalse(piece.hasPrefix(" "))
    }
    XCTAssertEqual((streamed + flushed).joined(separator: " "), source)
    XCTAssertEqual(splitter.buffered, "")
  }

  func testSeveralCompleteSentencesDrainAtOnce() {
    var splitter = StreamingSentenceSplitter()
    splitter.append("One. Two. Three. Four.")
    XCTAssertEqual(splitter.takeSentences(), ["One.", "Two.", "Three.", "Four."])
    XCTAssertEqual(splitter.buffered, "")
  }
}

final class ErrorTaxonomyTests: XCTestCase {
  private let cases: [(FridayError, Int32)] = [
    (.usage("x"), 2),
    (.daemonUnavailable, 3),
    (.serverUnreachable("127.0.0.1:8787"), 3),
    (.unknownVoice("x", suggestion: nil), 4),
    (.voiceSubstituted(voice: "simone", deliveredRate: 22_050, hint: "install it"), 10),
    (.config("x"), 5),
    (.synthesisFailed("x"), 6),
    (.timeout(stage: "x", seconds: 1), 7),
    (.nothingCaptured(chunks: 1, formats: ""), 8),
    (.emptyInput("x"), 8),
    (.audioOutput("x"), 9),
    (.cancelled, 130),
  ]

  func testEveryCaseMapsToItsDocumentedCode() {
    for (error, expected) in cases {
      XCTAssertEqual(error.exitCode, expected, "\(error) should exit \(expected)")
      XCTAssertFalse(error.description.isEmpty, "\(error) needs a message")
    }
    XCTAssertEqual(Set(cases.map { $0.0.exitCode }), Set<Int32>([2, 3, 4, 5, 6, 7, 8, 9, 10, 130]))
  }

  // The tell is the rate: premium Siri voices arrive at 48 kHz (natural asset) or
  // 24 kHz (neural asset); 22.05 kHz is the legacy render the daemon substitutes.
  func testLegacySubstitutionIsDetectedByRate() {
    // The tell is the rate: premium Siri voices arrive at 48 kHz (natural asset) or
    // 24 kHz (neural); 22.05 kHz is the legacy render the daemon substitutes silently.
    XCTAssertTrue(isLegacySubstitution(deliveredRate: 22_050, assetKey: "en-US:fmvoice:female:simone:premium:0"))
    XCTAssertFalse(isLegacySubstitution(deliveredRate: 48_000, assetKey: "en-IN:natural:female:Riya:premium:5049"))
    XCTAssertFalse(isLegacySubstitution(deliveredRate: 24_000, assetKey: "en-US:fmvoice:female:simone:premium:0"))
    // A genuinely legacy MacinTalk voice can be 22.05 kHz and is not a substitution.
    XCTAssertFalse(isLegacySubstitution(deliveredRate: 22_050, assetKey: "en-US:Samantha"))
  }

  // The daemon matches a subscription on the assetKey it computes for the voice it is
  // handed, so the identity has to be rebuilt exactly: hyphenated locale, gender word,
  // and the asset's own version. Measured against the installed en-IN Riya asset, whose
  // daemon key is "en-IN:natural:female:Riya:premium:5049".
  func testAssetIdentityMatchesTheDaemonsOwnKeyFormat() {
    let asset = TTSAssetInfo(
      identifier: "com.apple.speech.synthesis.voice.custom.siri.riya.premium",
      name: "Riya", language: "en_IN", technology: "natural", quality: "premium",
      gender: 2, version: 5049, downloadBytes: 0, diskBytes: 0, locallyAvailable: true
    )
    XCTAssertEqual(asset.voiceLanguage, "en-IN")
    XCTAssertEqual(asset.nativeAssetKey, "en-IN:natural:female:Riya:premium:5049")
    // The MobileAsset specifier keeps the underscore form; mixing the two matches nothing.
    XCTAssertEqual(asset.specifier, "com.apple.siri.tts.voice.en_IN.riya.natural.premium")
  }

  // Three real states from this machine, checked without touching the asset store. The
  // install offer must follow the asset store, not the daemon's inventory, and it must
  // never propose a downgrade.
  func testInstallOffersOnlyABetterAsset() {
    func asset(_ specifier: String, _ technology: String, _ quality: String) -> TTSAssetInfo {
      // com.apple.siri.tts.voice.<locale>.<name>.<technology>.<quality>
      let parts = specifier.components(separatedBy: ".")
      return TTSAssetInfo(
        identifier: specifier, name: parts[6].capitalized, language: parts[5],
        technology: technology, quality: quality, gender: 2, version: 0,
        downloadBytes: 0, diskBytes: 0, locallyAvailable: false
      )
    }
    let simone = [
      asset("com.apple.siri.tts.voice.en_US.simone.natural.premium", "natural", "premium"),
      asset("com.apple.siri.tts.voice.en_US.simone.neural.premium", "neural", "premium"),
    ]
    XCTAssertEqual(
      installableAsset(
        for: "Simone", in: simone,
        installed: ["com.apple.siri.tts.voice.en_US.simone.neural.premium": "1"]
      ),
      "com.apple.siri.tts.voice.en_US.simone.natural.premium",
      "the natural asset is the Siri path and must be offered over an installed neural one"
    )

    let riya = [
      asset("com.apple.siri.tts.voice.en_IN.riya.natural.premium", "natural", "premium"),
      asset("com.apple.siri.tts.voice.en_IN.riya.neural.premium", "neural", "premium"),
    ]
    XCTAssertNil(
      installableAsset(
        for: "Riya", in: riya,
        installed: ["com.apple.siri.tts.voice.en_IN.riya.natural.premium": "1"]
      ),
      "a working voice must not be offered a 66 MB downgrade"
    )

    // Aman: premium is downloadable while only the compact quality is installed.
    let aman = [
      asset("com.apple.siri.tts.voice.en_IN.aman.neuralAX.premium", "neuralAX", "premium"),
      asset("com.apple.siri.tts.voice.en_IN.aman.neuralAX.compact", "neuralAX", "compact"),
    ]
    XCTAssertEqual(
      installableAsset(
        for: "Aman", in: aman,
        installed: ["com.apple.siri.tts.voice.en_IN.aman.neuralAX.compact": "1"]
      ),
      "com.apple.siri.tts.voice.en_IN.aman.neuralAX.premium",
      "premium outranks compact within the same family"
    )
  }

  func testVoiceTypeMappingCoversTheCatalogFamilies() {
    XCTAssertEqual(voiceType(forTechnology: "natural"), 6)
    XCTAssertEqual(voiceType(forTechnology: "neural"), 4)
    XCTAssertEqual(voiceType(forTechnology: "neuralAX"), 5)
    XCTAssertEqual(voiceType(forTechnology: "gryphon"), 3)
    // "fmvoice" is the expressive identity; it has no downloadable individual bundle.
    XCTAssertNil(voiceType(forTechnology: "fmvoice"))
  }

  func testUnknownVoiceNamesTheNearMiss() {
    let hinted = FridayError.unknownVoice("Riaya", suggestion: "Riya").description
    XCTAssertTrue(hinted.contains("did you mean 'Riya'?"))
    XCTAssertTrue(hinted.contains("friday voices"))
    XCTAssertFalse(FridayError.unknownVoice("zzz", suggestion: nil).description.contains("did you mean"))
  }
}

final class ConfigTests: XCTestCase {
  func testRoundTrip() throws {
    var config = FridayConfig()
    config.defaultVoice = "simone"
    config.defaultGeneration = "standard"
    config.pace = 4
    config.expressivity = 2
    config.sentenceChunking = true
    config.lossless = true
    let decoded = try JSONDecoder().decode(FridayConfig.self, from: try JSONEncoder().encode(config))
    XCTAssertEqual(decoded.defaultVoice, "simone")
    XCTAssertEqual(decoded.defaultGeneration, "standard")
    XCTAssertEqual(decoded.pace, 4)
    XCTAssertEqual(decoded.expressivity, 2)
    XCTAssertEqual(decoded.sentenceChunking, true)
    XCTAssertEqual(decoded.lossless, true)
  }

  func testPartialAndEmptyObjectsDecodeToNilSoBuiltInsApply() throws {
    let partial = try JSONDecoder().decode(FridayConfig.self, from: Data(#"{"defaultVoice":"Riya"}"#.utf8))
    XCTAssertEqual(partial.defaultVoice, "Riya")
    XCTAssertNil(partial.pace)
    let empty = try JSONDecoder().decode(FridayConfig.self, from: Data("{}".utf8))
    XCTAssertNil(empty.defaultVoice)
  }

  func testBuiltInDefaults() {
    XCTAssertEqual(FridayConfig.builtInVoice, "simone")
    XCTAssertEqual(FridayConfig.builtInGeneration, "standard")
    XCTAssertTrue(FridayConfig.builtInSentenceChunking)
    XCTAssertTrue(FridayConfig.builtInLossless)
  }

  func testGenerationNormalisation() {
    XCTAssertEqual(FridayConfig.normalizeGeneration("STANDARD"), "standard")
    XCTAssertEqual(FridayConfig.normalizeGeneration("calm"), "standard")
    XCTAssertEqual(FridayConfig.normalizeGeneration("3b"), "expressive")
    XCTAssertEqual(FridayConfig.normalizeGeneration("model"), "expressive")
    XCTAssertNil(FridayConfig.normalizeGeneration("theatrical"))
  }

  func testOnOffParsing() {
    XCTAssertEqual(parseOnOff("on"), true)
    XCTAssertEqual(parseOnOff("TRUE"), true)
    XCTAssertEqual(parseOnOff("yes"), true)
    XCTAssertEqual(parseOnOff("1"), true)
    XCTAssertEqual(parseOnOff("off"), false)
    XCTAssertEqual(parseOnOff("No"), false)
    XCTAssertEqual(parseOnOff("0"), false)
    XCTAssertNil(parseOnOff("maybe"))
  }
}

final class AudioFormattingTests: XCTestCase {
  func testFormatIdentifiers() {
    XCTAssertEqual(fourCharacterCode(0x6C7063_6D), "lpcm")
    XCTAssertEqual(fourCharacterCode(0x6F7075_73), "opus")
  }

  func testFormatPlausibility() {
    var format = AudioStreamBasicDescription()
    format.mSampleRate = 48_000
    format.mChannelsPerFrame = 1
    format.mFormatID = kAudioFormatLinearPCM
    format.mBitsPerChannel = 16
    XCTAssertTrue(isPlausibleFormat(format))

    format.mSampleRate = 1_000
    XCTAssertFalse(isPlausibleFormat(format))

    format.mSampleRate = 48_000
    format.mChannelsPerFrame = 0
    XCTAssertFalse(isPlausibleFormat(format))

    format.mChannelsPerFrame = 1
    format.mFormatID = 0
    XCTAssertTrue(isPlausibleFormat(format), "compressed formats report zero bit depth")
  }

  func testPcmClampsAndRounds() {
    let samples: [Float] = [-1.0, -0.5, 0.0, 0.5, 1.0]
    let pcm = pcmData(samples: samples)
    XCTAssertEqual(pcm.count, samples.count * 2)
    XCTAssertEqual(int16Sample(pcm, 0), -32767)
    XCTAssertEqual(int16Sample(pcm, 1), -16384)
    XCTAssertEqual(int16Sample(pcm, 2), 0)
    XCTAssertEqual(int16Sample(pcm, 3), 16384)
    XCTAssertEqual(int16Sample(pcm, 4), 32767)

    let clamped = pcmData(samples: [2.0, -2.0])
    XCTAssertEqual(int16Sample(clamped, 0), 32767)
    XCTAssertEqual(int16Sample(clamped, 1), -32767)
  }

  func testWavHeaderLayout() throws {
    let samples: [Float] = [-1.0, -0.5, 0.0, 0.5, 1.0]
    let wav = try wavData(samples: samples, sampleRate: 48_000)
    XCTAssertEqual(wav.count, 44 + samples.count * 2)
    XCTAssertEqual(asciiField(wav, 0, 4), "RIFF")
    XCTAssertEqual(uint32Field(wav, 4), UInt32(wav.count - 8))
    XCTAssertEqual(asciiField(wav, 8, 4), "WAVE")
    XCTAssertEqual(asciiField(wav, 12, 4), "fmt ")
    XCTAssertEqual(uint32Field(wav, 16), 16)
    XCTAssertEqual(uint16Field(wav, 20), 1, "linear PCM, not float")
    XCTAssertEqual(uint16Field(wav, 22), 1, "mono")
    XCTAssertEqual(uint32Field(wav, 24), 48_000)
    XCTAssertEqual(uint32Field(wav, 28), 96_000)
    XCTAssertEqual(uint16Field(wav, 32), 2)
    XCTAssertEqual(uint16Field(wav, 34), 16)
    XCTAssertEqual(asciiField(wav, 36, 4), "data")
    XCTAssertEqual(uint32Field(wav, 40), UInt32(samples.count * 2))
  }

  func testWavRejectsImpossibleInputs() throws {
    XCTAssertThrowsError(try wavData(samples: [], sampleRate: 48_000))
    XCTAssertThrowsError(try wavData(samples: [0.5], sampleRate: 1_000))
    let atFortyFour = try wavData(samples: [1.0], sampleRate: 44_100)
    XCTAssertEqual(uint32Field(atFortyFour, 24), 44_100)
  }
}

final class UTF8DecoderTests: XCTestCase {
  func testCharacterSplitAcrossTwoReads() {
    var decoder = IncrementalUTF8Decoder()
    let bytes = Array("😀".utf8)
    XCTAssertEqual(bytes.count, 4)
    XCTAssertEqual(decoder.append(Data(bytes.prefix(2))), "")
    XCTAssertEqual(decoder.append(Data(bytes.suffix(2))), "😀")
    XCTAssertEqual(decoder.finish(), "")
  }

  func testAsciiAndEmptyReads() {
    var decoder = IncrementalUTF8Decoder()
    XCTAssertEqual(decoder.append(Data("hello ".utf8)), "hello ")
    var empty = IncrementalUTF8Decoder()
    XCTAssertEqual(empty.append(Data()), "")
  }

  func testHeldLeadByteCompletesLater() {
    var decoder = IncrementalUTF8Decoder()
    let fold = Array("🙏".utf8)
    XCTAssertEqual(decoder.append(Data([0x41] + fold.prefix(1))), "A")
    XCTAssertEqual(decoder.append(Data(fold.dropFirst() + [0x42])), "🙏B")
  }

  func testOneBytePerReadLosesNothing() {
    var decoder = IncrementalUTF8Decoder()
    let source = "नमस्ते"
    var assembled = ""
    for byte in Array(source.utf8) { assembled += decoder.append(Data([byte])) }
    assembled += decoder.finish()
    XCTAssertEqual(assembled, source)
  }

  func testUnterminatedTailDegradesToOneReplacement() {
    var decoder = IncrementalUTF8Decoder()
    XCTAssertEqual(decoder.append(Data([0x41])), "A")
    XCTAssertEqual(decoder.append(Data([0xF0])), "")
    XCTAssertEqual(decoder.finish(), "\u{FFFD}")
  }
}
