import Darwin
import Foundation
import MiddleAICore
import Security

struct SystemIntegrityCollector: Sendable {
  private struct CommandSpec {
    let executable: String
    let arguments: [String]
    let source: String
  }

  func capture(intervalMinutes: Int, bundleURL: URL?) async -> SystemIntegritySnapshot {
    await Task.detached(priority: .utility) {
      Self.captureSynchronously(intervalMinutes: intervalMinutes, bundleURL: bundleURL)
    }.value
  }

  private static func captureSynchronously(
    intervalMinutes: Int, bundleURL: URL?
  ) -> SystemIntegritySnapshot {
    var states: [String: String] = [:]
    var artifacts: [IntegrityArtifact] = []
    var signals: [IntegritySignal] = []
    var unavailable: [String] = []
    var checked: Set<String> = []

    func output(_ spec: CommandSpec, timeout: TimeInterval = 12) -> String? {
      let result = SafeCommandRunner.run(
        executable: spec.executable, arguments: spec.arguments, timeout: timeout)
      guard result.status == 0, !result.timedOut else {
        unavailable.append(spec.source)
        return nil
      }
      checked.insert(spec.source)
      return result.output
    }

    if let text = output(
      CommandSpec(
        executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
        arguments: ["--getglobalstate"], source: "security.firewall"))
    {
      states["security.firewall"] =
        text.localizedCaseInsensitiveContains("enabled")
        ? "enabled" : "disabled"
    }
    if let text = output(
      CommandSpec(
        executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
        arguments: ["--getstealthmode"], source: "security.stealth_mode"))
    {
      states["security.stealth_mode"] =
        text.localizedCaseInsensitiveContains("on")
        ? "enabled" : "disabled"
    }
    if let text = output(
      CommandSpec(
        executable: "/usr/sbin/spctl", arguments: ["--status"],
        source: "security.gatekeeper"))
    {
      states["security.gatekeeper"] =
        text.localizedCaseInsensitiveContains("enabled")
        ? "enabled" : "disabled"
    }
    if let text = output(
      CommandSpec(
        executable: "/usr/bin/fdesetup", arguments: ["status"],
        source: "security.filevault"))
    {
      states["security.filevault"] =
        text.localizedCaseInsensitiveContains("is on")
        ? "enabled" : "disabled"
    }
    if let text = output(
      CommandSpec(
        executable: "/usr/bin/csrutil", arguments: ["status"], source: "security.sip"))
    {
      states["security.sip"] =
        text.localizedCaseInsensitiveContains("enabled")
        ? "enabled" : "disabled"
    }
    if let text = output(
      CommandSpec(
        executable: "/usr/bin/dscl",
        arguments: [".", "-read", "/Groups/admin", "GroupMembership"],
        source: "identity.admin_members"))
    {
      states["identity.admin_members"] = IntegrityHash.sha256(Self.normalized(text))
    }
    if let text = output(
      CommandSpec(
        executable: "/usr/bin/dscl", arguments: [".", "-list", "/Users", "UniqueID"],
        source: "identity.local_users"))
    {
      let localAccounts = text.components(separatedBy: .newlines).filter { line in
        guard let uid = Int(line.split(whereSeparator: \.isWhitespace).last ?? "") else {
          return false
        }
        return uid >= 500
      }.joined(separator: "\n")
      states["identity.local_users"] = IntegrityHash.sha256(Self.normalized(localAccounts))
    }
    if let text = output(
      CommandSpec(
        executable: "/bin/launchctl", arguments: ["print-disabled", "system"],
        source: "security.remote_login"))
    {
      let sshDisabled =
        text.range(
          of: #"\"com\.openssh\.sshd\"\s*=>\s*true"#, options: .regularExpression) != nil
      states["security.remote_login"] = sshDisabled ? "disabled" : "not-explicitly-disabled"
    }
    let remoteManagementURL = URL(
      fileURLWithPath: "/Library/Preferences/com.apple.RemoteManagement.plist")
    if FileManager.default.fileExists(atPath: remoteManagementURL.path) {
      if let data = try? Data(contentsOf: remoteManagementURL, options: [.mappedIfSafe]) {
        states["security.remote_management"] = IntegrityHash.sha256(data)
        checked.insert("security.remote_management")
      } else {
        unavailable.append("security.remote_management")
      }
    } else {
      states["security.remote_management"] = "not-configured"
      checked.insert("security.remote_management")
    }

    if let text = output(
      CommandSpec(
        executable: "/usr/bin/profiles", arguments: ["status", "-type", "enrollment"],
        source: "mdm.enrollment"))
    {
      states["mdm.enrollment"] = Self.mdmEnrollmentState(text)
      if let server = Self.firstCapture(
        pattern: #"(?im)^MDM server:\s*(\S+)\s*$"#, in: text)
      {
        states["mdm.server"] = IntegrityHash.sha256(server.lowercased())
      } else {
        states["mdm.server"] = "not-reported"
      }
    }
    if let text = output(
      CommandSpec(
        executable: "/usr/bin/profiles", arguments: ["show", "-type", "configuration"],
        source: "artifacts.configurationProfile"))
    {
      artifacts += Self.profileArtifacts(from: text)
    }
    if let text = output(
      CommandSpec(
        executable: "/usr/bin/systemextensionsctl", arguments: ["list"],
        source: "artifacts.systemExtension"))
    {
      artifacts += Self.systemExtensionArtifacts(from: text)
    }
    if let text = output(
      CommandSpec(
        executable: "/usr/bin/security",
        arguments: [
          "find-certificate", "-a", "-Z", "/Library/Keychains/System.keychain",
        ], source: "artifacts.systemCertificate"), timeout: 20)
    {
      artifacts += Self.systemCertificateArtifacts(from: text)
    }
    if let text = output(
      CommandSpec(
        executable: "/usr/bin/security", arguments: ["dump-trust-settings", "-d"],
        source: "artifacts.rootCertificate"), timeout: 20)
    {
      artifacts += Self.trustedRootArtifacts(from: text)
    }
    if let text = output(
      CommandSpec(
        executable: "/usr/sbin/scutil", arguments: ["--proxy"], source: "network.proxy"))
    {
      states["network.proxy"] = IntegrityHash.sha256(Self.normalized(text))
    }
    if let text = output(
      CommandSpec(
        executable: "/usr/sbin/scutil", arguments: ["--dns"], source: "network.dns"))
    {
      states["network.dns"] = IntegrityHash.sha256(Self.normalizedDNS(text))
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    let watchedDirectories: [(URL, IntegrityArtifact.Kind, String)] = [
      (URL(fileURLWithPath: "/Library/LaunchAgents"), .launchAgent, "system"),
      (URL(fileURLWithPath: "/Library/LaunchDaemons"), .launchDaemon, "system"),
      (home.appendingPathComponent("Library/LaunchAgents"), .launchAgent, "user"),
      (
        URL(fileURLWithPath: "/Library/PrivilegedHelperTools"), .privilegedHelper,
        "system"
      ),
    ]
    for (directory, kind, scope) in watchedDirectories {
      let sourceID = "artifacts.\(kind.rawValue)"
      guard FileManager.default.fileExists(atPath: directory.path) else {
        checked.insert(sourceID)
        continue
      }
      do {
        artifacts += try Self.fileArtifacts(in: directory, kind: kind, scope: scope)
        checked.insert(sourceID)
      } catch {
        unavailable.append(sourceID)
      }
    }
    let managedPreferenceDirectories = [
      URL(fileURLWithPath: "/Library/Managed Preferences", isDirectory: true),
      home.appendingPathComponent("Library/Managed Preferences", isDirectory: true),
    ]
    for directory in managedPreferenceDirectories {
      let sourceID = "artifacts.\(IntegrityArtifact.Kind.managedPreference.rawValue)"
      guard FileManager.default.fileExists(atPath: directory.path) else {
        checked.insert(sourceID)
        continue
      }
      do {
        let scope = directory.path.hasPrefix(home.path) ? "user" : "system"
        artifacts += try Self.managedPreferenceArtifacts(in: directory, scope: scope)
        checked.insert(sourceID)
      } catch {
        unavailable.append(sourceID)
      }
    }

    let loginResult = SafeCommandRunner.run(
      executable: "/usr/bin/sfltool", arguments: ["dumpbtm"], timeout: 12,
      maximumBytes: 1_200_000)
    if loginResult.status == 0, !loginResult.timedOut {
      artifacts += Self.loginItemArtifacts(from: loginResult.output)
      checked.insert("artifacts.loginItem")
    } else {
      unavailable.append("artifacts.loginItem")
    }

    let cronResult = SafeCommandRunner.run(
      executable: "/usr/bin/crontab", arguments: ["-l"], timeout: 5)
    if !cronResult.timedOut, cronResult.status == 0 || cronResult.status == 1 {
      artifacts += Self.cronArtifacts(from: cronResult.output, home: home)
      checked.insert("artifacts.scheduledTask")
    } else {
      unavailable.append("artifacts.scheduledTask")
    }
    artifacts += Self.sensitiveUserFileArtifacts(
      home: home, checked: &checked, unavailable: &unavailable)

    let defender = Self.defenderHealth()
    states.merge(defender.states) { _, new in new }
    signals += defender.signals
    if defender.available {
      checked.insert("defender.health")
    } else {
      unavailable.append("defender.health")
    }

    if let executable = bundleURL?.appendingPathComponent("Contents/MacOS/MiddleAI"),
      let data = try? Data(contentsOf: executable, options: [.mappedIfSafe])
    {
      states["middleai.bundle"] = IntegrityHash.sha256(data)
      checked.insert("middleai.bundle")
    } else {
      unavailable.append("middleai.bundle")
    }

    let securityLogs = Self.securityLogSignals(intervalMinutes: intervalMinutes)
    signals += securityLogs.signals
    if securityLogs.available {
      checked.insert("security.logs")
    } else {
      unavailable.append("security.logs")
    }
    let intuneLogs = Self.intuneAgentSignals(intervalMinutes: intervalMinutes)
    signals += intuneLogs.signals
    if intuneLogs.available {
      checked.insert("intune.logs")
    } else {
      unavailable.append("intune.logs")
    }

    return SystemIntegritySnapshot(
      states: states, artifacts: artifacts, signals: Self.coalesced(signals),
      unavailableSources: Array(Set(unavailable)), checkedSources: Array(checked))
  }

  private static func fileArtifacts(
    in directory: URL, kind: IntegrityArtifact.Kind, scope: String
  ) throws -> [IntegrityArtifact] {
    let urls = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])
    return urls.prefix(500).compactMap { url in
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true || values.isSymbolicLink == true,
        let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
      else { return nil }
      let plist =
        (try? PropertyListSerialization.propertyList(from: data, format: nil))
        as? [String: Any]
      let label = (plist?["Label"] as? String) ?? url.lastPathComponent
      let identifier = "\(scope):\(label)"
      let executablePath =
        (plist?["Program"] as? String)
        ?? (plist?["ProgramArguments"] as? [String])?.first
        ?? (kind == .privilegedHelper ? url.path : nil)
      let signature = executablePath.flatMap { Self.signatureInfo(URL(fileURLWithPath: $0)) }
      return IntegrityArtifact(
        kind: kind, identifier: identifier, digest: IntegrityHash.sha256(data),
        teamIdentifier: signature?.teamID, signed: signature?.valid,
        source: IntegrityFindingSource(
          kind: .file, title: url.lastPathComponent, locator: url.path,
          collectorID: "artifacts.\(kind.rawValue)"))
    }
  }

  private static func signatureInfo(_ url: URL) -> (valid: Bool, teamID: String?)? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode
    else { return (false, nil) }
    let valid = SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess
    var information: CFDictionary?
    let teamID: String?
    if SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
      let values = information as? [String: Any]
    {
      teamID = values[kSecCodeInfoTeamIdentifier as String] as? String
    } else {
      teamID = nil
    }
    return (valid, teamID)
  }

