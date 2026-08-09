import AppKit
import EventKit
import Foundation
import MiddleAICore

final class MacVoiceActionExecutor: VoiceActionExecuting, @unchecked Sendable {
  private weak var state: AppState?
  private let eventStore = EKEventStore()

  init(state: AppState) { self.state = state }

  func execute(_ request: VoiceActionRequest) async throws -> VoiceActionExecutionResult {
    switch request.kind {
    case .newConversation:
      try await requireState { state in state.newConversation() }
      return VoiceActionExecutionResult(message: "Neue Unterhaltung gestartet.")
    case .switchProfile:
      guard let requestedProfile = request.profile else {
        throw VoiceActionParseError.invalidField("profile")
      }
      let displayName = try await requireState { state -> String in
        guard let profileID = state.config.profileID(matching: requestedProfile) else {
          throw VoiceActionParseError.invalidField("profile")
        }
        state.selectProfile(profileID)
        return state.config.profileDisplayName(for: profileID)
      }
      return VoiceActionExecutionResult(message: "Profil \(displayName) ist aktiv.")
    case .copyLastAnswer:
      let copied = try await requireState { state -> Bool in
        guard !state.responseText.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(state.responseText, forType: .string)
      }
      guard copied else {
        throw MiddleAIError.configuration("Es gibt noch keine Antwort zum Kopieren")
      }
      return VoiceActionExecutionResult(message: "Die letzte Antwort wurde kopiert.")
    case .summarizeSelection:
      try await requireState { state in state.previewSelectedText(action: .shorten) }
      return VoiceActionExecutionResult(
        message: "Die lokale Vorschau für den markierten Text wird geöffnet.")
    case .createReminder:
      guard let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines),
        !title.isEmpty
      else { throw VoiceActionParseError.missingField("title") }
      let granted = try await eventStore.requestFullAccessToReminders()
      guard granted else {
        throw MiddleAIError.configuration(
          "Der Zugriff auf Erinnerungen wurde in macOS nicht freigegeben")
      }
      let reminder = EKReminder(eventStore: eventStore)
      reminder.title = title
      reminder.calendar = eventStore.defaultCalendarForNewReminders()
      if let dueAt = request.dueAt {
        reminder.dueDateComponents = Calendar.current.dateComponents(
          [.year, .month, .day, .hour, .minute], from: dueAt)
      }
      try eventStore.save(reminder, commit: true)
      return VoiceActionExecutionResult(message: "Die bestätigte Erinnerung wurde angelegt.")
    }
  }

  private func requireState<T: Sendable>(
    _ operation: @escaping @MainActor (AppState) throws -> T
  ) async throws -> T {
    try await MainActor.run {
      guard let state else { throw MiddleAIError.configuration("MiddleAI ist nicht verfügbar") }
      return try operation(state)
    }
  }
}
