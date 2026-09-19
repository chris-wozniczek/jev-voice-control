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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button("Done") { controller.showSettings = false }
                    .controlSize(.small)
            }

            GroupBox("API key") {
                SecureField("ts-…", text: $config.apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            GroupBox("Behaviour") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Ask before running commands", isOn: $config.alwaysConfirm)
                    Toggle("Speak replies", isOn: $config.speakReplies)
                }
            }

            GroupBox("Voice") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Voice", selection: $config.voiceIdentifier) {
                        Text("System default").tag(String?.none)
                        ForEach(voices, id: \.identifier) { voice in
                            Text(voiceLabel(voice)).tag(Optional(voice.identifier))
                        }
                    }
                    Slider(value: $config.speechRate, in: 0.3...0.7) {
                        Text("Speech rate")
                    }
                    Text("Rate \(config.speechRate, specifier: "%.2f")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Test voice") {
                        Task { await controller.speaker.say("Hi, I'm Jev. Ready when you are.") }
                    }
                    HStack(spacing: 6) {
                        Text("Higher-quality voices: System Settings → Accessibility → Read & Speak → System Voice → Manage Voices")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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

            GroupBox("App aliases") {
                VStack(alignment: .leading, spacing: 6) {
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
                }
                .onAppear { loadAliases() }
            }

            HStack {
                Text("\(AppRegistry.shared.entries.count) apps known")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { AppRegistry.shared.refresh() }
                    .controlSize(.small)
            }
            Spacer()
        }
        .onAppear { loadAliases() }
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
