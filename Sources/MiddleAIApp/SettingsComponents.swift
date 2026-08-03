import AppKit
import MiddleAICore
import SwiftUI

struct ProviderSelectionCard: View {
  let title: String
  let subtitle: String
  let symbol: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: symbol)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(selected ? Color.white : Color.accentColor)
          .frame(width: 31, height: 31)
          .background(
            selected ? Color.white.opacity(0.18) : Color.accentColor.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .lineLimit(1)
          Text(subtitle)
            .font(.caption2)
            .foregroundStyle(selected ? Color.white.opacity(0.78) : Color.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(selected ? Color.white : Color.secondary.opacity(0.7))
      }
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
      .background(
        selected ? Color.accentColor : Color.primary.opacity(0.035),
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(
            selected ? Color.accentColor : Color.primary.opacity(0.075), lineWidth: 0.8)
      }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct IntelligenceStep: View {
  let number: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Text(number)
        .font(.caption.weight(.bold))
        .foregroundStyle(Color.accentColor)
        .frame(width: 25, height: 25)
        .background(Color.accentColor.opacity(0.11), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

struct FormattingApplicationOption: Identifiable {
  var id: String { bundleIdentifier.lowercased() }
  let bundleIdentifier: String
  let name: String
  let symbol: String
  let icon: NSImage?
  let isBuiltIn: Bool
}

struct FormattingApplicationRow: View {
  let application: FormattingApplicationOption
  let enabled: Bool
  let onToggle: (Bool) -> Void
  let onRemove: (() -> Void)?

  var body: some View {
    HStack(spacing: 10) {
      Group {
        if let icon = application.icon {
          Image(nsImage: icon).resizable().interpolation(.high)
        } else {
          Image(systemName: application.symbol)
            .resizable().scaledToFit().padding(5)
            .foregroundStyle(Color.accentColor)
        }
      }
      .frame(width: 28, height: 28)
      .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(application.name).font(.callout.weight(.medium))
        Text(application.bundleIdentifier)
          .font(.caption2.monospaced()).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 0)
      if let onRemove {
        Label("Aktiv", systemImage: "checkmark.circle.fill")
          .font(.caption.weight(.medium)).foregroundStyle(.green)
        Button(role: .destructive, action: onRemove) {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Aus der Formatierungsliste entfernen")
      } else {
        Toggle("", isOn: Binding(get: { enabled }, set: { value in onToggle(value) }))
          .labelsHidden()
          .toggleStyle(.switch)
      }
    }
    .padding(.horizontal, 11).padding(.vertical, 9)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
  }
}

struct SettingsCard<Content: View>: View {
  let title: String
  let subtitle: String
  let symbol: String
  @ViewBuilder let content: Content

  init(
    title: String, subtitle: String, symbol: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.symbol = symbol
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack(alignment: .top, spacing: 11) {
        Image(systemName: symbol)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.accentColor)
          .frame(width: 30, height: 30)
          .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.headline)
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
      }
      Divider()
      VStack(alignment: .leading, spacing: 13) { content }
    }
    .padding(19)
    .background(
      Color(nsColor: .controlBackgroundColor).opacity(0.72),
      in: RoundedRectangle(cornerRadius: 18, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.075), lineWidth: 0.8)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .shadow(color: .black.opacity(0.035), radius: 8, y: 3)
  }
}

struct TTSModelStatusRow: View {
  let model: TTSModelDownloadStatus
  let selected: Bool
  let onRepair: () -> Void
  let onDelete: () -> Void

  private var statusColor: Color {
    switch model.phase {
    case .installed: return .green
    case .downloading: return .accentColor
    case .failed: return .red
    case .needsRepair: return .orange
    case .updateAvailable: return .blue
    case .notDownloaded: return .secondary
    }
  }

