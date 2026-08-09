import AppKit
import ServiceManagement

enum LaunchAtLoginRegistrationState: Equatable {
  case checking
  case enabled
  case disabled
  case requiresApproval
  case unavailable
}

struct LaunchAtLoginSnapshot: Equatable {
  let state: LaunchAtLoginRegistrationState
  let message: String
}

@MainActor
final class LaunchAtLoginController {
  static let preferenceKey = "app.launchAtLogin.enabled"

  private let service: SMAppService

  init(service: SMAppService = .mainApp) {
    self.service = service
  }

  var isInstalledInApplications: Bool {
    let path = Bundle.main.bundleURL.standardizedFileURL.path
    return path == "/Applications/MiddleAI.app" || path.hasPrefix("/Applications/")
  }

  func reconcile(enabled: Bool) -> LaunchAtLoginSnapshot {
    do {
      if enabled {
        switch service.status {
        case .enabled, .requiresApproval:
          break
        case .notRegistered, .notFound:
          try service.register()
        @unknown default:
          return LaunchAtLoginSnapshot(
            state: .unavailable,
            message: "Der Autostart-Status dieser macOS-Version ist unbekannt.")
        }
      } else {
        switch service.status {
        case .enabled, .requiresApproval:
          try service.unregister()
        case .notRegistered, .notFound:
          break
        @unknown default:
          return LaunchAtLoginSnapshot(
            state: .unavailable,
            message: "Der Autostart-Status dieser macOS-Version ist unbekannt.")
        }
      }
    } catch {
      let current = snapshot(preferenceEnabled: enabled)
      if current.state == .requiresApproval { return current }
      return LaunchAtLoginSnapshot(
        state: .unavailable,
        message: "Autostart konnte nicht geändert werden: \(error.localizedDescription)")
    }

    return snapshot(preferenceEnabled: enabled)
  }

  func snapshot(preferenceEnabled: Bool) -> LaunchAtLoginSnapshot {
    switch service.status {
    case .enabled:
      return LaunchAtLoginSnapshot(
        state: .enabled,
        message: "Aktiv. MiddleAI startet nach der macOS-Anmeldung automatisch im Hintergrund.")
    case .requiresApproval:
      return LaunchAtLoginSnapshot(
        state: .requiresApproval,
        message:
          "Vorgemerkt. Bitte erlaube MiddleAI einmal unter Allgemein > Anmeldeobjekte & Erweiterungen."
      )
    case .notRegistered:
      return LaunchAtLoginSnapshot(
        state: preferenceEnabled ? .unavailable : .disabled,
        message: preferenceEnabled
          ? "Autostart ist gewünscht, aber noch nicht bei macOS registriert."
          : "Deaktiviert. MiddleAI startet nur, wenn du die App selbst öffnest.")
    case .notFound:
      return LaunchAtLoginSnapshot(
        state: .unavailable,
        message: "macOS konnte MiddleAI nicht als Anmeldeobjekt finden.")
    @unknown default:
      return LaunchAtLoginSnapshot(
        state: .unavailable,
        message: "Der Autostart-Status dieser macOS-Version ist unbekannt.")
    }
  }
}
