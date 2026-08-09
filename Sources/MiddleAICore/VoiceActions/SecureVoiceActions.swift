import Foundation

/// The complete set of actions which spoken input may request. Keeping this list closed is
/// intentional: model output is never interpreted as code, a URL, or a shell command.
public enum VoiceActionKind: String, Codable, CaseIterable, Sendable {
  case newConversation = "new_conversation"
  case switchProfile = "switch_profile"
  case copyLastAnswer = "copy_last_answer"
  case summarizeSelection = "summarize_selection"
  case createReminder = "create_reminder"
}

public struct VoiceActionRequest: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var kind: VoiceActionKind
  public var profile: String?
  public var title: String?
  public var dueAt: Date?
  public var createdAt: Date

  public init(
    id: UUID = UUID(), kind: VoiceActionKind, profile: String? = nil, title: String? = nil,
    dueAt: Date? = nil, createdAt: Date = Date()
  ) {
    self.id = id
    self.kind = kind
    self.profile = profile
    self.title = title
    self.dueAt = dueAt
    self.createdAt = createdAt
  }
}

public enum VoiceActionParseError: LocalizedError, Equatable {
  case notAnAction
  case malformedPayload
  case unsupportedAction(String)
  case unexpectedField(String)
  case missingField(String)
  case invalidField(String)

  public var errorDescription: String? {
    switch self {
    case .notAnAction: return "Die Spracheingabe enthält keine bekannte lokale Aktion."
    case .malformedPayload: return "Die strukturierte Aktion ist kein gültiges JSON-Objekt."
    case .unsupportedAction(let action): return "Die Aktion „\(action)“ ist nicht freigegeben."
    case .unexpectedField(let field): return "Das Aktionsfeld „\(field)“ ist nicht erlaubt."
    case .missingField(let field): return "Der Aktion fehlt das Feld „\(field)“."
    case .invalidField(let field): return "Das Aktionsfeld „\(field)“ ist ungültig."
    }
  }
}

/// Parses deterministic phrases and constrained local-model JSON. The JSON parser validates
/// every object key, so extra model-generated parameters cannot silently reach an executor.
public struct StructuredVoiceActionParser: Sendable {
  private static let topLevelFields: Set<String> = ["action", "parameters"]

  public init() {}

