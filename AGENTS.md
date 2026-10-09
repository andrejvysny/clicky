# Clicky — Agent Instructions

## Current delivery

Native macOS companion, macOS 14.2+, Apple Silicon. Quick Ask, local preview, clean Claude/Codex sessions, and development visual task guides are active. Preserve the original blue companion, cursor animation, shortcut/editor behavior, and legacy `leanring-buddy` directory/scheme. Release walkthroughs remain gated until native acceptance passes; do not change capability flags based on portable tests alone.

`CompanionAppDelegate` starts `AskController`, the notch-anchored island shown only for walkthrough instructions (`IslandController`: the current step card with n/N progress, title, detail, waiting status and ⌥⇧ shortcuts; blocked or uncertain steps), Quick Ask beside the cursor with every chat answer and error under its input, the companion spinner with faded elapsed seconds while working and a red companion on error, Carbon hotkey, and text-mode companion. It does not start the dormant voice pipeline, analytics, permission polling, onboarding, Cloudflare warmup, updater, or login item.

Default backend remains **Local preview (no AI)**. Settings (Preview backend) offers a deterministic no-AI guide demo, with no captures or real verification. Shortcut is Option+Shift+Space, configurable. Enter sends, Shift+Enter inserts a newline, Escape stops a running reply and otherwise closes; IME composition must not prematurely submit. Preserve indentation, paths, Unicode, and line breaks. Quick Ask owns temporary keyboard focus; companion/circle stay click-through. The island is nonactivating and never key; its buttons accept clicks without activating Clicky. The island is hidden unless a walkthrough needs it; it never asks for sharing. Conversation stays at the cursor: Quick Ask stays open after Enter with its top edge fixed, the answer appears under the input and the input keeps focus for a follow-up. While a reply runs, Quick Ask ignores outside clicks and app switches so the answer always lands under the input; afterwards the next outside click closes it. A walkthrough step closes it so the user can act. The full reply stays available from the menu.

Setup (`WindowSnapshotCapture.runFirstLaunchSetup`, versioned by `clickySetupVersion`) asks for Screen Recording, one Allow/Not now alert for screen sharing (sets Automatic or Off and the display-fallback preference), and the Accessibility prompt. The only later prompt is session display consent (below); capture fails with a Settings pointer instead, and with sharing off answers are text-only with a one-line Settings hint. Opening Quick Ask captures no images and sends nothing. The only read on open is the opt-in (default Off) "Attach selected text": `AXSelectedText` of the focused, non-secure element in the originating window, bounded to 16 KiB, held in memory as a removable quote. Long multi-line pastes collapse to verbatim chips. Effort (Low/Medium/High) is per prompt and resets to Low after sending; Codex applies it per turn, Claude fixes it at task-process launch. Submit text first; the agent requests context through the shared schema when needed. With Automatic sharing (default) the window Quick Ask was opened from (or, when Clicky itself was frontmost, the app the user came from) is shared automatically per question; with no identifiable window (e.g. the desktop) the display under the pointer at ask time is bound as the task's target, and before its first capture Clicky asks once per running process, display and provider (`GuideDisplayConsent`; Share display or Text only). The persisted preference (legacy `displaySharingApproved` migrates to `displayFallbackAllowed`) is never a live grant; relaunch or turning it off clears the grant, so annotations and full walkthroughs (observation, target guard, verification) work on the desktop too; a display target has no AX window, so AX outcomes and field reads stay off. Pointing requests return an `annotation` (target, `mark` circle/underline/highlight/arrow/value, short `label`, answer `text` shown under the input; no action/outcome, never provenance); targets get 2% edge slack, and a stale capture id on a mark or step gets one automatic fresh capture. Legacy Always and the retired Confirm per task migrate to Automatic; Off keeps its intent. Exact window/process grants include only established related UI. Use independent-window capture or explicit window inclusion with automatic children disabled. Never implicitly capture an entire app, and never capture a display without that session consent. PNGs remain in memory, at most 3 MiB/4096 px per axis; overviews at most 1568 px long side/1.15 MP. Capture envelopes bind IDs, revisions, transforms, scope and geometry. Pause invalidates leases and stops pending transmissions.

