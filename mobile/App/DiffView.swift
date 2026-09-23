import SwiftUI
import ZeronClient
import ZeronGenerated

/// Read-only working tree changes: file summary, then the raw patch.
struct DiffView: View {
    let chat: Chat

    @Environment(AppModel.self) var app
    @Environment(\.dismiss) var dismiss
    @State var diff: CheckoutDiff?
    @State var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let diff {
                    List {
                        Section {
                            ForEach(diff.files, id: \.path) { file in
                                HStack {
                                    Text(file.path)
                                        .font(.footnote.monospaced())
                                        .lineLimit(1)
                                        .truncatedMiddle()
                                    Spacer()
                                    DiffStat(additions: file.additions, deletions: file.deletions)
                                }
                            }
                        } header: {
                            DiffStat(additions: diff.additions, deletions: diff.deletions)
                        }
                        Section {
                            PatchText(patch: diff.patch)
                            if diff.truncated {
                                Label("Truncated", systemImage: "ellipsis")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.plain)
                } else if failed {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Could not load changes")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(chat.branch ?? "Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Close")
            }
        }
        .task {
            guard let cwd = chat.cwd else { failed = true; return }
            do {
                diff = try await app.connection.call(Rpc.getCheckoutDiff, CheckoutDiffParams(cwd: cwd, chatId: chat.id, targetDeviceId: chat.deviceId))
            } catch {
                failed = true
            }
        }
    }
}

struct PatchText: View {
    let patch: String

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(patch.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .foregroundStyle(color(for: line))
                }
            }
            .font(.caption.monospaced())
            .selectable()
        }
    }

    private func color(for line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        if line.hasPrefix("@@") { return .blue }
        return .primary
    }
}
