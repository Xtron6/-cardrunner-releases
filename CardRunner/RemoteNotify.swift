import Foundation
import IOKit

// MARK: - Pure gating logic

/// Returns true only when remote alerts are enabled AND the Mac has been idle at least
/// `thresholdMinutes`. thresholdMinutes <= 0 means "always when enabled".
nonisolated func shouldSendRemoteAlert(enabled: Bool, idleSeconds: TimeInterval, thresholdMinutes: Int) -> Bool {
    guard enabled else { return false }
    if thresholdMinutes <= 0 { return true }
    let thresholdSeconds = TimeInterval(thresholdMinutes) * 60
    return idleSeconds >= thresholdSeconds
}

/// Composite delivery gate. Fires only when a destination is configured, and then either:
///   • `afkMode` is ON — the manual "I'm away" override, a GUARANTEED send that bypasses idle, or
///   • the automatic away gate passes (`awayEnabled` && idle >= threshold).
/// Keeps `shouldSendRemoteAlert` intact (AFK is layered on top, not folded in).
nonisolated func shouldDeliverRemoteAlert(afkMode: Bool,
                                          awayEnabled: Bool,
                                          idleSeconds: TimeInterval,
                                          thresholdMinutes: Int,
                                          hasDestination: Bool) -> Bool {
    guard hasDestination else { return false }
    if afkMode { return true }
    return shouldSendRemoteAlert(enabled: awayEnabled, idleSeconds: idleSeconds, thresholdMinutes: thresholdMinutes)
}

// MARK: - Pure message formatter

/// Formats the alert body. failed==true produces a failure alert; otherwise a success alert.
/// Omits the verified suffix when verified==false.
nonisolated func remoteAlertBody(cardName: String, newFiles: Int, destRel: String, verified: Bool, failed: Bool) -> String {
    if failed {
        return "⚠️ Transfer failed — \(cardName) not fully copied. Do not format the card."
    }
    let fileWord = newFiles == 1 ? "file" : "files"
    var body = "✅ \(cardName): \(newFiles) \(fileWord) → \(destRel)"
    if verified {
        body += " · verified"
    }
    return body
}

// MARK: - System idle time

/// Live read of system idle time via IOKit HIDIdleTime. Returns 0 on any failure (fail-open:
/// 0 idle means "user is active" so we DON'T buzz the phone unnecessarily).
nonisolated func systemIdleSeconds() -> TimeInterval {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator) == KERN_SUCCESS else { return 0 }
    defer { IOObjectRelease(iterator) }
    let entry = IOIteratorNext(iterator)
    guard entry != 0 else { return 0 }
    defer { IOObjectRelease(entry) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = props?.takeRetainedValue() as? [String: Any],
          let idleNs = dict["HIDIdleTime"] as? UInt64 else { return 0 }
    return TimeInterval(idleNs) / 1_000_000_000.0
}

// MARK: - Remote notifier

enum RemoteNotifier {

    /// Fire whichever channels are configured. Empty imessageTo skips iMessage; empty slackWebhook
    /// skips Slack. Does not block the caller — work happens on a background queue.
    static func send(body: String, imessageTo: String, slackWebhook: String) {
        DispatchQueue.global(qos: .utility).async {
            if !imessageTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = sendIMessage(to: imessageTo, body: body)
            }
            if !slackWebhook.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sendSlack(webhook: slackWebhook, body: body) { _, _ in }
            }
        }
    }

    /// Send a test message NOW to whichever channels are configured, calling `completion` on the
    /// main thread with (success, errorMessage?).
    static func sendTest(imessageTo: String, slackWebhook: String, completion: @escaping (Bool, String?) -> Void) {
        let trimmedPhone = imessageTo.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSlack = slackWebhook.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedPhone.isEmpty && trimmedSlack.isEmpty {
            DispatchQueue.main.async {
                completion(false, "No phone number or Slack webhook configured")
            }
            return
        }

        let testBody = "✅ CardRunner test alert — remote notifications are working."

        DispatchQueue.global(qos: .utility).async {
            var errors: [String] = []
            var anySuccess = false
            let group = DispatchGroup()

            if !trimmedPhone.isEmpty {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let (ok, err) = sendIMessage(to: trimmedPhone, body: testBody)
                    if ok {
                        anySuccess = true
                    } else {
                        errors.append("iMessage: \(err ?? "failed")")
                    }
                    group.leave()
                }
            }

            if !trimmedSlack.isEmpty {
                group.enter()
                sendSlack(webhook: trimmedSlack, body: testBody) { ok, err in
                    if ok {
                        anySuccess = true
                    } else {
                        errors.append("Slack: \(err ?? "failed")")
                    }
                    group.leave()
                }
            }

            group.wait()

            let success = anySuccess
            let message: String? = errors.isEmpty ? nil : errors.joined(separator: "; ")
            DispatchQueue.main.async {
                completion(success, success ? (errors.isEmpty ? nil : message) : (message ?? "Failed to send"))
            }
        }
    }

    // MARK: - iMessage

    /// Sends via AppleScript through osascript. NOTE: this requires the user to grant
    /// Automation control of Messages — a system prompt appears on first send. That is
    /// expected behavior, not a bug.
    private static func sendIMessage(to recipient: String, body: String) -> (Bool, String?) {
        let escapedRecipient = escapeForAppleScript(recipient)
        let escapedBody = escapeForAppleScript(body)
        let script = """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to participant "\(escapedRecipient)" of targetService
            send "\(escapedBody)" to targetBuddy
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, "Failed to launch osascript: \(error.localizedDescription)")
        }

        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrString = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 || !stderrString.isEmpty {
            return (false, stderrString.isEmpty ? "osascript exited with status \(process.terminationStatus)" : stderrString)
        }
        return (true, nil)
    }

    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Slack

    private static func sendSlack(webhook: String, body: String, completion: @escaping (Bool, String?) -> Void) {
        guard webhook.hasPrefix("https://hooks.slack.com/") else {
            completion(false, "Invalid Slack webhook URL")
            return
        }
        guard let url = URL(string: webhook) else {
            completion(false, "Invalid Slack webhook URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ["text": body]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(false, "Failed to encode message")
            return
        }
        request.httpBody = jsonData

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                completion(false, error.localizedDescription)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(false, "No response from Slack")
                return
            }
            if (200...299).contains(httpResponse.statusCode) {
                completion(true, nil)
            } else {
                completion(false, "Slack returned status \(httpResponse.statusCode)")
            }
        }
        task.resume()
    }
}
