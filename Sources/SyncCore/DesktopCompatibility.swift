import Foundation

/// Exact Desktop builds whose native storage and configuration contracts were inspected.
/// Do not replace this with a version range: a newer build may change login or history formats.
public enum DesktopCompatibility {
    public static let verifiedVersions = ["4.29.0", "4.4212.0"]
    public static func supports(_ version: String) -> Bool { verifiedVersions.contains(version) }
    public static var description: String { verifiedVersions.joined(separator: "、") }
}
