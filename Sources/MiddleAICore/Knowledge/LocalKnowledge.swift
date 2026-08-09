import Foundation

public struct KnowledgeSource: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable { case file, directory }

  public var id: String
  public var path: String
  public var displayName: String
  public var kind: Kind
  public var enabled: Bool
  public var createdAt: Date
  public var lastIndexedAt: Date?

  public init(
    id: String = UUID().uuidString, path: String, displayName: String, kind: Kind,
    enabled: Bool = true, createdAt: Date = Date(), lastIndexedAt: Date? = nil
  ) {
    self.id = id
    self.path = path
    self.displayName = displayName
    self.kind = kind
    self.enabled = enabled
    self.createdAt = createdAt
    self.lastIndexedAt = lastIndexedAt
  }
}

public struct KnowledgeChunk: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var sourceID: String
  public var relativePath: String
  public var title: String
  public var content: String
  public var searchTerms: String
  public var startLine: Int
  public var endLine: Int
  public var updatedAt: Date

  public init(
    id: String = UUID().uuidString, sourceID: String, relativePath: String, title: String,
    content: String, searchTerms: String, startLine: Int, endLine: Int,
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.sourceID = sourceID
    self.relativePath = relativePath
    self.title = title
    self.content = content
    self.searchTerms = searchTerms
    self.startLine = startLine
    self.endLine = endLine
    self.updatedAt = updatedAt
  }
}

public struct StoredKnowledgeChunk: Equatable, Sendable {
  public var source: KnowledgeSource
  public var chunk: KnowledgeChunk

  public init(source: KnowledgeSource, chunk: KnowledgeChunk) {
    self.source = source
    self.chunk = chunk
  }
}

public struct KnowledgeSearchHit: Equatable, Sendable, Identifiable {
  public var id: String { chunkID }
  public let chunkID: String
  public let sourceID: String
  public let sourceName: String
  public let fileURL: URL
  public let relativePath: String
  public let excerpt: String
  public let citation: String
  public let score: Double

  public init(
    chunkID: String, sourceID: String, sourceName: String, fileURL: URL,
    relativePath: String, excerpt: String, citation: String, score: Double
  ) {
    self.chunkID = chunkID
    self.sourceID = sourceID
    self.sourceName = sourceName
    self.fileURL = fileURL
    self.relativePath = relativePath
    self.excerpt = excerpt
    self.citation = citation
    self.score = score
  }
}

public struct KnowledgeIndexReport: Equatable, Sendable {
  public let sourceID: String
  public let indexedFiles: Int
  public let indexedChunks: Int
  public let skippedFiles: Int

  public init(sourceID: String, indexedFiles: Int, indexedChunks: Int, skippedFiles: Int) {
    self.sourceID = sourceID
    self.indexedFiles = indexedFiles
    self.indexedChunks = indexedChunks
    self.skippedFiles = skippedFiles
  }
}

public enum KnowledgePathPolicy {
  public static let supportedExtensions: Set<String> = [
    "txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "html", "htm",
  ]
  private static let forbiddenComponents: Set<String> = [
    ".ssh", ".gnupg", ".aws", ".azure", ".kube", "keychains", "cookies", "safari",
    "mail", "messages",
  ]
  private static let forbiddenNames: Set<String> = [
    ".env", "id_rsa", "id_ed25519", "known_hosts", "authorized_keys", "login.keychain-db",
  ]
  private static let forbiddenExtensions: Set<String> = [
    "key", "pem", "p12", "pfx", "kdbx", "sqlite", "sqlite3", "db",
  ]

  public static func validatedGrant(_ url: URL, fileManager: FileManager = .default) throws
    -> (url: URL, kind: KnowledgeSource.Kind)
  {
    let originalValues = try url.standardizedFileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
    guard originalValues.isSymbolicLink != true else {
      throw MiddleAIError.configuration(
        "Symbolische Verknüpfungen werden nicht als Wissensquelle akzeptiert")
    }
    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    let values = try resolved.resourceValues(forKeys: [
      .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey,
    ])
    guard values.isRegularFile == true || values.isDirectory == true else {
      throw MiddleAIError.configuration(
        "Nur vorhandene Dateien oder Ordner können freigegeben werden")
    }
    guard values.isSymbolicLink != true else {
      throw MiddleAIError.configuration(
        "Symbolische Verknüpfungen werden nicht als Wissensquelle akzeptiert")
    }
    try validateSafePath(resolved)
    let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
    let path = resolved.path
    guard path != "/", path != home, path != "/Users" else {
      throw MiddleAIError.configuration(
        "Bitte nur einen konkreten Unterordner oder eine Datei freigeben")
    }
    if values.isRegularFile == true {
      guard supportedExtensions.contains(resolved.pathExtension.lowercased()) else {
        throw MiddleAIError.configuration("Dieser Dateityp kann lokal noch nicht indiziert werden")
      }
      return (resolved, .file)
    }
    return (resolved, .directory)
  }

