import AppKit
import SwiftUI

@MainActor enum MiddleAIIconProvider {
  static var image: NSImage {
    if let url = Bundle.main.resourceURL?.appendingPathComponent("MiddleAI-AppIcon.png"),
      let image = NSImage(contentsOf: url)
    {
      return image
    }
    return NSApplication.shared.applicationIconImage
  }
}

struct MiddleAIIconView: View {
  var cornerRadius: CGFloat = 12

  var body: some View {
    Image(nsImage: MiddleAIIconProvider.image)
      .resizable()
      .interpolation(.high)
      .antialiased(true)
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .accessibilityHidden(true)
  }
}
