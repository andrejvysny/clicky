# Clicky — Agent Instructions

## Current delivery

Native macOS menu-bar companion, macOS 14.2+, Apple Silicon. The active implementation is text-first: cursor-adjacent Quick Ask, offline preview, and managed Claude Code/Codex text sessions. Preserve the original blue companion and cursor animation. Do not rename the legacy `leanring-buddy` directory or scheme.

`CompanionAppDelegate` starts `AskController`, `QuickAskPanelManager`, a Carbon registered hotkey, and `CompanionManager.startTextMode()`. It does not start the legacy voice pipeline, permission polling, Cloudflare warmup, email onboarding, analytics, or automatic login-item registration. PostHog is removed; `ClickyAnalytics` is a compatibility no-op for dormant views. Sparkle is retained but its updater is not started.

Default backend is **Local preview (no AI)**; it visibly echoes text and must never be presented as a real agent response. Default shortcut is Option+Shift+Space, configurable in Settings. Ask popup is temporarily keyable; companion and response overlays remain nonactivating/click-through. Enter submits, Shift+Enter inserts a line, and Escape cancels. IME composition must not prematurely submit. Preserve code indentation, paths, Unicode, and line breaks. Drafts/replies stay in memory; only preferences and provider/project/session metadata persist.

Quick Ask's explicit Attach button captures only the window of the originating app resolved before popup presentation. Use `SCContentFilter(desktopIndependentWindow:)`, never a fallback display capture. Screen Recording is requested only by that action. Preview the attachment before sending; PNGs stay in memory, are capped at 3 MiB and 4096 pixels per axis, and travel over stdin as Claude image blocks or Codex image data URLs. Popup dismissal/provider changes/removal invalidate capture leases. Failed or canceled agent turns restore text only; require an explicit new attachment. System reply speech uses AVSpeechSynthesizer, defaults to voice-only (typed requests silent), and supports Always plus explicit Speak/Stop. Preview does not automatically speak.

Managed Claude uses the user's installed binary and normal authentication, stdin stream-json, and `--tools ""`. Codex uses app-server stdio, account status, thread start/resume, turn streaming, a read-only sandbox, and untrusted approval policy. Action approvals are explicitly declined in this text client. Do not add `bypassPermissions`, `--bare`, unsafe automatic approvals, shell prompt injection, or account-token extraction. Managed resume is not live terminal attachment. Never silently retry a submitted prompt.

## Source map

| Files | Responsibility |
|---|---|
| `TextInput/AskController.swift` (~190 lines) | Settings, in-memory drafts/replies, session metadata, serialized UI submission, recovery |
| `TextInput/QuickAskPanelManager.swift` (~140 lines) | Cursor placement, focus ownership/restoration, dismissal observers |
| `TextInput/QuickAskEditor.swift` (~80 lines) | Plain-text NSTextView, IME-aware key handling, bounded editor growth |
| `TextInput/QuickAskView.swift` (~100 lines) | Composer, backend selection, settings and shortcut capture |
| `TextInput/QuickAskHotkey.swift` (~80 lines) | Carbon shortcut registration and rebinding; no keylogging/event tap |
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

Local ASR, smart cleanup, system-wide dictation insertion, visual MCP, persistent guidance/auto-advance, and live terminal attachment are **not enabled**. Contracts and deterministic supporting state machines exist, with setup in `docs/SUPPORTING_SETUP.md`. Scoped screenshots and system speech are available for manual development-build testing but remain unvalidated on a Mac. Do not set release capability flags true without validating the actual native feature. No microphone or automatic screen capture should be triggered by typed Ask.

Legacy `BuddyDictationManager`, AssemblyAI/OpenAI/Apple speech providers, ClaudeAPI, ElevenLabs client, onboarding views, and `worker/` remain for reference. They are not current app prerequisites. Migrate these incrementally; keep known nonblocking Swift concurrency and deprecated `onChange` warnings unchanged.

## Build and verification

Open `leanring-buddy.xcodeproj` in **Xcode 16+ / Swift 6+**; select shared scheme `leanring-buddy`, set the user's signing team, Cmd+R to build/run, and Cmd+U for native tests. **Do not run `xcodebuild` from the terminal**: the repository prohibits it because it affects TCC permissions.

The Xcode app compiles the synchronized `leanring-buddy/TextInput/Core` files directly. Root `Package.swift` compiles the same files as ClickyCore in Swift 5 language mode and also builds `clicky-text`. Do not link a duplicate ClickyCore copy into the app.

Portable checks: `bash scripts/test-core.sh` with Swift 6+ and Python 3. Cloud installation: `bash scripts/cloud-setup.sh` uses the official signed Swift 6.2.3 Debian toolchain and pins its signing fingerprint. Caches stay outside tracked source. Linux Foundation subprocess lifecycle tests require local socket IPC; if sandboxing blocks the wakeup socket pair, run the test command with the appropriate execution permission rather than disabling tests.

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
