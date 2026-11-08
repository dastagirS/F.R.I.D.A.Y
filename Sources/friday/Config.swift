import Foundation

// Persisted defaults, so the locked-in voice is a setting rather than a
// recompile. CLI flags always win over this file.
struct FridayConfig: Codable {
  var defaultVoice: String?
  var defaultGeneration: String?
  var pace: Int?
  var expressivity: Int?
  var sentenceChunking: Bool?

  static var fileURL: URL {
    if let override = ProcessInfo.processInfo.environment["FRIDAY_CONFIG"], !override.isEmpty {
      return URL(fileURLWithPath: override)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/friday", isDirectory: true)
      .appendingPathComponent("config.json")
  }

  static func load() -> FridayConfig {
    guard let data = try? Data(contentsOf: fileURL),
          let decoded = try? JSONDecoder().decode(FridayConfig.self, from: data) else {
      return FridayConfig()
    }
    return decoded
  }

  func save() throws {
    let url = FridayConfig.fileURL
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: url, options: .atomic)
  }

  // The built-in lock-in, used when neither flags nor the config file decide.
  static let builtInVoice = "simone"
  static let builtInGeneration = "standard"

  // On by default: per-sentence requests materially raise the odds of the daemon's
  // lossless encoder and lower time-to-first-word on long answers. It is a bias,
  // not a guarantee; the codec stays the daemon's choice either way.
  static let builtInSentenceChunking = true

  static func normalizeGeneration(_ raw: String) -> String? {
    switch raw.lowercased() {
    case "standard", "legacy", "calm": return "standard"
    case "expressive", "3b", "model": return "expressive"
    default: return nil
    }
  }
}
