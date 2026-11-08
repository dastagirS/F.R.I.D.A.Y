import AVFoundation
import Foundation
import SiriTTSService

struct SpeakOptions {
  var text: String?
  var voice: String?
  var language: String?
  var generation: String?
  var forceStandard = false
  var forceExpressive = false
  var pace: Int?
  var expressivity: Int?
  var rate: Float = 1.0
  var pitch: Float = 1.0
  var volume: Float = 1.0
  var outputPath: String?
  var timingsToStdout = false
  var timingsPath: String?
  var prewarm = false
  var chunked: Bool?
  var listVoices = false
  var quiet = false
  var showHelp = false
  var completionsShell: String?
  var showMan = false
  var showSkill = false
}

func parseSpeakOptions(_ arguments: [String]) throws -> SpeakOptions {
  var options = SpeakOptions()
  var positionals: [String] = []
  var iterator = arguments.makeIterator()
  while let argument = iterator.next() {
    switch argument {
    case "-h", "--help": options.showHelp = true
    case "-l", "--list": options.listVoices = true
    case "-v", "--voice": options.voice = iterator.next()
    case "--language": options.language = iterator.next()
    case "--generation": options.generation = iterator.next()
    case "--standard", "--legacy": options.forceStandard = true
    case "--expressive": options.forceExpressive = true
    case "--pace":
      guard let value = iterator.next(), let parsed = Int(value) else { throw FridayError.usage("--pace needs 1 through 5") }
      options.pace = parsed
    case "--expressivity":
      guard let value = iterator.next(), let parsed = Int(value) else { throw FridayError.usage("--expressivity needs 1 through 5") }
      options.expressivity = parsed
    case "-r", "--rate": options.rate = Float(iterator.next() ?? "") ?? 1.0
    case "--pitch": options.pitch = Float(iterator.next() ?? "") ?? 1.0
    case "--volume": options.volume = Float(iterator.next() ?? "") ?? 1.0
    case "-o", "--out": options.outputPath = iterator.next()
    case "--timings": options.timingsToStdout = true
    case "--timings-out": options.timingsPath = iterator.next()
    case "--prewarm": options.prewarm = true
    case "--chunked": options.chunked = true
    case "--no-chunked": options.chunked = false
    case "-q", "--quiet": options.quiet = true
    case "--completions": options.completionsShell = iterator.next()
    case "--man": options.showMan = true
    case "--skill": options.showSkill = true
    case "--": while let rest = iterator.next() { positionals.append(rest) }
    default: positionals.append(argument)
    }
  }
  let joined = positionals.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  if joined == "-" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    options.text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  } else if !joined.isEmpty {
    options.text = joined
  }
  return options
}

func fail(_ error: Error) -> Never {
  if let fridayError = error as? FridayError {
    FileHandle.standardError.write("friday: \(fridayError.description)\n".data(using: .utf8)!)
    exit(fridayError.exitCode)
  }
  FileHandle.standardError.write("friday: \(error)\n".data(using: .utf8)!)
  exit(1)
}

