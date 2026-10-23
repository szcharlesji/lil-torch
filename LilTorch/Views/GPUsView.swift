import SwiftUI
import TorchKit

/// The lab's GPUs at a glance: what's free, what's yours, who's using the rest.
struct GPUsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable {
        case all = "All", free = "Free", mine = "Mine"
    }

    var body: some View {
        NavigationStack {
            List {
                if let lab = model.lab {
                    Section {
                        Summary(lab: lab, filter: $filter)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 2))

                    ForEach(lab.hosts) { host in
                        let gpus = host.gpus.filter { shows($0, user: lab.user) }
                        if !gpus.isEmpty {
                            Section {
                                ForEach(gpus) { gpu in
                                    GPURow(gpu: gpu, user: lab.user)
                                }
                            } header: {
                                HostHeader(host: host)
                            }
                        }
                    }

                    Section {
                        EmptyView()
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            if !lab.unreachable.isEmpty {
                                Text("Not reporting: \(lab.unreachable.map(\.host).joined(separator: ", "))")
                            }
                            UpdatedFooter(date: lab.fetchedAt, refreshing: model.isRefreshing)
                        }
                    }
                }
            }
            .navigationTitle("GPUs")
            .refreshable { await model.refresh() }
            .overlay {
                if model.lab == nil {
                    ContentUnavailableView(
                        "No Lab GPUs",
                        systemImage: "square.grid.3x3",
                        description: Text("Add an agent running on a lab machine (like orion) to see GPU availability.")
                    )
                }
            }
        }
    }

    private func shows(_ gpu: GPU, user: String) -> Bool {
        switch filter {
        case .all: true
        case .free: gpu.availability(for: user) == .free
        case .mine: gpu.availability(for: user) == .mine
        }
    }
}

private struct Summary: View {
    let lab: GPUSnapshot
    @Binding var filter: GPUsView.Filter

    var body: some View {
        let all = lab.hosts.flatMap(\.gpus)
        let free = all.filter { $0.availability(for: lab.user) == .free }.count
        let mine = all.filter { $0.availability(for: lab.user) == .mine }.count
        HStack(spacing: 10) {
            Tile(count: free, label: "Free", color: .green, selected: filter == .free) {
                filter = filter == .free ? .all : .free
            }
            Tile(count: mine, label: "Mine", color: .accentColor, selected: filter == .mine) {
                filter = filter == .mine ? .all : .mine
            }
            Tile(count: all.count, label: "Total", color: .secondary, selected: filter == .all) {
                filter = .all
            }
        }
        .padding(.vertical, 4)
    }

    private struct Tile: View {
        let count: Int
        let label: String
        let color: Color
        let selected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count)")
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(color)
                    Text(label).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? color : .clear, lineWidth: 2)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct HostHeader: View {
    let host: GPUHost

    var body: some View {
        HStack {
            Text(host.name)
            Spacer()
            let models = Set(host.gpus.map { Format.model($0.model) }).filter { !$0.contains("Error") }
            Text(models.sorted().joined(separator: ", "))
                .textCase(nil)
                .lineLimit(1)
        }
    }
}

private struct GPURow: View {
    let gpu: GPU
    let user: String

    var body: some View {
        let availability = gpu.availability(for: user)
        HStack(alignment: .top, spacing: 12) {
            Text("\(gpu.index)")
                .font(.system(.callout, design: .rounded, weight: .bold))
                .frame(width: 28, height: 28)
                .foregroundStyle(availability == .busy ? Color.primary : .white)
                .background(availability == .busy ? AnyShapeStyle(.quaternary) : AnyShapeStyle(availability.color),
                            in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 5) {
                if gpu.error {
                    Text("Not responding").font(.subheadline).foregroundStyle(.red)
                } else {
                    HStack {
                        Text(availability == .free ? "Free" : Format.model(gpu.model))
                            .font(.subheadline.weight(availability == .free ? .semibold : .regular))
                            .foregroundStyle(availability == .free ? .green : .primary)
                        Spacer()
                        if let temperature = gpu.temperature {
                            Text("\(temperature)°C")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(temperature >= 85 ? .orange : .secondary)
                        }
                    }
                    metric("Compute", value: Double(gpu.utilization ?? 0) / 100, text: "\(gpu.utilization ?? 0)%", tint: .blue)
                    if let used = gpu.memoryUsed, let total = gpu.memoryTotal, total > 0 {
                        metric("Memory", value: Double(used) / Double(total),
                               text: "\(Format.memory(used)) / \(Format.memory(total))", tint: .purple)
                    }
                    if !gpu.users.isEmpty {
                        Text(gpu.users.map { "\(Format.user($0.name)) \(Format.memory($0.memory))" }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(availability == .mine ? Color.accentColor : .secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func metric(_ label: String, value: Double, text: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Meter(value: value, tint: tint)
            Text(text)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 86, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(text)")
    }
}
