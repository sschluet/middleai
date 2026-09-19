import Foundation

public enum AudioCaptureFormatPolicy {
  public static func isUsableHardwareInput(
    sampleRate: Double,
    channelCount: UInt32
  ) -> Bool {
    sampleRate.isFinite && sampleRate > 0 && channelCount > 0
  }
}
