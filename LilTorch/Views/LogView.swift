import SwiftUI
import TorchKit

struct LogView: View {
    @Environment(AppModel.self) private var model
    let agentID: UUID
    let title: String
    let path: String
    @State var follow: Bool

    @State private var lines = 200
    @State private var tail: LogTail?
    @State private var error: String?
    @State private var loading = false
    @State private var wrap = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    if let tail {
                        if tail.size == nil, tail.text.isEmpty {
                            ContentUnavailableView("Log file not found", systemImage: "doc.questionmark",
                                                   description: Text(path))
                        } else {
                            Text(verbatim: tail.text)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: !wrap, vertical: true)
                                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                        }
                    } else if let error {
                        ContentUnavailableView("Couldn't read log", systemImage: "exclamationmark.triangle",
                                               description: Text(error))
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
            }
            // Open at the end like `tail`, but keep short logs at the top.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .onChange(of: tail?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { statusBar }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Options", systemImage: "ellipsis.circle") {
                    Picker("Lines", selection: $lines) {
                        ForEach([100, 200, 1000, 5000], id: \.self) { Text("Last \($0) lines").tag($0) }
                    }
                    Toggle("Follow", systemImage: "arrow.down.to.line", isOn: $follow)
                    Toggle("Wrap lines", systemImage: "text.word.spacing", isOn: $wrap)
                    Button("Copy path", systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
                    if let text = tail?.text {
                        ShareLink(item: text, subject: Text(path))
                    }
                }
            }
        }
        .task(id: "\(lines)-\(follow)") {
            await load()
            while follow, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await load()
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            if loading { ProgressView().controlSize(.mini) }
            if let tail, let size = tail.size {
                Text(Format.bytes(size))
                if let modified = tail.modified {
                    Text("· modified \(modified, format: .relative(presentation: .named))")
                }
            }
            Spacer()
            if follow { Label("Following", systemImage: "dot.radiowaves.left.and.right").labelStyle(.titleAndIcon) }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func load() async {
        guard let client = model.client(for: agentID) else { return }
        loading = true
        defer { loading = false }
        do {
            tail = try await client.log(path: path, lines: lines)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
