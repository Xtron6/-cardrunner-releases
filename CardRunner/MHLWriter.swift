//  MHLWriter.swift — CardRunner
//  Standalone ASC MHL sidecar generator. Zero ContentView imports — takes a list of
//  hash entries and produces valid ASC MHL XML. The hashes come from cardcopy's
//  VERIFY_OK lines (inline SHA-256), NOT from the shell's MD5 verify_transfer().
import Foundation

nonisolated struct MHLHashEntry {
    let relativePath: String
    let sha256Hex: String
    let fileSize: Int64
    let modificationDate: Date
}

nonisolated enum MHLWriter {
    /// XML-escape a string for safe embedding in element text content.
    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&",  with: "&amp;")
         .replacingOccurrences(of: "<",  with: "&lt;")
         .replacingOccurrences(of: ">",  with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Generate an ASC MHL v1.1 XML string from hash entries.
    ///
    /// This emits the original ASC / Pomfort Media Hash List format (`version="1.1"`),
    /// which is widely readable by YoYotta, Silverstack and ShotPut Pro. The body
    /// structure intentionally matches the v1.1 schema exactly:
    ///   - `<creatorinfo>` carries `<name>`, `<username>`, `<hostname>`, `<tool>`
    ///     (name + version) and `<startdate>`/`<finishdate>`.
    ///   - Each `<hash>` carries `<file>` (relative path), `<size>` (bytes),
    ///     `<lastmodificationdate>`, `<sha256>` (lowercase hex) and `<hashdate>`.
    ///
    /// The version string ("1.1") deliberately matches the element structure below —
    /// we do NOT emit v2.0-labelled markup with v1.x children.
    static func generateXML(entries: [MHLHashEntry], creatorInfo: String = "CardRunner",
                             version: String = "1.9.0") -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let now = iso.string(from: Date())

        let userName = NSUserName()
        let hostName = ProcessInfo.processInfo.hostName
        let tool = "\(creatorInfo) \(version)"

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<hashlist version=\"1.1\">\n"
        xml += "  <creatorinfo>\n"
        xml += "    <name>\(xmlEscape(creatorInfo))</name>\n"
        xml += "    <username>\(xmlEscape(userName))</username>\n"
        xml += "    <hostname>\(xmlEscape(hostName))</hostname>\n"
        xml += "    <tool>\(xmlEscape(tool))</tool>\n"
        xml += "    <startdate>\(now)</startdate>\n"
        xml += "    <finishdate>\(now)</finishdate>\n"
        xml += "  </creatorinfo>\n"

        for entry in entries {
            xml += "  <hash>\n"
            xml += "    <file>\(xmlEscape(entry.relativePath))</file>\n"
            xml += "    <size>\(entry.fileSize)</size>\n"
            xml += "    <lastmodificationdate>\(iso.string(from: entry.modificationDate))</lastmodificationdate>\n"
            xml += "    <sha256>\(entry.sha256Hex.lowercased())</sha256>\n"
            xml += "    <hashdate>\(now)</hashdate>\n"
            xml += "  </hash>\n"
        }

        xml += "</hashlist>\n"
        return xml
    }

    /// Write an ASC MHL sidecar file to <directory>/ASC_MHL/<cardName>_<timestamp>.mhl.
    /// Returns the URL of the written file, or throws on I/O failure.
    @discardableResult
    static func writeMHL(entries: [MHLHashEntry], creatorInfo: String = "CardRunner",
                          version: String = "1.9.0",
                          to directory: URL, cardName: String) throws -> URL {
        let mhlDir = directory.appendingPathComponent("ASC_MHL", isDirectory: true)
        try FileManager.default.createDirectory(at: mhlDir, withIntermediateDirectories: true)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss"
        fmt.timeZone = TimeZone.current
        let timestamp = fmt.string(from: Date())
        let safeName = cardName.replacingOccurrences(of: "/", with: "_")
        let filename = "\(safeName)_\(timestamp).mhl"

        let fileURL = mhlDir.appendingPathComponent(filename)
        let xml = generateXML(entries: entries, creatorInfo: creatorInfo, version: version)
        try xml.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
