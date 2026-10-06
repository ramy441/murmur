import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.contentView = NSHostingView(rootView: HistoryView(close: { [weak window] in window?.close() }))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 400, height: 400)
        window.setFrameAutosaveName("MurmurHistoryWindowV2")
        window.center()
        return window
    }
}

struct HistoryView: View {
    let close: () -> Void

    @State private var entries: [HistoryEntry] = []
    @State private var query = ""
    @State private var copiedID: Int?
    @State private var showToast = false
    @State private var toastTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private var filtered: [HistoryEntry] {
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search transcripts", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                }
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 8)

            Divider()

            if entries.isEmpty {
                emptyState("No transcripts yet")
            } else if filtered.isEmpty {
                emptyState("No matches")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // non-lazy so scrollTo has real row geometry to anchor against, not an estimate
                        VStack(spacing: 0) {
                            ForEach(filtered) { entry in
                                HistoryRow(entry: entry, isCopied: copiedID == entry.id, copy: { copy(entry) })
                                Divider()
                            }
                        }
                    }
                    .onChange(of: query) { _, _ in
                        guard let first = filtered.first else { return }
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showToast {
                toast
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(minWidth: 360, minHeight: 320)
        .onExitCommand { close() }
        .onAppear {
            searchFocused = true
            reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reload()
        }
    }

    private func reload() {
        entries = HistoryStore.load()
    }

    private var countLabel: String {
        query.isEmpty ? "\(entries.count) transcripts" : "\(filtered.count) of \(entries.count)"
    }

    private func emptyState(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var toast: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Copied to clipboard")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 6)
    }

    private func copy(_ entry: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)

        copiedID = entry.id
        toastTask?.cancel()
        withAnimation { showToast = true }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { showToast = false }
            copiedID = nil
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let isCopied: Bool
    let copy: () -> Void

    @State private var hovering = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Self.relativeFormatter.localizedString(for: entry.date, relativeTo: Date()))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(entry.date.formatted(date: .abbreviated, time: .standard))

            Text(entry.text)
                .font(.system(size: 13))
                .lineLimit(3)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: copy) {
                Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(hovering ? Color.primary.opacity(0.05) : Color.clear)
        .onHover { hovering = $0 }
    }
}
