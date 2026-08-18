//
//  AppUpdateChecker.swift
//  mimika-ai-voice-studio
//
//  Detects when a newer version is live on the App Store using Apple's public iTunes Lookup endpoint — unauthenticated, no API key, no backend.
//
//  Users with automatic updates off never learn a release shipped, and Mac App Store apps cannot self-update, so the badge deep-links to the product page.
//
//  Fails silently by design: no network, a malformed response, or an app that isn't published yet all resolve to "no badge" rather than an error surface. Nothing here is on the engine-load path.
//

import Foundation
import Observation
import OSLog

// MARK: - File-scoped logger

private let logger = Logger(subsystem: "com.slaughters85j.pocket-tts-macos", category: "AppUpdateChecker")

// MARK: - AppUpdateChecker

/// Compares the running build against the version the App Store reports as live.
@MainActor
@Observable
final class AppUpdateChecker {

    // MARK: Shared instance

    static let shared = AppUpdateChecker()

    // MARK: Observable state

    /// True when the store reports a newer version the user has not dismissed.
    private(set) var updateAvailable = false

    /// Version currently live on the App Store (e.g. "1.5.12"); empty until a check succeeds.
    private(set) var storeVersion = ""

    /// Product page URL returned by the lookup endpoint.
    private(set) var storeURL: URL?

    // MARK: Constants

    /// Namespaced to match the app's other UserDefaults keys (see `ReviewPromptGate.Keys`).
    private enum Keys {
        static let dismissedVersion = "com.slaughtersj.mimika-ai-voice-studio.update.dismissedVersion"
        static let lastCheck = "com.slaughtersj.mimika-ai-voice-studio.update.lastCheck"
    }

    /// Minimum gap between network checks. The lookup endpoint is edge-cached and trails real releases by hours, so polling more aggressively buys nothing.
    private static let minimumCheckInterval: TimeInterval = 6 * 60 * 60

    private init() {}

    // MARK: Update check

    /// Queries the App Store and refreshes `updateAvailable`.
    /// - Parameter force: bypasses the throttle, for an explicit user-initiated check.
    func checkForUpdate(force: Bool = false) async {
        guard force || shouldCheck() else { return }
        guard
            let bundleID = Bundle.main.bundleIdentifier,
            let request = lookupRequest(bundleID: bundleID)
        else { return }

        guard
            let (data, _) = try? await URLSession.shared.data(for: request),
            let response = try? JSONDecoder().decode(LookupResponse.self, from: data),
            let result = response.results.first
        else {
            logger.debug("Update check did not complete (offline, throttled upstream, or unpublished)")
            return
        }

        UserDefaults.standard.set(Date(), forKey: Keys.lastCheck)

        storeVersion = result.version
        storeURL = URL(string: result.trackViewUrl)

        let dismissed = UserDefaults.standard.string(forKey: Keys.dismissedVersion) ?? ""
        let isNewer = Self.isVersion(result.version, newerThan: Bundle.main.appVersion)
        updateAvailable = isNewer && result.version != dismissed

        let local = Bundle.main.appVersion
        logger.debug(
            "Update check: store=\(result.version, privacy: .public) local=\(local, privacy: .public) newer=\(isNewer)"
        )
    }

    /// Hides the badge until a version newer than the current store version ships.
    func dismissCurrentUpdate() {
        UserDefaults.standard.set(storeVersion, forKey: Keys.dismissedVersion)
        updateAvailable = false
    }

    // MARK: App Store link

    /// Product page link on the native store scheme, so the App Store app opens directly instead of bouncing the user through a browser.
    ///
    /// Falls back to `ReviewPromptGate.productPageURL` so the link is never dead before the first lookup succeeds. See that property for the slug-path and `action=write-review` constraints.
    var appStoreDeepLink: URL {
        guard let storeURL else { return ReviewPromptGate.productPageURL }
        return Self.nativeScheme(for: storeURL)
    }

    /// Rewrites an `https` App Store URL onto the platform's native store scheme, preserving path and query. Returns the input unchanged if the URL cannot be decomposed.
    static func nativeScheme(for url: URL) -> URL {
        #if os(macOS)
        let scheme = "macappstore"
        #else
        let scheme = "itms-apps"
        #endif
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        return components?.url ?? url
    }

    // MARK: Helpers

    /// True when no check has run yet, or the throttle window has elapsed.
    private func shouldCheck() -> Bool {
        guard let last = UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date else { return true }
        return Date().timeIntervalSince(last) >= Self.minimumCheckInterval
    }

    private func lookupRequest(bundleID: String) -> URLRequest? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            // Cache-buster: the endpoint is aggressively edge-cached and will otherwise keep serving a
            // stale version for hours after a release goes live.
            URLQueryItem(name: "cb", value: String(Int(Date().timeIntervalSince1970))),
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        return request
    }

    /// Numeric version comparison. A plain string compare is wrong here: "1.5.10" sorts BEFORE "1.5.9"
    /// lexically, which would silently hide the badge at 1.5.10.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    // MARK: Lookup response

    /// Minimal shape of the iTunes Lookup payload — only the fields the badge needs.
    private struct LookupResponse: Decodable {
        struct Result: Decodable {
            let version: String
            let trackViewUrl: String
        }

        let results: [Result]
    }
}

// MARK: - Bundle version strings

extension Bundle {
    /// Marketing version (`CFBundleShortVersionString`), e.g. "1.5.11".
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// Build number (`CFBundleVersion`).
    var appBuild: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
