import Foundation
import Security

/// Whether this copy of Sorl was signed with the CloudKit entitlement. Ad-hoc builds have no entitlements, and any
/// CloudKit object (other than `CKRecord`) would crash them, so `CloudSync` checks this before creating one.
enum ICloudEntitlement {
    static let hasCloudKit: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        guard let services = value as? [String] else { return false }
        return services.contains("CloudKit")
    }()
}
