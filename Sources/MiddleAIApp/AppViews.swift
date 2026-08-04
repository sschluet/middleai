import AppKit
import MiddleAICore
import SwiftUI

struct QuickInputView: View {
  @ObservedObject var state: AppState
  @FocusState private var focused: Bool
  @State private var searchText = ""

  private var filteredConversations: [Conversation] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return state.conversations }
    return state.conversations.filter {
      ($0.title + " " + $0.summary).localizedCaseInsensitiveContains(query)
    }
  }

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 10) {
          MiddleAIIconView(cornerRadius: 9).frame(width: 36, height: 36)
          VStack(alignment: .leading, spacing: 1) {
            Text("MiddleAI").font(.headline)
            Text("Lokaler Sprachassistent").font(.caption).foregroundStyle(.secondary)
          }
        }
        .padding(.horizontal, 14)

        Button {
          state.newConversation()
          focused = true
        } label: {
          Label("Neue Unterhaltung", systemImage: "square.and.pencil")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 12)

        HStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("Unterhaltungen suchen", text: $searchText)
            .textFieldStyle(.plain)
          if !searchText.isEmpty {
            Button {
              searchText = ""
            } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
          RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07))
        }
        .padding(.horizontal, 12)

        ScrollView {
          LazyVStack(spacing: 4) {
            ForEach(filteredConversations) { conversation in
              ConversationSidebarRow(
                conversation: conversation,
                selected: conversation.id == state.engine?.manager.currentConversation?.id
              ) {
                state.activateConversation(conversation)
              }
            }
          }
          .padding(.horizontal, 8)
        }
      }
      .padding(.vertical, 16)
      .frame(width: 252)
      .background(.ultraThinMaterial)

      Divider()

      VStack(spacing: 0) {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text(state.currentTitle)
              .font(.title3.weight(.semibold))
              .lineLimit(1)
            Text(state.engine?.activeProfile.capitalized ?? "Default")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            state.setPrivateSession(!state.isPrivateSession)
          } label: {
            Label(
              state.isPrivateSession ? "Privat" : "Private Sitzung",
              systemImage: state.isPrivateSession ? "lock.fill" : "lock.open")
          }
          .buttonStyle(.bordered)
          .help(
            state.isPrivateSession
              ? "Private Sitzung beenden und temporären Verlauf verwerfen"
              : "Neue Sitzung ohne lokalen SQLite-Verlauf starten")
          HStack(spacing: 6) {
            Circle()
              .fill(state.status == "Connected" ? Color.green : Color.orange)
              .frame(width: 7, height: 7)
            Text(state.status == "Connected" ? "Verbunden" : "Offline")
              .font(.caption.weight(.medium))
              .foregroundStyle(.secondary)
          }
          .padding(.horizontal, 9).padding(.vertical, 5)
          .background(Color.primary.opacity(0.045), in: Capsule())
          if state.engine?.manager.currentConversation?.openWebUIChatID != nil {
            Button {
              state.openCurrentChat()
            } label: {
              Label(state.config.assistantProviderTitle, systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.bordered)
          }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 15)

        Divider()

        ZStack {
          ScrollView {
            if state.responseText.isEmpty && !state.isWorking {
              VStack(spacing: 14) {
                MiddleAIIconView(cornerRadius: 17)
                  .frame(width: 70, height: 70)
                Text("Womit kann ich helfen?")
                  .font(.title2.weight(.semibold))
                Text(
                  "Schreibe eine Nachricht oder nutze die rechte Optionstaste für eine Sprachanfrage."
                )
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 430)
              }
              .frame(maxWidth: .infinity, minHeight: 370)
            } else if !state.responseText.isEmpty {
              Text(state.responseText)
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
                .background(
                  Color(nsColor: .controlBackgroundColor).opacity(0.76),
                  in: RoundedRectangle(cornerRadius: 19, style: .continuous)
                )
                .overlay {
                  RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
                }
                .shadow(color: .black.opacity(0.035), radius: 10, y: 4)
                .padding(24)
            }
          }

          if state.isWorking {
            VStack(spacing: 12) {
              ProgressView().controlSize(.small)
              Text("\(state.config.assistantProviderTitle) erstellt die Antwort")
                .font(.callout.weight(.medium))
              Text("Ein Druck auf die rechte Optionstaste bricht ab.")
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if !state.lastError.isEmpty {
          Label(state.lastError, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .textSelection(.enabled)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }

        HStack(alignment: .bottom, spacing: 12) {
          TextField("Nachricht an MiddleAI", text: $state.input, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($focused)
            .disabled(state.isWorking)
            .onSubmit { state.submit() }
          Button {
            state.submit()
          } label: {
            Image(systemName: "arrow.up")
              .font(.system(size: 13, weight: .bold))
              .frame(width: 26, height: 26)
          }
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.circle)
          .disabled(
            state.isWorking || state.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 17, style: .continuous)
            .strokeBorder(.quaternary, lineWidth: 0.8)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
      }
      .background(
        LinearGradient(
          colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.025)],
          startPoint: .top, endPoint: .bottom))
    }
    .frame(minWidth: 820, minHeight: 560)
    .onAppear { focused = true }
    .onReceive(NotificationCenter.default.publisher(for: .middleAIQuickInputFocus)) { _ in
      focused = true
    }
  }
}

struct ConversationSidebarRow: View {
  let conversation: Conversation
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: "bubble.left.and.text.bubble.right")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(selected ? Color.accentColor : .secondary)
          .frame(width: 18)
        VStack(alignment: .leading, spacing: 3) {
          Text(conversation.title)
            .font(.callout.weight(selected ? .semibold : .regular))
            .lineLimit(1)
          Text(conversation.lastUsedAt, style: .relative)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
      .background(
        selected ? Color.accentColor.opacity(0.12) : Color.clear,
        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}
