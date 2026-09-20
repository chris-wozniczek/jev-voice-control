import JevVoiceCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var controller: VoiceController
    @ObservedObject private var agentRunner = AgentRunner.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.showSettings {
                SettingsView()
            } else {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !controller.missingPermissions.isEmpty {
                            permissionsBanner
                        }
                        transcriptCard
                        if !controller.suggestions.isEmpty {
                            suggestionSection
                        }
                        if agentRunner.isRunning || !agentRunner.steps.isEmpty {
                            agentStepsSection
                        } else if !controller.decisions.isEmpty {
                            stepsSection
                        } else if controller.transcript.isEmpty {
                            hints
                        }
                    }
                    .padding(16)
                }
                Divider()
                footer
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: 380, height: 540)
        .background(.regularMaterial)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            JevLogo()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Jev Voice")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                StatusPill(status: controller.status)
            }
            Spacer()
            if controller.latencyMs > 0 || !controller.model.isEmpty {
                Text(metaText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Button {
                controller.showSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    private var metaText: String {
        var parts: [String] = []
        if !controller.model.isEmpty { parts.append(controller.model) }
        if controller.latencyMs > 0 { parts.append("\(Int(controller.latencyMs)) ms") }
        return parts.joined(separator: " · ")
    }

    // MARK: Cards

    private var permissionsBanner: some View {
        Card(tint: .orange) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Permissions needed", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                ForEach(controller.missingPermissions) { permission in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(permission.rawValue).font(.caption.weight(.medium))
                            Text(permission.purpose).font(.caption2).foregroundStyle(.secondary)
                        }
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
        }
    }

    private var transcriptCard: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: controller.isListening ? "waveform" : "quote.opening")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(controller.isListening ? Color.accentColor : Color.secondary)
                    .symbolEffectIfAvailable(active: controller.isListening)
                    .frame(width: 18)
                Text(transcriptText)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(controller.transcript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(5)
                    .animation(.default, value: controller.transcript)
            }
        }
    }

    private var transcriptText: String {
        if !controller.transcript.isEmpty { return controller.transcript }
        if let status = controller.speechStatusMessage, controller.isListening {
            return status
        }
        return controller.isListening ? "Listening…" : "Press Talk or ⌥Space and say what you need."
    }

    private var suggestionSection: some View {
        Card(tint: .orange) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Did you mean:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(controller.suggestions, id: \.self) { app in
                        HStack(spacing: 2) {
                            Button(app) {
                                controller.useSuggestion(app)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button {
                                controller.useSuggestion(app, teachAlias: true)
                            } label: {
                                Image(systemName: "graduationcap")
                            }
                            .buttonStyle(.borderless)
                            .help("Teach this phrase as an alias for \(app)")
                        }
                    }
                }
            }
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(controller.decisions.count == 1 ? "Step" : "Steps")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if controller.status != .thinking && controller.status != .executing {
                    Button("Clear") {
                        controller.clearHistory()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                if case .error(let message) = controller.status {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
            ForEach(Array(controller.decisions.enumerated()), id: \.offset) { index, decision in
                DecisionRow(index: index + 1, decision: decision, status: controller.status)
            }
            if controller.status == .awaitingConfirm {
                confirmBar
            }
        }
    }

    private var agentStepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Computer use")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if agentRunner.isRunning {
                    Button("Stop") { agentRunner.cancel() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                } else {
                    Button("Clear") {
                        agentRunner.clearSteps()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(agentRunner.steps) { step in
                        Card {
                            HStack(spacing: 8) {
                                stepIcon(step.result)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(step.index). \(step.tool)")
                                        .font(.callout.weight(.medium))
                                    if !step.argsSummary.isEmpty {
                                        Text(step.argsSummary)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text(String(format: "%.1fs", step.elapsed))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private func stepIcon(_ result: AgentStepResult) -> some View {
        switch result {
        case .ok: return Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: return Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pendingConfirm: return Image(systemName: "hourglass").foregroundStyle(.orange)
        }
    }

    private var confirmBar: some View {
        Card(tint: .yellow) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.yellow)
                Text(controller.awaitingVoiceAnswer ? "Say “yes” or “no”" : "Run these steps?")
                    .font(.callout)
                Spacer()
                Button("Dismiss") { controller.dismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Run") { Task { await controller.confirmAndExecute() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var hints: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try saying")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach([
                "open chrome, search for banana",
                "maximize safari",
                "open cmux, type hello",
                "volume 40 percent",
            ], id: \.self) { example in
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("“\(example)”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Group {
                if controller.config.listeningMode == .hold {
                    Button {} label: {
                        Label("Hold to talk", systemImage: "mic.fill")
                            .font(.body.weight(.semibold))
                            .frame(minWidth: 98)
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if !controller.isListening { controller.startListening() }
                            }
                            .onEnded { _ in controller.stopListening() }
                    )
                } else {
                    Button {
                        controller.toggle()
                    } label: {
                        Label(controller.isListening ? "Stop" : "Talk",
                              systemImage: controller.isListening ? "stop.fill" : "mic.fill")
                            .font(.body.weight(.semibold))
                            .frame(minWidth: 72)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
            .tint(controller.isListening ? .red : .accentColor)
            .disabled(controller.missingPermissions.contains { $0 != .accessibility })
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.hotKeyRegistered ? "⌥ Space" : "⌥Space is taken")
                    .font(.caption.weight(.medium).monospaced())
                    .foregroundStyle(controller.hotKeyRegistered ? Color.secondary : Color.orange)
                Text(controller.config.listeningMode == .hold
                     ? "release to run"
                     : "say “go” or pause to run")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(controller.config.listeningMode == .hold ? "hold to talk" : "tap to talk")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
    }
}

// MARK: - Components

struct StatusPill: View {
    let status: VoiceController.Status

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var color: Color {
        switch status {
        case .listening: return .red
        case .thinking, .executing: return .orange
        case .awaitingConfirm: return .yellow
        case .done: return .green
        case .error: return .red
        case .idle: return .gray
        }
    }

    private var text: String {
        switch status {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .awaitingConfirm: return "Waiting for confirmation"
        case .executing: return "Working"
        case .done: return "Done"
        case .error: return "Something went wrong"
        }
    }
}

struct Card<Content: View>: View {
    var tint: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill((tint ?? Color.primary).opacity(tint == nil ? 0.04 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder((tint ?? Color.primary).opacity(tint == nil ? 0.08 : 0.25), lineWidth: 1)
            )
    }
}

struct DecisionRow: View {
    let index: Int
    let decision: Decision
    let status: VoiceController.Status

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.12))
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(decision.action == .none ? "Nothing to do" : decision.executionSummary)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    Text("“\(decision.clause)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !detailChips.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(detailChips, id: \.self) { chip in
                                Text(chip)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                trailing
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if status == .done {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if status == .executing {
            ProgressView().controlSize(.small)
        } else if decision.riskTier == .destructive {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .help("Destructive action — asks before running")
        } else if decision.confidence < 0.6 {
            Text("\(Int(decision.confidence * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var detailChips: [String] {
        [
            decision.url,
            decision.query.map { "search: \($0)" },
            decision.text.map { "type: \($0)" },
            decision.percent.map { "\($0)%" },
        ].compactMap { $0 }
    }

    private var symbol: String {
        switch decision.action {
        case .openApp: return "arrow.up.forward.app"
        case .closeApp: return "xmark.app"
        case .switchApp: return "arrow.left.arrow.right"
        case .minimizeApp: return "arrow.down.right.and.arrow.up.left"
        case .maximizeApp: return "arrow.up.left.and.arrow.down.right"
        case .fullscreenApp: return "rectangle.expand.vertical"
        case .restoreApp: return "macwindow"
        case .hideApp: return "eye.slash"
        case .openURL: return "link"
        case .webSearch: return "magnifyingglass"
        case .dictate: return "keyboard"
        case .system: return "slider.horizontal.3"
        case .none: return "minus.circle"
        }
    }
}

/// Vector rendition of the app icon glyph (see scripts/make-icon.swift).
struct JevLogo: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.44, green: 0.37, blue: 1.0),
                                     Color(red: 0.22, green: 0.16, blue: 0.80)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .shadow(color: .black.opacity(0.25), radius: s * 0.04, y: s * 0.02)
                HStack(spacing: s * 0.045) {
                    ForEach(Array([0.18, 0.30, 0.44, 0.30, 0.18].enumerated()), id: \.offset) { _, h in
                        Capsule().fill(.white).frame(width: s * 0.085, height: s * h)
                    }
                }
                .offset(y: -s * 0.05)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private extension View {
    @ViewBuilder
    func symbolEffectIfAvailable(active: Bool) -> some View {
        if #available(macOS 14.0, *) {
            self.symbolEffect(.variableColor.iterative, isActive: active)
        } else {
            self
        }
    }
}
