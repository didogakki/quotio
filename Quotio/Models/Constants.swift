//
//  Constants.swift
//  Quotio
//
//  App-wide constants and configuration values.
//

import Foundation


/// Runtime identity for storage, keychain, logging, and build-flavor separation.
///
/// Release intentionally keeps the historical identifiers so existing users keep
/// their Application Support data and keychain items. Non-release bundle IDs use
/// isolated app support storage while keychain services are derived from the
/// active bundle identifier.
nonisolated enum AppIdentity {
    static let releaseBundleIdentifier = "dev.quotio.desktop"
    static let releaseAppSupportDirectoryName = "Quotio"
    static let debugAppSupportDirectoryName = "Quotio-Debug"

    static var bundleIdentifier: String {
        let value = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? releaseBundleIdentifier : value
    }

    static var isReleaseBundle: Bool {
        bundleIdentifier == releaseBundleIdentifier
    }

    static var appSupportDirectoryName: String {
        isReleaseBundle ? releaseAppSupportDirectoryName : debugAppSupportDirectoryName
    }

    static var loggingSubsystem: String {
        bundleIdentifier
    }

    static var remoteManagementKeychainService: String {
        "\(bundleIdentifier).remote-management"
    }

    static var localManagementKeychainService: String {
        "\(bundleIdentifier).local-management"
    }

    static var warpKeychainService: String {
        "\(bundleIdentifier).warp"
    }

    static func applicationSupportDirectoryURL(fileManager: FileManager = .default) -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory not found")
        }
        return appSupport.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }

    static func dispatchQueueLabel(_ suffix: String) -> String {
        "\(bundleIdentifier).\(suffix)"
    }
}

/// App-wide constants
enum AppConstants {
    
    // MARK: - Proxy Version Management
    
    /// Maximum number of proxy versions to keep installed.
    /// Older versions beyond this limit will be automatically deleted after upgrades.
    static let maxInstalledVersions = 3
    
    // MARK: - Network
    
    /// Default proxy port
    static let defaultProxyPort: UInt16 = 17080
    
    // MARK: - UI
    
    /// Maximum number of items to display in menu bar
    static let maxMenuBarItems = 3
}
