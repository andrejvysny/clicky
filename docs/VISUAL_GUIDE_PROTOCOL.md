# Visual task guide protocol

The development app uses one Clicky-owned task and one provider process. The user performs desktop actions. Release walkthrough presentation is gated in `VisualGuideController+Turns.swift` until the native acceptance matrix passes. `ClickyCapabilities.verifiedGuidance` remains false.

## Contracts and ownership

`GuideContract` packages prompt `clicky-guide-3`, isolation profile `clicky-isolation-1`, and the shared strict JSON schema. All portable contracts are explicitly `nonisolated`. The app compiles these sources directly; it does not link another copy of ClickyCore.

`GuideAgentTurn` sends a JSON host request containing `protocolVersion`, `purpose`, `text`, optional `task`, and optional `capture` (window or display). Purposes are planning, sideQuestion, verification, continuation, recovery, and oneOffContext. Task context contains the goal, task ID, step/context revisions, current step, and milestone provenance. Images accompany the request as Claude image blocks or Codex image data URLs over stdin.

Responses are exactly one of:

| Variant | Required meaning |
|---|---|
| `context_request` | Approved window overview, or a detail crop referencing the current capture ID |
| `guide_step` | Short instruction, capture ID, pixel target, expected action, independently checkable outcome; optional `detail`, `mark`, `value`, dim `ghost` target and `estimatedSteps` |
| `annotation` | Answer `text` (shown under the input), pixel target, `mark` (circle, underline, highlight, arrow, value + `value`), short `label`; points only, never progress |
| `explanation` | Readable conceptual answer |
| `clarification` | One necessary question |
| `verification_result` | Current capture ID, Boolean verdict, concrete outcome evidence |
| `task_completed` | Fresh evidence confirming the entire goal |
| `task_proposal` | Proposed distinct goal; replacement requires the host's choice |

Every schema field is required, with nullable fields for unused values. Unknown fields, invalid nested objects, missing grounding, nonfinite/out-of-image rectangles, unsupported keys, stale capture IDs, and inappropriate response purposes fail closed. Responses are buffered until validation; raw JSON never reaches the UI. Targets and crops use image pixels. Expected key masks use AppKit Command/Option/Shift/Control bits; only matching key metadata is retained, never typed characters.

The host owns locating, waiting, verifying, uncertain, paused, completed, and canceled states. It serializes provider turns and captures. Task/step/context revisions, transaction generations, and capture leases reject late work after cancellation, replacement, movement, or revocation. Each planning request permits two evidence acquisitions, including an initial image and any detail crop. Verification permits one fresh check and one fresh recheck; persistent uncertainty stops automatic turns.

An action attempt, a verified outcome, and manual acknowledgement are separate. Next records a manual milestone. A different route can satisfy the same independently checked outcome. Final verified completion requires fresh evidence; Finished manually explicitly records manual completion. A side question (only while a walkthrough is visible) preserves the task and cannot produce a step or completion; it may point with an annotation. An `explanation` carrying a capture ID and valid target is normalized to an annotation. An annotation or step whose capture is stale (or whose mark falls outside the 2% edge slack) gets one automatic fresh capture before failing. Resume and Retry relocate against fresh evidence. Failed/canceled user turns restore text only.

## Sharing boundary

Quick Ask resolves the originating PID/application/window before taking focus. Opening it captures nothing and sends nothing. The popup remains beside its original opening position; it no longer tracks the pointer. Text is submitted first. A context request grants the originating window under Automatic sharing; consent was given once at setup and nothing prompts mid-task. Off prevents sharing and the answer is text-only with a Settings hint. An explicitly attached image can still support an explanation.

Legacy Always migrates by its saved raw value to Task window. Legacy Off and Ask each time retain their intent. Saved project directories and coding-session bindings are retired. Preferences and isolated authentication persist; task content, responses, snapshots, and milestones are in memory.

A grant identifies an exact window and process. Independent capture uses `SCContentFilter(desktopIndependentWindow:)`. Established AX-related sheets, dialogs, and menus can be included through explicit window inclusion; `includeChildWindows` and shadows are disabled. A same-app unrelated window is not included. Without a reliable relationship, use Change target and explicitly select the window. There is no application-wide fallback. With no identifiable window (e.g. the desktop), the display under the pointer at ask time becomes the task's grant target (`WindowCaptureTarget.display`), only when the setup consent allows it. It uses the same capture envelope, observation, target guard and verification as a window; it has no AX window, so AX outcomes and field reads are unavailable and app activation does not pause it.

Capture envelopes contain capture/time, task/step/context revisions, grant, PID/application/window/display identities, included window identities, image dimensions, global top-left captured region, and pixel-to-desktop scale/translation. Detail captures have their own envelope and transform. PNG limits are 3 MiB and 4096 pixels per axis; overview sizing is at most 1568 pixels on the long side and 1.15 MP. A capture failure never silently sends text without the requested evidence.

Pause cancels queued captures/transmissions and invalidates leases. Closing/minimizing the target or activating another window pauses guidance. Returning requires fresh validation. Screen Recording is requested only through an authorized capture. Accessibility is optional: denied/custom controls use vision and manual Check now.

