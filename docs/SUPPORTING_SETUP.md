# Supporting module setup

The active development delivery is the visual task guide described in [VISUAL_GUIDE_PROTOCOL.md](VISUAL_GUIDE_PROTOCOL.md). It uses clean provider sessions, task-window grants, persistent steps, and independent outcome checks. Native release acceptance remains incomplete; release capability flags stay unavailable. No model is downloaded at launch and no MCP listener starts. The scoped interaction observer runs only while a guide waits for an action.

MCP notes below are deferred reference material. Local audio and dictation are implemented for development (see LOCAL_AI.md).

## Writing targets

Writing and snippet insertion ([WRITING_PROTOCOL.md](WRITING_PROTOCOL.md)) uses the existing Accessibility permission. Inserting into macOS Terminal also asks once for Automation (Terminal): Clicky reads only the front tab's window id, tty, busy state and foreground process to confirm a ready shell prompt, and never runs scripts or commands in Terminal. VS Code needs the opt-in bridge extension in `Tools/clicky-vscode-bridge` (install steps in its README) plus Settings › Writing › VS Code; without it VS Code results stay preview + Copy.

## Local audio

Implemented as a development feature; see [LOCAL_AI.md](LOCAL_AI.md). Recognition runs in the bundled worker (FluidAudio 0.17.7 Parakeet TDT v3 via `AsrModels.loadLocal`, or WhisperKit 1.1.1 with a local tokenizer and downloads disabled). Cleanup runs S1-mini through MLX Swift. `HybridRecordingGesture` drives the separate Ask and Dictate shortcuts. Models are pinned and installed only on explicit Download/Import.

## Dictation

`DictationDestination` requires the original process/window/element/selection to remain unchanged and refuses secure or unsupported destinations. This is an eligibility gate, not an inserter. Resolve AX elements on the Mac, verify element lifetime, and show preview/Copy when identity is uncertain. Clipboard fallback must detect concurrent clipboard changes before restoring prior contents. Never synthesize Enter.

## Guide integration and deferred MCP

`WindowSnapshotCapture` supplies exact originating-window capture using a desktop-independent ScreenCaptureKit filter. Task grants authorize fresh captures after a structured provider context request. Established related windows are explicitly included; uncertain windows require selection. `WindowAttachmentState` still protects explicit preview attachments. Screenshots stay in memory. Failed or canceled user turns restore text only; Retry obtains fresh evidence under the active grant. Broader capture requires explicit approval for one transmission.

`GuideTaskState`, `GuideObserver`, and `VisualGuideController` own freshness, expected interactions, bounded verification, and continuation. Action detection, outcome verification, and manual acknowledgement are separate. `GuidanceVerification` remains a legacy supporting contract. Never declare an outcome verified from a click alone.

Prepare a separate `clicky-mcp` executable using the Swift MCP SDK (Annotate pins `0.12.1`). Bridge stdio to a private, versioned Unix socket owned by the app; do not use a public TCP service. Verify caller identity for screenshot/AX reads, distinguish drawing authority from reading authority, cap message/image sizes, and return correlation IDs and structured errors. Tool proposals: `clicky_get_context`, `clicky_capture`, `clicky_locate`, `clicky_show_step`, `clicky_annotate`, `clicky_wait_for_step`, `clicky_get_guidance_status`, `clicky_clear`.

Reuse Annotate's tested geometry and IPC concepts after adapting its global Y-down coordinates to an explicit Clicky point-space contract. Keep original Clicky cursor animations and use non-key, click-through panels. The Quick Ask panel is the only temporary typing surface.

## Acceptance

Follow [MAC_VALIDATION.md](MAC_VALIDATION.md) for provider isolation, native sharing, interaction, and real workflow checks. Keep deferred integrations separate from that acceptance gate.

Do not enable unavailable capabilities or call them production-ready before their corresponding Mac acceptance checks pass.
