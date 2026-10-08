# Clicky — Agent Instructions

## Current delivery

Native macOS menu-bar companion, macOS 14.2+, Apple Silicon. The active implementation is text-first: cursor-adjacent Quick Ask, offline preview, and managed Claude Code/Codex text sessions. Preserve the original blue companion and cursor animation. Do not rename the legacy `leanring-buddy` directory or scheme.

`CompanionAppDelegate` starts `AskController`, `QuickAskPanelManager`, a Carbon registered hotkey, and `CompanionManager.startTextMode()`. It does not start the legacy voice pipeline, permission polling, Cloudflare warmup, email onboarding, analytics, or automatic login-item registration. PostHog is removed; `ClickyAnalytics` is a compatibility no-op for dormant views. Sparkle is retained but its updater is not started.

Default backend is **Local preview (no AI)**; it visibly echoes text and must never be presented as a real agent response. Default shortcut is Option+Shift+Space, configurable in Settings. The shortcut opens a minimal ghost input that follows the pointer beside the companion (Option pins it, Command+Shift+A attaches); the full composer with backend/settings and the last reply opens from the menu bar. Ask popup is temporarily keyable; companion and response overlays remain nonactivating/click-through. Enter submits, Shift+Enter inserts a line, and Escape cancels. IME composition must not prematurely submit. Preserve code indentation, paths, Unicode, and line breaks. Drafts/replies stay in memory; only preferences and provider/project/session metadata persist.

Quick Ask's explicit Attach button captures only the window of the originating app resolved before popup presentation. Use `SCContentFilter(desktopIndependentWindow:)`, never a fallback display capture. Screen Recording is requested by the first capture (window attach or screen sharing). Preview the attachment before sending; PNGs stay in memory, are capped at 3 MiB and 4096 pixels per axis, and travel over stdin as Claude image blocks or Codex image data URLs. Popup dismissal/provider changes/removal invalidate capture leases. Failed or canceled agent turns restore text only; require an explicit new attachment. Screen sharing (Settings: Off / Ask each time / Always, default Always at the user's request) adds a display capture of the screen under the pointer via `SCContentFilter(display:excludingApplications:)` excluding Clicky's own windows. With Always it is captured automatically each time Quick Ask opens (never in the background or between asks); otherwise only from the eye button / Command+Shift+S. The filled eye and Screen chip always indicate an attached capture. Enter during a pending capture sends once it finishes; a failed capture keeps the popup open with its error instead of silently sending text only. Captures are sized by `CaptureSizing` (≤1568 px long side, ≤1.15 MP) so model coordinates are not rescaled, and carry `capturedRegion` (global top-left points). When an image has a region, Core appends the `ScreenPointing` instruction to the user message (not the system prompt, which Claude snapshots on the first turn). Replies ending in `[POINT:x,y:label]` / `[BOX:x,y,w,h:label]` are stripped, mapped to screen points, drawn by `PointingPresenter` (click-through circle + label, dismissed by any click or after 45 s), and the companion flies there. System reply speech uses AVSpeechSynthesizer, defaults to voice-only (typed requests silent), and supports Always plus explicit Speak/Stop. Preview does not automatically speak.

Managed Claude uses the user's installed binary and normal authentication, stdin stream-json, `--tools ""`, and `--strict-mcp-config` (no MCP servers/connectors). Codex uses app-server stdio launched with `-c features.apps=false -c features.plugins=false -c approvals_reviewer="user"`, account status, `config/read` followed by thread start/resume that disables every configured MCP server for the thread, turn streaming, a read-only sandbox, untrusted approval policy, and `approvalsReviewer: "user"`. Action approvals are explicitly declined in this text client. Do not add `bypassPermissions`, `--bare`, unsafe automatic approvals, shell prompt injection, or account-token extraction. Managed resume is not live terminal attachment. Never silently retry a submitted prompt.

## Source map

| Files | Responsibility |
|---|---|
| `TextInput/AskController.swift` (~190 lines) | Settings, in-memory drafts/replies, session metadata, serialized UI submission, recovery |
| `TextInput/QuickAskPanelManager.swift` (~140 lines) | Cursor placement, focus ownership/restoration, dismissal observers |
| `TextInput/QuickAskEditor.swift` (~80 lines) | Plain-text NSTextView, IME-aware key handling, bounded editor growth |
| `TextInput/GhostAskView.swift` (~120 lines) | Minimal cursor-following ghost input, attachment chip, inline errors |
| `TextInput/QuickAskView.swift` (~160 lines) | Full composer (menu Settings / Read last reply), backend selection, settings and shortcut capture |
| `TextInput/QuickAskHotkey.swift` (~80 lines) | Carbon shortcut registration and rebinding; no keylogging/event tap |
| `TextInput/GuidanceStepController.swift` (DEBUG only) | Debug guidance circle/card, scoped click/key observation, verification logging |
| `TextInput/Core/ScreenPointing.swift` | Capture sizing, pointing instruction, tag parsing/streaming stripping, pixel-to-screen mapping |
| `TextInput/PointingPresenter.swift`, `GuidanceOverlay.swift` | Production pointing circle/label and companion flight; overlay shared with DEBUG guidance |
| `TextInput/Core/GuidanceDebugRequest.swift` | `clicky-debug://` request parsing and key-name table |
| `TextInput/TextCompanionPanelView.swift` (~45 lines) | Menu controls, last-response reading/copy, companion visibility |
| `TextInput/Core/AskModels.swift` | Request/session/events, validation, cancellation generations and recovery state |
| `TextInput/Core/AgentProcess.swift` | Portable process pipes, concurrent stderr draining, bounded framing, timeout/cancellation |
| `TextInput/Core/JSONProtocol.swift`, `CodexConversation.swift` | Provider wire encoding/parsing and text-only permission behavior |
| `TextInput/Core/PopupPlacement.swift` | Testable point-space placement and clamping |
| `TextInput/Core/ImageAttachment.swift` | Bounded PNG payloads, originating-window identity and per-presentation capture leases |
| `TextInput/WindowSnapshotCapture.swift` | Native scoped ScreenCaptureKit capture and in-memory PNG encoding |
| `TextInput/LocalReplySpeech.swift` | Local system reply speech and cancellation |
| `TextInput/Core/HybridRecordingGesture.swift` | Future Ask/Dictate tap/hold state machine; not audio capture |
| `TextInput/Core/GuidanceVerification.swift` | Expected-action/outcome gate and dictation-destination eligibility; not native observers/insertion |
| `TextInput/Core/SupportingCapabilities.swift` | Unavailable capability flags and supporting contracts |
| `CompanionManager.swift`, `OverlayWindow.swift`, `DesignSystem.swift` | Original blue buddy state, visuals, animation and design tokens |
| `CompanionResponseOverlay.swift` | Compact streamed-response bubble; full reply remains in Quick Ask |
| `MenuBarPanelManager.swift`, `leanring_buddyApp.swift` | Menu-bar shell and text-first lifecycle |
| `Tools/ClickyTextCLI/` | Portable stdin-based text transport diagnostic |
| `Tests/ClickyCoreTests/` | Portable behavioral/process tests and offline Python fixture |
| `leanring-buddyUITests/QuickAskUITests.swift` | Four Mac-only preview UI tests |

