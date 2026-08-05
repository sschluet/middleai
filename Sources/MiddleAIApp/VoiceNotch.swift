import AppKit
import SwiftUI

enum VoiceMode: Hashable, Sendable {
  case dictation
  case assistant

  var title: String {
    switch self {
    case .dictation: return "Diktat"
    case .assistant: return "MiddleAI"
    }
  }

  var color: Color {
    switch self {
    case .dictation: return .white.opacity(0.88)
    case .assistant: return Color(red: 1.0, green: 0.35, blue: 0.35)
    }
  }

  var symbol: String {
    switch self {
    case .dictation: return "text.cursor"
    case .assistant: return "sparkles"
    }
  }
}

enum VoicePhase: Sendable {
  case listening
  case transcribing
  case polishing
  case thinking
  case result
  case error
}

@MainActor final class VoiceOverlayModel: ObservableObject {
  @Published var mode: VoiceMode = .dictation
  @Published var phase: VoicePhase = .listening
  @Published var level: Float = 0
  @Published var detail = ""
  @Published var targetIcon: NSImage?

  let islandWidth: CGFloat = 258
  let islandHeight: CGFloat = 40

  var statusTitle: String {
    switch phase {
    case .listening: return mode.title
    case .transcribing: return "Lokal transkribieren"
    case .polishing: return "Diktat lokal glätten"
    case .thinking: return "KI-Anbieter antwortet"
    case .result: return mode == .dictation ? "Text eingefügt" : "Antwort wird vorgelesen"
    case .error: return "Nicht geklappt"
    }
  }

  var visibleStatus: String {
    if phase == .error, !detail.isEmpty { return detail }
    return statusTitle
  }
}

private struct VoiceIslandView: View {
  @ObservedObject var model: VoiceOverlayModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 10) {
      modeIndicator
        .frame(width: 20, height: 20)

      if model.phase == .listening {
        IslandWaveform(
          level: model.level, color: model.mode.color, active: model.phase == .listening
        )
        .frame(width: 58, height: 22)
      } else {
        phaseIndicator
          .frame(width: 18, height: 20)
      }

      Text(model.visibleStatus)
        .font(.system(size: 14, weight: .medium, design: .rounded))
        .foregroundStyle(model.phase == .error ? Color.red.opacity(0.96) : .white.opacity(0.92))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: 128, alignment: .leading)
    }
    .padding(.horizontal, 20)
    .frame(width: model.islandWidth, height: model.islandHeight, alignment: .center)
    .preferredColorScheme(.dark)
    .animation(reduceMotion ? nil : .snappy(duration: 0.14), value: model.phase)
  }

  @ViewBuilder private var modeIndicator: some View {
    if let icon = model.targetIcon, model.mode == .dictation {
      Image(nsImage: icon)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    } else {
      Image(systemName: model.mode.symbol)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(model.mode.color)
        .frame(width: 18, height: 18)
    }
  }

  @ViewBuilder private var phaseIndicator: some View {
    switch model.phase {
    case .transcribing, .polishing, .thinking:
      ProgressView().controlSize(.small).tint(model.mode.color).scaleEffect(0.82)
    case .result:
      Image(systemName: "checkmark")
        .font(.system(size: 11, weight: .bold)).foregroundStyle(model.mode.color)
    case .error:
      Image(systemName: "exclamationmark")
        .font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
    case .listening:
      EmptyView()
    }
  }
}

private enum VoiceOverlayPresentation {
  case notch(CGSize)
  case floating(menuBarHeight: CGFloat)
}

private struct VoiceOverlayRootView: View {
  @ObservedObject var model: VoiceOverlayModel
  let presentation: VoiceOverlayPresentation

  @ViewBuilder var body: some View {
    switch presentation {
    case .notch(let size):
      VoiceNotchRootView(model: model, hardwareNotchSize: size)
    case .floating(let menuBarHeight):
      VoiceFloatingRootView(model: model, menuBarHeight: menuBarHeight)
    }
  }
}

private struct VoiceFloatingRootView: View {
  @ObservedObject var model: VoiceOverlayModel
  let menuBarHeight: CGFloat

  var body: some View {
    VoiceIslandView(model: model)
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background {
        ZStack {
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.ultraThinMaterial)
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.black.opacity(0.70))
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .strokeBorder(.white.opacity(0.13), lineWidth: 0.8)
      }
      .shadow(color: .black.opacity(0.36), radius: 18, y: 8)
      .padding(.top, menuBarHeight + 10)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

/// Concave shoulder geometry adapted from MIT-licensed DynamicNotchKit, the
/// same notch component used throughout MiddleAI.
private struct FluidNotchShape: Shape {
  var topCornerRadius: CGFloat = 15
  var bottomCornerRadius: CGFloat = 20

  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY + topCornerRadius),
      control: CGPoint(x: rect.minX + topCornerRadius, y: rect.minY))
    path.addLine(
      to: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY - bottomCornerRadius))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + topCornerRadius + bottomCornerRadius, y: rect.maxY),
      control: CGPoint(x: rect.minX + topCornerRadius, y: rect.maxY))
    path.addLine(
      to: CGPoint(x: rect.maxX - topCornerRadius - bottomCornerRadius, y: rect.maxY))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY - bottomCornerRadius),
      control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.maxY))
    path.addLine(
      to: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY + topCornerRadius))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.minY),
      control: CGPoint(x: rect.maxX - topCornerRadius, y: rect.minY))
    path.closeSubpath()
    return path
  }
}

