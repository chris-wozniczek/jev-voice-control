# Jev Voice — design

Jev Voice is a macOS menu-bar app that lets you operate the computer by
talking: open, close and arrange apps, type into whatever is focused, drive
Devin Desktop, cmux, Notes, Chrome and arbitrary websites. This document
explains how it is built and, more importantly, why it is built this way. It
reflects v0.9.1.

## Design principles

1. **Decide, don't generate.** Every decision that matters — which command a
   clause is, which app it targets, which on-screen control to act on, whether
   the utterance is finished, whether the goal is achieved — is a *typed
   choice or probability* returned by TypeSafe's Jev (a System One model), never
   free text. Jev cannot hallucinate a button that isn't there because it only
   picks from candidates we hand it. Arguments (URLs, queries, dictated text)
   are extracted deterministically from the transcript.
2. **Ground every action in a fresh observation.** No action is taken on a
   coordinate or element the app has not just observed. Pointer and keyboard
   events are real CGEvents, but they are always aimed at geometry read from the
   Accessibility tree or from OCR of the current screen — never at coordinates a
   language model invented.
3. **Verify before claiming done.** Every mutation has a postcondition (field
   contains the text, element count changed, window appeared, tree diff). The
   app never says "Done" from a planner's confidence alone.
4. **Local first, fast.** Most commands are handled by a deterministic parser
   with no network call. Jev calls are single round trips (~100–300 ms). Speech
   is transcribed on-device.
5. **Bounded fallbacks, generic code.** OCR, Accessibility wake-up, Chrome
   DevTools and DeepSeek exist for the cases native Accessibility cannot cover,
   and each is entered in a fixed order with a fixed budget. There is no
   per-app patch layer; app knowledge lives in data files (`app-actions.json`,
   `web-sites.json`, `policy.json`).

## The pipeline

```
 hold ⌥Space ─► SpeechAnalyzer / Apple Speech / Whisper (on-device)
                          │ release = end of utterance (hold mode)
                          ▼
                 TranscriptNormalizer · ClauseSplitter
                          │  one clause per command; content after
                          │  "type/write…" is never split
                          ▼
        ┌──── LocalCommandParser (deterministic, ~0 ms) ────┐
        │ matched                                            │ not matched
        ▼                                                    ▼
     Executor                                     Jev router (1 request)
  NSWorkspace / CGEvent /                  action · target_app · system_action
  osascript / pmset                        mentions_url · refers_to_frontmost
        │                                  composes · destructive
        │                                                    │
        │                          ┌─────────────────────────┤
        │                          ▼                         ▼
        │                    local action               uiTask / dictate
        │                    via Executor                    │
        │                                                    ▼
        │                                              AgentRunner
        │                                   ┌──── fast path (app-actions.json,
        │                                   │     submit keys) — verified
        │                                   ▼
        │                          observe target window (AX tree, ≤1.5 s)
        │                                   ▼
        │                     Jev Choice: next_action from real candidates
        │                                   ▼
        │                        act once (AXPress → CGEvent click,
        │                        in-process Unicode typing, key press)
        │                                   ▼
        │                          re-observe → postcondition check
        │                                   ▼
        └──────────────────────► speak result / ask yes-no
```

### 1. Hearing

* **Engines.** `SpeechAnalyzerEngine` (macOS 26 streaming, default when the
  model is present), the classic `SFSpeechRecognizer`, and WhisperKit. All run
  on-device. Custom vocabulary (Devin, cmux, x.com, …) is fed to each engine
  and `TranscriptNormalizer` fixes recurring mishearings ("Devon" → Devin).
* **Push-to-talk.** Hold mode is the default: key-down starts the engine,
  key-up finalizes. There is no silence guessing, so nothing is cut off and the
  command fires ~50–300 ms after release. Toggle mode keeps a silence timer
  (1–5 s) with a Jev end-of-turn judgment on top: after a 0.6 s pause Jev
  answers `complete?`; ≥0.75 finalizes immediately, ≤0.35 keeps listening up to
  4 s, otherwise the timer decides (`EndOfTurnPolicy`, `SilenceGate`).
* **Lifecycle.** Only one SpeechAnalyzer may consume the audio stream at a
  time; `start()` awaits the previous analyzer's finish task before creating
  the next, and a key-up that arrives during that wait is replayed so every
  utterance finalizes exactly once.

### 2. Understanding

