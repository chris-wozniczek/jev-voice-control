import JevVoiceCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var controller: VoiceController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if controller.showSettings {
                SettingsView()
            } else {
                header
                if !controller.missingPermissions.isEmpty {
                    permissionsBanner
                }
                transcriptSection
                decisionsSection
                Spacer(minLength: 0)
                footer
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.headline)
            Spacer()
            if controller.latencyMs > 0 {
                Text("\(Int(controller.latencyMs)) ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !controller.model.isEmpty {
                Text(controller.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                controller.showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .listening: return .red
        case .thinking, .executing: return .orange
        case .awaitingConfirm: return .yellow
        case .done: return .green
        case .error: return .red
        case .idle: return .gray
        }
    }

    private var statusText: String {
        switch controller.status {
        case .idle: return "Idle"
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .awaitingConfirm: return "Confirm"
        case .executing: return "Executing…"
        case .done: return "Done"
        case .error(let message): return "Error: \(message)"
        }
    }

    private var permissionsBanner: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("Permissions needed", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.bold())
                    .foregroundStyle(.orange)
                ForEach(controller.missingPermissions) { permission in
                    HStack {
                        Text("\(permission.rawValue) — to \(permission.purpose)")
                            .font(.caption)
                        Spacer()
                        Button(permission.canPrompt ? "Allow" : "Open Settings") {
                            Task {
                                await permission.request()
                                controller.refreshPermissions()
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transcriptSection: some View {
        GroupBox {
            Text(controller.transcript.isEmpty ? "Click Talk or press ⌥Space, then speak" : "“\(controller.transcript)”")
                .font(.callout)
                .italic(controller.transcript.isEmpty)
                .foregroundStyle(controller.transcript.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(4)
        }
    }

    private var decisionsSection: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(controller.decisions.enumerated()), id: \.offset) { _, decision in
                    DecisionCard(
                        decision: decision,
                        needsConfirm: controller.status == .awaitingConfirm
                            && decision.action != .none,
                        onConfirm: { Task { await controller.confirmAndExecute() } },
                        onDismiss: { controller.dismiss() }
                    )
                }
            }
        }
        .frame(maxHeight: 340)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                controller.toggle()
            } label: {
                Label(controller.isListening ? "Stop" : "Talk",
                      systemImage: controller.isListening ? "stop.circle.fill" : "mic.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.isListening ? .red : .accentColor)
            .disabled(controller.missingPermissions.contains { $0 != .accessibility })
            Text(controller.hotKeyRegistered ? "or ⌥Space anywhere" : "⌥Space is taken by another app")
                .font(.caption2)
                .foregroundStyle(controller.hotKeyRegistered ? Color.secondary : Color.orange)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }
}

struct DecisionCard: View {
    let decision: Decision
    let needsConfirm: Bool
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(decision.clause)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Text(decision.action.rawValue)
                    .font(.callout.bold())
                Spacer()
                Text("\(Int(decision.confidence * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProbabilityBars(probabilities: decision.actionProbabilities)
            if let target = decision.targetApp {
                Text("→ \(target)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let system = decision.systemAction, system != .none {
                Text("⚙ \(system.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            slotChips
            if needsConfirm {
                HStack {
                    Button("Run", action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Dismiss", action: onDismiss)
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var slotChips: some View {
        let chips: [String] = [
            decision.url.map { "🔗 \($0)" },
            decision.query.map { "🔎 \($0)" },
            decision.text.map { "⌨ \($0)" },
            decision.percent.map { "🔊 \($0)%" },
        ].compactMap { $0 }
        if !chips.isEmpty {
            FlowLayout(items: chips)
        }
    }
}

struct ProbabilityBars: View {
    let probabilities: [String: Double]

    var body: some View {
        let top = probabilities.sorted { $0.value > $1.value }.prefix(4)
        VStack(spacing: 3) {
            ForEach(Array(top), id: \.key) { key, value in
                HStack(spacing: 6) {
                    Text(key)
                        .font(.caption2)
                        .frame(width: 70, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: max(2, geo.size.width * value))
                            .animation(.easeOut(duration: 0.35), value: value)
                    }
                    .frame(height: 8)
                    Text("\(Int(value * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
    }
}

struct FlowLayout: View {
    let items: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                    .lineLimit(1)
            }
            Spacer()
        }
    }
}
