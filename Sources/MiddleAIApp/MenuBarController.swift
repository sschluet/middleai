import AppKit
import MiddleAICore

@MainActor
final class MenuBarController: NSObject {
  private weak var state: AppState?
  private let statusItem: NSStatusItem
  private var pendingSingleClick: DispatchWorkItem?

  init(state: AppState) {
    self.state = state
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()

    guard let button = statusItem.button else { return }
    let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MiddleAI")
    image?.isTemplate = true
    button.image = image
    button.imagePosition = .imageOnly
    button.toolTip = "MiddleAI"
    button.target = self
    button.action = #selector(statusButtonClicked)
    button.sendAction(on: [.leftMouseUp])
  }

  @objc private func statusButtonClicked() {
    let clickCount = NSApp.currentEvent?.clickCount ?? 1
    if clickCount >= 2 {
      pendingSingleClick?.cancel()
      pendingSingleClick = nil
      state?.startNewConversation()
      return
    }

    pendingSingleClick?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.pendingSingleClick = nil
      self?.showMenu()
    }
    pendingSingleClick = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + min(NSEvent.doubleClickInterval, 0.30), execute: work)
  }

  private func showMenu() {
    guard let button = statusItem.button else { return }
    statusItem.menu = makeMenu()
    button.performClick(nil)
    statusItem.menu = nil
  }

  private func makeMenu() -> NSMenu {
    let menu = NSMenu(title: "MiddleAI")
    menu.autoenablesItems = false

    menu.addItem(informationalItem("Status: \(state?.status ?? "Starting")"))
    menu.addItem(informationalItem(state?.voiceStatus ?? "Voice wird gestartet"))
    menu.addItem(informationalItem(state?.ttsStatus ?? "Sprachausgabe wird gestartet"))
    menu.addItem(.separator())
    menu.addItem(informationalItem("Current Conversation:"))
    menu.addItem(informationalItem(state?.currentTitle ?? "No active conversation"))
    menu.addItem(.separator())

    let activeProfile = state?.engine?.activeProfile ?? state?.config.activeProfile ?? "default"
    let activeProfileName =
      state?.config.profileDisplayName(for: activeProfile)
      ?? AppConfig.defaultProfileName(for: activeProfile)
    let profileItem = NSMenuItem(
      title: "Profil: \(activeProfileName)", action: nil, keyEquivalent: "")
    let profileMenu = NSMenu(title: "Profile")
    for profile in AppConfig.supportedProfileIDs {
      let title =
        state?.config.profileDisplayName(for: profile)
        ?? AppConfig.defaultProfileName(for: profile)
      let item = actionItem(title, action: #selector(selectProfile(_:)))
      item.representedObject = profile
      item.state = profile == activeProfile ? .on : .off
      profileMenu.addItem(item)
    }
    profileItem.submenu = profileMenu
    profileItem.isEnabled = true
    menu.addItem(profileItem)
    menu.addItem(.separator())

    menu.addItem(actionItem("MiddleAI öffnen…", action: #selector(showQuickInput)))
    let selectionItem = NSMenuItem(
      title: "Markierten Text lokal bearbeiten", action: nil, keyEquivalent: "")
    let selectionMenu = NSMenu(title: "Markierten Text lokal bearbeiten")
    let selectionActions: [(String, TextTransformationAction)] = [
      ("Nur korrigieren", .correct), ("Formulierung glätten", .polish),
      ("Kürzen", .shorten), ("Ausführlicher formulieren", .expand),
      ("Auf Deutsch übersetzen", .translateGerman),
      ("Auf Englisch übersetzen", .translateEnglish), ("In Stichpunkte", .bulletPoints),
      ("Antwortentwurf", .replyDraft),
    ]
    for (title, action) in selectionActions {
      let item = actionItem(title, action: #selector(transformSelection(_:)))
      item.representedObject = action.rawValue
      selectionMenu.addItem(item)
    }
    selectionItem.submenu = selectionMenu
    selectionItem.isEnabled = true
    menu.addItem(selectionItem)
    menu.addItem(actionItem("Einstellungen…", action: #selector(showSetup)))
    menu.addItem(actionItem("Hilfe & Systemanforderungen…", action: #selector(showHelp)))
    menu.addItem(actionItem("Neue Unterhaltung", action: #selector(startNewConversation)))
    menu.addItem(actionItem("Sprachausgabe stoppen", action: #selector(stopSpeaking)))
    menu.addItem(.separator())
    if state?.meetingController.isRecording == true {
      menu.addItem(
        actionItem("Besprechungsaufnahme beenden", action: #selector(stopMeeting)))
      menu.addItem(
        actionItem("Besprechungsaufnahme verwerfen", action: #selector(cancelMeeting)))
    } else {
      let meeting = actionItem(
        "Besprechungsaufnahme starten", action: #selector(startMeeting))
      meeting.isEnabled = state?.meetingController.isProcessing != true
      menu.addItem(meeting)
    }

    let providerItem = actionItem(
      "Anbieter-Seite öffnen", action: #selector(openProviderPage))
    providerItem.isEnabled = state?.engine?.manager.currentConversation?.openWebUIChatID != nil
    menu.addItem(providerItem)
    menu.addItem(.separator())
    menu.addItem(actionItem("Diagnose…", action: #selector(showDiagnostics)))

    if let error = state?.lastError, !error.isEmpty {
      let item = informationalItem(error)
      item.attributedTitle = NSAttributedString(
        string: error, attributes: [.foregroundColor: NSColor.systemRed])
      menu.addItem(item)
    }

    menu.addItem(.separator())
    menu.addItem(actionItem("MiddleAI beenden", action: #selector(quit)))
    return menu
  }

  private func actionItem(_ title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = true
    return item
  }

  private func informationalItem(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  @objc private func showQuickInput() { state?.showQuickInput() }
  @objc private func transformSelection(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
      let action = TextTransformationAction(rawValue: raw)
    else { return }
    state?.previewSelectedText(action: action)
  }
  @objc private func showSetup() { state?.showSetupWindow(initialPane: .general) }
  @objc private func showHelp() { state?.showHelpWindow() }
  @objc private func startNewConversation() { state?.startNewConversation() }
  @objc private func stopSpeaking() { state?.stopSpeaking() }
  @objc private func startMeeting() { state?.startMeeting() }
  @objc private func stopMeeting() { state?.stopMeeting() }
  @objc private func cancelMeeting() { state?.cancelMeeting() }
  @objc private func openProviderPage() { state?.openCurrentChat() }
  @objc private func showDiagnostics() { state?.showSetupWindow(initialPane: .diagnostics) }
  @objc private func quit() { NSApplication.shared.terminate(nil) }

  @objc private func selectProfile(_ sender: NSMenuItem) {
    guard let profile = sender.representedObject as? String else { return }
    state?.selectProfile(profile)
  }
}
