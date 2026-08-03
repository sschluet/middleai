import Foundation

enum TTSModelDownloadPhase: Equatable {
  case notDownloaded
  case downloading
  case installed
  case needsRepair
  case updateAvailable
  case failed
}

struct TTSModelDownloadStatus: Identifiable, Equatable {
  let id: String
  let title: String
  let detail: String
  let source: String
  let license: String
  let revision: String?
  let expectedBytes: Int64
  var downloadedBytes: Int64
  var phase: TTSModelDownloadPhase
  var validationMessage: String?
  var errorMessage: String?

  var progress: Double {
    guard expectedBytes > 0 else { return 0 }
    return min(phase == .installed ? 1 : 0.98, Double(downloadedBytes) / Double(expectedBytes))
  }

  var expectedSize: String { Self.size(expectedBytes) }
  var downloadedSize: String { Self.size(downloadedBytes) }

  private static func size(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: bytes)
  }
}

/// Durable installation receipt written only after the provider has loaded the model.
/// The model caches remain owned by Hugging Face or FluidAudio; this receipt records the
/// exact snapshot and runtime that MiddleAI has actually verified.
struct TTSModelInstallationManifest: Codable, Equatable {
  static let schemaVersion = 1

  let schema: Int
  let modelID: String
  let source: String
  let revision: String
  let license: String
  let expectedArtifacts: [String]
  let expectedBytes: Int64
  let runtime: [String: String]
  let installedAt: Date
  let lastVerifiedAt: Date
  let functionalTestPassed: Bool
}

enum TTSModelLibrary {
  private struct Definition {
    let id: String
    let title: String
    let detail: String
    let source: String
    let license: String
    let expectedBytes: Int64
    let expectedRevision: String?
    let requiredArtifacts: [String]
  }

  private struct Validation {
    let bytes: Int64
    let revision: String?
    let missingArtifacts: [String]
    let runtimeValid: Bool

    var artifactsValid: Bool { missingArtifacts.isEmpty }
  }

  private static let definitions = [
    Definition(
      id: "qwen3_tts", title: "Qwen3-TTS",
      detail: "Natürliches Deutsch · MLX · geschäftlich nutzbare Standardauswahl",
      source: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit",
      license: "Apache-2.0", expectedBytes: 2_800_000_000, expectedRevision: nil,
      requiredArtifacts: [
        "config.json", "model.safetensors", "tokenizer_config.json",
        "speech_tokenizer/config.json", "speech_tokenizer/model.safetensors",
      ]),
    Definition(
      id: "voxtral_tts", title: "Mistral Voxtral TTS",
      detail: "MLX · ausschließlich nicht-kommerzielle Nutzung",
      source: "mlx-community/Voxtral-4B-TTS-2603-mlx-4bit",
      license: "CC BY-NC 4.0", expectedBytes: 3_000_000_000, expectedRevision: nil,
      requiredArtifacts: [
        "config.json", "params.json", "model.safetensors",
        "voice_embedding/de_female.safetensors",
      ]),
    Definition(
      id: "supertonic3", title: "Supertonic 3",
      detail: "Mehrsprachiges Core-ML-Modell · fünf weibliche Stile",
      source: "FluidInference/supertonic-3-coreml",
      license: "Siehe Modellrepository", expectedBytes: 400_000_000,
      expectedRevision: "1.7.3",
      requiredArtifacts: [
        "manifest.json", "tts.json", "unicode_indexer.json", "TextEncoder.mlmodelc",
        "DurationPredictor.mlmodelc", "Vocoder.mlmodelc",
        "VectorEstimatorVariants/VectorEstimator_L512_int4.mlmodelc", "voice_styles/F1.json",
      ]),
    Definition(
      id: "pockettts", title: "PocketTTS",
      detail: "Kompatibilitätsmodell · für Deutsch nur eingeschränkt empfohlen",
      source: "FluidInference/pocket-tts-coreml",
      license: "Siehe Modellrepository", expectedBytes: 2_800_000_000,
      expectedRevision: "2.1",
      requiredArtifacts: [
        "v2.1/german_24l/manifest.json", "v2.1/german_24l/cond_prefill.mlmodelc",
        "v2.1/german_24l/flowlm_stepv2.mlmodelc",
        "v2.1/german_24l/flow_decoder_fused.mlmodelc",
        "v2.1/german_24l/mimi_decoder.mlmodelc",
        "v2.1/german_24l/constants_bin/tokenizer.model",
      ]),
  ]

