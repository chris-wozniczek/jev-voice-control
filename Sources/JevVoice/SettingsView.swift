import AVFoundation
import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var controller: VoiceController
    @ObservedObject private var config = Config.shared
    @State private var aliasDrafts: [AliasDraft] = []

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
                        .onChange(of: draft.alias) { _ in saveAliases() }
                        .onChange(of: draft.target) { _ in saveAliases() }
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
