# Local AI: worker, Lab and voice input

Development milestone for the target Mac (M4 Pro, 24 GB). The default assistant backend stays Local preview; the on-device backend below is opt-in and, local inference is experimental until native acceptance passes (see [MAC_VALIDATION.md](MAC_VALIDATION.md) › Local AI and voice). Benchmark procedures and results: [LOCAL_BENCHMARKS.md](LOCAL_BENCHMARKS.md).

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
| Clicky window › Local AI (Models, Playground, Results) | `TextInput/Settings/Panes/Models*.swift`, `ModelRow.swift`, `PlaygroundPane.swift`, `ResultsPane.swift`, `TextInput/LocalAI/Lab*.swift`, `LocalAILabModel.swift` |
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
- **Cleanup is untrusted.** `CleanupGate` checks additions, unexplained deletions, negation, numbers, names, length and recall. It spells minus signs and decimal points as words before aligning, because WER normalization drops them, so a lost sign or split decimal goes to review. A dropped repeat of a number or negation ("5 5 1", "not not") is never excused as a stutter and also goes to review. Only `accept` auto-inserts; `review` and `reject` show an editable preview with the raw transcript available. Self-reported confidence is never used.
- **Providers:** writing has its own provider preference (`askWritingProvider`), migrated from the shared one unchanged. Local speech never falls back to any cloud service.

## Setup

1. Install the Metal Toolchain (Xcode › Settings › Components, or `xcodebuild -downloadComponent MetalToolchain`). Without it MLX models cannot load; Core ML speech still works.
2. `bash scripts/build-local-worker.sh` writes `build/local-worker/{clicky-local-worker, mlx.metallib, VERSION}`. **Run it before building the app.** The Xcode target's "Embed Local Worker" phase copies the worker into `Contents/Helpers` and signs it on copy; the "Embed MLX Shaders" phase copies `mlx.metallib` into `Contents/Resources`. The app build fails if either file is missing.
3. Models: Settings › Models (Download; Import folder… in the expanded row), or `clicky-local-bench models download <id>`. Store: `~/Library/Application Support/Clicky/Models/<id>/<revision>`, verified against pinned hashes. Nothing downloads automatically.
4. Load models explicitly in Settings › Models (or set a load policy in the expanded row), then use Playground or the voice shortcuts.

## On-device assistant backend

Settings › General › Backend › **On-device** (`AgentProvider.local`) answers Quick Ask, pointing, walkthroughs and writing with the selected vision model; writing can also pick it separately. Nothing runs through Claude Code or Codex and there is no cloud fallback.

- `LocalMLXAgent` implements `GuideAgentRunning`. The worker keeps no state, so the agent holds the transcript in memory (44 KB UTF-8 budget, oldest exchanges dropped first) and resends it every turn. Only the latest capture is attached; a turn that names another capture gets no image.
- Screen first: Qwen3-VL-4B answered "help me …" in text or with a guessed box instead of asking for the screen, so on-device questions attach the shared window on the first turn when sharing allows it (same grant and display-consent rules as a context request; the image never leaves the Mac). With sharing off the turn stays text only, and an annotation, step or verdict without a capture is turned into a context request.
- `LocalPrompt` (`clicky-local-guide-1`, `clicky-local-writing-1`) is a compact version of the shared contracts, with one JSON example per kind. Boxes are `[x1, y1, x2, y2]` on the 0–1000 grid; the model never writes a captureID.
- `LocalReply` extracts the first JSON object, converts grid boxes to pixels of the sent image, inserts that image's captureID, maps gesture synonyms (`left_click` → `click`), fills unused nullable fields and drops fields the kind does not use. The shared `GuidePresentation.parseResponse` then validates as for any provider, so a missing target, action or verdict still fails.
- An unusable reply gets one repair turn naming the field to fix; a second failure is a normal provider error (Retry). The shared wrong-purpose correction still applies once.
- Output caps: writing 4096 tokens, verification 512, other guide turns 1536. Image long side up to 1568 px. Effort does not apply.
- Requests honour the vision group's load policy; with Manual the error asks you to load the model in Models. An assistant turn waits up to 5 s for another foreground job on the inference worker before reporting busy.
- Candidates in the catalog: Qwen3-VL 4B (default), 2B, 8B 4-bit (5.8 GB) and 8B 8-bit (9.9 GB; above the default 45% budget on 24 GB). Qwen3-VL-30B-A3B 4-bit (18.3 GB weights, about 23 GB estimated) does not fit the 80% maximum budget on 24 GB and is not listed.

