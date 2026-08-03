import AppKit

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

    let profileItem = NSMenuItem(
      title:
        "Profile: \(state?.engine?.activeProfile.capitalized ?? state?.config.activeProfile.capitalized ?? "Default")",
      action: nil, keyEquivalent: "")
    let profileMenu = NSMenu(title: "Profile")
    for profile in ["default", "management", "architecture", "coding", "research"] {
      let item = actionItem(profile.capitalized, action: #selector(selectProfile(_:)))
      item.representedObject = profile
      profileMenu.addItem(item)
    }
    profileItem.submenu = profileMenu
    profileItem.isEnabled = true
    menu.addItem(profileItem)
    menu.addItem(.separator())

    menu.addItem(actionItem("MiddleAI öffnen…", action: #selector(showQuickInput)))
    menu.addItem(actionItem("Setup / Settings…", action: #selector(showSetup)))
    menu.addItem(actionItem("Hilfe & Systemanforderungen…", action: #selector(showHelp)))
    menu.addItem(actionItem("New Conversation", action: #selector(startNewConversation)))
    menu.addItem(actionItem("Stop Speaking", action: #selector(stopSpeaking)))

    let providerItem = actionItem(
      "Anbieter-Seite öffnen", action: #selector(openProviderPage))
    providerItem.isEnabled = state?.engine?.manager.currentConversation?.openWebUIChatID != nil
    menu.addItem(providerItem)
    menu.addItem(.separator())
    menu.addItem(actionItem("Settings", action: #selector(showSetup)))
    menu.addItem(actionItem("Diagnostics", action: #selector(runDiagnostics)))

    if let error = state?.lastError, !error.isEmpty {
      let item = informationalItem(error)
      item.attributedTitle = NSAttributedString(
        string: error, attributes: [.foregroundColor: NSColor.systemRed])
      menu.addItem(item)
    }

    menu.addItem(.separator())
    menu.addItem(actionItem("Quit MiddleAI", action: #selector(quit)))
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
  @objc private func showSetup() { state?.showSetupWindow() }
  @objc private func showHelp() { state?.showHelpWindow() }
  @objc private func startNewConversation() { state?.startNewConversation() }
  @objc private func stopSpeaking() { state?.stopSpeaking() }
  @objc private func openProviderPage() { state?.openCurrentChat() }
  @objc private func runDiagnostics() { state?.submit("Welcher Chat ist gerade aktiv?") }
  @objc private func quit() { NSApplication.shared.terminate(nil) }

  @objc private func selectProfile(_ sender: NSMenuItem) {
    guard let profile = sender.representedObject as? String else { return }
    state?.selectProfile(profile)
  }
}