Paths above are relative to `leanring-buddy/` unless their directory is at repository root.

## Supporting scope

Local ASR, smart cleanup, system-wide dictation insertion, visual MCP, persistent guidance/auto-advance, and live terminal attachment are **not enabled**. Contracts and deterministic supporting state machines exist, with setup in `docs/SUPPORTING_SETUP.md`. Scoped screenshots and system speech are available for manual development-build testing but remain unvalidated on a Mac. DEBUG builds only: `clicky-debug://guide?x=&y=&w=&h=&text=&expect=click|rightclick|key[&key=&mods=cmd,shift,opt,ctrl]` (global top-left points) draws a click-through circle and step card, and `clicky-debug://cancel` clears it. A global mouse monitor and, only during an active key step with Accessibility granted, a global key monitor feed `GuidanceVerification`. Non-matching keys are counted only, never stored, displayed, or logged. Matches are reported as action-verified, not outcome-verified. Results go to the unified log (category `guidance`, non-sensitive fields only). Do not set release capability flags true without validating the actual native feature. No microphone or automatic screen capture should be triggered by typed Ask.

Legacy `BuddyDictationManager`, AssemblyAI/OpenAI/Apple speech providers, ClaudeAPI, ElevenLabs client, onboarding views, and `worker/` remain for reference. They are not current app prerequisites. Migrate these incrementally; keep known nonblocking Swift concurrency and deprecated `onChange` warnings unchanged.

## Build and verification

Open `leanring-buddy.xcodeproj` in **Xcode 26+ / Swift 6.2+** (the target uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); select shared scheme `leanring-buddy`, set the user's signing team, Cmd+R to build/run, and Cmd+U for native tests. **Do not run `xcodebuild` from the terminal**: the repository prohibits it because it affects TCC permissions.

The Xcode app compiles the synchronized `leanring-buddy/TextInput/Core` files directly. Root `Package.swift` compiles the same files as ClickyCore in Swift 5 language mode with the app target's MainActor default isolation and approachable-concurrency features, and also builds `clicky-text`. Core declarations are explicitly `nonisolated`; keep new Core types `nonisolated` so process readers never hop to the main actor. Do not link a duplicate ClickyCore copy into the app.

Portable checks: `bash scripts/test-core.sh` with Swift 6.2+ and Python 3. App-source typecheck without building or signing: see `docs/MAC_VALIDATION.md` (`swiftc -typecheck`, never `xcodebuild`). Cloud installation: `bash scripts/cloud-setup.sh` uses the official signed Swift 6.2.3 Debian toolchain and pins its signing fingerprint. Caches stay outside tracked source. Linux Foundation subprocess lifecycle tests require local socket IPC; if sandboxing blocks the wakeup socket pair, run the test command with the appropriate execution permission rather than disabling tests.

Mac preflight: `bash scripts/mac-preflight.sh`. Detailed acceptance, real-provider compatibility, and remaining limitations: `docs/MAC_VALIDATION.md`. AppKit syntax parsing in Linux is not Mac typechecking or GUI validation. Never claim native tests ran without a Mac.

The `--clicky-ui-test` launch argument selects a dedicated preferences domain, preview backend, no hotkey/companion/capture target, and a panel that remains visible after submission for assertions. It does not validate production focus restoration.

## Conventions

- All UI state updates are on `@MainActor`; keep audio/model/process work off the UI thread.
- Use SwiftUI for views and AppKit where native focus/windows/text input require it.
- Use clear descriptive names, async/await, and comments explaining non-obvious decisions.
- All interactive buttons must show a pointer cursor on hover.
- Track request IDs/generations so stale callbacks cannot mutate a later interaction.
- Preserve pre-existing user changes. Do not change unrelated features or known warnings.
- Never log raw prompts, replies, screenshots, clipboard contents, credentials, or sensitive AX values.
- Do not perform desktop actions or synthesize Enter. Future dictation must validate its original destination and offer Copy on uncertainty.
- No product subagent platform or automatic live-terminal typing.
- No force-pushing main. Suggested branches: `feature/description` or `fix/description`; imperative commit messages explaining why.
- Use existing checkouts in cloud tasks; do not create Git worktrees unless explicitly requested.
- Update these instructions when architecture, build commands, or file responsibilities change.