## Presentation

Chat answers, errors and annotation text appear under the Quick Ask input. Walkthrough instructions appear in the notch island: n/N (N is the model's estimate), segmented progress (verified filled, user-confirmed outlined), title, detail, waiting status and ⌥⇧← back · ⌥⇧→ skip · ⌥⇧R retry · ⌥⇧⌫ end. The target carries only the mark (and a label for one-off annotations) plus the companion. Marks are drawn on one click-through panel per display above open menus; one bright mark at a time, at most one dim ghost, the label never overlaps the target and stays inside its window. Captures exclude Clicky's own windows.

## Observation and freshness

Observers run only while waiting. Opening Quick Ask stops them, so composer Enter/clicks cannot satisfy a target step. Mouse matching uses recorded position, timestamp, button, and click count. Double-click steps reject the first click and use the OS interval for coalescing. Expected keys reject repeats/duplicates; other character/key data is discarded. Field reads are bounded, scoped to the approved AX tree, and exclude secure fields. Value notifications invalidate annotations without per-character cloud requests; commit keys or leaving the expected field trigger verification.

Relevant interactions, focus/menu changes, and AX notifications coalesce verification. A bounded local AX predicate can confirm a changed outcome. A predicate already satisfied before the step cannot itself verify that step; fresh vision is required. Unsupported notifications have Check now. Local target-region comparisons remove stale annotations while waiting; they never initiate provider turns. No pointer-driven, per-character, or periodic cloud screenshots occur. Provider verdicts and final completion are checked against a new local capture before acceptance. Uncertainty removes the annotation and offers refresh.

The target circle/companion stay click-through. Separate nonactivating controls provide Check now, Retry, Next, Pause, scope changes, and End. Pause/End remain usable during active requests. Checklist/sharing details are collapsed by default. They show the exact window, last transmission, and manual/verified provenance. The no-AI demo uses deterministic fixtures, performs no capture, and never claims real outcome verification.

## Provider isolation

Clicky's requested defaults are Claude `claude-haiku-5-5` and Codex `gpt-6-luna`, both at `low` effort. The user may raise effort for one prompt (Quick Ask ⌥⇧E); follow-up checks, retries and manual Next run at `low`. Claude receives explicit model/effort flags at process launch, so a running task keeps its launch effort; Codex receives process configuration (audited at `low`), thread model and per-turn model/effort. Model access failures are visible and never trigger substitution. Model IDs/effort support: [Claude Haiku 5.5](https://platform.claude.com/docs/en/models/haiku-5-5/overview), [Claude effort](https://platform.claude.com/docs/en/build-with-claude/effort), [GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna).

Claude uses normal authentication, safe mode, empty setting sources, owned settings/system prompt, no tools except the schema adapter, strict MCP, disabled slash commands, and no session persistence. Debug output is directed to `/dev/null`. Preflight audits file/drop-in/remote-cached/MDM policy. Read-only control requests inspect effective settings before each user/image submission. Hooks, helpers, custom instruction sources, and incompatible settings block the backend. Claude's three bundled plugin metadata entries are allowed; custom plugins are rejected. Builtin agent names do not grant execution tools. CLI upgrades require compatibility and marker revalidation.

Codex uses a dedicated child `CODEX_HOME`, official ChatGPT sign-in, owned working directory, explicit base/developer instructions, ephemeral thread, and per-turn output schema. Strict configuration disables instruction discovery, memories, hooks, plugins/apps, shell/exec, browser/computer use, delegation, image/file tooling, and unrelated capabilities. Effective configuration and empty instruction-source diagnostics are required. Host-discovered skills are enumerated separately, disabled in the owned configuration and thread overrides, and configured MCP servers are disabled per thread. Approval/tool requests are declined. Authentication is never copied from a personal Codex profile or extracted by Clicky.

The process/conversation remains alive across task steps and side questions. Only an active provider turn has a five-minute timeout. Local waiting has none. End closes the process. Unexpected loss requires explicit Retry into a fresh session with the in-memory task context; the submitted prompt is never automatically replayed. `clicky-guide` tests this runner and prints presentation kinds only. `clicky-text` remains a legacy diagnostic and is not the app's guide runner.

Local memory-only behavior is separate from provider retention after transmission. Native real-provider storage/isolation acceptance must verify the absence of prompt/image transcripts after each CLI/profile/prompt upgrade. Turn IDs correlate provider results; stale results cannot finish another request. Owned task files are removed after child exit rather than while it can still write.

## Validation and release

Run `bash scripts/test-core.sh` (use `--disable-sandbox` if the host already sandboxes SwiftPM and nested sandbox creation is denied), `bash scripts/typecheck-app.sh`, and `bash scripts/typecheck-app.sh --debug`. The typecheck script uses a temporary Sparkle declaration stub, so it does not replace a real Xcode build. Build/run/test using Xcode's shared legacy scheme only; never terminal `xcodebuild`.

The native matrix and current evidence are in [MAC_VALIDATION.md](MAC_VALIDATION.md). Plane remains authoritative for product decisions and future work; this document describes the version-specific implementation, not a backlog.
