import AVFoundation
import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var controller: VoiceController
    @ObservedObject private var config = Config.shared
    @ObservedObject private var driver = CuaDriver.shared
    @ObservedObject private var whisperStore = WhisperModelStore.shared
    @State private var aliasDrafts: [AliasDraft] = []
    @State private var driverTestStatus = ""
    @State private var hintCount = HintStore.shared.count
    @State private var appActionCount = AppActionRegistry.shared.actions.count

    private var voices: [AVSpeechSynthesisVoice] {
        let preferredPrefixes = Locale.preferredLanguages.map {
            $0.split(separator: "-").first.map(String.init) ?? $0
        } + ["en"]
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                preferredPrefixes.contains { voice.language.hasPrefix($0) }
            }
            .sorted {
                if $0.quality.rawValue != $1.quality.rawValue {
                    return $0.quality.rawValue > $1.quality.rawValue
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    controller.showSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                Text("Settings")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                Spacer()
                Button("Done") { controller.showSettings = false }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("TypeSafe API key", systemImage: "key") {
                        SecureField("ts-…", text: $config.apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    section("Behaviour", systemImage: "hand.raised") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Ask before running commands", isOn: $config.alwaysConfirm)
                            Toggle("Speak replies", isOn: $config.speakReplies)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    section("Safety", systemImage: "shield") {
                        Text(config.safetyPolicyPath ?? "No policy loaded")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack {
                            Button("Open policy file") {
                                guard let path = config.safetyPolicyPath else { return }
                                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                            }
                            .controlSize(.small)
                            Button("Reveal in Finder") {
                                guard let path = config.safetyPolicyPath else { return }
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    URL(fileURLWithPath: path)
                                ])
                            }
                            .controlSize(.small)
                        }
                    }

                    section("Computer use", systemImage: "macwindow") {
                        VStack(alignment: .leading, spacing: 8) {
                            SecureField("DeepSeek API key", text: $config.deepSeekAPIKey)
                                .textFieldStyle(.roundedBorder)
                            Picker("Planner", selection: $config.plannerMode) {
                                Text("Jev (fast, picks from what's on screen)").tag(PlannerMode.jev)
                                Text("DeepSeek Flash (open-ended)").tag(PlannerMode.deepSeek)
                            }
                            Picker("DeepSeek thinking", selection: $config.deepSeekThinking) {
                                Text("Off (fastest)").tag(DeepSeekThinking.off)
                                Text("Low").tag(DeepSeekThinking.low)
                                Text("High").tag(DeepSeekThinking.high)
                            }
                            Stepper(
                                "Fallback max steps: \(config.fallbackMaxSteps)",
                                value: $config.fallbackMaxSteps,
                                in: 1...25
                            )
                            Stepper(
                                "Fallback max seconds: \(Int(config.fallbackMaxSeconds))",
                                value: $config.fallbackMaxSeconds,
                                in: 5...90,
                                step: 1
                            )
                            Text("DeepSeek fallback stops after either limit.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Written replies")
                                .font(.callout.weight(.semibold))
                                .padding(.top, 4)
                            Picker("Writer", selection: $config.generatorSource) {
                                Text("DeepSeek").tag(GeneratorSource.deepSeek)
                                Text("local oMLX").tag(GeneratorSource.omlx)
                            }
                            if config.generatorSource == .omlx {
                                TextField("oMLX base URL", text: $config.omlxBaseURL)
                                    .textFieldStyle(.roundedBorder)
                                TextField("oMLX text model", text: $config.omlxTextModel)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Toggle("Show generated text before typing it", isOn: $config.previewGeneratedText)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            Toggle("Let Jev operate apps (Cua)", isOn: $config.computerUseEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            Picker("Default browser", selection: $config.defaultBrowser) {
                                ForEach(["Google Chrome", "Safari", "Arc", "Brave Browser", "Firefox"], id: \.self) {
                                    Text($0).tag($0)
                                }
                            }
                            Text("Used when a command names a site without a browser.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Toggle("App shortcuts (app-actions.json)", isOn: $config.appActionsEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            Toggle("Native Accessibility (in-process)", isOn: $config.nativeAXEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            Text("Reads the window's Accessibility tree directly; Cua is used when it's too thin.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Toggle("Read labels from the screen (OCR)", isOn: $config.ocrFallbackEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            Text("When an app exposes almost no controls, Jev reads visible text with Apple Vision and clicks it. Needs Screen Recording.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack {
                                Text("\(appActionCount) actions loaded")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Reveal file") {
                                    AppActionRegistry.shared.ensureUserFileExists()
                                    NSWorkspace.shared.activateFileViewerSelecting([
                                        AppActionRegistry.userFileURL
                                    ])
                                }
                                .controlSize(.small)
                                Button("Reload") {
                                    AppActionRegistry.shared.reload()
                                    appActionCount = AppActionRegistry.shared.actions.count
                                }
                                .controlSize(.small)
                            }
                            Toggle("Read web pages through Chrome DevTools when available", isOn: $config.cdpEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            HStack {
                                Text("CDP port")
                                TextField(
                                    "9222",
                                    text: Binding(
                                        get: { String(config.cdpPort) },
                                        set: { config.cdpPort = Int($0) ?? config.cdpPort }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 76)
                            }
                            Text("Enable it with: open -a \"Google Chrome\" --args --remote-debugging-port=9222")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Optional in Jev mode: used for screens without accessible controls.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack {
                                Text("Learned shortcuts: \(hintCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Forget learned shortcuts") {
                                    HintStore.shared.clear()
                                    hintCount = HintStore.shared.count
                                }
                                .controlSize(.small)
                            }
                            HStack {
                                Text(driverStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Test driver") {
                                    Task {
                                        do {
                                            let apps = try await driver.apps()
                                            driverTestStatus = "\(apps.count) apps found"
                                        } catch {
                                            driverTestStatus = error.localizedDescription
                                        }
                                    }
                                }
                                .controlSize(.small)
                            }
                            if !driverTestStatus.isEmpty {
                                Text(driverTestStatus)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Screen Recording")
                                        .font(.callout)
                                    Text("Optional for screenshots when an app has no accessibility tree")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Permission.screenRecording.isGranted ? "Allowed" : "Not allowed")
                                    .font(.caption)
                                    .foregroundStyle(Permission.screenRecording.isGranted ? .green : .orange)
                                Button(Permission.screenRecording.isGranted ? "Open" : "Allow") {
                                    Permission.screenRecording.openSystemSettings()
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    hearingSection
                    section("Voice", systemImage: "speaker.wave.2") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Voice", selection: $config.voiceIdentifier) {
                        Text("System default").tag(String?.none)
                        ForEach(voices, id: \.identifier) { voice in
                            Text(voiceLabel(voice)).tag(Optional(voice.identifier))
                        }
                    }
                    HStack {
                        Text("Speed").font(.callout)
                        Slider(value: $config.speechRate, in: 0.3...0.7)
                        Button {
                            Task { await controller.speaker.say("Hi, I'm Jev. Ready when you are.") }
                        } label: {
                            Label("Test", systemImage: "play.fill")
                        }
                        .controlSize(.small)
                    }
                    HStack(alignment: .top, spacing: 6) {
                        Text("Higher-quality voices: System Settings → Accessibility → Read & Speak → System Voice → Manage Voices")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open") {
                            if let url = URL(
                                string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent"
                            ) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }

            section("App aliases", systemImage: "textformat.abc") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Teach Jev what you call your apps, e.g. “see mux” → cmux.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach($aliasDrafts) { $draft in
                        HStack {
                            TextField("Alias", text: $draft.alias)
                                .textFieldStyle(.roundedBorder)
                            Picker("App", selection: $draft.target) {
                                ForEach(AppRegistry.shared.names, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            Button {
                                aliasDrafts.removeAll { $0.id == draft.id }
                                saveAliases()
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        .onChange(of: draft.alias) { _, _ in saveAliases() }
                        .onChange(of: draft.target) { _, _ in saveAliases() }
                    }
                    Button {
                        aliasDrafts.append(AliasDraft(alias: "", target: AppRegistry.shared.names.first ?? ""))
                    } label: {
                        Label("Add alias", systemImage: "plus")
                    }
                    .controlSize(.small)
                    HStack {
                        Text("\(AppRegistry.shared.entries.count) apps known")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Rescan apps") { AppRegistry.shared.refresh() }
                            .controlSize(.mini)
                    }
                }
            }
                }
                .padding(16)
            }
        }
        .onAppear { loadAliases() }
    }

    private var hearingSection: some View {
        section("Hearing", systemImage: "waveform.and.mic") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Engine", selection: $config.speechEngine) {
                    Text("Apple (classic)").tag(SpeechEngineKind.apple)
                    Text("Apple (streaming, macOS 26)")
                        .tag(SpeechEngineKind.appleStreaming)
                        .disabled(!SpeechEngineKind.streamingAvailable)
                    Text("Whisper on-device").tag(SpeechEngineKind.whisper)
                }
                .onChange(of: config.speechEngine) { _, engine in
                    if engine == .whisper {
                        whisperStore.preload()
                    } else if engine == .appleStreaming {
                        if #available(macOS 26, *) {
                            SpeechAnalyzerEngine.preload()
                        }
                    }
                }
                if !SpeechEngineKind.streamingAvailable {
                    Text("Apple streaming is unavailable on this macOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Whisper model", selection: $config.whisperModel) {
                    ForEach(WhisperModelStore.models) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .disabled(config.speechEngine != .whisper)
                .onChange(of: config.whisperModel) { _, model in
                    whisperStore.select(model)
                }
                TextField(
                    "Language code (blank = auto)",
                    text: Binding(
                        get: { config.speechLanguage ?? "" },
                        set: { config.speechLanguage = $0.isEmpty ? nil : $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .disabled(config.speechEngine != .whisper)
                HStack {
                    switch whisperStore.state {
                    case .notDownloaded:
                        Text("Not downloaded")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Download") { whisperStore.downloadSelected() }
                            .controlSize(.small)
                    case .downloading(let progress):
                        ProgressView(value: progress)
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    case .ready:
                        Text(whisperStore.readySizeMB.map { "Ready · \($0) MB" } ?? "Ready")
                            .foregroundStyle(.secondary)
                    case .failed(let message):
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Retry") { whisperStore.downloadSelected() }
                            .controlSize(.small)
                    }
                }
                Picker("Listening", selection: $config.listeningMode) {
                    Text("Tap to talk").tag(ListeningMode.toggle)
                    Text("Hold to talk").tag(ListeningMode.hold)
                }
                if config.listeningMode == .toggle {
                    Toggle("Smart end of speech (Jev)", isOn: $config.endOfTurnJudgeEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    HStack {
                        Text("Silence timeout")
                        Slider(value: $config.silenceTimeout, in: 1...5, step: 0.5)
                        Text("\(config.silenceTimeout, specifier: "%.1f") s")
                            .font(.caption.monospacedDigit())
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                TextField(
                    "Extra words (comma-separated)",
                    text: Binding(
                        get: { config.customVocabulary.joined(separator: ", ") },
                        set: {
                            config.customVocabulary = $0
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
                Text("Names the recognizer should expect: sites, models, products.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Whisper hears app names like cmux and Devin more reliably; runs fully offline.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func section<Content: View>(
        _ title: String, systemImage: String, @ViewBuilder content: () -> Content
    ) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                content()
            }
        }
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch voice.quality {
        case .premium: quality = "Premium"
        case .enhanced: quality = "Enhanced"
        default: quality = "Default"
        }
        return "\(voice.name) (\(voice.language), \(quality))"
    }

    private var driverStatus: String {
        switch driver.state {
        case .stopped: return "Driver: Not started"
        case .starting: return "Driver: Starting…"
        case .ready: return "Driver: Ready"
        case .failed(let message): return "Driver: Failed — \(message)"
        }
    }

    private func loadAliases() {
        aliasDrafts = config.appAliases
            .map { AliasDraft(alias: $0.key, target: $0.value) }
            .sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
    }

    private func saveAliases() {
        config.appAliases = Dictionary(
            aliasDrafts.compactMap { draft in
                let alias = draft.alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let target = draft.target.trimmingCharacters(in: .whitespacesAndNewlines)
                return alias.isEmpty || target.isEmpty ? nil : (alias, target)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        AppRegistry.shared.refresh()
    }
}

private struct AliasDraft: Identifiable {
    let id = UUID()
    var alias: String
    var target: String
}
