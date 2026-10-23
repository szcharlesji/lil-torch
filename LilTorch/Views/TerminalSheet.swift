import SwiftTerm
import SwiftUI
import TorchKit

enum TerminalTarget: String, Identifiable {
    /// `ssh torch` from the agent's machine. With no live login, NYU asks for the
    /// password and Duo here, and that login becomes the agent's shared connection.
    case torch
    /// A login shell on the agent's lab machine.
    case local

    var id: String { rawValue }
}

struct TerminalSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let agentID: UUID
    let target: TerminalTarget
    @State private var attempt = 0
    @State private var state: TerminalState = .connecting

    var body: some View {
        let agent = model.agent(agentID)
        NavigationStack {
            VStack(spacing: 0) {
                if target == .torch, let agent, model.state(agent).loginNeeded {
                    Text("Enter your NYU password and approve Duo. Once you reach a prompt, tap Done; the login stays active on \(agent.name).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
                TerminalRepresentable(agentID: agentID, target: target, state: $state)
                    .id(attempt)
                    .overlay { overlay }
            }
            .navigationTitle(target == .torch ? "Torch" : agent?.name ?? "Shell")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onDisappear {
            // A new login may have brought Torch back.
            Task { await model.refresh() }
        }
    }

    @ViewBuilder private var overlay: some View {
        switch state {
        case .connecting:
            ProgressView("Connecting…")
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .closed(let error):
            VStack(spacing: 12) {
                Text(error == nil ? "Session ended" : "Couldn't open a terminal").font(.headline)
                if let error { Text(error).font(.footnote).multilineTextAlignment(.center) }
                Button("Reconnect", systemImage: "arrow.clockwise") {
                    state = .connecting
                    attempt += 1
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        case .open:
            EmptyView()
        }
    }
}

enum TerminalState: Equatable {
    case connecting, open, closed(String?)
}

private struct TerminalRepresentable: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    let agentID: UUID
    let target: TerminalTarget
    @Binding var state: TerminalState

    func makeCoordinator() -> Coordinator {
        Coordinator(client: model.client(for: agentID), target: target, state: $state)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        view.terminalDelegate = context.coordinator
        context.coordinator.start(on: view)
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {}

    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// Bridges SwiftTerm to the agent's terminal WebSocket.
    @MainActor
    final class Coordinator {
        private let client: AgentClient?
        private let target: TerminalTarget
        private let state: Binding<TerminalState>
        private var socket: URLSessionWebSocketTask?
        private var reader: Task<Void, Never>?

        init(client: AgentClient?, target: TerminalTarget, state: Binding<TerminalState>) {
            self.client = client
            self.target = target
            self.state = state
        }

        func start(on view: TerminalView) {
            reader = Task { [weak view] in
                // Let the view lay out first so the terminal starts at its real size.
                try? await Task.sleep(for: .milliseconds(150))
                guard let view, let client else {
                    state.wrappedValue = .closed("This agent isn't paired.")
                    return
                }
                let terminal = view.getTerminal()
                let socket = client.terminal(target: target.rawValue, cols: terminal.cols, rows: terminal.rows)
                self.socket = socket
                socket.resume()
                var opened = false
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        if !opened {
                            opened = true
                            state.wrappedValue = .open
                            _ = view.becomeFirstResponder()
                        }
                        switch message {
                        case .data(let data): view.feed(byteArray: [UInt8](data)[...])
                        case .string(let text): view.feed(text: text)
                        @unknown default: break
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    state.wrappedValue = .closed(socket.closeCode == .normalClosure ? nil : error.localizedDescription)
                }
            }
        }

        func stop() {
            reader?.cancel()
            socket?.cancel(with: .normalClosure, reason: nil)
        }

        fileprivate func send(_ bytes: ArraySlice<UInt8>) {
            socket?.send(.data(Data(bytes))) { _ in }
        }

        fileprivate func resize(cols: Int, rows: Int) {
            socket?.send(.string(#"{"type":"resize","cols":\#(cols),"rows":\#(rows)}"#)) { _ in }
        }
    }
}

extension TerminalRepresentable.Coordinator: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        send(data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme) else { return }
        UIApplication.shared.open(url)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