* `ClauseSplitter` finds command boundaries ("open Notes, then type hello")
  while treating everything after a dictation verb as content — "type the
  prompt, check RAM usage" is one command. Lone verbs followed by a comma
  ("Click, send") are not boundaries.
* `LocalCommandParser` covers the deterministic vocabulary: open/quit/switch/
  hide/minimize/maximize/full-screen/restore an app, go to a URL, search,
  type, volume, mute, lock, screenshot, dark mode, end words.
* Anything else goes to **one Jev request** with seven questions (see the
  README table). `SlotExtractor` then pulls the argument out of the clause:
  URL, query, percentage, or dictation text, including target-phrase stripping
  so "type in the prompt box to check CPU" types `check CPU`.
* `SafetyPolicy` (from `policy.json`) is applied to the transcript: blocked
  patterns (shell, payments, credentials, `rm -rf`-class phrases) refuse
  outright; `confirm` words always ask; `confirmInBrowser` words (send,
  submit, post, tweet, reply) ask only when the target is a browser or a site
  workflow. Sending a prompt inside Devin or cmux therefore needs no yes/no,
  posting on X does.

### 3. Acting on the UI (`AgentRunner`)

Every UI task runs through the same loop regardless of app.

**Target.** The router's `target_app` (or the sticky target carried over from a
previous clause, e.g. the app just opened) is resolved to a process and its
main window via `AXWindowLocator`.

**Fast path.** If `app-actions.json` has a phrase match for the app (e.g. Notes
"new note" → ⌘N) or the goal is a submit ("send the prompt" → ⌘↩ then ↩ in the
focused field), the keys are pressed and the *expected change* is checked
(element count, field emptied, menu title overlapping the goal words). A fast
path that cannot verify falls through to the generic loop instead of claiming
success.

**Observe.** `AXTreeReader` walks the target window's Accessibility tree
in-process (up to 600 elements, 1.5 s budget). Each snapshot carries
`partial: Bool`; a partial snapshot is never treated as evidence that the UI is
stuck. Electron apps often expose a sparse tree until touched, so a
`wake` re-observation focuses the window and re-walks; a `full` observation
spends up to 4 s.

**Choose.** `JevStepPlanner` ranks candidates (buttons, links, rows, tabs,
text fields, menu items; OCR labels when the tree is thin) by goal-word
overlap, excluding words that are *content to type*, and asks Jev one
`next_action` Choice over the real candidates plus `done`/`stuck`. Dictation
goals restrict candidates to text-input roles (`AXTextField`, `AXTextArea`,
`AXSearchField`, `AXComboBox`), so the content of a prompt can never select an
unrelated list row. Idempotency: a create/new/send control that already
changed the screen is not pressed again in the same run.

**Act.** One action per step. Clicks use `AXPress`; if the element refuses and
its frame is known, one real `CGEvent` click at the frame centre. Typing uses
in-process Unicode key events into the focused field (`KeyboardFocus`), with
the Cua helper as a bounded fallback. Keys are posted to the target process.

**Verify.** Re-observe and evaluate the action-specific postcondition
(`TextEntry.verifyTyped`, `SnapshotDiff`, window/element counts). Only a
verified change produces `done`. If the step budget runs out but the goal
is already verifiably met, the run reports success (`budget-but-goal-met`)
rather than a false failure.

**Recovery order when Jev says `stuck`:**

```
full re-observe (4 s) → Accessibility wake-up → forced OCR → bounded escalation → clear failure
```

* **OCR** (`OCRReader`, Apple Vision, local, ~0.1–0.3 s) turns visible text
  into positioned candidates that Jev can pick like any element; clicks land
  at the label's centre.
* **Chrome DevTools** (`CDPBridge`) reads the DOM of a Chromium/Electron
  window when the AX tree stays thin and remote debugging is enabled.
* **DeepSeek** (`DeepSeekPlanner`, tool-calling with a scaled screenshot) is the
  last resort for open-ended tasks, capped by `fallbackMaxSteps` (6) and
  `fallbackMaxSeconds` (30). It is entered in roughly 1 in 10 commands in
  practice, and every action it proposes still runs through the same
  act/verify path.

Runs are serialized: a new command while a run is active cancels the old one,
so two runs never fight over one window. The whole run has a 90 s wall clock.

### 4. Confirmation

Destructive or policy-flagged actions speak a question and wait. In hold mode
the answer is the next held utterance (or Yes/No in the popover) with a 15 s
timeout; the microphone is never opened unasked. In toggle mode listening
resumes automatically for 8 s. Accepted answers include "yes", "yes please",
"go ahead", "yes send it"; anything else cancels.

