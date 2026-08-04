@preconcurrency import AVFoundation
import CryptoKit
import Foundation

public struct TTSLocalOptions: Sendable {
  public let pronunciations: [String: String]
  public let cacheMaximumBytes: Int64

  public init(pronunciations: [String: String] = [:], cacheMaximumBytes: Int64 = 0) {
    self.pronunciations = pronunciations
    self.cacheMaximumBytes = max(0, cacheMaximumBytes)
  }
}

public actor TTSAudioCache {
  public static let shared = TTSAudioCache()

  private let directory: URL

  public init(directory: URL? = nil) {
    self.directory =
      directory
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".middleai/cache/tts", isDirectory: true)
  }

  public static func key(provider: String, voice: String, rate: Float, text: String) -> String {
    let input = "\(provider)\u{0}\(voice)\u{0}\(rate)\u{0}\(text)"
    return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  public func data(for key: String, maximumBytes: Int64) -> Data? {
    guard maximumBytes > 0, isSafeKey(key) else { return nil }
    let url = directory.appendingPathComponent("\(key).wav")
    guard let data = try? Data(contentsOf: url), Self.isWAV(data),
      (try? AVAudioFile(forReading: url)) != nil
    else {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    try? FileManager.default.setAttributes(
      [.modificationDate: Date()], ofItemAtPath: url.path)
    return data
  }

  public func store(_ data: Data, for key: String, maximumBytes: Int64) throws {
    guard maximumBytes > 0, Self.isWAV(data), Int64(data.count) <= maximumBytes, isSafeKey(key)
    else {
      return
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let url = directory.appendingPathComponent("\(key).wav")
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: url.path)
    try prune(to: maximumBytes)
  }

  public func clear() throws {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
  }

  public func currentSize() -> Int64 {
    entries().reduce(0) { $0 + $1.size }
  }

  private func prune(to maximumBytes: Int64) throws {
    var files = entries().sorted { $0.modified < $1.modified }
    var total = files.reduce(0) { $0 + $1.size }
    while total > maximumBytes, !files.isEmpty {
      let oldest = files.removeFirst()
      try? FileManager.default.removeItem(at: oldest.url)
      total -= oldest.size
    }
  }

  private func entries() -> [(url: URL, size: Int64, modified: Date)] {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
    else { return [] }
    return urls.compactMap { url in
      guard url.pathExtension == "wav", let values = try? url.resourceValues(forKeys: keys),
        values.isRegularFile == true
      else { return nil }
      return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
    }
  }

  private func isSafeKey(_ key: String) -> Bool {
    key.count == 64
      && key.unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "0123456789abcdef").contains($0)
      }
  }

  private static func isWAV(_ data: Data) -> Bool {
    data.count >= 12 && data.prefix(4) == Data("RIFF".utf8)
      && data.dropFirst(8).prefix(4) == Data("WAVE".utf8)
  }
}
