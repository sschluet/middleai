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

    func output(_ spec: CommandSpec, timeout: TimeInterval = 12) -> String? {
      let result = SafeCommandRunner.run(
        executable: spec.executable, arguments: spec.arguments, timeout: timeout)
      guard result.status == 0, !result.timedOut else {
        unavailable.append(spec.source)
        return nil
      }
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
      } else {
        unavailable.append("security.remote_management")
      }
    } else {
      states["security.remote_management"] = "not-configured"
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
        ], source: "certificates.system_roots"), timeout: 20)
    {
      states["certificates.system_roots"] = IntegrityHash.sha256(Self.normalized(text))
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
      guard FileManager.default.fileExists(atPath: directory.path) else { continue }
      do {
        artifacts += try Self.fileArtifacts(in: directory, kind: kind, scope: scope)
      } catch {
        unavailable.append("artifacts.\(kind.rawValue)")
      }
    }
    let managedPreferenceDirectories = [
      URL(fileURLWithPath: "/Library/Managed Preferences", isDirectory: true),
      home.appendingPathComponent("Library/Managed Preferences", isDirectory: true),
    ]
    for directory in managedPreferenceDirectories {
      guard FileManager.default.fileExists(atPath: directory.path) else { continue }
      do {
        let scope = directory.path.hasPrefix(home.path) ? "user" : "system"
        artifacts += try Self.managedPreferenceArtifacts(in: directory, scope: scope)
      } catch {
        unavailable.append("artifacts.\(IntegrityArtifact.Kind.managedPreference.rawValue)")
      }
    }

    if let executable = bundleURL?.appendingPathComponent("Contents/MacOS/MiddleAI"),
      let data = try? Data(contentsOf: executable, options: [.mappedIfSafe])
    {
      states["middleai.bundle"] = IntegrityHash.sha256(data)
    } else {
      unavailable.append("middleai.bundle")
    }

    signals += Self.securityLogSignals(intervalMinutes: intervalMinutes)
    signals += Self.intuneAgentSignals(intervalMinutes: intervalMinutes)

    return SystemIntegritySnapshot(
      states: states, artifacts: artifacts, signals: Self.coalesced(signals),
      unavailableSources: Array(Set(unavailable)))
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
        teamIdentifier: signature?.teamID, signed: signature?.valid)
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
          digest: IntegrityHash.sha256(data)))
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
        digest: IntegrityHash.sha256(Self.normalized(block)))
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
        signed: true)
    }
  }

  private static func securityLogSignals(intervalMinutes: Int) -> [IntegritySignal] {
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
    guard result.status == 0, !result.timedOut else { return [] }
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
          summary: "Sicherheitsrelevanter Fehler in \(process)", severity: severity))
    }
    if authenticationFailures >= 5 {
      signals.append(
        IntegritySignal(
          category: .identity, identifier: "repeated-authentication-failures",
          summary: "Wiederholte fehlgeschlagene Anmeldungen",
          severity: authenticationFailures >= 20 ? .critical : .warning,
          count: authenticationFailures))
    }
    return signals
  }

  private static func intuneAgentSignals(intervalMinutes: Int) -> [IntegritySignal] {
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
    guard count >= 5 else { return [] }
    return [
      IntegritySignal(
        category: .deviceManagement, identifier: "intune-agent-repeated-errors",
        summary: "Intune-Agent meldet wiederholte Fehler", severity: .warning, count: count)
    ]
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
