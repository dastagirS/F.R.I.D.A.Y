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
  var lossless: Bool?
  var listVoices = false
  var quiet = false
  var showHelp = false
  var completionsShell: String?
  var showMan = false
  var showSkill = false
  var debug = false
}

// Flags that take a value, for the "did you mean" suggestion on a typo.
let speakFlags: [String] = [
  "-h", "--help", "-l", "--list", "-v", "--voice", "--language", "--generation",
  "--standard", "--legacy", "--expressive", "--pace", "--expressivity", "-r", "--rate",
  "--pitch", "--volume", "-o", "--out", "--timings", "--timings-out", "--prewarm",
  "--chunked", "--no-chunked", "--lossless", "--fast", "-q", "--quiet", "--completions",
  "--man", "--skill", "--debug"
]
let subcommands = ["serve", "voices", "config"]

// Edit distance, used only to suggest a correction for a mistyped flag or subcommand.
func editDistance(_ left: String, _ right: String) -> Int {
  let a = Array(left), b = Array(right)
  guard !a.isEmpty else { return b.count }
  guard !b.isEmpty else { return a.count }
  var previous = Array(0...b.count)
  // Bounded loop: one row per character of the longer string, one column per the other.
  for i in 1...a.count {
    var current = [i] + Array(repeating: 0, count: b.count)
    for j in 1...b.count {
      current[j] = a[i - 1] == b[j - 1]
        ? previous[j - 1]
        : 1 + min(previous[j - 1], previous[j], current[j - 1])
    }
    previous = current
  }
  return previous[b.count]
}

func suggestion(for token: String, among candidates: [String]) -> String? {
  let ranked = candidates
    .map { ($0, editDistance(token, $0)) }
    .filter { $0.1 <= 3 }
    .sorted { $0.1 < $1.1 }
  return ranked.first?.0
}

func unknownFlag(_ flag: String, among candidates: [String]) throws -> Never {
  let hint = suggestion(for: flag, among: candidates).map { "did you mean '\($0)'?" } ?? "run 'friday --help'"
  throw FridayError.usage("unknown option '\(flag)'; \(hint)")
}

// Values are required and validated here, so a typo cannot silently become a default.
func value(_ iterator: inout IndexingIterator<[String]>, for flag: String) throws -> String {
  guard let next = iterator.next() else {
    throw FridayError.usage("\(flag) needs a value")
  }
  // A following flag means the value was forgotten; '-' alone is the stdin convention.
  if next.hasPrefix("-"), next != "-", Float(next) == nil {
    throw FridayError.usage("\(flag) needs a value, got '\(next)'")
  }
  return next
}

func number(_ iterator: inout IndexingIterator<[String]>, for flag: String, greaterThan minimum: Float) throws -> Float {
  let raw = try value(&iterator, for: flag)
  guard let parsed = Float(raw) else {
    throw FridayError.usage("\(flag) needs a number, got '\(raw)'")
  }
  guard parsed > minimum else {
    throw FridayError.usage("\(flag) must be greater than \(minimum), got '\(raw)'")
  }
  return parsed
}

func preset(_ iterator: inout IndexingIterator<[String]>, for flag: String) throws -> Int {
  let raw = try value(&iterator, for: flag)
  guard let parsed = Int(raw), (1...5).contains(parsed) else {
    throw FridayError.usage("\(flag) needs 1 through 5, got '\(raw)'")
  }
  return parsed
}