  public static func isSafeIndexableFile(_ url: URL, inside root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
    guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else { return false }
    guard supportedExtensions.contains(resolved.pathExtension.lowercased()) else { return false }
    do {
      let values = try resolved.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        values.isHidden != true, (values.fileSize ?? 0) <= 8_000_000
      else { return false }
      try validateSafePath(resolved)
      return true
    } catch { return false }
  }

  private static func validateSafePath(_ url: URL) throws {
    let components = url.pathComponents.map { $0.lowercased() }
    if components.contains(where: { $0.hasPrefix(".") && $0 != "." && $0 != ".." })
      || components.contains(where: forbiddenComponents.contains)
      || forbiddenNames.contains(url.lastPathComponent.lowercased())
      || forbiddenExtensions.contains(url.pathExtension.lowercased())
    {
      throw MiddleAIError.configuration(
        "Dieser sensible oder versteckte Pfad darf nicht indiziert werden")
    }
  }
}

/// Local, explicitly scoped knowledge base. No network request is made by this type.
public actor LocalKnowledgeBase {
  private let store: any LocalContextStoreProtocol
  private let fileManager: FileManager
  private let maximumFilesPerSource: Int
  private let maximumChunkCharacters: Int

  public init(
    store: any LocalContextStoreProtocol, fileManager: FileManager = .default,
    maximumFilesPerSource: Int = 2_000, maximumChunkCharacters: Int = 1_600
  ) {
    self.store = store
    self.fileManager = fileManager
    self.maximumFilesPerSource = max(1, maximumFilesPerSource)
    self.maximumChunkCharacters = max(400, maximumChunkCharacters)
  }

  @discardableResult public func grant(url: URL, displayName: String? = nil) throws
    -> KnowledgeSource
  {
    let validated = try KnowledgePathPolicy.validatedGrant(url, fileManager: fileManager)
    if let existing = try store.knowledgeSources().first(where: { $0.path == validated.url.path }) {
      return existing
    }
    let source = KnowledgeSource(
      path: validated.url.path,
      displayName: displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? validated.url.lastPathComponent,
      kind: validated.kind)
    try store.saveKnowledgeSource(source)
    return source
  }

  public func sources() throws -> [KnowledgeSource] { try store.knowledgeSources() }

  public func setEnabled(sourceID: String, enabled: Bool) throws {
    guard var source = try store.knowledgeSource(id: sourceID) else {
      throw MiddleAIError.storage("Die Wissensquelle wurde nicht gefunden")
    }
    source.enabled = enabled
    try store.saveKnowledgeSource(source)
  }

  public func revoke(sourceID: String) throws {
    try store.deleteKnowledgeSource(id: sourceID)
  }

  @discardableResult public func index(sourceID: String, now: Date = Date()) throws
    -> KnowledgeIndexReport
  {
    guard let source = try store.knowledgeSource(id: sourceID) else {
      throw MiddleAIError.storage("Die Wissensquelle wurde nicht gefunden")
    }
    let validated = try KnowledgePathPolicy.validatedGrant(
      URL(fileURLWithPath: source.path), fileManager: fileManager)
    let files = try indexableFiles(at: validated.url, kind: validated.kind)
    var chunks: [KnowledgeChunk] = []
    var indexedFiles = 0
    var skippedFiles = 0
    for file in files.prefix(maximumFilesPerSource) {
      do {
        let content = try Self.loadText(from: file)
        let relativePath = Self.relativePath(file, root: validated.url, kind: validated.kind)
        let fileChunks = Self.chunks(
          content, maximumCharacters: maximumChunkCharacters
        ).map { segment in
          KnowledgeChunk(
            sourceID: source.id, relativePath: relativePath,
            title: file.deletingPathExtension().lastPathComponent,
            content: segment.text,
            searchTerms: Self.searchTerms(segment.text + " " + relativePath),
            startLine: segment.startLine, endLine: segment.endLine, updatedAt: now)
        }
        guard !fileChunks.isEmpty else {
          skippedFiles += 1
          continue
        }
        chunks.append(contentsOf: fileChunks)
        indexedFiles += 1
      } catch {
        skippedFiles += 1
      }
    }
    if files.count > maximumFilesPerSource { skippedFiles += files.count - maximumFilesPerSource }
    try store.replaceKnowledgeChunks(sourceID: source.id, chunks: chunks, indexedAt: now)
    return KnowledgeIndexReport(
      sourceID: source.id, indexedFiles: indexedFiles, indexedChunks: chunks.count,
      skippedFiles: skippedFiles)
  }

  public func search(_ query: String, limit: Int = 8) throws -> [KnowledgeSearchHit] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    let tokens = TextSimilarity.tokens(query)
    guard !tokens.isEmpty else { return [] }
    let candidates = try store.knowledgeCandidates(tokens: tokens, limit: max(80, limit * 20))
    var hits: [KnowledgeSearchHit] = []
    hits.reserveCapacity(candidates.count)
    for stored in candidates {
      let score = TextSimilarity.cosine(query, stored.chunk.title + " " + stored.chunk.content)
      let root = URL(fileURLWithPath: stored.source.path)
      let fileURL: URL
      if stored.source.kind == .file {
        fileURL = root
      } else {
        fileURL = root.appendingPathComponent(stored.chunk.relativePath)
      }
      let location: String
      if stored.chunk.startLine == stored.chunk.endLine {
        location = "Zeile \(stored.chunk.startLine)"
      } else {
        location = "Zeilen \(stored.chunk.startLine)–\(stored.chunk.endLine)"
      }
      let citation = "\(stored.source.displayName) · \(stored.chunk.relativePath) · \(location)"
      hits.append(
        KnowledgeSearchHit(
          chunkID: stored.chunk.id, sourceID: stored.source.id,
          sourceName: stored.source.displayName, fileURL: fileURL,
          relativePath: stored.chunk.relativePath, excerpt: stored.chunk.content,
          citation: citation, score: score))
    }
    let ranked = hits.filter { $0.score > 0 }.sorted { lhs, rhs in
      lhs.score == rhs.score ? lhs.citation < rhs.citation : lhs.score > rhs.score
    }
    return Array(ranked.prefix(max(1, min(limit, 30))))
  }

  public func context(for query: String, maximumCharacters: Int = 8_000) throws -> String {
    let hits = try search(query, limit: 12)
    var result = ""
    for (index, hit) in hits.enumerated() {
      let block = "[Quelle \(index + 1): \(hit.citation)]\n\(hit.excerpt)\n\n"
      guard result.count + block.count <= max(0, maximumCharacters) else { break }
      result += block
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func indexableFiles(at root: URL, kind: KnowledgeSource.Kind) throws -> [URL] {
    if kind == .file {
      return KnowledgePathPolicy.isSafeIndexableFile(root, inside: root) ? [root] : []
    }
    guard
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [
          .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey,
        ], options: [.skipsHiddenFiles, .skipsPackageDescendants],
        errorHandler: { _, _ in true })
    else { return [] }
    var files: [URL] = []
    for case let file as URL in enumerator {
      if KnowledgePathPolicy.isSafeIndexableFile(file, inside: root) { files.append(file) }
      if files.count >= maximumFilesPerSource * 2 { break }
    }
    return files.sorted { $0.path < $1.path }
  }

  private static func loadText(from url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count <= 8_000_000 else {
      throw MiddleAIError.configuration("Die Datei ist zu groß")
    }
    let decoded =
      String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .isoLatin1)
    guard var text = decoded else {
      throw MiddleAIError.invalidResponse("Die Textkodierung wird nicht unterstützt")
    }
    if ["html", "htm"].contains(url.pathExtension.lowercased()) {
      text = text.replacingOccurrences(
        of: #"<script[\s\S]*?</script>|<style[\s\S]*?</style>"#, with: " ",
        options: [.regularExpression, .caseInsensitive])
      text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }
    return text.replacingOccurrences(of: "\u{0000}", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func relativePath(
    _ file: URL, root: URL, kind: KnowledgeSource.Kind
  ) -> String {
    guard kind == .directory else { return file.lastPathComponent }
    let prefix = root.standardizedFileURL.path + "/"
    let path = file.standardizedFileURL.path
    return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : file.lastPathComponent
  }

  private struct Segment {
    let text: String
    let startLine: Int
    let endLine: Int
  }

  private static func chunks(_ text: String, maximumCharacters: Int) -> [Segment] {
    let lines = text.components(separatedBy: .newlines)
    var result: [Segment] = []
    var current: [String] = []
    var currentCount = 0
    var startLine = 1
    func flush(endLine: Int) {
      let content = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      if !content.isEmpty {
        result.append(Segment(text: content, startLine: startLine, endLine: endLine))
      }
      current.removeAll(keepingCapacity: true)
      currentCount = 0
    }
    for (offset, line) in lines.enumerated() {
      let lineNumber = offset + 1
      if current.isEmpty { startLine = lineNumber }
      if currentCount + line.count + 1 > maximumCharacters, !current.isEmpty {
        flush(endLine: max(startLine, lineNumber - 1))
        startLine = lineNumber
      }
      if line.count <= maximumCharacters {
        current.append(line)
        currentCount += line.count + 1
      } else {
        for slice in line.chunks(ofMaximumLength: maximumCharacters) {
          if !current.isEmpty { flush(endLine: lineNumber) }
          current = [slice]
          currentCount = slice.count
          flush(endLine: lineNumber)
        }
      }
    }
    if !current.isEmpty { flush(endLine: max(startLine, lines.count)) }
    return result
  }

  private static func searchTerms(_ text: String) -> String {
    " " + Array(Set(TextSimilarity.tokens(text))).sorted().joined(separator: " ") + " "
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }

  fileprivate func chunks(ofMaximumLength length: Int) -> [String] {
    guard count > length else { return [self] }
    var result: [String] = []
    var start = startIndex
    while start < endIndex {
      let end = index(start, offsetBy: length, limitedBy: endIndex) ?? endIndex
      result.append(String(self[start..<end]))
      start = end
    }
    return result
  }
}
