//
//  ReportGenerator.swift
//  CardRunner
//
//  Pure, dependency-free report generation for the daily media offload report.
//  DITs previously hand-typed this. Everything here is deterministic and testable —
//  NO SwiftUI / UI coupling. Feed it the history entries the History view is showing
//  (+ a title/date-range label) and it returns CSV and a human-readable summary.
//
//  Footage-safety note: this is a *reporting* layer. It never mutates history; it only
//  formats what already happened. The verification tier is surfaced verbatim from each
//  entry so a "SIZE CHECKED" card can never be misread as "VERIFIED" in the paperwork.
//

import Foundation

nonisolated enum ReportGenerator {

    // MARK: Unit helpers

    /// Bytes → gibibytes, matching the app's 1024-based display convention.
    /// When an entry has no recorded byte count (older entries: `totalBytesTransferred == 0`),
    /// fall back to the avgMBps × durationSec approximation the UI uses elsewhere.
    static func gib(for e: IngestHistoryEntry) -> Double {
        if e.totalBytesTransferred > 0 {
            return Double(e.totalBytesTransferred) / 1_073_741_824.0
        }
        // avgMBps is MB/s (1000-ish MB); approximate transferred MB then → GiB.
        let approxMB = Double(e.avgMBps) * Double(e.durationSec)
        return approxMB / 1024.0
    }

    /// Human duration, e.g. "1h 04m", "3m 12s", "8s".
    static func durationLabel(_ sec: Int) -> String {
        if sec >= 3600 { return "\(sec / 3600)h \(String(format: "%02d", (sec % 3600) / 60))m" }
        if sec >= 60   { return "\(sec / 60)m \(sec % 60)s" }
        return "\(sec)s"
    }

    /// Human verification label for paperwork — reuses the app's own tier vocabulary.
    static func verificationLabel(_ e: IngestHistoryEntry) -> String {
        e.verificationTier.displayText
    }

    // MARK: Totals

    struct Totals {
        var cards: Int = 0
        var files: Int = 0
        var gib: Double = 0
        var durationSec: Int = 0
        /// Session average throughput (MB/s) weighted by duration — a plain mean of
        /// avgMBps would over-weight a tiny fast card against a long slow one.
        var sessionAvgMBps: Int = 0
    }

    static func totals(for entries: [IngestHistoryEntry]) -> Totals {
        var t = Totals()
        t.cards = entries.count
        var weightedMBps = 0.0
        for e in entries {
            t.files += e.newFiles
            t.gib   += gib(for: e)
            t.durationSec += e.durationSec
            weightedMBps  += Double(e.avgMBps) * Double(e.durationSec)
        }
        t.sessionAvgMBps = t.durationSec > 0 ? Int((weightedMBps / Double(t.durationSec)).rounded()) : 0
        return t
    }

    // MARK: CSV

    /// RFC-4180-style field escaping: wrap in quotes if the field contains a comma,
    /// quote, CR or LF, and double any embedded quotes.
    static func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    static let csvHeader = "Date,Time,Card,Files,Size (GB),Avg MB/s,Duration,Verification,Destination,Peak MB/s,Hardware"

    // MARK: Speed / Hardware helpers

    /// Abbreviated hardware path, e.g. "USB 10Gb/s→TB 40Gb/s SSD".
    /// Returns "" when source or dest link info is not available.
    static func hardwarePathLabel(for e: IngestHistoryEntry) -> String {
        let sourceLink = e.sourceLink
        let sourceProtocol = e.sourceProtocol
        let destLink = e.destLink
        let destProtocol = e.destProtocol
        let destMedia = e.destMedia
        guard !sourceLink.isEmpty, !destLink.isEmpty else { return "" }
        var parts: [String] = []
        if !sourceProtocol.isEmpty { parts.append(sourceProtocol) }
        parts.append(sourceLink)
        parts.append("→")
        // Abbreviate "Thunderbolt" → "TB"
        let dp = destProtocol.replacingOccurrences(of: "Thunderbolt", with: "TB")
        if !dp.isEmpty { parts.append(dp) }
        parts.append(destLink)
        if !destMedia.isEmpty { parts.append(destMedia) }
        return parts.joined(separator: " ")
    }

    /// Pure helper: format a hardware path from its components (for testing and UI).
    /// Abbreviates "Thunderbolt" → "TB".
    static func formatHardwarePath(sourceProtocol: String, sourceLink: String,
                                   destProtocol: String, destLink: String,
                                   destMedia: String) -> String {
        guard !sourceLink.isEmpty, !destLink.isEmpty else { return "" }
        var parts: [String] = []
        if !sourceProtocol.isEmpty { parts.append(sourceProtocol) }
        parts.append(sourceLink)
        parts.append("→")
        let dp = destProtocol.replacingOccurrences(of: "Thunderbolt", with: "TB")
        if !dp.isEmpty { parts.append(dp) }
        parts.append(destLink)
        if !destMedia.isEmpty { parts.append(destMedia) }
        return parts.joined(separator: " ")
    }

    private static func csvDateTime(_ d: Date) -> (date: String, time: String) {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter(); tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "HH:mm:ss"
        return (df.string(from: d), tf.string(from: d))
    }

    /// One header row + one row per entry. Empty input → header-only (still valid CSV).
    static func generateCSV(entries: [IngestHistoryEntry]) -> String {
        var lines = [csvHeader]
        for e in entries {
            let dt = csvDateTime(e.timestamp)
            let peakMBps = e.peakMBps
            let cols = [
                dt.date,
                dt.time,
                e.cardName.isEmpty ? "Card" : e.cardName,
                String(e.newFiles),
                String(format: "%.2f", gib(for: e)),
                String(e.avgMBps),
                durationLabel(e.durationSec),
                verificationLabel(e),
                e.destPath,
                peakMBps > 0 ? String(peakMBps) : "",
                hardwarePathLabel(for: e)
            ]
            lines.append(cols.map(csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Human-readable summary (Markdown)

    /// A plain-text / Markdown summary with per-card lines and a totals footer.
    /// `title` is a caller-supplied label such as "Offload Report — 2026-07-31".
    static func generateSummary(entries: [IngestHistoryEntry], title: String) -> String {
        let t = totals(for: entries)
        var out = "# \(title)\n\n"

        if entries.isEmpty {
            out += "_No ingests recorded for this range._\n"
            return out
        }

        out += "## Cards\n\n"
        for e in entries {
            let dt = csvDateTime(e.timestamp)
            let name = e.cardName.isEmpty ? "Card" : e.cardName
            out += "- **\(name)** — \(e.newFiles) \(e.mediaLabel), "
            out += String(format: "%.2f GB", gib(for: e))
            out += " · \(e.avgMBps) MB/s · \(durationLabel(e.durationSec))"
            out += " · \(verificationLabel(e))"
            out += " · \(dt.date) \(dt.time)"
            if !e.destPath.isEmpty { out += "\n    - \(e.destPath)" }
            out += "\n"
        }

        out += "\n## Totals\n\n"
        out += "- Cards: \(t.cards)\n"
        out += "- Files: \(t.files)\n"
        out += String(format: "- Total size: %.2f GB\n", t.gib)
        out += "- Duration: \(durationLabel(t.durationSec))\n"
        out += "- Session avg: \(t.sessionAvgMBps) MB/s\n"
        let sessionPeak = entries.map { $0.peakMBps }.max() ?? 0
        if sessionPeak > 0 { out += "- Session peak: \(sessionPeak) MB/s\n" }
        return out
    }
}
