import Foundation
import ObjectiveC.runtime
import SiriTTSService

// The downloadable voice catalog lives behind private TTS asset classes with no
// headers, and several of its getters return scalars. Sending `perform` to a
// method that returns BOOL or NSInteger hands back a bogus object pointer and
// crashes, so every accessor here checks its Objective-C type encoding first and
// calls through a correctly typed IMP.

struct TTSAssetInfo {
  let identifier: String
  let name: String
  let language: String
  let technology: String
  let quality: String
  let gender: Int
  let version: Int
  let downloadBytes: Int
  let diskBytes: Int
  var locallyAvailable: Bool

  // MobileAsset specifier shape used by the elimination API.
  var specifier: String {
    "com.apple.siri.tts.voice.\(language).\(name.lowercased()).\(technology).\(quality)"
  }

  // Locale spelling used inside an asset identity. Apple's own keys are hyphenated
  // ("en-IN:natural:female:Riya:premium:5049"); the MobileAsset specifier uses the
  // underscore form ("…voice.en_IN.riya.natural.premium"). Mixing them matches nothing.
  var voiceLanguage: String {
    language.replacingOccurrences(of: "_", with: "-")
  }

  // The identity `SynthesisVoice.assetKey` produces once type, gender, footprint and
  // version are set — the value the daemon matches a subscription against.
  var nativeAssetKey: String {
    let genderName: String
    switch gender {
    case 1: genderName = "male"
    case 2: genderName = "female"
    case 3: genderName = "neutral"
    default: genderName = "undefined"
    }
    return "\(voiceLanguage):\(technology):\(genderName):\(name):\(quality):\(version)"
  }
}

// Subscribing is not a name lookup: the daemon matches the assetKey of the voice it is
// handed, and a bare SynthesisVoice(language:name:) computes "en_US:undefined:undefined:
// simone:undefined:0", which matches no asset, so the request succeeds and nothing is
// downloaded. The mapping is Apple's own VoiceType numbering.
func voiceType(forTechnology technology: String) -> Int? {
  switch technology.lowercased() {
  case "vocalizer": return 1
  case "custom": return 2
  case "gryphon": return 3
  case "neural": return 4
  case "neuralax": return 5
  case "natural": return 6
  default: return nil
  }
}

// Returns nil rather than a voice that cannot match, so a caller reports the reason
// instead of printing a request that will be ignored.
func subscribableVoice(for asset: TTSAssetInfo) -> SynthesisVoice? {
  guard let type = voiceType(forTechnology: asset.technology) else { return nil }
  let voice = SynthesisVoice(language: asset.voiceLanguage, name: asset.name)
  for (key, selector) in [("type", "setType:"), ("gender", "setGender:"), ("footprint", "setFootprint:")] {
    guard voice.responds(to: NSSelectorFromString(selector)) else { return nil }
    voice.setValue(key == "footprint" ? 2 : (key == "type" ? type : asset.gender), forKey: key)
  }
  voice.version = asset.version
  guard voice.assetKey == asset.nativeAssetKey else { return nil }
  return voice
}

private let siriFrameworkPath = "/System/Library/PrivateFrameworks/SiriTTSService.framework/SiriTTSService"
private let textToSpeechFrameworkPath = "/System/Library/PrivateFrameworks/TextToSpeech.framework/TextToSpeech"
private let mobileAssetFrameworkPath = "/System/Library/PrivateFrameworks/MobileAsset.framework/MobileAsset"
private let uafAssetType = "com.apple.MobileAsset.UAF.Siri.TextToSpeech"
private let uafAssetRootDefault = "/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/purpose_auto"

// Test hook so purge verification can run against a scratch directory instead of
// real Apple assets.
func uafAssetRoot() -> String {
  if let override = ProcessInfo.processInfo.environment["FRIDAY_UAF_ASSET_ROOT"], !override.isEmpty {
    return override
  }
  return uafAssetRootDefault
}

private func encoding(of object: AnyObject, _ name: String) -> String? {
  guard let method = class_getInstanceMethod(type(of: object), NSSelectorFromString(name)),
        let types = method_getTypeEncoding(method) else { return nil }
  return String(cString: types)
}

