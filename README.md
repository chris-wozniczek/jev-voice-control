# Jev Voice

A macOS menu-bar app that turns spoken commands into actions using
[TypeSafe AI's Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev)
— a System One model that returns *typed decisions with probabilities* instead of
generated text.

**v0.9.1** is a public reliability release. Hold **⌥Space** to speak and
release it to send the command. Toggle mode is available in Settings when you
prefer to start and stop listening with a press.

Useful links: [Design](DESIGN.md) ·
[documentation site](https://chris-wozniczek.github.io/jev-voice-control/)

Press **⌥Space**, say something, and Jev decides what to do:

- "open chrome and go to google.com"
- "quit spotify"
- "type hello world"
- "set volume to 30"
- "search for swift concurrency"
- "maximize chrome"
- "full screen safari"
- "restore chrome"

App names support common aliases such as “chrome”, “code”, “cmux”, and
“settings”. The app can speak short execution replies using the selected macOS
voice, and Settings can enable **Ask before running commands** for a
voice-confirmation step.

Mixed commands combine deterministic local actions with Jev-guided UI work:
“open Devin and start a new session” = local open + Jev-guided click. The app
keeps those typed decisions in order, carries the opened app forward as the UI
task target, and asks for confirmation before actions that sound hard to undo.

Speech is transcribed **on-device**. SpeechAnalyzer streaming is the default
engine on macOS 26 when it is available and compiled into the build; Whisper
and the classic Apple speech recognizer are available alternatives in Settings
› Hearing. The transcript and the small amount of app context needed for
routing—such as the frontmost app and installed app names—are sent to Jev.

Typing activates the target app before every keystroke path and reads the
focused field back after typing. If the field does not show the text, Jev uses
an in-process Unicode keyboard fallback and keeps the task open for
verification. Settings › Hearing includes extra vocabulary for sites, models,
and products; the same words are supplied to Apple Speech, Apple SpeechAnalyzer
streaming on macOS 26, and Whisper. Apple SpeechAnalyzer assets are preloaded at
launch when available. Whisper's language code is configurable in Settings ›
Hearing; leave it blank for automatic language detection. When Whisper is
selected, its model is loaded at app launch so the first tap can start listening
immediately. Whisper uses audio energy to detect the end of speech. Smart end
of speech can ask Jev whether a short pause ends the command, while retaining
the configured silence timeout as a hard cap.
Apple streaming requires Swift 6.2+/Xcode 26; check a built binary with
`--engine-info`.

## How it works

### How it decides

The decision flow is deliberately layered:

1. The local parser handles deterministic commands and extracts slots.
2. Jev routes ambiguous clauses and returns typed action decisions.
3. The fast path handles known app/site actions when their preconditions match.
4. The computer-use path observes the target application's Accessibility tree.
5. Jev picks an element, Jev Voice acts on it, then re-observes and verifies the
   result.

The bounded fallbacks are a wake-up rewalk for lazy Accessibility trees, local
OCR for visible controls, Chrome DevTools Protocol for thin Chromium/Electron
trees, and DeepSeek for open-ended or escalated planner work. Text entry starts
with in-process Unicode keyboard events and uses the verified Cua path when
needed. DeepSeek thinking and the fallback step/time budgets are configurable
in Computer use settings.

### Learned tools

Scriptable unknown commands can become learned tools. When **Learn scriptable
tools** is enabled, Jev can generate an AppleScript or JXA tool for system
tasks such as dark mode, volume, reminders, Calendar events, and timers. Each
tool must compile, pass the policy scanner, and pass a Jev review before it is
confirmed and run. Successful tools are cached at
`~/Library/Application Support/Jev Voice/tools/`; Settings › Learned tools
lists seed and learned tools, with per-tool enable/delete controls and a
master toggle. UI work, browsing, and operating Devin or terminal apps always
stay on the Accessibility/Cua agent path.

### Chrome DevTools fallback

When a Chromium or Electron window has a thin Accessibility tree, Jev can read
visible web controls through Chrome DevTools Protocol and use those controls
for clicks and text entry. Enable remote debugging with
`open -a "Google Chrome" --args --remote-debugging-port=9222`, then enable the
Chrome DevTools option in Computer use settings.

### Written replies

Requests such as “write a note apologising for the delay” are composed by a
generative text model rather than typing the spoken words verbatim. DeepSeek
is used by default, or a local oMLX OpenAI-compatible endpoint can be selected
in Computer use settings. Jev classifies the request; it does not generate
the prose. Generated text is previewed before typing by default.

### Web workflows

Sites are resolved from the bundled `web-sites.json` registry, with optional
user overrides at `~/Library/Application Support/Jev Voice/web-sites.json`.
Search commands also fall back to extracting a query from phrases such as
“check the last Juventus game” when the structured query slot is empty.
Choose the default browser in Settings › Computer use; a browser named in the
command overrides it. Site workflows open the requested host before the
generic computer-use loop starts.

Requests such as “compose a post on X about the new release” generate wording
for the requested site, open X, and continue through the normal observe,
choose, type, and verify flow. The bundled x.com shortcut can press `n` once
to open the composer when no text field is visible. Post, Send, Publish, Tweet,
and Reply controls require confirmation before submission.

### Safety policy

The bundled `Resources/policy.json` blocks shell, payment, credential, and
irreversible file-operation phrases. Its `confirm` defaults are `delete`,
`remove`, `empty trash`, `publish`, and `pay`; its browser-only
`confirmInBrowser` defaults are `send`, `submit`, `post`, `tweet`, and `reply`.
The browser list is applied only when the target is a browser/site workflow.
A user override at
`~/Library/Application Support/Jev Voice/policy.json` replaces the bundled
policy. Settings › Safety shows the loaded policy and can open or reveal it.

```
microphone ──> SpeechAnalyzer / Apple Speech / Whisper (on-device) ──> transcript
                                                      │
                                          ClauseSplitter (multi-verb clauses)
                                          │
                              POST /v1/systemone  ──> Jev (typed answers)
                                            per clause: action?   target_app?
                                            system_action? mentions_url?
                                            refers_to_frontmost? destructive?
                                                      │
                                 Decision + SlotExtractor (url/query/text/%)
                                                      │
                              Executor (NSWorkspace / CGEvent / osascript / pmset)
```

Jev's routing answers are typed and never free text — each clause is one
`systemOne` call with a state
payload (`clause`, `full_transcript`, `frontmost_app`, `installed_apps`, `aliases`) and seven
questions:

| question | type | shape |
|---|---|---|
| `action` | choice | one of `openApp`, `closeApp`, `openURL`, `webSearch`, `dictate`, `uiTask`, `system`, `none` |
| `target_app` | choice | installed app names (≤254) + `none` |
| `system_action` | choice | `volumeSet`, `mute`, `lockScreen`, `screenshot`, … |
| `mentions_url` | noul | probability the clause names a website |
| `refers_to_frontmost` | noul | "quit it" → the frontmost app |
| `composes` | noul | probability the clause asks Jev to write the wording |
| `destructive` | noul | probability the clause is hard to undo |

Arguments (URLs, queries, dictation text, percentages) can't come from Jev —
it's decision-only — so they're extracted deterministically by `SlotExtractor`
heuristics.

Most commands execute locally without a network call. Commands Jev handles
remain typed decisions; low-confidence or ambiguous commands ask for
confirmation before anything executes.

## Install with Homebrew

This repository doubles as a Homebrew tap (see `Casks/jev-voice.rb`):

```sh
brew tap chris-wozniczek/jev-voice https://github.com/chris-wozniczek/jev-voice-control
brew install --cask jev-voice
```

Homebrew 7+ refuses untrusted third-party taps; if prompted, run
`brew trust chris-wozniczek/jev-voice` first.

Releases are produced by `.github/workflows/release.yml`: bump
`CFBundleShortVersionString` in `Info.plist`, push a matching `vX.Y.Z` tag, and
the workflow builds `Jev-Voice-X.Y.Z.zip`, publishes a GitHub release, and
commits the new version/sha256 into the cask.

## Build from source

```sh
make app    # builds build/Jev Voice.app (ad-hoc signed)
make run    # launches it
make test   # unit tests (pure logic: clause splitting, slot extraction, codecs)
make dist   # zips the app into build/Jev-Voice-<version>.zip and prints its sha256
```

Then set your API key in the popover's Settings (gear icon), or:

```sh
defaults write com.chriswozniczek.jevvoice typesafeAPIKey <key>
# or export TYPESAFE_API_KEY=... before launching
```

### Permissions

- **Microphone** — hear commands
- **Speech Recognition** — transcribe (on-device when supported)
- **Accessibility** — inspect and act on application controls and type text
- **Screen Recording** — capture the screen for local OCR and screenshots
- **Automation (System Events)** — control System Events for AppleScript actions

### Teaching Jev app shortcuts

Optional app shortcuts provide a fast path for common actions such as opening a
new session or tab. They are stored in:

```text
~/Library/Application Support/Jev Voice/app-actions.json
```

The file contains an `actions` array. Each entry has an `app` name (or `*`),
an optional `bundleId`, a display `name`, matching `phrases`, and key steps:

```json
{
  "actions": [
    {
      "app": "Devin",
      "name": "new session",
      "phrases": ["new session"],
      "steps": [
        {"kind": "key", "key": "n", "modifiers": ["command"]}
      ]
    }
  ]
}
```

Disable or edit these shortcuts in Settings. Everything still works through
the generic observe → Jev → act → verify loop without this file.

Native Accessibility can read the target window's tree in-process for lower
latency and uses Cua when the tree is too thin. Disable it in Computer use
settings to use the Cua observer exclusively.

When an app exposes almost no accessible controls, the optional OCR fallback
uses Apple Vision locally to read visible labels and click their screen
coordinates. It requires Screen Recording permission and can be disabled in
Settings › Computer use.

DeepSeek screenshots are resized to reduce request cost. The fallback budget
is configurable as **Fallback max steps** and **Fallback max seconds** in
Settings › Computer use.

End words are `do it`, `execute`, `send it`, `over`, and `that's it`; `go` is
kept as navigation language rather than ending a command.

## Debugging

Inspect recent Jev Voice logs with:

```sh
log show --last 5m --predicate 'subsystem == "com.chriswozniczek.jevvoice"' --info
```

Useful structured log keys include:

- `stage=axtree elements=... partial=...`
- `stage=ocr`
- `stage=click`
- `outcome=...`
- `analyzer final=...`

The step list includes a **Clear** button for removing completed local steps.

## Limitations

- Jev is text-only and never generates strings, so URLs/queries/dictation come
  from heuristics over the transcript, not from the model.
- System actions are AppleScript/`pmset` based; brightness key codes may vary
  on some hardware.
- App launching scans standard macOS application directories and running
  regular applications, with aliases and user-defined aliases from Settings.

## Privacy

- Speech recognition runs on-device (`requiresOnDeviceRecognition` when supported).
- The transcript, frontmost app name, installed app list, and configured app
  aliases are sent to `api.typesafe.ai` when routing requires Jev. Your API key
  stays in local `UserDefaults`.

## License

Jev Voice is available under the [MIT License](LICENSE).
