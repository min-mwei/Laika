import AppKit
import Foundation
import XCTest

final class LaikaUITests: XCTestCase {
    private struct Defaults {
        static let harnessURL = "http://127.0.0.1:8766/harness.html"
        static let outputPath = "/tmp/laika-automation-output.json"
        static let configPath = "/tmp/laika-automation-config.json"
        static let timeoutSeconds: TimeInterval = 240
        static let pollIntervalSeconds: TimeInterval = 0.5
        static let preflightTimeoutSeconds: TimeInterval = 12
        static let safariLaunchTimeout: TimeInterval = 12
        static let safariLaunchRetries = 3
        static let safariActivateTimeout: TimeInterval = 6
        static let safariActivateRetries = 2
        static let safariRetryDelaySeconds: TimeInterval = 0.75
        static let safariQuitTimeout: TimeInterval = 5
        static let safariWindowTimeout: TimeInterval = 4
        static let safariFocusDelaySeconds: TimeInterval = 0.2
    }

    private func waitForAppState(_ app: XCUIApplication, _ state: XCUIApplication.State, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state == .runningForeground {
                if isSafariActive(app) {
                    return true
                }
            } else if app.state == state {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Defaults.pollIntervalSeconds))
        }
        if state == .runningForeground {
            return isSafariActive(app)
        }
        return app.state == state
    }

    private func waitForWindow(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.state == .notRunning || runningSafariApp() == nil {
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.windows.firstMatch.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Defaults.pollIntervalSeconds))
        }
        return app.windows.firstMatch.exists
    }

    private func waitForSafariRunning(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runningSafariApp() != nil {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Defaults.pollIntervalSeconds))
        }
        return runningSafariApp() != nil
    }

    private func waitForSafariLaunchCompletion(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let app = runningSafariApp(), app.isFinishedLaunching {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Defaults.pollIntervalSeconds))
        }
        return runningSafariApp()?.isFinishedLaunching == true
    }

    private func runningSafariApp() -> NSRunningApplication? {
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first
    }

    private func isSafariFrontmost() -> Bool {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Safari"
    }

    private func isSafariActive(_ app: XCUIApplication) -> Bool {
        if app.state == .runningForeground {
            return true
        }
        guard let safari = runningSafariApp() else {
            return false
        }
        return safari.isActive || isSafariFrontmost()
    }

    private func logSafariState(_ label: String, app: XCUIApplication) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostId = frontmost?.bundleIdentifier ?? "none"
        let frontmostName = frontmost?.localizedName ?? "none"
        let safariApp = runningSafariApp()
        let safariPid = safariApp?.processIdentifier ?? 0
        let safariActive = safariApp?.isActive ?? false
        let safariFinished = safariApp?.isFinishedLaunching ?? false
        print("[LaikaUITests] \(label) state=\(app.state.rawValue) frontmost=\(frontmostName) (\(frontmostId)) safariPid=\(safariPid) safariActive=\(safariActive) safariFinished=\(safariFinished)")
    }

    private func artifactDirectory(for outputPath: String) -> URL? {
        let trimmed = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let base = trimmed.hasSuffix(".json") ? String(trimmed.dropLast(5)) : trimmed
        return URL(fileURLWithPath: base + "-artifacts", isDirectory: true)
    }

    private func sanitizeArtifactLabel(_ label: String) -> String {
        let sanitized = label.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "failure" : trimmed
    }

    private func captureFailureArtifacts(label: String, app: XCUIApplication, outputPath: String) {
        guard let directory = artifactDirectory(for: outputPath) else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return
        }
        let tag = sanitizeArtifactLabel(label)
        let screenshotPath = directory.appendingPathComponent("\(tag).png")
        let hierarchyPath = directory.appendingPathComponent("\(tag).ui.txt")
        let screenshot = XCUIScreen.main.screenshot()
        do {
            try screenshot.pngRepresentation.write(to: screenshotPath)
        } catch {
        }
        if let hierarchyData = app.debugDescription.data(using: .utf8) {
            try? hierarchyData.write(to: hierarchyPath)
        }
        print("[LaikaUITests] Failure artifacts written to \(directory.path)")
    }

    private func harnessHealthURL(from harnessURL: String) -> URL? {
        guard let url = URL(string: harnessURL) else {
            return nil
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/api/health"
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    private func fetchJSON(from url: URL, timeout: TimeInterval) -> [String: Any]? {
        var payload: [String: Any]?
        let semaphore = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data, options: []),
               let dict = json as? [String: Any] {
                payload = dict
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 0.5) == .timedOut {
            task.cancel()
        }
        return payload
    }

    private func waitForAutomationReady(healthURL: URL, timeout: TimeInterval) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastHealth: [String: Any]? = nil
        while Date() < deadline {
            if let health = fetchJSON(from: healthURL, timeout: 2.0) {
                lastHealth = health
                let readyFlag = health["ready"] as? Bool ?? false
                let readyCount = health["readyCount"] as? Int ?? 0
                if readyFlag || readyCount > 0 {
                    return health
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Defaults.pollIntervalSeconds))
        }
        return lastHealth
    }

    private func escapeAppleScriptString(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runAppleScript(_ source: String, label: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            print("[LaikaUITests] AppleScript \(label) failed to compile.")
            return false
        }
        script.executeAndReturnError(&error)
        if let error = error {
            let errorNumber = error[NSAppleScript.errorNumber] as? Int
            let errorMessage = error[NSAppleScript.errorMessage] as? String
            if errorNumber == -1743 {
                print("[LaikaUITests] AppleScript \(label) not authorized. Enable Automation permission for Xcode/xctest to control Safari.")
            } else if let errorMessage = errorMessage {
                let code = errorNumber.map(String.init) ?? "unknown"
                print("[LaikaUITests] AppleScript \(label) error (\(code)): \(errorMessage)")
            } else {
                print("[LaikaUITests] AppleScript \(label) error: \(error)")
            }
            return false
        }
        return true
    }

    private func forceActivateSafari() {
        guard let app = runningSafariApp() else {
            return
        }
        if !app.isFinishedLaunching {
            _ = waitForSafariLaunchCompletion(timeout: Defaults.safariActivateTimeout)
        }
        _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    private func launchSafariViaWorkspace() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    private func activateSafariViaAppleScript() -> Bool {
        guard let app = runningSafariApp() else {
            return false
        }
        if !app.isFinishedLaunching {
            return false
        }
        let script = """
        tell application "Safari"
            activate
            if (count of windows) is 0 then
                make new document
            end if
        end tell
        """
        return runAppleScript(script, label: "activate")
    }

    private func activateSafari(_ app: XCUIApplication) -> Bool {
        if isSafariActive(app) {
            return true
        }
        for _ in 0..<Defaults.safariActivateRetries {
            logSafariState("activate attempt", app: app)
            app.activate()
            forceActivateSafari()
            if waitForAppState(app, .runningForeground, timeout: Defaults.safariActivateTimeout) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Defaults.safariRetryDelaySeconds))
        }
        if !isSafariActive(app) {
            logSafariState("activate failed", app: app)
        }
        return isSafariActive(app)
    }

    private func ensureSafariWindow(_ app: XCUIApplication) -> Bool {
        if runningSafariApp() == nil {
            return false
        }
        if !activateSafari(app) {
            return false
        }
        app.typeKey("n", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(Defaults.safariFocusDelaySeconds))
        if waitForWindow(app, timeout: Defaults.safariWindowTimeout) {
            return true
        }
        if activateSafariViaAppleScript() {
            return waitForWindow(app, timeout: Defaults.safariWindowTimeout)
        }
        return false
    }

    private func openSafariURLViaWorkspace(_ url: String) -> Bool {
        guard let openURL = URL(string: url) else {
            return false
        }
        guard let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([openURL], withApplicationAt: safariURL, configuration: configuration, completionHandler: nil)
        if waitForSafariRunning(timeout: Defaults.safariLaunchTimeout) {
            return waitForSafariLaunchCompletion(timeout: Defaults.safariActivateTimeout)
        }
        return false
    }

    private func openSafariURLViaKeyboard(_ app: XCUIApplication, _ url: String) -> Bool {
        if !ensureSafariWindow(app) {
            return false
        }
        app.typeKey("l", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(Defaults.safariFocusDelaySeconds))
        app.typeText(url)
        app.typeKey(.return, modifierFlags: [])
        return true
    }

    private func openSafariURL(_ app: XCUIApplication, _ url: String) -> Bool {
        if openSafariURLViaWorkspace(url) {
            return true
        }
        if openSafariURLViaKeyboard(app, url) {
            return true
        }
        return openSafariURLViaAppleScript(url)
    }

    private func openSafariURLViaAppleScript(_ url: String) -> Bool {
        guard URL(string: url) != nil else {
            return false
        }
        if runningSafariApp() == nil {
            launchSafariViaWorkspace()
            _ = waitForSafariRunning(timeout: Defaults.safariLaunchTimeout)
        }
        let didFinishLaunching = waitForSafariLaunchCompletion(timeout: Defaults.safariActivateTimeout)
        if runningSafariApp() == nil || !didFinishLaunching {
            return false
        }
        let escapedURL = escapeAppleScriptString(url)
        let script = """
        tell application "Safari"
            activate
            if (count of windows) is 0 then
                make new document
            end if
            open location "\(escapedURL)"
        end tell
        """
        return runAppleScript(script, label: "open_location")
    }

    private func closeSafariWindowsViaAppleScript() {
        guard runningSafariApp()?.isFinishedLaunching == true else {
            return
        }
        let script = """
        tell application "Safari"
            if (count of windows) is greater than 0 then
                close every window
            end if
        end tell
        """
        _ = runAppleScript(script, label: "close_windows")
    }

    private func launchSafari(_ app: XCUIApplication, quitFirst: Bool) -> Bool {
        if quitFirst && app.state != .notRunning {
            app.terminate()
            _ = waitForAppState(app, .notRunning, timeout: Defaults.safariQuitTimeout)
            if runningSafariApp() != nil {
                runningSafariApp()?.forceTerminate()
                _ = waitForAppState(app, .notRunning, timeout: Defaults.safariQuitTimeout)
            }
        }
        for _ in 0..<Defaults.safariLaunchRetries {
            logSafariState("launch attempt", app: app)
            if runningSafariApp() != nil {
                if !waitForSafariLaunchCompletion(timeout: Defaults.safariActivateTimeout) {
                    app.terminate()
                    _ = waitForAppState(app, .notRunning, timeout: Defaults.safariQuitTimeout)
                    RunLoop.current.run(until: Date().addingTimeInterval(Defaults.safariRetryDelaySeconds))
                    continue
                }
                if ensureSafariWindow(app) {
                    return true
                }
            } else {
                launchSafariViaWorkspace()
                if waitForSafariRunning(timeout: Defaults.safariLaunchTimeout) {
                    if !waitForSafariLaunchCompletion(timeout: Defaults.safariActivateTimeout) {
                        app.terminate()
                        _ = waitForAppState(app, .notRunning, timeout: Defaults.safariQuitTimeout)
                        RunLoop.current.run(until: Date().addingTimeInterval(Defaults.safariRetryDelaySeconds))
                        continue
                    }
                    if ensureSafariWindow(app) {
                        return true
                    }
                }
            }
            app.terminate()
            _ = waitForAppState(app, .notRunning, timeout: Defaults.safariQuitTimeout)
            RunLoop.current.run(until: Date().addingTimeInterval(Defaults.safariRetryDelaySeconds))
        }
        return false
    }

    func testAutomationScenario() throws {
        let env = ProcessInfo.processInfo.environment
        var harnessURL = Defaults.harnessURL
        var outputPath = Defaults.outputPath
        var timeout = Defaults.timeoutSeconds
        var quitSafari = false

        if let data = try? Data(contentsOf: URL(fileURLWithPath: Defaults.configPath)),
           let json = try? JSONSerialization.jsonObject(with: data, options: []),
           let config = json as? [String: Any] {
            if let url = config["harnessURL"] as? String, !url.isEmpty {
                harnessURL = url
            }
            if let path = config["outputPath"] as? String, !path.isEmpty {
                outputPath = path
            }
            if let timeoutValue = config["timeoutSeconds"] as? Double, timeoutValue > 0 {
                timeout = timeoutValue
            }
            if let quitValue = config["quitSafari"] as? Bool {
                quitSafari = quitValue
            }
        }

        if let url = env["LAIKA_AUTOMATION_URL"], !url.isEmpty {
            harnessURL = url
        }
        if let path = env["LAIKA_AUTOMATION_OUTPUT"], !path.isEmpty {
            outputPath = path
        }
        if let timeoutValue = TimeInterval(env["LAIKA_AUTOMATION_TIMEOUT"] ?? ""), timeoutValue > 0 {
            timeout = timeoutValue
        }
        if let quitValue = env["LAIKA_AUTOMATION_QUIT_SAFARI"]?.lowercased() {
            if quitValue == "1" || quitValue == "true" || quitValue == "yes" {
                quitSafari = true
            } else if quitValue == "0" || quitValue == "false" || quitValue == "no" {
                quitSafari = false
            }
        }

        if FileManager.default.fileExists(atPath: outputPath) {
            try? FileManager.default.removeItem(atPath: outputPath)
        }

        let app = XCUIApplication(bundleIdentifier: "com.apple.Safari")
        defer {
            if quitSafari {
                app.terminate()
                _ = waitForAppState(app, .notRunning, timeout: Defaults.safariQuitTimeout)
            } else {
                closeSafariWindowsViaAppleScript()
            }
        }
        if !launchSafari(app, quitFirst: quitSafari) {
            captureFailureArtifacts(label: "launch_failed", app: app, outputPath: outputPath)
            XCTFail("Failed to launch Safari.")
            return
        }
        if !activateSafari(app) {
            captureFailureArtifacts(label: "activate_failed", app: app, outputPath: outputPath)
            XCTFail("Failed to activate Safari.")
            return
        }
        _ = waitForWindow(app, timeout: Defaults.safariWindowTimeout)

        if !openSafariURL(app, harnessURL) {
            captureFailureArtifacts(label: "open_url_failed", app: app, outputPath: outputPath)
            XCTFail("Failed to open harness URL in Safari.")
            return
        }

        if let healthURL = harnessHealthURL(from: harnessURL) {
            let health = waitForAutomationReady(healthURL: healthURL, timeout: Defaults.preflightTimeoutSeconds)
            let readyFlag = health?["ready"] as? Bool ?? false
            let readyCount = health?["readyCount"] as? Int ?? 0
            if !readyFlag && readyCount == 0 {
                let lastEvent = health?["lastEvent"] as? String ?? "none"
                captureFailureArtifacts(label: "bridge_ready_timeout", app: app, outputPath: outputPath)
                XCTFail("Bridge preflight timed out. Enable the Laika extension for localhost, open the app once, and ensure automation is enabled. Last event: \(lastEvent).")
                return
            }
        } else {
            print("[LaikaUITests] Unable to derive harness health URL; skipping preflight.")
        }

        let deadline = Date().addingTimeInterval(timeout)
        var outputJSON: Any?
        var lastError: Error?

        while Date() < deadline {
            if FileManager.default.fileExists(atPath: outputPath) {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
                    outputJSON = try JSONSerialization.jsonObject(with: data, options: [])
                    break
                } catch {
                    lastError = error
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Defaults.pollIntervalSeconds))
        }

        guard let payload = outputJSON as? [String: Any] else {
            let suffix = lastError.map { " Last error: \($0)." } ?? ""
            captureFailureArtifacts(label: "output_timeout", app: app, outputPath: outputPath)
            XCTFail("Timed out waiting for automation output at \(outputPath).\(suffix)")
            return
        }

        if let error = payload["error"] as? String, !error.isEmpty {
            captureFailureArtifacts(label: "automation_error", app: app, outputPath: outputPath)
            XCTFail("Automation error: \(error)")
        }
    }
}
