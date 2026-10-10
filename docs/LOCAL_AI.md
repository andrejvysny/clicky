# Local AI: worker, Lab and voice input

Development milestone for the target Mac (M4 Pro, 24 GB). Nothing here changes the default assistant backend; local inference is experimental until native acceptance passes (see [MAC_VALIDATION.md](MAC_VALIDATION.md) › Local AI and voice). Benchmark procedures and results: [LOCAL_BENCHMARKS.md](LOCAL_BENCHMARKS.md).

## Components

| Responsibility | Code |
|---|---|
| Wire contract (versioned frames, requests, exactly-once outcomes) | `Core/LocalWorkerProtocol.swift` |
| Host client (launch, handshake, cancel grace, crash/hang handling) | `Core/LocalWorkerConnection.swift` |
| Pinned model catalog, verified download/import, atomic publish | `Core/LocalModelCatalog*.swift`, `Core/LocalModelInstaller.swift`, `scripts/generate-model-catalog.py` |
| Load policies, memory budget, idle unload | `Core/LocalModelResidency.swift` |
| Speech pipeline (ASR → cleanup), cleanup prompt | `Core/LocalSpeechPipeline.swift` |
| Cleanup gate (meaning-preservation checks), normalization, WER/CER | `Core/CleanupGate.swift`, `Core/TranscriptText.swift`, `Core/SpeechMetrics.swift` |
| Voice session state machine and delivery decision | `Core/VoiceSession.swift`, `Core/HybridRecordingGesture.swift` |
| Bounded audio buffer, signal stats | `Core/AudioCapture.swift` |
| Benchmark schema, datasets, runner | `Core/LocalBenchmark*.swift`, `Tools/ClickyLocalBench` |
| Worker executable (MLX text/vision/cleanup, Parakeet, WhisperKit) | `Tools/ClickyLocalWorker` (separate package) |
| App runtime (assets, workers, policies, pressure) | `TextInput/LocalAI/LocalAIRuntime*.swift`, `LocalAIEnvironment.swift` |
| Local AI Lab window | `TextInput/LocalAI/Lab*.swift`, `LocalAILab*.swift` |
| Microphone capture | `TextInput/VoiceAudioRecorder.swift` |
| Voice modes, shortcuts, status panel | `TextInput/Voice/*.swift` |
| Dictation insertion | `WritingCoordinator.startDictation` (intent `.dictation`) |

## Decisions

- **One worker binary, two processes.** `clicky-local-worker --role inference` hosts MLX models (vision/text and cleanup); `--role speech` hosts Core ML ASR. Voice never loads the vision model; a speech crash leaves inference running. The app links none of MLX, FluidAudio or WhisperKit.
- **IPC: inherited pipes** with length-prefixed binary frames (`CLKW`, 64 KiB header, 16 MiB payload). The host creates the pipes, so no listener or peer authentication is needed; a Unix socket added nothing, and XPC would require an Xcode service target. Every event carries the per-launch session nonce; the ledger drops stale events and treats unknown ones as protocol violations.
- **Cancellation:** the host revokes authority immediately (the consumer stops listening), sends `cancel`, and terminates a worker that does not finish within 3 s. Restart never replays a request.
- **Sandbox:** the worker calls `sandbox_init(kSBXProfileNoNetwork)` before reading any request (`networkDenied` in readiness). It is otherwise unsandboxed like the app: a separate process is not filesystem isolation, GPU isolation or a memory quota. Downloads happen only in the host.
- **Priority:** "Protect foreground apps" (default on) renices workers to 10. This is CPU scheduling only; GPU and Neural Engine sharing are not controlled.
- **Loading:** manual by default per group (vision, cleanup, speech). Opt-in "Load when needed" and "Load at startup", plus idle unload. A manual-policy voice shortcut shows "Load speech pipeline" and does not record. An explicit benchmark Run may load its models without changing preferences.
- **Resource protection:** one expensive job per worker role; voice and Lab runs preempt benchmark jobs. Memory-pressure warning cancels benchmarks and clears caches; critical also unloads idle groups and refuses new loads. Serious or critical thermal state refuses benchmark runs. Model budget: 45% of physical memory, checked against measured footprints.
- **Cleanup is untrusted.** `CleanupGate` checks additions, unexplained deletions, negation, numbers, names, length and recall. Only `accept` auto-inserts; `review` and `reject` show an editable preview with the raw transcript available. Self-reported confidence is never used.
- **Providers:** writing has its own provider preference (`askWritingProvider`), migrated from the shared one unchanged. Local speech never falls back to any cloud service.

