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
    @EnvironmentObject var vm: CloneViewModel
    @ObservedObject var job: CloneJob
    let onClose: () -> Void

    private var success: Bool { job.state == .completed && job.mode.hashes }
    private var quick: Bool { job.mode == .quick && job.kind == .offload }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: quick ? "exclamationmark.triangle.fill" : success ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(quick ? .orange : success ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(quick ? "Copied — not verified" : success ? "All destinations verified (\(job.mode.rawValue))" : "Verification failed")
                        .font(.title2).bold()
                    Text(quick ? "Quick mode makes no checksums. Keep the card until a verified copy exists."
                         : success ? "Safe to wipe the source card."
                                   : "Do NOT wipe the source. See the problems below.")
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
                if job.kind == .offload && job.source.isRemovable && success {
                    Button {
                        vm.eject(job.source)
                        onClose()
                    } label: { Label("Eject \(job.source.name)", systemImage: "eject") }
                }
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