`GuideAgentSession` keeps one child process/conversation alive per task, and across plain answers so follow-up questions keep context; New conversation, provider change, task end, errors, or an explicitly raised Claude effort close it. Claude uses normal authentication, safe mode, empty setting sources, replacement prompt, no tools, strict MCP, schema output, and no session persistence. It audits effective settings before every user/image submission. Codex uses a dedicated child CODEX_HOME, official ChatGPT sign-in, explicit base/developer instructions, ephemeral thread, output schema, strict capability/source diagnostics, separately disabled host skills, and disabled MCP servers. Never copy/extract personal credentials, resume a personal coding chat, select a project runtime directory, add permission bypasses, or automatically replay a submitted request.

The host owns guide state, evidence freshness, observation, outcome verification and completion provenance. Matching input is an attempt, not success. Manual Next never claims verification. Two planning acquisitions maximum; verification has one initial check and one fresh recheck. Persistent uncertainty offers Retry/Next. Side questions pause/preserve; distinct goals require Keep current task/Start new task. All walkthrough content/evidence stays in memory; only preferences, clean configuration, and isolated authentication persist. Provider retention after transmission is separate.

See [visual guide protocol](docs/VISUAL_GUIDE_PROTOCOL.md) and [native validation](docs/MAC_VALIDATION.md) for precise behavior and gates.

## Source map

