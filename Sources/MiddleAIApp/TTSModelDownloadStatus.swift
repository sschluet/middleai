import Foundation

enum TTSModelDownloadPhase: Equatable {
  case notDownloaded
  case downloading
  case installed
  case failed
}

struct TTSModelDownloadStatus: Identifiable, Equatable {
  let id: String
  let title: String
  let detail: String
  let expectedBytes: Int64
  var downloadedBytes: Int64
  var phase: TTSModelDownloadPhase
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

enum TTSModelLibrary {
  private struct Definition {
    let id: String
    let title: String
    let detail: String
    let expectedBytes: Int64
  }

  private static let definitions = [
    Definition(
      id: "qwen3_tts", title: "Qwen3-TTS",
      detail: "Natürliches Deutsch · MLX · geschäftlich nutzbare Standardauswahl",
      expectedBytes: 2_800_000_000),
    Definition(
      id: "voxtral_tts", title: "Mistral Voxtral TTS",
      detail: "MLX · nur nicht-kommerzielle Nutzung gemäß CC BY-NC 4.0",
      expectedBytes: 3_000_000_000),
    Definition(
      id: "supertonic3", title: "Supertonic 3",
      detail: "Mehrsprachiges Core-ML-Modell · fünf weibliche Stile",
      expectedBytes: 400_000_000),
    Definition(
      id: "pockettts", title: "PocketTTS",
      detail: "Kompatibilitätsmodell · für Deutsch nur eingeschränkt empfohlen",
      expectedBytes: 2_800_000_000),
  ]

  static func modelID(for provider: String) -> String? {
    switch provider {
    case "adaptive": return "supertonic3"
    case "qwen3_tts", "voxtral_tts", "supertonic3", "pockettts": return provider
    default: return nil
    }
  }

  static func scan(
    activeModelID: String?, confirmed: Set<String>, failures: [String: String]
  ) -> [TTSModelDownloadStatus] {
    let paths = modelPaths()
    return definitions.map { definition in
      let bytes = (paths[definition.id] ?? []).reduce(Int64(0)) { result, url in
        result + directorySize(at: url)
      }
      let ready = confirmed.contains(definition.id) || isReady(definition.id, bytes: bytes, paths: paths)
      let phase: TTSModelDownloadPhase
      if ready {
        phase = .installed
      } else if activeModelID == definition.id {
        phase = .downloading
      } else if failures[definition.id] != nil {
        phase = .failed
      } else {
        phase = .notDownloaded
      }
      return TTSModelDownloadStatus(
        id: definition.id, title: definition.title, detail: definition.detail,
        expectedBytes: definition.expectedBytes, downloadedBytes: bytes,
        phase: phase, errorMessage: failures[definition.id])
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
    let runtime = home.appendingPathComponent(".middleai/runtime", isDirectory: true)
    return [
      "qwen3_tts": [
        huggingFaceHub.appendingPathComponent(
          "models--mlx-community--Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit", isDirectory: true),
        runtime,
      ],
      "voxtral_tts": [
        huggingFaceHub.appendingPathComponent(
          "models--mlx-community--Voxtral-4B-TTS-2603-mlx-4bit", isDirectory: true),
        runtime,
      ],
      "supertonic3": [fluidRoot.appendingPathComponent("supertonic-3", isDirectory: true)],
      "pockettts": [fluidRoot.appendingPathComponent("pocket-tts", isDirectory: true)],
    ]
  }

  private static func isReady(_ id: String, bytes: Int64, paths: [String: [URL]]) -> Bool {
    switch id {
    case "qwen3_tts":
      return bytes > 2_000_000_000 && managedPythonExists()
    case "voxtral_tts":
      return bytes > 2_300_000_000 && managedPythonExists()
    case "supertonic3": return bytes > 120_000_000
    case "pockettts": return bytes > 1_000_000_000
    default: return false
    }
  }

  private static func managedPythonExists() -> Bool {
    let python = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".middleai/runtime/voxtral/.venv/bin/python")
    return FileManager.default.isExecutableFile(atPath: python.path)
  }

  private static func directorySize(at url: URL) -> Int64 {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
    if !isDirectory.boolValue {
      return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
    guard let enumerator = fileManager.enumerator(
      at: url,
      includingPropertiesForKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey,
      ],
      options: [.skipsPackageDescendants])
    else { return 0 }
    var total: Int64 = 0
    for case let fileURL as URL in enumerator {
      guard let values = try? fileURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey]),
        values.isRegularFile == true, values.isSymbolicLink != true
      else { continue }
      total += Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
    }
    return total
  }
}
