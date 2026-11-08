import Foundation
import SiriTTSService

final class VoiceCatalog {
  let session: DaemonSession
  private(set) var voices: [SynthesisVoice]

  init(session: DaemonSession, voices: [SynthesisVoice]) {
    self.session = session
    self.voices = voices
  }

  static func open() throws -> VoiceCatalog {
    let session = DaemonSession()
    session.keepActive = true
    guard session.invokeDaemon() else { throw FridayError.daemonUnavailable }
    var list: [SynthesisVoice] = []
    let filled = DispatchSemaphore(value: 0)
    session.downloadedVoices(matching: nil) { found in
      list = found
      filled.signal()
    }
    guard pumpRunLoop(filled, timeout: 20) else {
      throw FridayError.timeout(stage: "the voice inventory from sirittsd", seconds: 20)
    }
    return VoiceCatalog(session: session, voices: list)
  }

  @discardableResult
  func refresh() -> [SynthesisVoice] {
    var list: [SynthesisVoice] = []
    let filled = DispatchSemaphore(value: 0)
    session.downloadedVoices(matching: nil) { found in
      list = found
      filled.signal()
    }
    if pumpRunLoop(filled, timeout: 20) { voices = list }
    return voices
  }

  static func isExpressive(_ voice: SynthesisVoice) -> Bool {
    voice.assetKey.contains(":fmvoice:")
  }

  static func generation(_ voice: SynthesisVoice) -> String {
    isExpressive(voice) ? "expressive" : "standard"
  }

  // Exact case first: two installed voices differ only by case ("Simone" neural
  // vs "simone" expressive), so a case-insensitive pass alone cannot tell them
  // apart. Substring matching is the last resort.
  func find(name: String) -> SynthesisVoice? {
    if let exact = voices.first(where: { $0.name == name || $0.assetKey == name }) { return exact }
    let lowered = name.lowercased()
    if let insensitive = voices.first(where: {
      ($0.name ?? "").lowercased() == lowered || $0.assetKey.lowercased() == lowered
    }) { return insensitive }
    return voices.first {
      ($0.name ?? "").lowercased().contains(lowered) || $0.assetKey.lowercased().contains(lowered)
    }
  }

  // Nearest installed name, so a typo reports the fix instead of just failing.
  func suggestion(for name: String) -> String? {
    let lowered = name.lowercased()
    let ranked = voices
      .compactMap { ($0.name, editDistance(lowered, ($0.name ?? "").lowercased())) }
      .filter { $0.1 <= 3 }
      .sorted { $0.1 < $1.1 }
    return ranked.first?.0
  }

  func resolve(name: String?, language: String?, config: FridayConfig) throws -> SynthesisVoice {
    if let name {
      guard let match = find(name: name) else {
        throw FridayError.unknownVoice(name, suggestion: suggestion(for: name))
      }
      return match
    }
    if let language, let match = voices.first(where: { $0.language.lowercased().hasPrefix(language.lowercased()) }) {
      return match
    }
    if let configured = config.defaultVoice, let match = find(name: configured) {
      return match
    }
    if let match = voices.first(where: { ($0.name ?? "") == FridayConfig.builtInVoice }) { return match }
    let localePrefix = Locale.current.identifier.replacingOccurrences(of: "-", with: "_").split(separator: "_").first.map(String.init) ?? "en"
    guard let fallback = voices.first(where: { $0.language.lowercased().hasPrefix(localePrefix) })
      ?? voices.first(where: { $0.language.lowercased().hasPrefix("en") })
      ?? voices.first else {
      throw FridayError.synthesisFailed("the daemon reports no installed voices")
    }
    return fallback
  }

  // Generation resolution: explicit flag, then the voice's own nature, then config.
  // A voice asset that has no expressive model behind it can only render on the
  // standard path, no matter what the config or flags ask for.
  func generation(requested: String?, for voice: SynthesisVoice, config: FridayConfig, forceStandard: Bool, forceExpressive: Bool, voiceWasExplicit: Bool, usingBuiltInDefault: Bool) -> String {
    guard VoiceCatalog.isExpressive(voice) else { return "standard" }
    if forceStandard { return "standard" }
    if forceExpressive { return "expressive" }
    if let requested, let normalized = FridayConfig.normalizeGeneration(requested) { return normalized }
    // A config-level render path describes the *default* voice; it must not
    // silently override a voice the caller asked for by name.
    if !voiceWasExplicit,
       let configured = config.defaultGeneration,
       let normalized = FridayConfig.normalizeGeneration(configured) { return normalized }
    // Nothing chose for us, so the built-in pair applies: simone on the calm path.
    return usingBuiltInDefault ? FridayConfig.builtInGeneration : "expressive"
  }

  func printList() {
    for voice in voices.sorted(by: { ($0.language, $0.name ?? "") < ($1.language, $1.name ?? "") }) {
      print("\(voice.language)\t\(voice.name ?? "-")\t\(VoiceCatalog.generation(voice))\t\(voice.assetKey)")
    }
  }
}
