//
//  SummarySheet.swift
//  SecureClone
//
//  Shown automatically when a job finishes: the full report, with buttons
//  to reveal the report folders in Finder.
//

import SwiftUI
import AppKit

struct SummarySheet: View {
    @ObservedObject var job: CloneJob
    let onClose: () -> Void

    private var success: Bool { job.state == .completed }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: success ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(success ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(success ? "All destinations verified" : "Verification failed")
                        .font(.title2).bold()
                    Text(success ? "Safe to wipe the source card."
                                 : "Do NOT wipe the source. See mismatches below.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollView {
                Text(job.finalReport ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                ForEach(job.reportLocations, id: \.self) { url in
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label(volumeName(url), systemImage: "folder")
                    }
                }
                Spacer()
                Button("Copy report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.finalReport ?? "", forType: .string)
                }
                Button("Close", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 440)
    }

    private func volumeName(_ url: URL) -> String {
        // /Volumes/SSD15/SecureClone_Logs → "SSD15"
        let parts = url.pathComponents
        if let i = parts.firstIndex(of: "Volumes"), i + 1 < parts.count { return parts[i + 1] }
        return url.deletingLastPathComponent().lastPathComponent
    }
}
