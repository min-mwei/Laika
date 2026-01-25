import AppKit
import XCTest

final class LaikaUITests: XCTestCase {
    private struct Defaults {
        static let harnessURL = "http://127.0.0.1:8766/harness.html"
        static let outputPath = "/tmp/laika-automation-output.json"
        static let configPath = "/tmp/laika-automation-config.json"
        static let timeoutSeconds: TimeInterval = 240
        static let pollIntervalSeconds: TimeInterval = 0.5
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
            if app.state == state {
                return true
            }
            if state == .runningForeground && isSafariFrontmost() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Defaults.pollIntervalSeconds))
        }
        return false
    }

    private func waitForWindow(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        return app.windows.firstMatch.waitForExistence(timeout: timeout)
    }

    private func runningSafariApp() -> NSRunningApplication? {
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first
    }

    private func isSafariFrontmost() -> Bool {
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Safari"
    }

    private func forceActivateSafari() {
        guard let app = runningSafariApp() else {
            return
        }
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        activateSafariViaAppleScript()
    }

    private func launchSafariViaWorkspace() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }

    private func activateSafariViaAppleScript() {
        let script = """
        tell application "System Events"
            set frontmost of process "Safari" to true
        end tell
        """
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    private func activateSafari(_ app: XCUIApplication) -> Bool {
        if app.state == .runningForeground {
            return true
        }
        if isSafariFrontmost() {
            return true
        }
        for _ in 0..<Defaults.safariActivateRetries {
            forceActivateSafari()
            if waitForAppState(app, .runningForeground, timeout: Defaults.safariActivateTimeout) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Defaults.safariRetryDelaySeconds))
        }
        return app.state == .runningForeground
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
            if app.state == .runningBackground {
                if activateSafari(app) {
                    _ = waitForWindow(app, timeout: Defaults.safariWindowTimeout)
                    return true
                }
            }
            if app.state == .runningForeground {
                _ = waitForWindow(app, timeout: Defaults.safariWindowTimeout)
                return true
            }
            if runningSafariApp() != nil {
                forceActivateSafari()
            } else {
                launchSafariViaWorkspace()
            }
            if waitForAppState(app, .runningForeground, timeout: Defaults.safariLaunchTimeout) || activateSafari(app) {
                _ = waitForWindow(app, timeout: Defaults.safariWindowTimeout)
                return true
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
            }
        }
        if !launchSafari(app, quitFirst: quitSafari) {
            XCTFail("Failed to launch Safari in foreground.")
            return
        }
        if !activateSafari(app) {
            XCTFail("Failed to activate Safari in foreground.")
            return
        }
        _ = waitForWindow(app, timeout: Defaults.safariWindowTimeout)

        app.typeKey("l", modifierFlags: .command)
        RunLoop.current.run(until: Date().addingTimeInterval(Defaults.safariFocusDelaySeconds))
        app.typeText(harnessURL)
        app.typeKey(.return, modifierFlags: [])

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
            XCTFail("Timed out waiting for automation output at \(outputPath).\(suffix)")
            return
        }

        if let error = payload["error"] as? String, !error.isEmpty {
            XCTFail("Automation error: \(error)")
        }
    }
}
