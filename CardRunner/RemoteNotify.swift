import Foundation
import Combine
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

// MARK: - Slack live-progress message formatters

/// Initial message posted when ingest starts (before any bytes are copied).
nonisolated func slackStartText(cardName: String, totalFiles: Int) -> String {
    let fileWord = totalFiles == 1 ? "file" : "files"
    return "⏳ *\(cardName)* — copying \(totalFiles) \(fileWord)\n░░░░░░░░░░ 0% · starting..."
}

/// Progress update message. Percent is 0–100; fills 0–10 blocks.
nonisolated func slackProgressText(cardName: String, totalFiles: Int, percent: Int, mbps: Double) -> String {
    let clamped  = min(max(percent, 0), 100)
    let filled   = clamped / 10
    let empty    = 10 - filled
    let bar      = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
    let mbpsStr  = mbps > 0 ? String(format: "%.0f MB/s", mbps) : "—"
    let fileWord = totalFiles == 1 ? "file" : "files"
    return "⏳ *\(cardName)* — copying \(totalFiles) \(fileWord)\n\(bar) \(clamped)% · \(mbpsStr)"
}

/// Finish message. Provides a complete ingest summary.
nonisolated func slackFinishText(cardName: String,
                                  newFiles: Int,
                                  destRel: String,
                                  durationSec: Int,
                                  avgMBps: Double,
                                  peakMBps: Double,
                                  hardwarePath: String,
                                  verified: Bool,
                                  failed: Bool) -> String {
    if failed {
        return "⚠️ *\(cardName)* — transfer failed. Do not format the card."
    }
    let fileWord = newFiles == 1 ? "file" : "files"
    let mins = durationSec / 60
    let secs = durationSec % 60
    let dur  = mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    var lines = ["✅ *\(cardName)* — \(newFiles) \(fileWord) → \(destRel)"]
    lines.append("⏱ \(dur) · avg \(String(format: "%.0f", avgMBps)) MB/s · peak \(String(format: "%.0f", peakMBps)) MB/s")
    if !hardwarePath.isEmpty {
        lines.append("🔗 \(hardwarePath)")
    }
    if verified {
        lines.append("🔒 Verified")
    }
    return lines.joined(separator: "\n")
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

// MARK: - Slack Bot API helpers

/// Posts a new message to the given channel via the Slack Bot API (`chat.postMessage`).
/// Validates the token prefix and checks `ok: true` in the response body.
/// Returns `(ts, error)` where `ts` is the message timestamp (for later updates).
/// Never blocks the caller — must be called from within a Task or async context.
nonisolated func slackPostMessage(token: String, channel: String, text: String) async -> (ts: String?, error: String?) {
    guard token.hasPrefix("xoxb-") else {
        return (nil, "Invalid Slack bot token (must start with xoxb-)")
    }
    guard let url = URL(string: "https://slack.com/api/chat.postMessage") else {
        return (nil, "Invalid Slack API URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

    let payload: [String: Any] = ["channel": channel, "text": text]
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
        return (nil, "Failed to encode message payload")
    }
    request.httpBody = body

    do {
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, "Failed to decode Slack response")
        }
        guard let ok = json["ok"] as? Bool, ok else {
            let slackError = json["error"] as? String ?? "unknown error"
            return (nil, "Slack error: \(slackError)")
        }
        let ts = json["ts"] as? String
        return (ts, nil)
    } catch {
        return (nil, error.localizedDescription)
    }
}

/// Updates an existing Slack message in place (`chat.update`).
/// Validates token prefix and `ok: true` in response body.
/// Returns `(success, error?)`.
nonisolated func slackUpdateMessage(token: String, channel: String, ts: String, text: String) async -> (Bool, String?) {
    guard token.hasPrefix("xoxb-") else {
        return (false, "Invalid Slack bot token (must start with xoxb-)")
    }
    guard let url = URL(string: "https://slack.com/api/chat.update") else {
        return (false, "Invalid Slack API URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

    let payload: [String: Any] = ["channel": channel, "ts": ts, "text": text]
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
        return (false, "Failed to encode message payload")
    }
    request.httpBody = body

    do {
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, "Failed to decode Slack response")
        }
        guard let ok = json["ok"] as? Bool, ok else {
            let slackError = json["error"] as? String ?? "unknown error"
            return (false, "Slack error: \(slackError)")
        }
        return (true, nil)
    } catch {
        return (false, error.localizedDescription)
    }
}

// MARK: - SlackLiveSession

/// Tracks a single in-flight ingest's live Slack message.
/// One instance per active card (keyed by processID in ContentView). Posts the initial
/// message on `start`, throttled updates via `update`, and a final summary via `finish`.
/// All network calls are dispatched off the main actor via Task {}.
@MainActor
final class SlackLiveSession {
    /// Slack message timestamp returned by `chat.postMessage` — nil until the post succeeds.
    private(set) var ts: String?
    /// Last percent value for which we fired an update, to enforce the ≥10pt throttle.
    private var lastUpdatePercent: Int = -1