  public func parseTranscript(_ transcript: String, now: Date = Date()) throws -> VoiceActionRequest
  {
    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw VoiceActionParseError.notAnAction }
    let normalized = trimmed.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE")
    ).lowercased().trimmingCharacters(in: .punctuationCharacters)

    switch normalized {
    case "neue unterhaltung", "neues gesprach", "neuer chat", "new conversation":
      return VoiceActionRequest(kind: .newConversation, createdAt: now)
    case "letzte antwort kopieren", "kopiere die letzte antwort", "copy last answer":
      return VoiceActionRequest(kind: .copyLastAnswer, createdAt: now)
    case "auswahl zusammenfassen", "markierten text zusammenfassen", "summarize selection":
      return VoiceActionRequest(kind: .summarizeSelection, createdAt: now)
    default:
      for prefix in ["wechsle zum profil ", "profil ", "switch profile "]
      where normalized.hasPrefix(prefix) {
        let value = String(normalized.dropFirst(prefix.count))
        guard Self.isSafeIdentifier(value) else {
          throw VoiceActionParseError.invalidField("profile")
        }
        return VoiceActionRequest(kind: .switchProfile, profile: value, createdAt: now)
      }
      for prefix in ["erinnere mich an ", "erstelle eine erinnerung ", "remind me to "]
      where normalized.hasPrefix(prefix) {
        let title = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(
          in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 500 else {
          throw VoiceActionParseError.invalidField("title")
        }
        return VoiceActionRequest(kind: .createReminder, title: title, createdAt: now)
      }
      throw VoiceActionParseError.notAnAction
    }
  }

  public func parseModelJSON(_ data: Data, now: Date = Date()) throws -> VoiceActionRequest {
    let root: [String: Any]
    do {
      guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw VoiceActionParseError.malformedPayload
      }
      root = decoded
    } catch let error as VoiceActionParseError {
      throw error
    } catch {
      throw VoiceActionParseError.malformedPayload
    }
    try Self.rejectUnexpectedFields(in: root, allowed: Self.topLevelFields)
    guard let actionName = root["action"] as? String else {
      throw VoiceActionParseError.missingField("action")
    }
    guard let kind = VoiceActionKind(rawValue: actionName) else {
      throw VoiceActionParseError.unsupportedAction(actionName)
    }
    let parameters: [String: Any]
    if let raw = root["parameters"] {
      guard let object = raw as? [String: Any] else {
        throw VoiceActionParseError.invalidField("parameters")
      }
      parameters = object
    } else {
      parameters = [:]
    }

    switch kind {
    case .newConversation, .copyLastAnswer, .summarizeSelection:
      try Self.rejectUnexpectedFields(in: parameters, allowed: [])
      return VoiceActionRequest(kind: kind, createdAt: now)
    case .switchProfile:
      try Self.rejectUnexpectedFields(in: parameters, allowed: ["profile"])
      guard let profile = parameters["profile"] as? String, Self.isSafeIdentifier(profile) else {
        throw VoiceActionParseError.missingField("profile")
      }
      return VoiceActionRequest(kind: kind, profile: profile, createdAt: now)
    case .createReminder:
      try Self.rejectUnexpectedFields(in: parameters, allowed: ["title", "due_at"])
      guard let title = parameters["title"] as? String,
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 500
      else { throw VoiceActionParseError.missingField("title") }
      var dueAt: Date?
      if let dueString = parameters["due_at"] as? String {
        dueAt = ISO8601DateFormatter().date(from: dueString)
        guard dueAt != nil else { throw VoiceActionParseError.invalidField("due_at") }
      } else if parameters["due_at"] != nil {
        throw VoiceActionParseError.invalidField("due_at")
      }
      return VoiceActionRequest(
        kind: kind, title: title.trimmingCharacters(in: .whitespacesAndNewlines), dueAt: dueAt,
        createdAt: now)
    }
  }

  private static func rejectUnexpectedFields(in object: [String: Any], allowed: Set<String>) throws
  {
    if let unexpected = Set(object.keys).subtracting(allowed).sorted().first {
      throw VoiceActionParseError.unexpectedField(unexpected)
    }
  }

  private static func isSafeIdentifier(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 60 else { return false }
    return !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

public struct VoiceActionPolicy: Equatable, Sendable {
  public var allowed: Set<VoiceActionKind>
  public var requiresConfirmation: Set<VoiceActionKind>

  public init(
    allowed: Set<VoiceActionKind> = Set(VoiceActionKind.allCases),
    requiresConfirmation: Set<VoiceActionKind> = [.createReminder]
  ) {
    self.allowed = allowed
    self.requiresConfirmation = requiresConfirmation
  }
}

public enum VoiceActionAuthorization: Equatable, Sendable {
  case approved
  case confirmationRequired(token: UUID, expiresAt: Date)
  case rejected
}

/// Issues short-lived, single-use confirmations for side effects. Executors should only receive
/// a request after `authorize` has returned true.
public actor VoiceActionAuthorizationGate {
  private struct Pending: Sendable {
    let requestID: UUID
    let expiresAt: Date
  }

  private let policy: VoiceActionPolicy
  private let confirmationLifetime: TimeInterval
  private var pending: [UUID: Pending] = [:]

  public init(
    policy: VoiceActionPolicy = VoiceActionPolicy(), confirmationLifetime: TimeInterval = 30
  ) {
    self.policy = policy
    self.confirmationLifetime = max(1, confirmationLifetime)
  }

  public func evaluate(_ request: VoiceActionRequest, now: Date = Date())
    -> VoiceActionAuthorization
  {
    pending = pending.filter { $0.value.expiresAt > now }
    guard policy.allowed.contains(request.kind) else { return .rejected }
    guard policy.requiresConfirmation.contains(request.kind) else { return .approved }
    let token = UUID()
    let expiry = now.addingTimeInterval(confirmationLifetime)
    pending[token] = Pending(requestID: request.id, expiresAt: expiry)
    return .confirmationRequired(token: token, expiresAt: expiry)
  }

  public func authorize(_ request: VoiceActionRequest, token: UUID, now: Date = Date()) -> Bool {
    guard let authorization = pending.removeValue(forKey: token),
      authorization.requestID == request.id, authorization.expiresAt > now,
      policy.allowed.contains(request.kind)
    else { return false }
    return true
  }

  public func cancel(token: UUID) { pending.removeValue(forKey: token) }
}

public struct VoiceActionExecutionResult: Equatable, Sendable {
  public var message: String

  public init(message: String) { self.message = message }
}

public protocol VoiceActionExecuting: Sendable {
  func execute(_ request: VoiceActionRequest) async throws -> VoiceActionExecutionResult
}

public enum VoiceActionDispatchOutcome: Equatable, Sendable {
  case executed(VoiceActionExecutionResult)
  case confirmationRequired(request: VoiceActionRequest, token: UUID, expiresAt: Date)
  case rejected
}

/// The only component that should call a platform executor. Requests that need confirmation are
/// retained as typed values and can only be executed with their bound, single-use token.
public actor SecureVoiceActionDispatcher {
  private let gate: VoiceActionAuthorizationGate
  private let executor: any VoiceActionExecuting

  public init(
    executor: any VoiceActionExecuting, policy: VoiceActionPolicy = VoiceActionPolicy(),
    confirmationLifetime: TimeInterval = 30
  ) {
    self.executor = executor
    gate = VoiceActionAuthorizationGate(
      policy: policy, confirmationLifetime: confirmationLifetime)
  }

  public func dispatch(_ request: VoiceActionRequest, now: Date = Date()) async throws
    -> VoiceActionDispatchOutcome
  {
    switch await gate.evaluate(request, now: now) {
    case .approved:
      return .executed(try await executor.execute(request))
    case .confirmationRequired(let token, let expiresAt):
      return .confirmationRequired(request: request, token: token, expiresAt: expiresAt)
    case .rejected:
      return .rejected
    }
  }

  public func confirm(
    request: VoiceActionRequest, token: UUID, now: Date = Date()
  ) async throws -> VoiceActionDispatchOutcome {
    guard await gate.authorize(request, token: token, now: now) else { return .rejected }
    return .executed(try await executor.execute(request))
  }

  public func cancel(token: UUID) async { await gate.cancel(token: token) }
}
