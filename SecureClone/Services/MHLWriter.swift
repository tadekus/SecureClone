//
//  MHLWriter.swift
//  SecureClone
//
//  Writes an ASC Media Hash List (.mhl) per destination drive. One MHL
//  describes everything copied to that drive, so it's compatible with the
//  rest of the post pipeline (Silverstack, YoYotta, etc.).
//
//  Format here targets the widely-supported MHL v1.1 structure.
//

import Foundation

enum MHLWriter {

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Build the MHL XML for a single destination.
    /// - Parameters:
    ///   - destinationRoot: the drive root this MHL describes
    ///   - outcomes: per-file results (must contain this destination)
    static func makeXML(
        destinationRoot: URL,
        outcomes: [FileCloneOutcome],
        algorithm: HashAlgorithm,
        startDate: Date,
        finishDate: Date,
        toolName: String = AppInfo.name,
        toolVersion: String = AppInfo.versionString
    ) -> String {
        let host = Host.current().localizedName ?? "unknown"
        let user = NSUserName()

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="1.1">
          <creatorinfo>
            <name>\(escape(user))</name>
            <username>\(escape(user))</username>
            <hostname>\(escape(host))</hostname>
            <tool>\(escape(toolName)) \(escape(toolVersion))</tool>
            <startdate>\(iso.string(from: startDate))</startdate>
            <finishdate>\(iso.string(from: finishDate))</finishdate>
          </creatorinfo>

        """

        for o in outcomes {
            guard let hash = o.destinationHashes[destinationRoot], !hash.isEmpty else { continue }
            let modStr = o.modificationDate.map { iso.string(from: $0) } ?? iso.string(from: finishDate)
            var extra = ""
            if let m = o.destinationMD5[destinationRoot], algorithm != .md5 { extra = "    <md5>\(m)</md5>\n" }
            xml += """
              <hash>
                <file>\(escape(o.relativePath))</file>
                <size>\(o.size)</size>
                <lastmodificationdate>\(modStr)</lastmodificationdate>
                <\(algorithm.mhlElement)>\(hash)</\(algorithm.mhlElement)>
            \(extra)    <hashdate>\(iso.string(from: finishDate))</hashdate>
              </hash>

            """
        }

        xml += "</hashlist>\n"
        return xml
    }

    /// Write the MHL file into the destination root. Returns the file URL.
    @discardableResult
    static func write(
        destinationRoot: URL,
        outcomes: [FileCloneOutcome],
        algorithm: HashAlgorithm,
        startDate: Date,
        finishDate: Date,
        jobName: String
    ) throws -> URL {
        let xml = makeXML(destinationRoot: destinationRoot,
                          outcomes: outcomes,
                          algorithm: algorithm,
                          startDate: startDate,
                          finishDate: finishDate)

        let fileName = "\(ReportNaming.base(jobName: jobName, date: finishDate)).mhl"
        let dir = destinationRoot.appendingPathComponent(SessionStore.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(fileName)
        try xml.data(using: .utf8)!.write(to: fileURL)
        return fileURL
    }

    // MARK: - Helpers

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

}