  private static func managedPreferenceArtifacts(in directory: URL, scope: String) throws
    -> [IntegrityArtifact]
  {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    var artifacts: [IntegrityArtifact] = []
    for case let url as URL in enumerator {
      if artifacts.count >= 500 { break }
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
      else { continue }
      let relative = String(url.path.dropFirst(directory.path.count)).trimmingCharacters(
        in: CharacterSet(charactersIn: "/"))
      artifacts.append(
        IntegrityArtifact(
          kind: .managedPreference, identifier: "\(scope):\(relative)",
          digest: IntegrityHash.sha256(data),
          source: IntegrityFindingSource(
            kind: .file, title: url.lastPathComponent, locator: url.path,
            collectorID: "artifacts.managedPreference")))
    }
    return artifacts
  }

  private static func profileArtifacts(from text: String) -> [IntegrityArtifact] {
    guard
      let expression = try? NSRegularExpression(
        pattern: #"(?im)^.*attribute:\s*profileIdentifier:\s*([^\s]+)\s*$"#)
    else { return [] }
    let source = text as NSString
    let matches = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
    return matches.enumerated().compactMap { index, match in
      guard match.numberOfRanges > 1 else { return nil }
      let identifier = source.substring(with: match.range(at: 1))
      let start = match.range.location
      let end = index + 1 < matches.count ? matches[index + 1].range.location : source.length
      let block = source.substring(with: NSRange(location: start, length: max(0, end - start)))
      return IntegrityArtifact(
        kind: .configurationProfile, identifier: identifier,
        digest: IntegrityHash.sha256(Self.normalized(block)),
        source: IntegrityFindingSource(
          kind: .profile, title: "Geräteverwaltung",
          locator: "x-apple.systempreferences:com.apple.Profiles-Settings.extension",
          detail: identifier, collectorID: "artifacts.configurationProfile"),
        risk: Self.profileRisk(block))
    }
  }

  private static func systemExtensionArtifacts(from text: String) -> [IntegrityArtifact] {
    text.components(separatedBy: .newlines).compactMap { raw in
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("---"), !line.hasPrefix("enabled") else { return nil }
      let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard fields.count >= 4,
        let bundleIndex = fields.firstIndex(where: { $0.contains(".") && !$0.contains("[") })
      else { return nil }
      let bundleID = fields[bundleIndex]
      let teamID = bundleIndex > 0 ? fields[bundleIndex - 1] : nil
      return IntegrityArtifact(
        kind: .systemExtension, identifier: bundleID,
        digest: IntegrityHash.sha256(Self.normalized(line)), teamIdentifier: teamID,
        signed: true,
        source: IntegrityFindingSource(
          kind: .systemSettings, title: "Erweiterungen",
          locator: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
          collectorID: "artifacts.systemExtension"))
    }
  }

  private static func profileRisk(_ block: String) -> IntegritySeverity {
    let securityPayloads = [
      "com.apple.security", "com.apple.applicationaccess", "com.apple.system-extension",
      "com.apple.syspolicy", "com.apple.MCX.FileVault2", "com.apple.security.firewall",
      "com.apple.vpn", "com.apple.networkextension", "com.apple.TCC.configuration-profile-policy",
      "com.apple.loginwindow", "com.apple.mobiledevice.passwordpolicy", "certificate",
    ]
    return securityPayloads.contains {
      block.localizedCaseInsensitiveContains($0)
    } ? .critical : .warning
  }

  private static func systemCertificateArtifacts(from text: String) -> [IntegrityArtifact] {
    let blocks = text.components(separatedBy: "SHA-256 hash:").dropFirst()
    return blocks.prefix(1_000).compactMap { raw -> IntegrityArtifact? in
      let block = String(raw)
      guard
        let fingerprint = block.components(separatedBy: .newlines).first?
          .trimmingCharacters(in: .whitespacesAndNewlines), !fingerprint.isEmpty
      else { return nil }
      let label =
        firstCapture(pattern: #"(?m)\"labl\"<blob>=\"([^\"]+)\""#, in: block)
        ?? "Zertifikat \(fingerprint.prefix(12))"
      return IntegrityArtifact(
        kind: .systemCertificate, identifier: label, digest: fingerprint.lowercased(),
        source: IntegrityFindingSource(
          kind: .keychain, title: "Schlüsselbundverwaltung",
          locator: "/System/Applications/Utilities/Keychain Access.app", detail: label,
          collectorID: "artifacts.systemCertificate"))
    }
  }

  private static func trustedRootArtifacts(from text: String) -> [IntegrityArtifact] {
    captures(pattern: #"(?m)^\s*Cert\s+\d+:\s*(.+?)\s*$"#, in: text).prefix(500).map { name in
      IntegrityArtifact(
        kind: .rootCertificate, identifier: name,
        digest: IntegrityHash.sha256(name.lowercased()),
        source: IntegrityFindingSource(
          kind: .keychain, title: "Vertrauensstellungen",
          locator: "/System/Applications/Utilities/Keychain Access.app", detail: name,
          collectorID: "artifacts.rootCertificate"),
        risk: .critical)
    }
  }

  private static func loginItemArtifacts(from text: String) -> [IntegrityArtifact] {
    let records = captures(pattern: #"(?ms)(^\s*#\d+:.*?)(?=^\s*#\d+:|\z)"#, in: text)
    return records.prefix(750).compactMap { block -> IntegrityArtifact? in
      let identifier = firstCapture(pattern: #"(?m)^\s*Identifier:\s*(.+?)\s*$"#, in: block)
      let name = firstCapture(pattern: #"(?m)^\s*Name:\s*(.+?)\s*$"#, in: block)
      guard let stable = identifier ?? name, !stable.isEmpty else { return nil }
      let team = firstCapture(pattern: #"(?m)^\s*Team Identifier:\s*(.+?)\s*$"#, in: block)
      let disposition = firstCapture(pattern: #"(?m)^\s*Disposition:\s*(.+?)\s*$"#, in: block) ?? ""
      let type = firstCapture(pattern: #"(?m)^\s*Type:\s*(.+?)\s*$"#, in: block) ?? ""
      return IntegrityArtifact(
        kind: .loginItem, identifier: stable,
        digest: IntegrityHash.sha256(
          normalized("\(stable)\n\(team ?? "")\n\(disposition)\n\(type)")),
        teamIdentifier: team,
        source: IntegrityFindingSource(
          kind: .systemSettings, title: "Anmeldeobjekte & Erweiterungen",
          locator: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
          detail: name, collectorID: "artifacts.loginItem"))
    }
  }

  private static func cronArtifacts(from text: String, home: URL) -> [IntegrityArtifact] {
    text.components(separatedBy: .newlines).enumerated().compactMap { index, raw in
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
      return IntegrityArtifact(
        kind: .scheduledTask, identifier: "Benutzer-Crontab Zeile \(index + 1)",
        digest: IntegrityHash.sha256(line),
        source: IntegrityFindingSource(
          kind: .file, title: "Lokale Crontab", locator: home.path,
          detail: "Mit ‘crontab -l’ im Terminal anzeigen",
          collectorID: "artifacts.scheduledTask"))
    }
  }

  private static func sensitiveUserFileArtifacts(
    home: URL, checked: inout Set<String>, unavailable: inout [String]
  ) -> [IntegrityArtifact] {
    let specifications: [(String, IntegrityArtifact.Kind)] = [
      (".ssh/authorized_keys", .authorizedKey), (".zshrc", .shellStartup),
      (".zprofile", .shellStartup), (".bash_profile", .shellStartup),
      (".profile", .shellStartup),
    ]
    var artifacts: [IntegrityArtifact] = []
    for (relative, kind) in specifications {
      let sourceID = "artifacts.\(kind.rawValue)"
      let url = home.appendingPathComponent(relative)
      guard FileManager.default.fileExists(atPath: url.path) else {
        checked.insert(sourceID)
        continue
      }
      guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
        unavailable.append(sourceID)
        continue
      }
      checked.insert(sourceID)
      artifacts.append(
        IntegrityArtifact(
          kind: kind, identifier: relative, digest: IntegrityHash.sha256(data),
          source: IntegrityFindingSource(
            kind: .file, title: url.lastPathComponent, locator: url.path,
            collectorID: sourceID),
          risk: kind == .authorizedKey ? .critical : .warning))
    }
    return artifacts
  }

  private static func defenderHealth() -> (
    states: [String: String], signals: [IntegritySignal], available: Bool
  ) {
    let executable =
      "/Applications/Microsoft Defender.app/Contents/Resources/Tools/wdavdaemonclient"
    guard FileManager.default.isExecutableFile(atPath: executable) else {
      return (["defender.installed": "false"], [], true)
    }
    let result = SafeCommandRunner.run(
      executable: executable, arguments: ["health", "--output", "json"], timeout: 12,
      maximumBytes: 500_000)
    guard result.status == 0, !result.timedOut,
      let data = result.output.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return ([:], [], false) }
    func value(_ key: String) -> String {
      guard let raw = object[key] else { return "unknown" }
      if let bool = raw as? Bool { return bool ? "enabled" : "disabled" }
      return String(describing: raw).lowercased()
    }
    var states = [
      "defender.installed": "true", "defender.healthy": value("healthy"),
      "defender.licensed": value("licensed"),
      "defender.real_time_protection": value("realTimeProtectionEnabled"),
      "defender.network_protection": value("networkProtectionStatus"),
      "defender.definitions": value("definitionsStatus"),
      "defender.full_disk_access": value("fullDiskAccessEnabled"),
      "defender.tamper_protection": value("tamperProtection"),
      "defender.passive_mode": value("passiveModeEnabled"),
    ]
    states = states.mapValues { String($0.prefix(120)) }
    let source = IntegrityFindingSource(
      kind: .application, title: "Microsoft Defender",
      locator: "/Applications/Microsoft Defender.app", collectorID: "defender.health")
    var signals: [IntegritySignal] = []
    if states["defender.healthy"] == "disabled" {
      signals.append(
        IntegritySignal(
          category: .securityConfiguration, identifier: "defender-unhealthy",
          summary: "Microsoft Defender meldet einen nicht gesunden Zustand", severity: .warning,
          source: source))
    }
    if states["defender.real_time_protection"] == "disabled" {
      signals.append(
        IntegritySignal(
          category: .securityConfiguration, identifier: "defender-real-time-disabled",
          summary: "Microsoft Defender Echtzeitschutz ist deaktiviert", severity: .critical,
          source: source))
    }
    return (states, signals, true)
  }

  private static func securityLogSignals(intervalMinutes: Int) -> (
    signals: [IntegritySignal], available: Bool
  ) {
    let minutes = min(1_440, max(10, intervalMinutes))
    let predicate = """
      ((messageType == error OR messageType == fault) AND
       (process == "mdmclient" OR process == "profiles" OR process CONTAINS[c] "Intune" OR
        process == "securityd" OR process == "syspolicyd" OR process == "amfid" OR
        process == "authd" OR process == "sshd" OR process == "loginwindow" OR
        process == "XProtect" OR process == "MRT" OR
        subsystem BEGINSWITH "com.apple.ManagedClient" OR
        subsystem BEGINSWITH "com.apple.security")) OR
      (process == "sshd" AND
       (eventMessage CONTAINS[c] "authentication failed" OR
        eventMessage CONTAINS[c] "failed password" OR eventMessage CONTAINS[c] "invalid user"))
      """
    let result = SafeCommandRunner.run(
      executable: "/usr/bin/log",
      arguments: [
        "show", "--last", "\(minutes)m", "--style", "ndjson", "--predicate", predicate,
      ], timeout: 20, maximumBytes: 1_500_000)
    guard result.status == 0, !result.timedOut else { return ([], false) }
    var signals: [IntegritySignal] = []
    var authenticationFailures = 0
    for line in result.output.components(separatedBy: .newlines).prefix(600) {
      guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let message = object["eventMessage"] as? String
      else { continue }
      let process = (object["process"] as? String) ?? "macOS"
      let normalized = normalizedLogMessage(message)
      guard Self.relevantSecurityMessage(normalized) else { continue }
      if Self.authenticationFailure(normalized) { authenticationFailures += 1 }
      let severity: IntegritySeverity =
        Self.criticalSecurityMessage(normalized) ? .critical : .warning
      let category: IntegrityCategory =
        process.localizedCaseInsensitiveContains("intune")
          || process == "mdmclient" || normalized.localizedCaseInsensitiveContains("profile")
        ? .deviceManagement : .system
      signals.append(
        IntegritySignal(
          category: category,
          identifier: "unified-log|\(process)|\(IntegrityHash.sha256(normalized).prefix(16))",
          summary: "Sicherheitsrelevanter Fehler in \(process)", severity: severity,
          source: IntegrityFindingSource(
            kind: .console, title: "Konsole", locator: "/System/Applications/Utilities/Console.app",
            detail: process, collectorID: "security.logs")))
    }
    if authenticationFailures >= 5 {
      signals.append(
        IntegritySignal(
          category: .identity, identifier: "repeated-authentication-failures",
          summary: "Wiederholte fehlgeschlagene Anmeldungen",
          severity: authenticationFailures >= 20 ? .critical : .warning,
          count: authenticationFailures,
          source: IntegrityFindingSource(
            kind: .console, title: "Konsole", locator: "/System/Applications/Utilities/Console.app",
            detail: "Anmeldeereignisse", collectorID: "security.logs")))
    }
    return (signals, true)
  }

  private static func intuneAgentSignals(intervalMinutes: Int) -> (
    signals: [IntegritySignal], available: Bool
  ) {
    let directories = [
      URL(fileURLWithPath: "/Library/Logs/Microsoft/Intune", isDirectory: true),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Logs/Microsoft/Intune", isDirectory: true),
    ]
    let cutoff = Date().addingTimeInterval(-Double(max(10, intervalMinutes)) * 60)
    let timestampFormatter = DateFormatter()
    timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
    timestampFormatter.timeZone = .current
    timestampFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss:SSS"
    var count = 0
    for directory in directories {
      guard
        let urls = try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
          options: [.skipsHiddenFiles])
      else { continue }
      for url in urls {
        guard url.pathExtension.lowercased() == "log",
          let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
          values.contentModificationDate.map({ $0 >= cutoff }) == true,
          let handle = try? FileHandle(forReadingFrom: url)
        else { continue }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 256_000 ? size - 256_000 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        count +=
          text.components(separatedBy: .newlines).filter { line in
            Self.isRecentIntuneError(line, cutoff: cutoff, formatter: timestampFormatter)
          }.count
      }
    }
    guard count >= 5 else { return ([], true) }
    return (
      [
        IntegritySignal(
          category: .deviceManagement, identifier: "intune-agent-repeated-errors",
          summary: "Intune-Agent meldet wiederholte Fehler", severity: .warning, count: count,
          source: IntegrityFindingSource(
            kind: .file, title: "Intune-Logs", locator: "/Library/Logs/Microsoft/Intune",
            collectorID: "intune.logs"))
      ], true
    )
  }

  private static func coalesced(_ signals: [IntegritySignal]) -> [IntegritySignal] {
    Dictionary(grouping: signals, by: \.identifier).map { _, values in
      var result = values[0]
      result.count = values.reduce(0) { $0 + $1.count }
      result.severity = values.map(\.severity).max() ?? result.severity
      return result
    }.sorted { $0.identifier < $1.identifier }
  }

  private static func mdmEnrollmentState(_ text: String) -> String {
    let normalized = text.lowercased()
    if normalized.contains("mdm enrollment: yes (user approved)") { return "user-approved" }
    if normalized.contains("mdm enrollment: yes") { return "enrolled" }
    return "not-enrolled"
  }

  private static func relevantSecurityMessage(_ value: String) -> Bool {
    let terms = [
      "unauthorized", "signature", "tamper", "malware", "xprotect", "blocked", "denied",
      "authentication failed", "failed authentication", "failed password", "invalid user",
      "profile installation failed", "profile removal", "not trusted",
      "integrity", "certificate revoked",
    ]
    return terms.contains { value.localizedCaseInsensitiveContains($0) }
  }

  private static func criticalSecurityMessage(_ value: String) -> Bool {
    let terms = [
      "tamper", "malware", "certificate revoked", "integrity check failed", "xprotect detected",
    ]
    return terms.contains { value.localizedCaseInsensitiveContains($0) }
  }

  private static func authenticationFailure(_ value: String) -> Bool {
    ["authentication failed", "failed authentication", "failed password", "invalid user"].contains {
      value.localizedCaseInsensitiveContains($0)
    }
  }

  private static func isRecentIntuneError(
    _ line: String, cutoff: Date, formatter: DateFormatter
  ) -> Bool {
    let fields = line.components(separatedBy: "|")
    guard fields.count >= 3 else { return false }
    let level = fields[2].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard ["E", "ERROR", "F", "FAULT"].contains(level) else { return false }
    let timestamp = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
    return formatter.date(from: timestamp).map { $0 >= cutoff } ?? false
  }

  private static func normalizedLogMessage(_ value: String) -> String {
    var result = value.replacingOccurrences(
      of: #"[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}"#, with: "<uuid>",
      options: .regularExpression)
    result = result.replacingOccurrences(
      of: #"\b\d{2,}\b"#, with: "<n>", options: .regularExpression)
    return String(result.prefix(500))
  }

  private static func normalized(_ value: String) -> String {
    value.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }.sorted().joined(separator: "\n")
  }

  private static func normalizedDNS(_ value: String) -> String {
    value.components(separatedBy: .newlines).compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        trimmed.hasPrefix("nameserver[") || trimmed.hasPrefix("domain")
          || trimmed.hasPrefix("search domain[") || trimmed.hasPrefix("if_index")
      else { return nil }
      return trimmed
    }.sorted().joined(separator: "\n")
  }

  private static func captures(pattern: String, in text: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: range).compactMap { match in
      guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else {
        return nil
      }
      return String(text[range])
    }
  }

  private static func firstCapture(pattern: String, in text: String) -> String? {
    captures(pattern: pattern, in: text).first
  }
}

private struct SafeCommandResult: Sendable {
  let status: Int32
  let output: String
  let timedOut: Bool
}

private enum SafeCommandRunner {
  static func run(
    executable: String, arguments: [String], timeout: TimeInterval,
    maximumBytes: Int = 800_000
  ) -> SafeCommandResult {
    guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
      return SafeCommandResult(status: -1, output: "", timedOut: false)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    let box = CommandDataBox(maximumBytes: maximumBytes)
    let reader = DispatchQueue(label: "de.middleai.integrity-command-reader", qos: .utility)
    let group = DispatchGroup()
    group.enter()
    reader.async {
      while let data = try? pipe.fileHandleForReading.read(upToCount: 65_536), !data.isEmpty {
        box.append(data)
      }
      group.leave()
    }
    do {
      try process.run()
      try? pipe.fileHandleForWriting.close()
    } catch {
      try? pipe.fileHandleForWriting.close()
      try? pipe.fileHandleForReading.close()
      group.wait()
      return SafeCommandResult(status: -1, output: "", timedOut: false)
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
    let timedOut = process.isRunning
    if timedOut {
      process.terminate()
      let terminationDeadline = Date().addingTimeInterval(1)
      while process.isRunning, Date() < terminationDeadline {
        Thread.sleep(forTimeInterval: 0.025)
      }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    try? pipe.fileHandleForReading.close()
    group.wait()
    return SafeCommandResult(
      status: process.terminationStatus,
      output: String(decoding: box.data, as: UTF8.self), timedOut: timedOut)
  }
}

private final class CommandDataBox: @unchecked Sendable {
  private let lock = NSLock()
  private let maximumBytes: Int
  private var storage = Data()

  init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

  func append(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    storage.append(data.prefix(max(0, maximumBytes - storage.count)))
  }

  var data: Data {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