## Setup

1. Install the Metal Toolchain (Xcode › Settings › Components, or `xcodebuild -downloadComponent MetalToolchain`). Without it MLX models cannot load; Core ML speech still works.
2. `bash scripts/build-local-worker.sh` writes `build/local-worker/{clicky-local-worker, mlx.metallib, VERSION}`. **Run it before building the app.** The Xcode target's "Embed Local Worker" Copy Files phase copies both files into `Contents/Helpers` and signs the worker on copy, so the app build fails if they are missing.
3. Models: Local AI Lab › Models (Download / Import folder…), or `clicky-local-bench models download <id>`. Store: `~/Library/Application Support/Clicky/Models/<id>/<revision>`, verified against pinned hashes. Nothing downloads automatically.
4. Load models explicitly in the Lab (or set a policy), then use the Lab tabs or the voice shortcuts.

## Voice input

- **Dictate Anywhere** (default ⌥⇧D) binds the focused destination at key-down. After stop it transcribes, cleans and gates the text, then inserts it once through the writing coordinator. Insertion requires the unchanged empty caret in the same app, and uninterrupted recording. Selections, unverified paste-only targets, multi-line terminal text, changed targets and gate concerns all give an editable review with Insert / Use original / Copy / Discard. Dictated text is never routed to an assistant or parsed as a command. Return is never sent.
- **Ask Clicky by voice** (default ⌥⇧A) opens Quick Ask at key-down. The text goes into the draft: set when the draft is empty, appended otherwise. It waits for your own Enter. "Use original" swaps back the raw transcript if that span is unchanged.
- **Activation:** a tap shorter than 0.25 s toggles; a hold records until release. Repeats are ignored, and a lost key-up is detected by polling key state. Stop and Cancel are buttons in the status panel; ⌥⇧Esc cancels while a session is active. The panel shows only mode, elapsed time and limit, device, level and stage. There is no live transcript.
- **Limits:** recordings default to 120 s, configurable from 60 to 300 s. Reaching the limit stops the recording visibly and processes what was captured. Silence is detected before ASR and inserts nothing. A device change, sleep or lock stops the recording; captured audio is processed but always goes to review. Audio stays in memory and is released after processing.

## Measured so far (native, this Mac)

DisfluencySpeech test subset, the same 10 clips as voice-benchmark run_001. Warm-ups are excluded and the system was otherwise idle. Result JSON is in `~/Library/Application Support/Clicky/Benchmarks/results/`.

| ASR | Raw WER | Per-clip P50 / P95 | Load (first / cached) |
|---|---|---|---|
| Parakeet TDT 0.6B v3 (FluidAudio 0.17.7, Core ML int8 encoder) | 1.6% | 59 / 64 ms | 14.2 s / 148 ms |
| Whisper large-v3-turbo 632 MB (WhisperKit 1.1.1) | 10.8% | 562 / 679 ms | 153 s / 1.28 s |
| Whisper small.en 217 MB (WhisperKit 1.1.1) | 10.0% | 410 / 557 ms | 15.0 s / 434 ms |

The first load includes Core ML/ANE compilation. Worker `phys_footprint` (69 MB Parakeet, 393 MB Whisper) does not include Neural Engine allocations, so it is not a full memory figure. Ten clips are not enough to rank close candidates. Cleanup (S1-mini via MLX) and Qwen3-VL text/vision are pending the Metal Toolchain.

## Limitations

- No native GUI acceptance yet. The Lab, the status panel, real microphone capture, Carbon key-up delivery and insertion into Chrome, VS Code and Terminal remain unverified (see MAC_VALIDATION.md).
- `mlx.metallib` targets macOS 14+. mlx-swift runs in JIT mode, so on M5 with macOS 26.2+ the NAX kernels are compiled at runtime from source embedded in the worker; they don't need to be in the metallib, and one metallib serves all Apple Silicon. This is untested on M5 hardware.
- Parakeet cancellation takes effect only after the current Core ML call returns, so the delay is bounded by one transcription. That measured 59 / 64 ms (P50 / P95) on 7.5 s clips and scales roughly linearly with audio length; Clicky revokes delivery immediately either way. WhisperKit cancels mid-call.
- SwiftPM fetches FluidAudio's NeMo text-processing binary at resolve time, although it is not linked.
- Personal benchmark recordings exist only after you record them in the Lab. Personal acceptance is pending.