    /// Post the initial message. If the post fails, `ts` stays nil and subsequent calls
    /// gracefully no-op. Does NOT block the main actor.
    func start(token: String, channel: String, cardName: String, totalFiles: Int) {
        ts = nil
        lastUpdatePercent = -1
        let text = slackStartText(cardName: cardName, totalFiles: totalFiles)
        Task {
            let (newTs, _) = await slackPostMessage(token: token, channel: channel, text: text)
            await MainActor.run { self.ts = newTs }
        }
    }

    /// Update the live message. No-ops if the initial post failed (`ts == nil`) or if
    /// percent hasn't changed by at least 10 points since the last update.
    func update(token: String, channel: String, cardName: String, totalFiles: Int, percent: Int, mbps: Double) {
        guard let currentTs = ts else { return }
        guard percent - lastUpdatePercent >= 10 else { return }
        lastUpdatePercent = percent
        let text = slackProgressText(cardName: cardName, totalFiles: totalFiles, percent: percent, mbps: mbps)
        Task {
            _ = await slackUpdateMessage(token: token, channel: channel, ts: currentTs, text: text)
        }
    }

    /// Post the final summary. If the initial post succeeded, updates in place; if not,
    /// falls back to posting a fresh message (so the finish always appears). Does NOT
    /// block the main actor.
    func finish(token: String, channel: String,
                cardName: String, newFiles: Int, destRel: String,
                durationSec: Int, avgMBps: Double, peakMBps: Double,
                hardwarePath: String, verified: Bool, failed: Bool) {
        let text = slackFinishText(cardName: cardName, newFiles: newFiles, destRel: destRel,
                                   durationSec: durationSec, avgMBps: avgMBps, peakMBps: peakMBps,
                                   hardwarePath: hardwarePath, verified: verified, failed: failed)
        if let currentTs = ts {
            let capturedTs = currentTs
            Task {
                _ = await slackUpdateMessage(token: token, channel: channel, ts: capturedTs, text: text)
            }
        } else {
            // Initial post failed — post fresh so the operator still sees the outcome.
            Task {
                _ = await slackPostMessage(token: token, channel: channel, text: text)
            }
        }
        ts = nil
        lastUpdatePercent = -1
    }
}

// MARK: - Remote notifier

enum RemoteNotifier {

    /// Fire whichever channels are configured. Empty imessageTo skips iMessage.
    /// slackBotToken + slackChannelId together enable Slack (both must be non-empty).
    /// Does not block the caller — work happens on a background queue.
    static func send(body: String, imessageTo: String, slackBotToken: String, slackChannelId: String) {
        DispatchQueue.global(qos: .utility).async {
            if !imessageTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = sendIMessage(to: imessageTo, body: body)
            }
            let trimToken   = slackBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimChannel = slackChannelId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimToken.isEmpty && !trimChannel.isEmpty {
                Task {
                    _ = await slackPostMessage(token: trimToken, channel: trimChannel, text: body)
                }
            }
        }
    }

    /// Send a test message NOW to whichever channels are configured, calling `completion` on the
    /// main thread with (success, errorMessage?).
    /// Uses async/await throughout to avoid DispatchGroup + Task races.
    static func sendTest(imessageTo: String, slackBotToken: String, slackChannelId: String, completion: @escaping (Bool, String?) -> Void) {
        let trimmedPhone   = imessageTo.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken   = slackBotToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedChannel = slackChannelId.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSlack       = !trimmedToken.isEmpty && !trimmedChannel.isEmpty

        if trimmedPhone.isEmpty && !hasSlack {
            DispatchQueue.main.async {
                completion(false, "No phone number or Slack bot token + channel configured")
            }
            return
        }

        let testBody = "✅ CardRunner test alert — remote notifications are working."

        Task {
            var errors: [String] = []
            var anySuccess = false

            // Run iMessage and Slack in parallel using async let.
            async let imessageResult: (Bool, String?)? = trimmedPhone.isEmpty ? nil : {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        let result = sendIMessage(to: trimmedPhone, body: testBody)
                        continuation.resume(returning: result)
                    }
                }
            }()

            async let slackResult: (String?, String?)? = hasSlack
                ? slackPostMessage(token: trimmedToken, channel: trimmedChannel, text: testBody)
                : nil

            if let (ok, err) = await imessageResult {
                if ok { anySuccess = true }
                else { errors.append("iMessage: \(err ?? "failed")") }
            }

            if let (ts, err) = await slackResult {
                if ts != nil { anySuccess = true }
                else { errors.append("Slack: \(err ?? "failed")") }
            }

            let message: String? = errors.isEmpty ? nil : errors.joined(separator: "; ")
            await MainActor.run {
                completion(anySuccess, anySuccess ? message : (message ?? "Failed to send"))
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
        // Collapse any newline / control character to a space FIRST: AppleScript string
        // literals can't span a raw newline, so an unescaped one would break the parse and
        // silently drop the alert. (Not a security issue — the script is argv-passed, never
        // shell-evaluated — purely robustness against odd card/folder names.) Then escape the
        // two literal-significant characters, backslash before quote so the order is stable.
        let cleaned = String(s.map { ($0.isNewline || ($0.unicodeScalars.first.map { CharacterSet.controlCharacters.contains($0) } ?? false)) ? " " : $0 })
        return cleaned.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