## Voice input

- **Dictate Anywhere** (default ⌥⇧D) binds the focused destination at key-down. After stop it transcribes, cleans and gates the text, then inserts it once through the writing coordinator. Insertion requires the unchanged empty caret in the same app, and uninterrupted recording. Selections, unverified paste-only targets, multi-line terminal text, changed targets and gate concerns all give an editable review with Insert / Use original / Copy / Discard. The voice session keeps its Cancel button and ⌥⇧Esc until the writer reports an outcome. Cancel before the commit point writes nothing; a write that already committed is reported as "Already inserted". After an insertion the panel offers Undo (only for a read-back-verified edit, and only if the field still holds that text) and Copy original. The raw transcript stays in memory until the next dictation. If the runtime unloads the speech model mid-transcription the session fails visibly; if it unloads the cleanup model, the raw transcript goes to review. Dictated text is never routed to an assistant or parsed as a command. Return is never sent.
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

The first load includes Core ML/ANE compilation. Worker `phys_footprint` (69 MB Parakeet, 393 MB Whisper) does not include Neural Engine allocations, so it is not a full memory figure. Ten clips are not enough to rank close candidates. MLX (metallib built with the Metal Toolchain), re-run with schema v2 after the review fixes. Memory is the sampled combined `phys_footprint` of the fresh workers (every 100 ms during the measured loop; short spikes can be missed), with the sum of each worker's own peak in parentheses as an upper bound. Neither includes Neural Engine/GPU accelerator allocations. Latency is CLI pipeline processing, not the GUI stop-to-text-ready interval:

| Pipeline | Quality | Latency | Memory: sampled combined peak (sum of peaks) |
|---|---|---|---|
| S1-mini cleanup on reference transcripts | clean WER 7.1% (Python: 7.1%); gate 7 accept / 1 review / 2 reject, including the known wrong repair; unchanged after the numeric-safety gate fix | 189 ms P50 per clip; load 368 ms | 1.54 GB (1.88 GB) |
| Parakeet + S1-mini (model-card prompt) | clean WER 8.5% (Python: 11.3%); gate 8 / 1 / 1, unchanged after the gate fix | 244 / 348 ms P50 / P95 | 1.62 GB (1.90 GB) |
| Parakeet + S1-mini (lowercase prompt) | clean WER 9.4% | 243 / 345 ms | not re-measured (1.87 GB) |
| Qwen3-VL-4B 4-bit, text rewrite | correct, polite rewrite | first token 58 ms, 195 ms total (warm); load 826 ms | 3.22 GB (3.23 GB) |
| Qwen3-VL-4B 4-bit, synthetic button grounding (10 × 1280×800) | JSON 10/10, target 10/10, mean IoU 0.91 | 2.5 s per image (about 1,100 prompt tokens of prefill) | 4.56 GB (4.58 GB) |

| Qwen3-VL-4B 4-bit, on-device assistant path (`clicky-local-bench guide`, 5 screens × pointing + step) | accepted 10/10, repairs 0, target hit 9/10, mean IoU 0.81 (before the example-based prompt: accepted 0/6, the model omitted `text` and wrote `left_click`) | 4.8 s per case (debug CLI, warm) | not measured |

Grounding must use the model-native `bbox_2d` box on a 0–1000 grid (`Core/LocalGrounding.swift`). Asking for pixels gave 1/10, because the model answered in its own grid regardless, and the worker downscales images to 1024 px. Image-size and crop trade-offs for vision latency are not measured yet.

## Limitations

- No native GUI acceptance yet. The Lab, the status panel, real microphone capture, Carbon key-up delivery and insertion into Chrome, VS Code and Terminal remain unverified (see MAC_VALIDATION.md).
- `mlx.metallib` targets macOS 14+. mlx-swift runs in JIT mode, so on M5 with macOS 26.2+ the NAX kernels are compiled at runtime from source embedded in the worker; they don't need to be in the metallib, and one metallib serves all Apple Silicon. This is untested on M5 hardware.
- Parakeet cancellation takes effect only after the current Core ML call returns, so the delay is bounded by one transcription. That measured 59 / 64 ms (P50 / P95) on 7.5 s clips and scales roughly linearly with audio length; Clicky revokes delivery immediately either way. WhisperKit cancels mid-call.
- SwiftPM fetches FluidAudio's NeMo text-processing binary at resolve time, although it is not linked.
- Personal benchmark recordings exist only after you record them in Settings › Playground › Speech. Personal acceptance is pending.
