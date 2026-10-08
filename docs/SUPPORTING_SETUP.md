# Supporting module setup

The current delivery prioritizes typed Quick Ask. Single-window screenshot attachment and local reply speech now have native implementations for Mac validation; no native acceptance is claimed. Supporting capabilities report unavailable until their release acceptance passes. No model is downloaded at app launch, and no MCP listener or input observer starts.

## Local audio

Recommended candidate: FluidAudio revision `0c0f113e8db4b862b19a99ce9fd7c9da73324f5f` (Apache-2.0), Swift 6+, macOS 14+. Add its Swift package to a separate integration target first. Its documented baseline is `AsrModels.downloadAndLoad(version: .ultra)`, followed by `AsrManager.loadModels` and `transcribe`. Ultra is not proof of smart cleanup or technical-token preservation. Validate its model license, download destinations, cache behavior, memory, and technical English speech on the M4 Pro before enabling it. WhisperKit remains an alternative requiring the same gates.

Implement `LocalTranscriptionProvider`; use `HybridRecordingGesture` for separate Ask/Dictate shortcuts. It supplies transitions only, not microphone capture. Connect cancellation to audio finalization exactly once, and do not submit old callbacks after mode/session changes.

## Dictation

`DictationDestination` requires the original process/window/element/selection to remain unchanged and refuses secure or unsupported destinations. This is an eligibility gate, not an inserter. Resolve AX elements on the Mac, verify element lifetime, and show preview/Copy when identity is uncertain. Clipboard fallback must detect concurrent clipboard changes before restoring prior contents. Never synthesize Enter.

## Guidance and MCP

`WindowSnapshotCapture` supplies explicit originating-window capture using a desktop-independent ScreenCaptureKit filter. `WindowAttachmentState` prevents canceled/dismissed captures from becoming attachments. Screenshots are immutable, stay in memory, are removed from the composer on submission, and are never automatically recaptured or restored for retries. This does not provide MCP capture authority or verified coordinates; future MCP requests need a separate authorized read scope and fresh geometry.

`GuidanceVerification` accepts only the expected action in a fresh target/window/display and waits for a separate matching outcome. Producers must decide freshness from real window geometry and timestamp evidence. Never mark `targetIsFresh` true merely because a click occurred.

Prepare a separate `clicky-mcp` executable using the Swift MCP SDK (Annotate pins `0.12.1`). Bridge stdio to a private, versioned Unix socket owned by the app; do not use a public TCP service. Verify caller identity for screenshot/AX reads, distinguish drawing authority from reading authority, cap message/image sizes, and return correlation IDs and structured errors. Tool proposals: `clicky_get_context`, `clicky_capture`, `clicky_locate`, `clicky_show_step`, `clicky_annotate`, `clicky_wait_for_step`, `clicky_get_guidance_status`, `clicky_clear`.

Reuse Annotate's tested geometry and IPC concepts after adapting its global Y-down coordinates to an explicit Clicky point-space contract. Keep original Clicky cursor animations and use non-key, click-through panels. The Quick Ask panel is the only temporary typing surface.

## Integration order

1. Pass the Mac Quick Ask checks for preview and both managed providers.
2. Add active-window capture with overlay exclusion and explicit per-request consent.
3. Integrate authorized MCP tools and persistent annotations.
4. Connect action observations to independent outcome verification.
5. Integrate local ASR, safe dictation, and system TTS independently of agent availability.

Do not enable unavailable capabilities or call them production-ready before their corresponding Mac acceptance checks pass.