func runSpeak(_ arguments: [String], config: FridayConfig) throws {
  let options = try parseSpeakOptions(arguments)
  if options.showHelp {
    print(usageText)
    return
  }
  if let shell = options.completionsShell {
    guard let script = completionScripts[shell.lowercased()] else {
      throw FridayError.usage("completions: choose zsh, bash or fish")
    }
    print(script)
    return
  }
  if options.showMan {
    print(manPage)
    return
  }
  if options.showSkill {
    print(skillText)
    return
  }

  let catalog = try VoiceCatalog.open()
  if options.listVoices {
    catalog.printList()
    return
  }

  let voice = try catalog.resolve(name: options.voice, language: options.language, config: config)
  let voiceWasExplicit = options.voice != nil || options.language != nil
  let usingBuiltInDefault = !voiceWasExplicit && config.defaultVoice == nil
  let generation = catalog.generation(
    requested: options.generation,
    for: voice,
    config: config,
    forceStandard: options.forceStandard,
    forceExpressive: options.forceExpressive,
    voiceWasExplicit: voiceWasExplicit,
    usingBuiltInDefault: usingBuiltInDefault
  )
  let chunkSentences = options.chunked ?? config.sentenceChunking ?? FridayConfig.builtInSentenceChunking
  let pace = options.pace ?? config.pace ?? 3
  let expressivity = options.expressivity ?? config.expressivity ?? 3
  let synthesizer = Synthesizer(catalog: catalog)

  // Ctrl-C during playback is a barge-in, not a crash: cancel the daemon
  // request and drop queued audio.
  signal(SIGINT, SIG_IGN)
  let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
  interruptSource.setEventHandler { synthesizer.cancelActive() }
  interruptSource.resume()

  if options.prewarm {
    let seconds = try synthesizer.prewarm(voice: voice, generation: generation, pace: pace, expressivity: expressivity)
    print(String(format: "prewarmed %@ [%@] %@ in %.2fs", voice.name ?? "-", voice.language,
                 generation == "expressive" ? "expressive pace\(pace) expressivity\(expressivity)" : "standard", seconds))
    return
  }

  guard let text = options.text, !text.isEmpty else {
    throw FridayError.usage(usageText)
  }

  let wantsTimings = options.timingsToStdout || options.timingsPath != nil
  let outcome = try synthesizer.synthesize(
    text: text,
    voice: voice,
    generation: generation,
    pace: pace,
    expressivity: expressivity,
    rate: options.rate,
    pitch: options.pitch,
    volume: options.volume,
    wantsTimings: wantsTimings,
    playback: options.outputPath == nil,
    chunkSentences: chunkSentences
  )

  if let outputPath = options.outputPath {
    let data = try wavData(samples: outcome.samples, sampleRate: 48000)
    do {
      try data.write(to: URL(fileURLWithPath: outputPath))
    } catch {
      throw FridayError.config("could not write \(outputPath): \(error)")
    }
  }

  if wantsTimings {
    let json = outcome.timings.json()
    let trimmed = String(decoding: json, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if let path = options.timingsPath {
      do {
        try (trimmed + "\n").write(toFile: path, atomically: true, encoding: .utf8)
      } catch {
        throw FridayError.config("could not write \(path): \(error)")
      }
    }
    if options.timingsToStdout {
      print(trimmed)
    }
  }

  if !options.quiet {
    let generationLabel = generation == "expressive" ? "expressive pace\(pace) expressivity\(expressivity)" : "standard"
    let timingsLabel = outcome.timings.timingsSupported ? " timings=\(outcome.timings.timings.count)" : ""
    let chunkLabel = outcome.chunkCount > 1 ? " chunks=\(outcome.chunkCount)" : ""
    // The daemon alternates lossless PCM and ~50 kbps Opus on its own; say which
    // one happened instead of letting the difference reach the ear unexplained.
    let codecLabel = outcome.sourceFormat.contains("opus") ? " codec=lossy" : ""
    FileHandle.standardError.write(String(
      format: "voice=%@ [%@] %@ src=%@ first_audio=%.0fms synthesis=%.2fs audio=%.2fs%@%@%@\n",
      outcome.voiceName as NSString, outcome.language as NSString, generationLabel as NSString,
      outcome.sourceFormat as NSString, outcome.firstAudioMilliseconds, outcome.synthesisSeconds,
      outcome.audioSeconds, chunkLabel as NSString, codecLabel as NSString, timingsLabel as NSString
    ).data(using: .utf8)!)
  }
}

let config = FridayConfig.load()
let arguments = Array(CommandLine.arguments.dropFirst())

if let subcommand = arguments.first, ["serve", "voices", "config"].contains(subcommand) {
  let rest = Array(arguments.dropFirst())
  do {
    switch subcommand {
    case "serve": try runServe(rest, config: config)
    case "voices": try runVoices(rest, config: config)
    default: try runConfig(rest, config: config)
    }
    exit(0)
  } catch {
    fail(error)
  }
}

do {
  try runSpeak(arguments, config: config)
  exit(0)
} catch {
  fail(error)
}