func parseSpeakOptions(_ arguments: [String]) throws -> SpeakOptions {
  var options = SpeakOptions()
  var positionals: [String] = []
  var iterator = arguments.makeIterator()
  while let argument = iterator.next() {
    switch argument {
    case "-h", "--help": options.showHelp = true
    case "-l", "--list": options.listVoices = true
    case "-v", "--voice": options.voice = try value(&iterator, for: argument)
    case "--language": options.language = try value(&iterator, for: argument)
    case "--generation": options.generation = try value(&iterator, for: argument)
    case "--standard", "--legacy": options.forceStandard = true
    case "--expressive": options.forceExpressive = true
    case "--pace": options.pace = try preset(&iterator, for: argument)
    case "--expressivity": options.expressivity = try preset(&iterator, for: argument)
    case "-r", "--rate": options.rate = try number(&iterator, for: argument, greaterThan: 0)
    case "--pitch": options.pitch = try number(&iterator, for: argument, greaterThan: 0)
    case "--volume": options.volume = try number(&iterator, for: argument, greaterThan: 0)
    case "-o", "--out": options.outputPath = try value(&iterator, for: argument)
    case "--timings": options.timingsToStdout = true
    case "--timings-out": options.timingsPath = try value(&iterator, for: argument)
    case "--prewarm": options.prewarm = true
    case "--chunked": options.chunked = true
    case "--no-chunked": options.chunked = false
    case "--lossless": options.lossless = true
    case "--fast": options.lossless = false
    case "-q", "--quiet": options.quiet = true
    case "--completions": options.completionsShell = try value(&iterator, for: argument)
    case "--man": options.showMan = true
    case "--skill": options.showSkill = true
    case "--debug": options.debug = true
    case "--": while let rest = iterator.next() { positionals.append(rest) }
    default:
      // A leading dash is a flag we do not know, never text to speak.
      if argument.hasPrefix("-"), argument != "-" { try unknownFlag(argument, among: speakFlags) }
      positionals.append(argument)
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
  guard let fridayError = error as? FridayError else {
    FileHandle.standardError.write(
      "friday: unexpected failure: \(error); re-run with --debug to see the stages\n".data(using: .utf8)!)
    exit(1)
  }
  // Ctrl-C is the user interrupting, not an error to explain.
  if case .cancelled = fridayError { exit(fridayError.exitCode) }
  FileHandle.standardError.write("friday: \(fridayError.description)\n".data(using: .utf8)!)
  if fridayError.exitCode == 1 {
    FileHandle.standardError.write("friday: re-run with --debug to see the stages\n".data(using: .utf8)!)
  }
  exit(fridayError.exitCode)
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
  let lossless = options.lossless ?? config.lossless ?? FridayConfig.builtInLossless
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
    // Concise by default; the full listing is one flag away.
    throw FridayError.usage(conciseUsageText)
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
    chunkSentences: chunkSentences,
    lossless: lossless
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
    let codecLabel = outcome.sourceFormat.contains("opus")
      ? (lossless ? " codec=lossy(requested lossless)" : " codec=lossy")
      : ""
    FileHandle.standardError.write(String(
      format: "voice=%@ [%@] %@ src=%@ first_audio=%.0fms synthesis=%.2fs audio=%.2fs%@%@%@\n",
      outcome.voiceName as NSString, outcome.language as NSString, generationLabel as NSString,
      outcome.sourceFormat as NSString, outcome.firstAudioMilliseconds, outcome.synthesisSeconds,
      outcome.audioSeconds, chunkLabel as NSString, codecLabel as NSString, timingsLabel as NSString
    ).data(using: .utf8)!)
  }
}

Debug.enableFromEnvironment()
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--debug") { Debug.enable() }
Debug.stage("start", "friday pid=\(getpid()) log=\(Debug.sinkDescription) args=\(arguments.count)")

let config: FridayConfig
do {
  config = try FridayConfig.load()
  Debug.stage("config", "\(FridayConfig.fileURL.path) \(FileManager.default.fileExists(atPath: FridayConfig.fileURL.path) ? "loaded" : "absent, using built-ins") voice=\(config.defaultVoice ?? FridayConfig.builtInVoice) generation=\(config.defaultGeneration ?? FridayConfig.builtInGeneration)")
} catch {
  fail(error)
}

// Only a lone token can be a mistyped subcommand: "friday server is down" is a
// sentence to speak, not a bad invocation of "serve".
if arguments.count == 1,
   let candidate = arguments.first,
   !candidate.hasPrefix("-"),
   !subcommands.contains(candidate),
   suggestion(for: candidate, among: subcommands) != nil {
  // Looks like a mistyped subcommand: say so rather than speaking it aloud as text.
  fail(FridayError.usage(
    "unknown command '\(candidate)'; did you mean '\(suggestion(for: candidate, among: subcommands)!)'? run 'friday --help'"))
}

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