private func objectValue(_ object: AnyObject, _ name: String) -> AnyObject? {
  guard let types = encoding(of: object, name), types.hasPrefix("@") else { return nil }
  guard let method = class_getInstanceMethod(type(of: object), NSSelectorFromString(name)) else { return nil }
  typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
  let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
  return getter(object, NSSelectorFromString(name))
}

private func stringValue(_ object: AnyObject, _ name: String) -> String? {
  objectValue(object, name) as? String
}

private func boolValue(_ object: AnyObject, _ name: String) -> Bool? {
  guard encoding(of: object, name) == "B16@0:8",
        let method = class_getInstanceMethod(type(of: object), NSSelectorFromString(name)) else { return nil }
  typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
  return unsafeBitCast(method_getImplementation(method), to: Getter.self)(object, NSSelectorFromString(name))
}

private func integerValue(_ object: AnyObject, _ name: String) -> Int? {
  guard encoding(of: object, name) == "q16@0:8",
        let method = class_getInstanceMethod(type(of: object), NSSelectorFromString(name)) else { return nil }
  typealias Getter = @convention(c) (AnyObject, Selector) -> Int
  return unsafeBitCast(method_getImplementation(method), to: Getter.self)(object, NSSelectorFromString(name))
}

private func classValue(_ cls: AnyClass, _ name: String) -> AnyObject? {
  guard let method = class_getClassMethod(cls, NSSelectorFromString(name)) else { return nil }
  typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
  return unsafeBitCast(method_getImplementation(method), to: Getter.self)(cls as AnyObject, NSSelectorFromString(name))
}

func listCatalogAssets() throws -> [TTSAssetInfo] {
  guard dlopen(siriFrameworkPath, RTLD_LAZY | RTLD_LOCAL) != nil else {
    throw FridayError.config("SiriTTSService could not be loaded")
  }
  guard dlopen(textToSpeechFrameworkPath, RTLD_LAZY | RTLD_LOCAL) != nil else {
    throw FridayError.config("TextToSpeech could not be loaded")
  }
  guard let assetClass = NSClassFromString("SiriTTSService.TTSAsset"),
        let typeClass = NSClassFromString("TTSAssetType") else {
    throw FridayError.config("the TTS asset catalog classes are absent on this macOS build")
  }
  guard let gryphonType = classValue(typeClass, "gryphonVoice") else {
    throw FridayError.config("the Gryphon asset type is unavailable on this macOS build")
  }
  guard let listMethod = class_getClassMethod(assetClass, NSSelectorFromString("listAssetsOfTypes:matching:")) else {
    throw FridayError.config("the asset catalog selector is absent on this macOS build")
  }
  typealias Lister = @convention(c) (AnyObject, Selector, NSArray, NSDictionary) -> AnyObject?
  let lister = unsafeBitCast(method_getImplementation(listMethod), to: Lister.self)
  guard let raw = lister(assetClass as AnyObject, NSSelectorFromString("listAssetsOfTypes:matching:"),
                         NSArray(object: gryphonType), NSDictionary()),
        let assets = raw as? [AnyObject] else {
    throw FridayError.config("the asset catalog returned an incompatible result")
  }

  let localStates = localAssetSpecifiers()
  return assets.map { asset in
    let attributes = (objectValue(asset, "attributes") as? [String: Any]) ?? [:]
    // VoiceAssetDescription looks like "Name:lang:technology:quality:uaf:CV 0"
    let description = (attributes["VoiceAssetDescription"] as? String)?.components(separatedBy: ":") ?? []
    let name = stringValue(asset, "name") ?? (description.first ?? "-")
    let language = (attributes["VoiceLocaleIdentifier"] as? String)
      ?? (stringValue(asset, "primaryLanguage")?.replacingOccurrences(of: "-", with: "_"))
      ?? (description.count > 1 ? description[1].replacingOccurrences(of: "-", with: "_") : "-")
    let technology = (description.count > 2 ? description[2] : stringValue(asset, "technology")) ?? "unknown"
    let quality = (description.count > 3 ? description[3] : stringValue(asset, "quality")) ?? "unknown"
    let downloadBytes = (attributes["VoiceDownloadSize"] as? NSNumber)?.intValue
      ?? (objectValue(asset, "downloadSize") as? NSNumber)?.intValue
      ?? 0
    let diskBytes = (attributes["VoiceDiskSize"] as? NSNumber)?.intValue ?? downloadBytes
    let identifier = stringValue(asset, "identifier") ?? "-"
    var info = TTSAssetInfo(
      identifier: identifier,
      name: name,
      language: language,
      technology: technology,
      quality: quality,
      gender: integerValue(asset, "gender") ?? 0,
      version: integerValue(asset, "versionNumber") ?? 0,
      downloadBytes: downloadBytes,
      diskBytes: diskBytes,
      locallyAvailable: boolValue(asset, "locallyAvailable") ?? false
    )
    if localStates[info.specifier] != nil { info.locallyAvailable = true }
    return info
  }
}