  private var statusTitle: String {
    switch model.phase {
    case .installed: return "Installiert · \(model.downloadedSize)"
    case .downloading: return "Wird geladen · \(model.downloadedSize) von ca. \(model.expectedSize)"
    case .failed: return "Download nicht abgeschlossen"
    case .needsRepair: return "Prüfung oder Reparatur erforderlich"
    case .updateAvailable: return "Neue lokale Revision verfügbar"
    case .notDownloaded:
      return model.downloadedBytes > 0
        ? "Teilweise geladen · \(model.downloadedSize) von ca. \(model.expectedSize)"
        : "Nicht geladen · ca. \(model.expectedSize)"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 11) {
        Image(systemName: model.phase == .installed ? "checkmark.circle.fill" : "arrow.down.circle")
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(statusColor)
          .frame(width: 22)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Text(model.title).font(.callout.weight(.semibold))
            if selected {
              Text("Ausgewählt")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.11), in: Capsule())
            }
          }
          Text(model.detail).font(.caption).foregroundStyle(.secondary)
          Text(statusTitle).font(.caption.weight(.medium)).foregroundStyle(statusColor)
          if let revision = model.revision {
            Text("Revision \(String(revision.prefix(12))) · \(model.license)")
              .font(.caption2).foregroundStyle(.secondary)
          }
          if let validation = model.validationMessage {
            Text(validation).font(.caption2).foregroundStyle(statusColor).lineLimit(2)
          }
        }
        Spacer(minLength: 0)
        if model.phase == .needsRepair || model.phase == .updateAvailable || model.phase == .failed
        {
          Button(action: onRepair) {
            Image(
              systemName: model.phase == .updateAvailable
                ? "arrow.down.circle" : "wrench.and.screwdriver")
          }
          .buttonStyle(.borderless)
          .help(
            model.phase == .updateAvailable
              ? "Neueste Revision laden" : "Modelldaten laden und prüfen"
          )
          .accessibilityLabel("\(model.title) reparieren oder aktualisieren")
        }
        if model.downloadedBytes > 0 && model.phase != .downloading {
          Button(action: onDelete) {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .help("Modelldaten in den Papierkorb verschieben")
          .accessibilityLabel("\(model.title) löschen")
        }
      }
      if model.phase == .downloading
        || (model.phase == .notDownloaded && model.downloadedBytes > 0)
      {
        ProgressView(value: model.progress)
          .tint(model.phase == .downloading ? Color.accentColor : .secondary)
      }
      if let error = model.errorMessage, model.phase == .failed {
        Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
      }
    }
    .padding(12)
    .background(
      selected ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.025),
      in: RoundedRectangle(cornerRadius: 13, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .strokeBorder(selected ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.055))
    }
  }
}

struct RequirementRow: View {
  let symbol: String
  let title: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 20)
      Text(title).font(.callout.weight(.medium)).frame(width: 126, alignment: .leading)
      Text(value).font(.callout).foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
  }
}

struct HelpStep: View {
  let number: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Text(number)
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .frame(width: 24, height: 24)
        .background(Color.accentColor, in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.semibold))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

struct SettingsField: View {
  let title: String
  let prompt: String
  @Binding var text: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 18) {
      Text(title).frame(width: 112, alignment: .leading).foregroundStyle(.secondary)
      TextField(prompt, text: $text).textFieldStyle(.roundedBorder)
    }
  }
}

struct VoiceSelectionCard: View {
  let voice: TTSVoiceDescriptor
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: voice.isFemale ? "person.wave.2" : "person.wave.2.fill")
          .foregroundStyle(selected ? Color.accentColor : .secondary)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 7) {
            Text(voice.name).font(.callout.weight(.semibold))
            if voice.isRecommended {
              Text("Empfohlen")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.10), in: Capsule())
            }
          }
          Text(voice.description).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.45))
      }
      .padding(11)
      .contentShape(Rectangle())
      .background(
        selected
          ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.55),
        in: RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
  }
}

struct ShortcutRow: View {
  let key: String
  let title: String
  let detail: String

  var body: some View {
    HStack(spacing: 14) {
      Text(key)
        .font(.system(.callout, design: .rounded).weight(.semibold))
        .frame(width: 72)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
    }
  }
}

struct ActivationKeyPickerRow: View {
  let title: String
  let detail: String
  let selection: ActivationKeyChoice
  let onChange: (ActivationKeyChoice) -> Void

  var body: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Picker(
        title,
        selection: Binding(get: { selection }, set: { value in onChange(value) })
      ) {
        ForEach(ActivationKeyChoice.allCases) { key in
          Text(key.label).tag(key)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 190)
    }
  }
}
