import Foundation

enum MiddleAIResourceLocator {
  private static let coreBundleName = "MiddleAI_MiddleAICore.bundle"

  static func url(
    forResource name: String,
    withExtension extensionName: String,
    mainBundle: Bundle = .main
  ) -> URL? {
    // SwiftPM's generated Bundle.module accessor only checks the application-bundle root and
    // the build directory. A normal macOS package stores resource bundles in Contents/Resources,
    // so using that accessor from the packaged app traps before the caller can handle a missing
    // resource. Resolve packaged resources explicitly and keep Bundle.module for SwiftPM builds.
    if mainBundle.bundleURL.pathExtension.lowercased() == "app" {
      guard let resourceDirectory = mainBundle.resourceURL else { return nil }
      return packagedURL(
        forResource: name,
        withExtension: extensionName,
        resourceDirectory: resourceDirectory)
    }

    return Bundle.module.url(forResource: name, withExtension: extensionName)
  }

  static func packagedURL(
    forResource name: String,
    withExtension extensionName: String,
    resourceDirectory: URL
  ) -> URL? {
    let bundleURL = resourceDirectory.appendingPathComponent(coreBundleName, isDirectory: true)
    return Bundle(url: bundleURL)?.url(forResource: name, withExtension: extensionName)
  }
}
