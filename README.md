# Jev Voice

A macOS menu-bar app that turns spoken commands into actions using
[TypeSafe AI's Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev)
— a System One model that returns *typed decisions with probabilities* instead of
generated text.

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

Speech is transcribed **on-device** (SFSpeechRecognizer). Only the transcript is
sent to the Jev API.

Typing activates the target app before every keystroke path and reads the
focused field back after typing. If the field does not show the text, Jev uses
an in-process Unicode keyboard fallback and keeps the task open for
verification. Settings › Hearing includes extra vocabulary for sites, models,
and products; the same words are supplied to Apple Speech and Whisper. Whisper's
language code is configurable in Settings › Hearing; leave it blank for
automatic language detection. When Whisper is selected, its model is loaded at
app launch so the first tap can start listening immediately.

## How it works

### How it decides

Jev first interprets deterministic local commands, then picks the next action
from the live accessibility elements on screen. DeepSeek Flash is an optional
fallback for open-ended tasks or screens without accessible controls.
Goal words rank matching controls ahead of unrelated settings, while a newly
opened Settings, Preferences, or About surface is detected and closed so the
request can continue on the original window.

Computer use settings let you choose the Jev step planner or DeepSeek Flash,
and control DeepSeek thinking (off, low, or high). In Jev mode, the DeepSeek
key is optional and is only used for fallback.

### Learned shortcuts

After a successful UI task, Jev remembers the app control that worked for that
goal. Similar requests can use those learned labels as additional context
without bypassing the live-screen decision.

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
Choose the default browser in Settings › Computer use; a browser named in the
command overrides it. Site workflows open the requested host before the
generic computer-use loop starts.

Requests such as “compose a post on X about the new release” generate wording
for the requested site, open X, and continue through the normal observe,
choose, type, and verify flow. The bundled x.com shortcut can press `n` once
to open the composer when no text field is visible. Post, Send, Publish, Tweet,
and Reply controls require confirmation before submission.

```
microphone ──> SFSpeechRecognizer (on-device) ──> transcript
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

Jev never produces free text — each clause is one `systemOne` call with a state
payload (`clause`, `full_transcript`, `frontmost_app`, `installed_apps`) and six
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
- **Accessibility** — required for the Cmd+V paste used by dictation
- **Automation** — required for `osascript` volume/brightness actions

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

End words are `do it`, `execute`, `send it`, `over`, and `that's it`; `go` is
kept as navigation language rather than ending a command.

## Debugging

Inspect recent Jev Voice logs with:

```sh
log show --last 5m --predicate 'subsystem == "com.chriswozniczek.jevvoice"' --info
```

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
- Only the transcript, frontmost app name, and installed app list are sent to
  `api.typesafe.ai`. Your API key stays in local `UserDefaults`.
