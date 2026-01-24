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
        static let safariRetryDelaySeconds: TimeInterval = 0.75
        static let safariQuitTimeout: TimeInterval = 5
    }

    private func waitForAppState(_ app: XCUIApplication, _ state: XCUIApplication.State, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.state == state {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(Defaults.pollIntervalSeconds))
        }
        return false
    }

    private func launchSafari(_ app: XCUIApplication, quitFirst: Bool) -> Bool {
        if quitFirst && app.state != .notRunning {
            app.terminate()
            _ = waitForAppState(app, .notRunning, timeout: Defaults.safariQuitTimeout)
        }
        for _ in 0..<Defaults.safariLaunchRetries {
            app.launch()
            if waitForAppState(app, .runningForeground, timeout: Defaults.safariLaunchTimeout) {
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
        if !launchSafari(app, quitFirst: quitSafari) {
            XCTFail("Failed to launch Safari in foreground.")
            return
        }

        app.typeKey("l", modifierFlags: .command)
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
