import Foundation

/// Deterministic, local context compaction for hosted providers. No conversation text is sent to
/// a second model merely to create the rolling summary.
public enum HostedContextWindow {
  public static let defaultTokenBudget = 24_000

  public static func prepared(
    _ messages: [Message], maximumEstimatedTokens: Int = defaultTokenBudget
  ) -> [Message] {
    let budget = max(512, maximumEstimatedTokens)
    guard estimatedTokens(messages) > budget else { return messages }

    let systemMessages = messages.filter { $0.role == .system }
    let conversation = messages.filter { $0.role != .system }
    let systemBudget = min(max(256, budget / 4), budget)
    let preparedSystems = fit(messages: systemMessages, into: systemBudget)
    let usedBySystems = estimatedTokens(preparedSystems)
    let available = max(256, budget - usedBySystems)
    let summaryBudget = min(2_000, max(128, available / 4))
    let recentBudget = max(128, available - summaryBudget)

    var recent: [Message] = []
    var used = 0
    var splitIndex = conversation.count
    for index in conversation.indices.reversed() {
      let message = conversation[index]
      let cost = estimatedTokens(message.content)
      if !recent.isEmpty, used + cost > recentBudget { break }
      let fitted =
        cost > recentBudget
        ? Message(
          id: message.id, role: message.role,
          content: truncate(message.content, estimatedTokenLimit: recentBudget),
          timestamp: message.timestamp)
        : message
      recent.insert(fitted, at: 0)
      used += estimatedTokens(fitted.content)
      splitIndex = index
      if used >= recentBudget { break }
    }

    let older = Array(conversation.prefix(splitIndex))
    var result = preparedSystems
    if !older.isEmpty {
      let summary = rollingSummary(older, estimatedTokenLimit: summaryBudget)
      if !summary.isEmpty {
        result.append(Message(role: .assistant, content: summary, timestamp: older.last!.timestamp))
      }
    }
    result.append(contentsOf: recent)
    return fitPreservingNewest(messages: result, into: budget)
  }

  public static func estimatedTokens(_ messages: [Message]) -> Int {
    messages.reduce(0) { $0 + estimatedTokens($1.content) + 6 }
  }

  public static func estimatedTokens(_ text: String) -> Int {
    max(1, (text.unicodeScalars.count + 3) / 4)
  }

  private static func rollingSummary(
    _ messages: [Message], estimatedTokenLimit: Int
  ) -> String {
    let heading = "Lokale Zusammenfassung früherer Gesprächsteile:\n"
    let maximumCharacters = max(80, estimatedTokenLimit * 4 - heading.count)
    var remaining = maximumCharacters
    var snippets: [String] = []
    for message in messages.reversed() where remaining > 0 {
      let label = message.role == .user ? "Nutzer" : "Assistent"
      let clean = message.content
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !clean.isEmpty else { continue }
      let allowance = min(320, remaining)
      let snippet = "\(label): \(String(clean.prefix(allowance)))"
      snippets.insert(snippet, at: 0)
      remaining -= snippet.count + 1
    }
    guard !snippets.isEmpty else { return "" }
    return heading + snippets.joined(separator: "\n")
  }

  private static func fit(messages: [Message], into budget: Int) -> [Message] {
    var remaining = budget
    var result: [Message] = []
    for message in messages {
      guard remaining > 0 else { break }
      let cost = estimatedTokens(message.content) + 6
      if cost <= remaining {
        result.append(message)
        remaining -= cost
      } else {
        let content = truncate(message.content, estimatedTokenLimit: max(1, remaining - 6))
        if !content.isEmpty {
          result.append(
            Message(
              id: message.id, role: message.role, content: content,
              timestamp: message.timestamp))
        }
        remaining = 0
      }
    }
    return result
  }

  private static func fitPreservingNewest(messages: [Message], into budget: Int) -> [Message] {
    let systems = fit(messages: messages.filter { $0.role == .system }, into: budget / 4)
    var remaining = max(0, budget - estimatedTokens(systems))
    var newest: [Message] = []
    for message in messages.filter({ $0.role != .system }).reversed() where remaining > 0 {
      let cost = estimatedTokens(message.content) + 6
      let fitted: Message
      if cost <= remaining {
        fitted = message
      } else {
        fitted = Message(
          id: message.id, role: message.role,
          content: truncate(message.content, estimatedTokenLimit: max(1, remaining - 6)),
          timestamp: message.timestamp)
      }
      newest.append(fitted)
      remaining -= min(remaining, estimatedTokens(fitted.content) + 6)
    }
    return systems + Array(newest.reversed())
  }

  private static func truncate(_ text: String, estimatedTokenLimit: Int) -> String {
    let characterLimit = max(16, estimatedTokenLimit * 4)
    guard text.count > characterLimit else { return text }
    let headCount = max(8, characterLimit * 3 / 4)
    let tailCount = max(8, characterLimit - headCount - 3)
    return String(text.prefix(headCount)) + " … " + String(text.suffix(tailCount))
  }
}