  private static var receiptDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".middleai/models/tts", isDirectory: true)
  }

  static func modelID(for provider: String) -> String? {
    switch provider {
    case "adaptive": return "supertonic3"
    case "qwen3_tts", "voxtral_tts", "supertonic3", "pockettts": return provider
    default: return nil
    }
  }

  static func provider(for modelID: String) -> String? {
    definitions.contains(where: { $0.id == modelID }) ? modelID : nil
  }

  static func scan(
    activeModelID: String?, confirmed _: Set<String>, failures: [String: String]
  ) -> [TTSModelDownloadStatus] {
    let paths = modelPaths()
    return definitions.map { definition in
      let validation = validate(definition, paths: paths)
      let receipt = loadReceipt(for: definition.id)
      let isPartial = FileManager.default.fileExists(atPath: partialMarker(for: definition.id).path)
      let revisionMatches = receipt?.revision == validation.revision
      let receiptMatches =
        receipt?.schema == TTSModelInstallationManifest.schemaVersion
        && receipt?.source == definition.source
        && receipt?.expectedArtifacts == definition.requiredArtifacts
        && receipt?.functionalTestPassed == true

      let phase: TTSModelDownloadPhase
      var validationMessage: String?
      if activeModelID == definition.id {
        phase = .downloading
      } else if failures[definition.id] != nil {
        phase = .failed
      } else if validation.bytes == 0 && receipt == nil && !isPartial {
        phase = .notDownloaded
      } else if validation.artifactsValid && validation.runtimeValid && receiptMatches
        && revisionMatches && !isPartial
      {
        phase = .installed
      } else if validation.artifactsValid && validation.runtimeValid && receiptMatches
        && receipt?.revision != validation.revision
      {
        phase = .updateAvailable
        validationMessage = "Ein neuer lokaler Snapshot wurde gefunden und muss geprüft werden."
      } else {
        phase = .needsRepair
        if !validation.missingArtifacts.isEmpty {
          validationMessage =
            "Fehlend: " + validation.missingArtifacts.prefix(3).joined(separator: ", ")
        } else if !validation.runtimeValid {
          validationMessage = "Die zugehörige lokale Laufzeit fehlt oder ist nicht verifiziert."
        } else if receipt == nil {
          validationMessage = "Vorhandene Modelldaten wurden noch nicht von MiddleAI geprüft."
        } else if isPartial {
          validationMessage = "Eine frühere Installation wurde nicht vollständig abgeschlossen."
        } else {
          validationMessage = "Der Installationsbeleg passt nicht mehr zu den Modelldaten."
        }
      }

      return TTSModelDownloadStatus(
        id: definition.id, title: definition.title, detail: definition.detail,
        source: definition.source, license: definition.license,
        revision: validation.revision, expectedBytes: definition.expectedBytes,
        downloadedBytes: validation.bytes, phase: phase,
        validationMessage: validationMessage, errorMessage: failures[definition.id])
    }
  }

  static func beginInstallation(modelID: String) throws {
    try FileManager.default.createDirectory(
      at: receiptDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let marker = Data("installation-in-progress\n".utf8)
    try marker.write(to: partialMarker(for: modelID), options: .atomic)
  }

  static func recordSuccessfulInstallation(modelID: String) throws {
    guard let definition = definitions.first(where: { $0.id == modelID }) else { return }
    let validation = validate(definition, paths: modelPaths())
    guard validation.artifactsValid else {
      throw NSError(
        domain: "MiddleAI.TTSModelLibrary", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Modellartefakte fehlen: \(validation.missingArtifacts.joined(separator: ", "))"
        ])
    }
    guard validation.runtimeValid else {
      throw NSError(
        domain: "MiddleAI.TTSModelLibrary", code: 2,
        userInfo: [
          NSLocalizedDescriptionKey: "Die lokale Modelllaufzeit konnte nicht verifiziert werden."
        ])
    }
    guard let revision = validation.revision, !revision.isEmpty else {
      throw NSError(
        domain: "MiddleAI.TTSModelLibrary", code: 3,
        userInfo: [
          NSLocalizedDescriptionKey: "Die exakte Modellrevision konnte nicht bestimmt werden."
        ])
    }
    try FileManager.default.createDirectory(
      at: receiptDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let now = Date()
    let manifest = TTSModelInstallationManifest(
      schema: TTSModelInstallationManifest.schemaVersion, modelID: modelID,
      source: definition.source, revision: revision, license: definition.license,
      expectedArtifacts: definition.requiredArtifacts, expectedBytes: definition.expectedBytes,
      runtime: runtimeDescription(for: modelID), installedAt: now, lastVerifiedAt: now,
      functionalTestPassed: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(to: receiptURL(for: modelID), options: .atomic)
    try? FileManager.default.removeItem(at: partialMarker(for: modelID))
  }

  static func markInstallationFailed(modelID: String) {
    // Intentionally leave the .partial marker behind so the next scan offers repair.
    if !FileManager.default.fileExists(atPath: partialMarker(for: modelID).path) {
      try? beginInstallation(modelID: modelID)
    }
  }

  static func clearInstallationRecord(modelID: String) {
    try? FileManager.default.removeItem(at: receiptURL(for: modelID))
    try? FileManager.default.removeItem(at: partialMarker(for: modelID))
  }

  static func deletablePaths(for modelID: String) -> [URL] {
    modelPaths()[modelID] ?? []
  }

  private static func receiptURL(for modelID: String) -> URL {
    receiptDirectory.appendingPathComponent("\(modelID).json")
  }

  private static func partialMarker(for modelID: String) -> URL {
    receiptDirectory.appendingPathComponent("\(modelID).partial")
  }

  private static func loadReceipt(for modelID: String) -> TTSModelInstallationManifest? {
    guard let data = try? Data(contentsOf: receiptURL(for: modelID)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(TTSModelInstallationManifest.self, from: data)
  }

  private static func validate(_ definition: Definition, paths: [String: [URL]]) -> Validation {
    let modelURLs = paths[definition.id] ?? []
    let bytes = modelURLs.reduce(Int64(0)) { $0 + directorySize(at: $1) }
    guard let root = resolvedArtifactRoot(for: definition, modelURLs: modelURLs) else {
      return Validation(
        bytes: bytes, revision: nil, missingArtifacts: definition.requiredArtifacts,
        runtimeValid: false)
    }
    let missing = definition.requiredArtifacts.filter {
      !artifactIsPresent(at: root.appendingPathComponent($0))
    }
    let revision = resolvedRevision(for: definition, modelRoot: modelURLs.first, artifactRoot: root)
    return Validation(
      bytes: bytes, revision: revision, missingArtifacts: missing,
      runtimeValid: runtimeIsValid(for: definition.id))
  }

  private static func resolvedArtifactRoot(for definition: Definition, modelURLs: [URL]) -> URL? {
    guard let base = modelURLs.first, FileManager.default.fileExists(atPath: base.path) else {
      return nil
    }
    guard definition.id == "qwen3_tts" || definition.id == "voxtral_tts" else { return base }
    let ref = base.appendingPathComponent("refs/main")
    guard
      let revision = try? String(contentsOf: ref, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !revision.isEmpty
    else { return nil }
    return base.appendingPathComponent("snapshots/\(revision)", isDirectory: true)
  }

  private static func resolvedRevision(
    for definition: Definition, modelRoot: URL?, artifactRoot: URL
  ) -> String? {
    if definition.id == "qwen3_tts" || definition.id == "voxtral_tts" {
      guard let modelRoot else { return nil }
      return try? String(contentsOf: modelRoot.appendingPathComponent("refs/main"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if definition.id == "supertonic3",
      let data = try? Data(contentsOf: artifactRoot.appendingPathComponent("manifest.json")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = json["version"] as? String
    {
      return version
    }
    if definition.id == "pockettts",
      let data = try? Data(
        contentsOf: artifactRoot.appendingPathComponent("v2.1/german_24l/manifest.json")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let version = json["version"] as? String
    {
      return version
    }
    return definition.expectedRevision
  }

  private static func runtimeIsValid(for modelID: String) -> Bool {
    switch modelID {
    case "qwen3_tts", "voxtral_tts":
      let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".middleai/runtime/voxtral", isDirectory: true)
      let manifestURL = root.appendingPathComponent("runtime-manifest.json")
      guard
        FileManager.default.isExecutableFile(
          atPath: root.appendingPathComponent(".venv/bin/python").path),
        let data = try? Data(contentsOf: manifestURL),
        let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: String]
      else { return false }
      return manifest["schema"] == "1" && manifest["python"] == "3.12"
        && manifest["mlx-audio"] == "0.4.6"
        && manifest["mistral-common"] == "1.11.7"
    case "supertonic3", "pockettts": return true  // FluidAudio/Core ML is linked into the app.
    default: return false
    }
  }

  private static func runtimeDescription(for modelID: String) -> [String: String] {
    switch modelID {
    case "qwen3_tts", "voxtral_tts":
      let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".middleai/runtime/voxtral/runtime-manifest.json")
      if let data = try? Data(contentsOf: url),
        let values = try? JSONSerialization.jsonObject(with: data) as? [String: String]
      {
        return values
      }
      return ["status": "runtime manifest missing"]
    default: return ["engine": "FluidAudio/CoreML", "distribution": "SwiftPM"]
    }
  }

  private static func modelPaths() -> [String: [URL]] {
    let environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser
    let huggingFaceHub: URL
    if let explicit = environment["HUGGINGFACE_HUB_CACHE"], !explicit.isEmpty {
      huggingFaceHub = URL(fileURLWithPath: explicit, isDirectory: true)
    } else if let hfHome = environment["HF_HOME"], !hfHome.isEmpty {
      huggingFaceHub = URL(fileURLWithPath: hfHome, isDirectory: true)
        .appendingPathComponent("hub", isDirectory: true)
    } else {
      huggingFaceHub = home.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }
    let fluidRoot: URL
    if let explicit = environment["FLUIDAUDIO_CACHE_DIR"], !explicit.isEmpty {
      fluidRoot = URL(fileURLWithPath: explicit, isDirectory: true)
    } else {
      fluidRoot = home.appendingPathComponent(".cache/fluidaudio/Models", isDirectory: true)
    }
    return [
      "qwen3_tts": [
        huggingFaceHub.appendingPathComponent(
          "models--mlx-community--Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit", isDirectory: true)
      ],
      "voxtral_tts": [
        huggingFaceHub.appendingPathComponent(
          "models--mlx-community--Voxtral-4B-TTS-2603-mlx-4bit", isDirectory: true)
      ],
      "supertonic3": [fluidRoot.appendingPathComponent("supertonic-3", isDirectory: true)],
      "pockettts": [fluidRoot.appendingPathComponent("pocket-tts", isDirectory: true)],
    ]
  }

  private static func directorySize(at url: URL) -> Int64 {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
    if !isDirectory.boolValue {
      return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
    guard
      let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey,
        ], options: [.skipsPackageDescendants])
    else { return 0 }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      guard
        let values = try? fileURL.resourceValues(
          forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey]),
        values.isRegularFile == true, values.isSymbolicLink != true
      else { continue }
      total += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
    }
    return total
  }

  private static func artifactIsPresent(at url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return false
    }
    if isDirectory.boolValue { return directorySize(at: url) > 0 }
    return ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
  }
}