| Files | Responsibility |
|---|---|
| `TextInput/AskController.swift` (~190 lines) | Preferences, in-memory composer/attachments, guide bridge and isolated sign-in |
| `TextInput/QuickAskPanelManager.swift` (~140 lines) | Cursor placement, focus ownership/restoration, dismissal observers |
| `TextInput/QuickAskEditor.swift` (~80 lines) | Plain-text NSTextView, IME-aware key handling, bounded editor growth |
| `TextInput/IslandController.swift`, `IslandView.swift`, `IslandGuideControls.swift`, `IslandChrome.swift` | Status island: mode derivation, top-center panel on the pointer's display, notch metrics, glyph wings, walkthrough step card and attention controls, shared black card style |
| `TextInput/CursorAskView.swift` | Quick Ask card beside the companion (inline attachment icons, effort dots, answers/errors/annotation text below the input) |
| `TextInput/Core/IslandLayout.swift` | Testable island footprint and top-center frame |
| `TextInput/ClickyChrome.swift` | Shared pieces: effort pips, spinner, status dot, keycaps |
| `TextInput/ScopedShortcuts.swift` | Option+Shift shortcuts registered only while visible: ⌥⇧←/⌥⇧→/⌥⇧R/⌥⇧⌫ (back/skip/retry/end) during a guide step, ⌥⇧C/⌥⇧V while Quick Ask shows a reply |
| `TextInput/Core/AskComposition.swift` | Effort levels, selection quote bounds, paste-chip threshold, fenced message composition |
| `TextInput/QuickAskView.swift` (~170 lines) | Clicky window from the menu: full last reply or grouped Settings (backend, shortcuts, screen, speech) |
| `TextInput/AppSettingsView.swift` | Native Settings scene using the same live AskController and preferences as the companion menu |
| `TextInput/QuickAskHotkey.swift` (~110 lines) | Carbon shortcut registration (per-identifier handlers), rebinding and shortcut labels; no keylogging/event tap |
| `TextInput/Core/ShortcutRegistration.swift`, `Core/ShellPanelLayout.swift` | Transactional shortcut replacement and finite, top-anchored panel geometry; native hosting layout is deferred/coalesced |
| `TextInput/GuidanceStepController.swift` (DEBUG only) | Debug guidance circle/card, scoped click/key observation, verification logging |
| `TextInput/Core/ScreenPointing.swift` | Capture sizing, pointing instruction, tag parsing/streaming stripping, pixel-to-screen mapping |
| `TextInput/PointingPresenter.swift`, `AnnotationOverlay*.swift`, `GuidanceOverlay.swift` | Click-through per-display annotation marks (circle, underline, highlight, arrow, value callout, dim ghost; one bright mark; label never overlaps the target and stays in its window; tones) and companion flight; `GuidanceOverlay` keeps the DEBUG step card |
| `TextInput/Core/AnnotationGeometry.swift`, `Core/CalloutPlacement*.swift` | Pure mark geometry and label placement adapted from adammcarter/annotate (MIT, see `THIRD_PARTY_NOTICES.md`) |
| `TextInput/Core/GuidanceDebugRequest.swift` | `clicky-debug://` request parsing and key-name table |
| `TextInput/TextCompanionPanelView.swift` (~185 lines) | Status-first menu panel: session state, modes/shortcuts (voice/Dictate shown Not enabled), effort, last reply, companion visibility |
| `TextInput/Core/AskModels.swift` | Request/session/events, validation, cancellation generations and recovery state |
| `TextInput/Core/AgentProcess.swift` | Portable process pipes, concurrent stderr draining, bounded framing, timeout/cancellation |
| `TextInput/Core/JSONProtocol.swift`, `CodexConversation.swift` | Provider wire encoding/parsing and text-only permission behavior |
| `TextInput/VisualGuideController*.swift` | Serialized task/capture/verification flow, recovery, automatic window/session display sharing, annotations |
| `TextInput/GuideObserver.swift`, `ScopedAccessibility.swift` | Scoped expected events, bounded nonsecure AX reads, local fallback checks |
| `TextInput/GuideEnvironment.swift` | Injectable native effects (clock, capture, AX, event sources, provider factory) for the coordinator and observer; `.live` in the app |
| `TextInput/Core/GuideControlAvailability.swift` | Which island controls are enabled; End/Pause never wait for a busy turn |
| `TextInput/Core/Guide*.swift` | Shared prompt/schema/host requests, task grants/evidence/provenance, clean provider transports and preview fixture |
| `TextInput/Core/PopupPlacement.swift` | Testable point-space placement and clamping |
| `TextInput/Core/ImageAttachment.swift` | Bounded PNG payloads, originating-window identity and per-presentation capture leases |
| `TextInput/WindowSnapshotCapture.swift` | Native scoped ScreenCaptureKit capture and in-memory PNG encoding |
| `TextInput/LocalReplySpeech.swift` | Local system reply speech and cancellation |
| `TextInput/Core/HybridRecordingGesture.swift` | Future Ask/Dictate tap/hold state machine; not audio capture |
| `TextInput/Core/GuidanceVerification.swift` | Expected-action/outcome gate and dictation-destination eligibility; not native observers/insertion |
| `TextInput/Core/SupportingCapabilities.swift` | Unavailable capability flags and supporting contracts |
| `CompanionManager.swift`, `OverlayWindow.swift`, `DesignSystem.swift` | Original blue buddy state, visuals, animation and design tokens |
| `MenuBarPanelManager.swift`, `leanring_buddyApp.swift` | Menu-bar shell and text-first lifecycle |
| `Tools/ClickyGuideCLI/` | Clean structured transport diagnostic; kinds only, no persisted requests |
| `scripts/audit-codex-isolation.mjs` | Temporary unauthenticated configuration/runtime-capability audit; no model inference or personal credential access |
| `Tools/ClickyTextCLI/` | Legacy text diagnostic, not the app guide runner |
| `Tests/ClickyCoreTests/` | Portable behavioral/process tests and offline Python fixture |
| `Tests/ClickyGuideNativeTests/` | macOS-only coordinator tests: the production `VisualGuideController`/`GuideObserver` compiled by SwiftPM with a fake clock, screen, AX and scripted provider |
| `leanring-buddyUITests/QuickAskUITests.swift` | Five Mac-only preview/guide demo UI tests |

Paths above are relative to `leanring-buddy/` unless their directory is at repository root.

## Supporting scope

Local ASR, smart cleanup, system-wide dictation insertion, visual MCP, and live terminal attachment are **not enabled**. Visual guidance/auto-advance are development-only until the native matrix passes. Contracts and deterministic supporting state machines exist, with setup in `docs/SUPPORTING_SETUP.md`. Scoped screenshots, annotations, and automatic Claude browser/desktop walkthroughs have native development-build evidence in `docs/MAC_VALIDATION.md`; the full release matrix and system speech remain unvalidated. DEBUG builds only: `clicky-debug://guide?x=&y=&w=&h=&text=&expect=click|rightclick|key[&key=&mods=cmd,shift,opt,ctrl]` (global top-left points) draws a click-through circle and step card, and `clicky-debug://cancel` clears it. A global mouse monitor and, only during an active key step with Accessibility granted, a global key monitor feed `GuidanceVerification`. Non-matching keys are counted only, never stored, displayed, or logged. Matches are reported as action-verified, not outcome-verified. Results go to the unified log (category `guidance`, non-sensitive fields only). Do not set release capability flags true without validating the actual native feature. No microphone or automatic screen capture should be triggered by typed Ask.

