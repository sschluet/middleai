import Foundation

public struct FormattedDictation: Equatable, Sendable {
  public let plainText: String
  public let html: String
  public let didApplyFormatting: Bool

  public init(plainText: String, html: String, didApplyFormatting: Bool) {
    self.plainText = plainText
    self.html = html
    self.didApplyFormatting = didApplyFormatting
  }
}

public enum DictationFormatter {
  public static func format(_ input: String) -> FormattedDictation {
    let original = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !original.isEmpty else {
      return FormattedDictation(plainText: "", html: "", didApplyFormatting: false)
    }

    var text = original
    var changed = false
    text = applyPairedQuotes(to: text, changed: &changed)
    text = applyInlineQuotes(to: text, changed: &changed)
    text = applyList(to: text, numbered: true, changed: &changed)
    text = applyList(to: text, numbered: false, changed: &changed)
    text = replacingCommand(
      #"(?i)\b(?:neuer\s+absatz|neuen\s+absatz|absatz\s+beginnen)\b[,.]?(?!\s*(?:ist|war|wird|soll|bedeutet|heißt)\b)\s*"#,
      in: text, with: "\n\n", changed: &changed)
    text = replacingCommand(
      #"(?i)\b(?:neue\s+zeile|neuen\s+zeile|zeilenumbruch)\b[,.]?(?!\s*(?:ist|war|wird|soll|bedeutet|heißt)\b)\s*"#,
      in: text, with: "\n", changed: &changed)
    text = normalizeWhitespace(text)

    return FormattedDictation(
      plainText: text, html: renderHTML(text), didApplyFormatting: changed && text != original)
  }

  private static func applyPairedQuotes(to input: String, changed: inout Bool) -> String {
    let patterns = [
      #"(?is)\b(?:anführungszeichen|anführungsstriche?)\s*(?:auf|anfang|öffnen)\b\s*[:,]?\s*(.+?)\s*\b(?:anführungszeichen|anführungsstriche?)\s*(?:zu|ende|schließen)\b"#,
      #"(?is)\bzitat\s+anfang\b\s*[:,]?\s*(.+?)\s*\bzitat\s+ende\b"#,
    ]
    return patterns.reduce(input) { result, pattern in
      replacingCommand(pattern, in: result, with: "„$1“", changed: &changed)
    }
  }

  private static func applyInlineQuotes(to input: String, changed: inout Bool) -> String {
    replacingCommand(
      #"(?i)\bin\s+anführungsstrichen\s*[:,]?\s*([^.!?\n]+?)(\s*[.!?]|$)"#,
      in: input, with: "„$1“$2", changed: &changed)
  }

  private static func applyList(
    to input: String, numbered: Bool, changed: inout Bool
  ) -> String {
    let startPattern = numbered
      ? #"(?i)\b(?:nummerierte\s+liste|nummerierte\s+aufzählung)\s*(?:beginnen|anfang)?\s*[:,-]?\s*"#
      : #"(?i)\b(?:(?:folgende\s+)?aufzählung|punkteliste|liste\s+mit\s+aufzählungszeichen)\s*(?:beginnen|anfang)?\s*[:,-]?\s*"#
    guard let startExpression = try? NSRegularExpression(pattern: startPattern),
      let startMatch = startExpression.firstMatch(
        in: input, range: NSRange(input.startIndex..., in: input)),
      let startRange = Range(startMatch.range, in: input)
    else { return input }

    let endPattern = #"(?i)\b(?:(?:aufzählung|liste)\s*(?:beenden|ende)|ende\s+der\s+(?:aufzählung|liste))\b"#
    let searchStart = startMatch.range.location + startMatch.range.length
    let searchRange = NSRange(location: searchStart, length: (input as NSString).length - searchStart)
    let endMatch = try? NSRegularExpression(pattern: endPattern).firstMatch(
      in: input, range: searchRange)
    let bodyEnd = endMatch?.range.location ?? (input as NSString).length
    let bodyRange = NSRange(location: searchStart, length: bodyEnd - searchStart)
    guard let swiftBodyRange = Range(bodyRange, in: input) else { return input }

    let separatorPattern = #"(?i)\s*\b(?:(?:nächster|neuer|weiterer)\s+punkt|punkt\s+(?:eins|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|\d+))\b\s*[:,-]?\s*"#
    guard let separator = try? NSRegularExpression(pattern: separatorPattern) else { return input }
    let body = String(input[swiftBodyRange])
    var itemStart = body.startIndex
    var items: [String] = []
    for match in separator.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
      guard let range = Range(match.range, in: body) else { continue }
      let candidate = cleanListItem(String(body[itemStart..<range.lowerBound]))
      if !candidate.isEmpty { items.append(candidate) }
      itemStart = range.upperBound
    }
    let finalItem = cleanListItem(String(body[itemStart...]))
    if !finalItem.isEmpty { items.append(finalItem) }
    guard items.count >= 2 else { return input }

    let prefix = String(input[..<startRange.lowerBound]).trimmingCharacters(in: .whitespaces)
    let suffixStart: String.Index
    if let endMatch, let endRange = Range(endMatch.range, in: input) {
      suffixStart = endRange.upperBound
    } else {
      suffixStart = input.endIndex
    }
    let suffix = String(input[suffixStart...]).trimmingCharacters(in: .whitespaces)
    let list = items.enumerated().map { index, item in
      numbered ? "\(index + 1). \(item)" : "• \(item)"
    }.joined(separator: "\n")
    changed = true
    return [prefix, list, suffix].filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  private static func cleanListItem(_ input: String) -> String {
    input.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
      CharacterSet(charactersIn: ",;:-")))
  }

  private static func normalizeWhitespace(_ input: String) -> String {
    var result = input
    result = replacing(#"[ \t]+\n"#, in: result, with: "\n")
    result = replacing(#"\n[ \t]+"#, in: result, with: "\n")
    result = replacing(#"\n{3,}"#, in: result, with: "\n\n")
    result = replacing(#"[ \t]{2,}"#, in: result, with: " ")
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func renderHTML(_ text: String) -> String {
    let blocks = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
    let body = blocks.map { block -> String in
      let lines = block.components(separatedBy: "\n")
      if lines.allSatisfy({ $0.hasPrefix("• ") }) {
        return "<ul>" + lines.map { "<li>\(escapeHTML(String($0.dropFirst(2))))</li>" }.joined()
          + "</ul>"
      }
      if lines.allSatisfy({ $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }) {
        return "<ol>" + lines.map { line in
          let item = line.replacingOccurrences(of: #"^\d+\. "#, with: "", options: .regularExpression)
          return "<li>\(escapeHTML(item))</li>"
        }.joined() + "</ol>"
      }
      return "<p>" + lines.map(escapeHTML).joined(separator: "<br>") + "</p>"
    }.joined()
    return "<!doctype html><html><body>\(body)</body></html>"
  }

  private static func escapeHTML(_ input: String) -> String {
    input.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  private static func replacingCommand(
    _ pattern: String, in input: String, with replacement: String, changed: inout Bool
  ) -> String {
    let result = replacing(pattern, in: input, with: replacement)
    if result != input { changed = true }
    return result
  }

  private static func replacing(_ pattern: String, in input: String, with replacement: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return input }
    return expression.stringByReplacingMatches(
      in: input, range: NSRange(input.startIndex..., in: input), withTemplate: replacement)
  }
}
