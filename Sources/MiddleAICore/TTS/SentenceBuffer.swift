import Foundation

public struct SentenceBuffer: Sendable {
  private var buffer = ""
  public init() {}
  public mutating func append(_ token: String) -> [String] {
    buffer += token
    var complete: [String] = []
    while let boundary = findBoundary(in: buffer) {
      let sentence = String(buffer[...boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
      buffer = String(buffer[buffer.index(after: boundary)...])
      if !sentence.isEmpty { complete.append(sentence) }
    }
    return complete
  }
  public mutating func flush() -> String? {
    let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    buffer = ""
    return value.isEmpty ? nil : value
  }
  private func findBoundary(in text: String) -> String.Index? {
    for index in text.indices where ".!?\n".contains(text[index]) {
      let next = text.index(after: index)
      if next == text.endIndex || text[next].isWhitespace { return index }
    }
    return nil
  }
}
