import Foundation

// Persisted defaults, so the locked-in voice is a setting rather than a
// recompile. CLI flags always win over this file.
struct FridayConfig: Codable {
  var defaultVoice: String?
  var defaultGeneration: String?
  var pace: Int?
  var expressivity: Int?
  var sentenceChunking: Bool?
  var lossless: Bool?

  static var fileURL: URL {
    if let override = ProcessInfo.processInfo.environment["FRIDAY_CONFIG"], !override.isEmpty {
      return URL(fileURLWithPath: override)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/friday", isDirectory: true)
      .appendingPathComponent("config.json")
  }

  // A missing file is normal. A file that exists but cannot be read or parsed is an
  // error: silently falling back to built-ins means editing the config has no visible
  // effect, which is the hardest kind of bug to find.
  static func load() throws -> FridayConfig {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return FridayConfig() }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw FridayError.config("cannot read config \(fileURL.path): \(error.localizedDescription); fix it or delete it")
    }
    guard !data.isEmpty else { return FridayConfig() }
    do {
      return try JSONDecoder().decode(FridayConfig.self, from: data)
    } catch {
      throw FridayError.config(
        "cannot use config \(fileURL.path): \(describeDecoding(error)); fix it, or run 'friday config reset'"
      )
    }
  }

  // DecodingError's default text is useless for debugging a hand-edited file, so the
  // key path and the offending value are pulled out explicitly.
  private static func describeDecoding(_ error: Error) -> String {
    guard let decoding = error as? DecodingError else { return error.localizedDescription }
    switch decoding {
    case .typeMismatch(let type, let context):
      return "key '\(keyPath(context))' has the wrong type (\(type)); \(describe(context.debugDescription))"
    case .valueNotFound(let type, let context):
      return "key '\(keyPath(context))' needs a \(type) value; \(describe(context.debugDescription))"
    case .keyNotFound(let key, let context):
      return "required key '\(key.stringValue)' is missing at \(keyPath(context))"
    case .dataCorrupted(let context):
      return "malformed JSON at \(keyPath(context)); \(context.debugDescription)"
    @unknown default:
      return "unrecognised decoding error"
    }
  }

  private static func keyPath(_ context: DecodingError.Context) -> String {
    let path = context.codingPath.map(\.stringValue).joined(separator: ".")
    return path.isEmpty ? "root" : path
  }

  private static func describe(_ text: String) -> String {
    text.split(separator: "\n").first.map(String.init) ?? text
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

  // Lossless by default: the compressed path is what made the voice sound wrong.
  static let builtInLossless = true

  static func normalizeGeneration(_ raw: String) -> String? {
    switch raw.lowercased() {
    case "standard", "legacy", "calm": return "standard"
    case "expressive", "3b", "model": return "expressive"
    default: return nil
    }
  }
}
