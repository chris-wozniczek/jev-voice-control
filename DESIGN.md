# Jev Voice design

Jev Voice is a layered macOS voice-control system. Speech is recognized locally,
then a transcript is split into clauses and handled by the deterministic local
parser or the TypeSafe Jev router. Jev returns typed choices and probabilities;
it does not generate the text that the app types.

## Execution layers

1. `ClauseSplitter` and `LocalCommandParser` handle deterministic commands and
   extract URLs, queries, dictation text, percentages, and compose briefs.
2. `CommandInterpreter` asks Jev for typed action, target-app, system-action,
   and intent judgments when local parsing is insufficient.
3. `Executor` handles local app, URL, system, and typing actions.
4. Computer-use requests enter `AgentRunner`, which observes the target app,
   asks Jev to choose one next action, executes it, and re-observes to verify.
5. Native Accessibility is preferred. Cua, OCR, Chrome DevTools Protocol, and
   DeepSeek are bounded fallbacks for sparse trees, visible-only controls,
   Chromium/Electron content, and planner escalation.

## Safety and verification

The bundled policy rejects blocked shell, credential, payment, and irreversible
operations. Confirmation is required for configured destructive actions, with a
browser-scoped confirmation list for send/submit/post-style controls.
Typing uses in-process keyboard events first and verifies the resulting field
value or snapshot; the Cua typing path is used as a fallback when necessary.

## Speech lifecycle

Hold-to-talk is the default interaction: Option-Space starts listening and
release finalizes the utterance. Toggle mode is available in Settings. Speech
Analyzer streaming is selected by default when the macOS 26 engine is available;
classic Apple speech and Whisper remain selectable alternatives.