private struct VoiceNotchRootView: View {
  @ObservedObject var model: VoiceOverlayModel
  let hardwareNotchSize: CGSize

  private let topCornerRadius: CGFloat = 15
  private let bottomCornerRadius: CGFloat = 20
  private let contentInset: CGFloat = 15

  private var width: CGFloat {
    max(model.islandWidth + contentInset * 2, hardwareNotchSize.width + topCornerRadius * 2)
  }

  private var height: CGFloat {
    hardwareNotchSize.height + model.islandHeight + contentInset
  }

  var body: some View {
    VStack(spacing: 0) {
      Color.clear.frame(height: hardwareNotchSize.height)
      VoiceIslandView(model: model)
      Color.clear.frame(height: contentInset)
    }
    .frame(width: width, height: height)
    .background {
      Rectangle().fill(.black).padding(-50)
    }
    .overlay {
      FluidNotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
        .stroke(.white.opacity(0.05), lineWidth: 0.8)
        .padding(.horizontal, 0.9)
        .padding(.vertical, 0.4)
    }
    .mask {
      FluidNotchShape(topCornerRadius: topCornerRadius, bottomCornerRadius: bottomCornerRadius)
        .padding(.horizontal, 0.5)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

private struct IslandWaveform: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let level: Float
  let color: Color
  let active: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 2.5) {
      ForEach(0..<7, id: \.self) { index in
        let distance = abs(Float(index) - 3) / 3
        let centerFactor = 1 - distance * 0.28
        let activity = active ? max(0.05, min(1, level * 1.8 * centerFactor)) : 0.05
        RoundedRectangle(cornerRadius: 1.25)
          .fill(color.opacity(active ? 0.95 : 0.24))
          .frame(width: 3, height: 4 + CGFloat(activity) * 12)
          .shadow(color: color.opacity(active ? 0.3 : 0), radius: 1.5)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: level)
  }
}

@MainActor final class VoiceNotchPresenter {
  let model = VoiceOverlayModel()
  private var panel: NSPanel?
  private var hideTask: Task<Void, Never>?
  private var screenNumber: NSNumber?

  func show(mode: VoiceMode, targetIcon: NSImage? = nil) {
    hideTask?.cancel()
    let screen = preferredScreen()
    model.mode = mode
    model.phase = .listening
    model.level = 0
    model.detail = ""
    model.targetIcon = targetIcon

    presentPanel(on: screen)
  }

  func setLevel(_ level: Float) {
    model.level = level
  }

  func update(phase: VoicePhase, detail: String) {
    hideTask?.cancel()
    model.phase = phase
    model.detail = detail
  }

  func hide(after delay: TimeInterval = 0) {
    hideTask?.cancel()
    hideTask = Task { [weak self] in
      if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
      guard !Task.isCancelled, let self else { return }
      self.dismissPanel()
    }
  }

  private func presentPanel(on screen: NSScreen) {
    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    if panel == nil || screenNumber != number {
      panel?.orderOut(nil)
      panel = makePanel(on: screen)
      screenNumber = number
    }
    guard let panel else { return }
    panel.setFrame(panelFrame(on: screen), display: true)
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.10
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }
  }

  private func makePanel(on screen: NSScreen) -> NSPanel {
    let result = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: true)
    result.hasShadow = false
    result.backgroundColor = .clear
    result.isOpaque = false
    result.level = .screenSaver
    result.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    result.hidesOnDeactivate = false
    result.ignoresMouseEvents = true
    result.isMovable = false

    let hosting = NSHostingView(
      rootView: VoiceOverlayRootView(model: model, presentation: presentation(on: screen)))
    hosting.wantsLayer = true
    hosting.layer?.backgroundColor = NSColor.clear.cgColor
    result.contentView = hosting
    return result
  }

  private func dismissPanel() {
    guard let panel, panel.isVisible else { return }
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.06
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)
        panel.animator().alphaValue = 0
      },
      completionHandler: {
        Task { @MainActor in
          panel.orderOut(nil)
          panel.alphaValue = 1
        }
      }
    )
  }

  private func panelFrame(on screen: NSScreen) -> NSRect {
    let size = NSSize(width: screen.frame.width / 2, height: screen.frame.height / 2)
    return NSRect(
      x: screen.frame.midX - size.width / 2,
      y: screen.frame.maxY - size.height,
      width: size.width,
      height: size.height)
  }

  private func presentation(on screen: NSScreen) -> VoiceOverlayPresentation {
    if let left = screen.auxiliaryTopLeftArea?.width,
      let right = screen.auxiliaryTopRightArea?.width
    {
      return .notch(
        CGSize(
          width: screen.frame.width - left - right,
          height: screen.safeAreaInsets.top))
    }
    return .floating(menuBarHeight: max(24, screen.frame.maxY - screen.visibleFrame.maxY))
  }

  private func preferredScreen() -> NSScreen {
    let pointer = NSEvent.mouseLocation
    return NSScreen.screens.first(where: { $0.frame.contains(pointer) })
      ?? NSScreen.main ?? NSScreen.screens[0]
  }
}