Legacy `BuddyDictationManager`, AssemblyAI/OpenAI/Apple speech providers, ClaudeAPI, ElevenLabs client, onboarding views, and `worker/` remain for reference. They are not current app prerequisites. Migrate these incrementally; keep known nonblocking Swift concurrency and deprecated `onChange` warnings unchanged.

## Build and verification

Open `leanring-buddy.xcodeproj` in **Xcode 26+ / Swift 6.2+** (the target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); select shared scheme `leanring-buddy`, set the user's signing team, Cmd+R to build/run, and Cmd+U for native tests. **Do not run `xcodebuild` from the terminal**: the repository prohibits it because it affects TCC permissions.

The Xcode app compiles the synchronized `leanring-buddy/TextInput/Core` files directly. Root `Package.swift` compiles the same files as ClickyCore in Swift 5 language mode with the app target's MainActor default isolation and approachable-concurrency features, and also builds `clicky-guide` and the legacy `clicky-text`. Core declarations are explicitly `nonisolated`; keep new Core types `nonisolated` so process readers never hop to the main actor. Do not link a duplicate ClickyCore copy into the app.

Portable checks: `bash scripts/test-core.sh` with Swift 6.2+ and Python 3. On macOS the same command also builds target `ClickyGuideNative` from the app's coordinator/observer sources (Core imported via `#if canImport(ClickyCore)`) and runs `ClickyGuideNativeTests`; these use injected `GuideEnvironment` fakes, touch no TCC-protected API and are not native event/focus or GUI evidence. App-source typecheck without building/signing: `bash scripts/typecheck-app.sh` and `--debug`; see `docs/MAC_VALIDATION.md`. Never terminal `xcodebuild`. Cloud installation: `bash scripts/cloud-setup.sh` uses the official signed Swift 6.2.3 Debian toolchain and pins its signing fingerprint. Caches stay outside tracked source. Linux Foundation subprocess lifecycle tests require local socket IPC; if sandboxing blocks the wakeup socket pair, run the test command with the appropriate execution permission rather than disabling tests.

Mac preflight: `bash scripts/mac-preflight.sh`. Detailed acceptance, real-provider compatibility, and remaining limitations: `docs/MAC_VALIDATION.md`. AppKit syntax parsing in Linux is not Mac typechecking or GUI validation. Never claim native tests ran without a Mac.

The `--clicky-ui-test` launch argument selects a dedicated preferences domain, preview backend, no hotkey/companion/capture target, and a panel that remains visible after submission for assertions. It does not validate production focus restoration.

## Conventions

- All UI state updates are on `@MainActor`; keep audio/model/process work off the UI thread.
- Use SwiftUI for views and AppKit where native focus/windows/text input require it.
- Use clear descriptive names, async/await, and comments explaining non-obvious decisions.
- All interactive buttons must show a pointer cursor on hover.
- Track request IDs/generations so stale callbacks cannot mutate a later interaction.
- Field-entry steps wait for the explicit commit key or departure from the expected field. Bubbled AX value/selection notifications must not trigger per-keystroke verification. Compare freshness using the original capture region/output dimensions before cropping; do not independently resample the target crop.
- Audit every owned Codex configuration override and runtime feature restriction before the first user turn; missing or contradictory diagnostics fail closed even for an allowlisted version.
- Preserve pre-existing user changes. Do not change unrelated features or known warnings.
- Never log raw prompts, replies, screenshots, clipboard contents, credentials, or sensitive AX values.
- Do not perform desktop actions or synthesize Enter. Future dictation must validate its original destination and offer Copy on uncertainty.
- No product subagent platform or automatic live-terminal typing.
- No force-pushing main. Suggested branches: `feature/description` or `fix/description`; imperative commit messages explaining why.
- Use existing checkouts in cloud tasks; do not create Git worktrees unless explicitly requested.
- Update these instructions when architecture, build commands, or file responsibilities change.