### 5. Learned tools and written replies

* **Learned tools** cover scriptable system tasks (dark mode, reminders,
  timers). Unknown command → Jev `scriptable?` → DeepSeek/oMLX writes an
  AppleScript/JXA tool → `osacompile`, policy scan, Jev review → spoken
  preview + yes/no → run → verify → cached under Application Support as a
  local fast path. UI work never goes through this path.
* **Written replies** ("write a note apologising for the delay"): Jev
  classifies the request as `composes`; DeepSeek or a local oMLX endpoint
  drafts the text (≤600 chars, 280 on x.com); it is previewed, then typed
  through the normal dictation path with verification.

## Module map

| Layer | Files |
|---|---|
| Hearing | `SpeechAnalyzerEngine`, `SpeechEngine`, `SpeechRecognizer`, `SilenceGate`, `EndOfTurnPolicy`, `HearingSettings`, `SpeechEnergy`, `TranscriptNormalizer` |
| Understanding | `ClauseSplitter`, `LocalCommandParser`, `CommandInterpreter`, `SlotExtractor`, `AppMatcher`, `GoalWords`, `JevClient`, `JevModels`, `SafetyPolicy`, `ExecutionPolicy` |
| Local execution | `Executor`, `InstalledApps`, `WebSiteRegistry`, `Permissions` |
| Computer use | `AgentRunner`, `AgentRouting`, `JevStepPlanner`, `FastPathPlanner`, `SubmitFastPath`, `AppActionRegistry`, `AgentRisk`, `SnapshotDiff`, `HintStore` |
| Observation & actuation | `AXTreeReader`, `AXWindowLocator`, `AXMenuBar`, `KeyboardFocus`, `TextEntry`, `OCRReader`, `CDPBridge`, `CuaDriver` |
| Fallback planners | `DeepSeekPlanner`, `AgentPrompt`, `ScreenshotScale`, `ContentGenerator` |
| Learned tools | `LearnedToolRouter`, `ToolSynthesizer`, `ToolExecutor`, `LearnedToolStore`, `LearnedTool` |
| UI | `VoiceController`, `ContentView`, `SettingsView`, `Speaker`, `Config`, `main` |

`JevVoiceCore` holds the pure, platform-free logic and is what the unit tests
exercise (clause splitting, slot extraction, policy, end-of-turn, codecs).
`JevVoice` holds AppKit, Accessibility, speech and networking.

## Budgets at a glance

| What | Value |
|---|---|
| AX walk (normal / full) | 1.5 s / 4 s, ≤600 elements |
| Jev request | one round trip per decision |
| End-of-turn judge | probe 0.6 s after a pause; finalize ≥0.75, wait ≤0.35 |
| Toggle-mode silence timer | 2.5 s default (1–5 s) |
| Confirmation timeout | 15 s hold / 8 s toggle |
| Fallback planner | 6 steps / 30 s (configurable) |
| Whole run | 90 s |
| OCR candidates offered to Jev | ≤60 (+ ≤200 AX elements) |

## Safety model

* Blocked patterns never execute, regardless of confidence.
* Confirmation words are data (`policy.json`, user-overridable) and are
  browser-aware.
* `AgentRisk` additionally flags destructive control labels (delete, remove,
  pay, uninstall, shut down, …) and browser posting labels before an element is
  pressed, even if the transcript did not contain the word.
* Every generated script (learned tools) must compile, pass the policy
  scanner and a Jev review, and is previewed aloud before its first run.
* Nothing leaves the machine except: the transcript and routing context to
  `api.typesafe.ai`; optionally a scaled screenshot and tool history to
  DeepSeek when the fallback planner is entered; optionally a brief to a text
  generator for written replies.

## Why not an LLM agent loop?

The previous generation of this app did use a generative planner as the main
loop. It was slow (4–6 s a step), produced coordinates that were sometimes
random, and confidently repeated create/send actions. Moving the decisions to
Jev — choosing among real candidates with a probability — made each step
~10× faster and made failures legible: the app can say *why* it stopped
(no text field visible, control refused, policy) instead of guessing. The
generative model is kept where generation is genuinely required: drafting
prose and writing scripts, both behind verification gates.

## Non-goals

* No cloud speech. Hearing stays on-device.
* No per-app hard-coded coordinates or selectors.
* No autonomous multi-minute agents; a command is one bounded task.