// Filesystem truth, independent of what the catalog claims.
func localAssetSpecifiers() -> [String: String] {
  var states: [String: String] = [:]
  let root = URL(fileURLWithPath: uafAssetRoot(), isDirectory: true)
  guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
    return states
  }
  for child in children where child.pathExtension == "asset" {
    let infoURL = child.appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: infoURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let properties = plist["MobileAssetProperties"] as? [String: Any],
          let specifier = properties["AssetSpecifier"] as? String,
          specifier.hasPrefix("com.apple.siri.tts.voice.") else { continue }
    states[specifier] = (properties["AssetVersion"] as? String) ?? "-"
  }
  return states
}

func validateEliminationABI() throws {
  guard dlopen(mobileAssetFrameworkPath, RTLD_LAZY | RTLD_LOCAL) != nil else {
    throw FridayError.config("MobileAsset could not be loaded")
  }
  guard let selectorClass = NSClassFromString("MAAutoAssetSelector"),
        NSClassFromString("MAAutoAsset") != nil else {
    throw FridayError.config("the MobileAsset elimination classes are absent on this macOS build")
  }
  guard let method = class_getInstanceMethod(selectorClass, NSSelectorFromString("initForAssetType:withAssetSpecifier:")) else {
    throw FridayError.config("the MobileAsset selector initializer is absent")
  }
  guard let types = method_getTypeEncoding(method), String(cString: types) == "@32@0:8@16@24" else {
    throw FridayError.config("the MobileAsset selector ABI changed on this macOS build")
  }
}

// Synchronous elimination. The returned object is advisory on this macOS: the
// client can receive an entitlement error while mobileassetd still completes the
// removal, so callers must re-check the filesystem.
func eliminateAsset(specifier: String) throws {
  try validateEliminationABI()
  guard let selectorClass = NSClassFromString("MAAutoAssetSelector"),
        let autoAssetClass = NSClassFromString("MAAutoAsset") else {
    throw FridayError.config("the MobileAsset elimination classes are absent")
  }
  // +alloc lives on the metaclass. Asking the class object itself for the
  // instance implementation hands back a forwarding stub that aborts on use.
  typealias Allocator = @convention(c) (AnyObject, Selector) -> AnyObject?
  let allocSelector = NSSelectorFromString("alloc")
  guard let allocMethod = class_getClassMethod(selectorClass, allocSelector),
        let allocated = unsafeBitCast(method_getImplementation(allocMethod), to: Allocator.self)(
          selectorClass as AnyObject, allocSelector) else {
    throw FridayError.config("the MobileAsset selector could not be allocated")
  }
  typealias Initializer = @convention(c) (AnyObject, Selector, NSString, NSString) -> AnyObject?
  let initSelector = NSSelectorFromString("initForAssetType:withAssetSpecifier:")
  guard let initMethod = class_getInstanceMethod(selectorClass, initSelector) else {
    throw FridayError.config("the MobileAsset selector initializer is absent")
  }
  let initialize = unsafeBitCast(method_getImplementation(initMethod), to: Initializer.self)
  guard let selector = initialize(allocated, initSelector, uafAssetType as NSString, specifier as NSString) else {
    throw FridayError.config("the MobileAsset selector could not be constructed")
  }
  typealias Eliminator = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
  let eliminateSelector = NSSelectorFromString("eliminateAllForSelectorSync:")
  guard let eliminateMethod = class_getClassMethod(autoAssetClass, eliminateSelector) else {
    throw FridayError.config("the MobileAsset elimination selector is absent")
  }
  _ = unsafeBitCast(method_getImplementation(eliminateMethod), to: Eliminator.self)(
    autoAssetClass as AnyObject, eliminateSelector, selector
  )
}
