# Local benchmarks

`clicky-local-bench` runs the same code as the app: `LocalWorkerConnection` + `LocalSpeechPipeline` (+ `CleanupGate`) in ClickyCore, with the real worker binary. Results are `LocalBenchmarkRun` JSON (schema in `Core/LocalBenchmarkRecord.swift`). The Local AI Lab reuses `LocalSpeechBenchmark`, `LocalGenerationBenchmark` and `LocalPersonalDataset`.

## Data rules

- Personal audio, references, transcripts and result files with model output **never enter Git**. They live under `~/Library/Application Support/Clicky/Benchmarks/{personal,results}` (directories 0700, files 0600).
- Result JSON contains sample ids, metrics and model output text. Review before sharing; observations are free text you type.
- The public dataset (DisfluencySpeech test split, read-only) is `voice-benchmark/data/disfluency_speech/test/full_manifest.csv`; revision comes from its `dataset_info.json`.
- Failure strings in results are error codes only (`inputTooLarge`, `inferenceFailed`, ...), never content.

## Setup

```bash
swift build --product clicky-local-bench          # or: swift run clicky-local-bench ...
bash scripts/build-local-worker.sh                # needs the Metal toolchain; writes build/local-worker/clicky-local-worker (+ mlx.metallib)
clicky-local-bench models list                    # 6 pinned entries + install status
clicky-local-bench models download parakeet-tdt-0.6b-v3-coreml   # Ctrl-C cancels
clicky-local-bench models download s1-mini
clicky-local-bench models verify s1-mini          # re-hash installed files
clicky-local-bench models import <entry-id> <folder>   # offline copy, hash-checked against the pins
clicky-local-bench models remove <entry-id> [--yes]
```

Default model store `~/Library/Application Support/Clicky/Models` (`--models-root` overrides). `--worker` overrides the worker path (default `build/local-worker/clicky-local-worker` under the repo).

## Reproduce Python run_001 (10 samples)

Same ids as `voice-benchmark/results/run_001/manifest.csv`:

```bash
IDS=test-0044,test-0098,test-0184,test-0123,test-0121,test-0167,test-0009,test-0176,test-0197,test-0113
clicky-local-bench speech --recognizer parakeet-tdt-0.6b-v3-coreml --cleanup s1-mini \
  --pipeline asr+cleanup --dataset disfluency --ids $IDS --warmup 2 --observation "run_001 subset, native"
clicky-local-bench speech --recognizer parakeet-tdt-0.6b-v3-coreml --pipeline asr --dataset disfluency --ids $IDS
clicky-local-bench speech --cleanup s1-mini --pipeline cleanup-on-reference --dataset disfluency --ids $IDS
# lowercase, unpunctuated cleanup input (what S1-mini was trained on):
clicky-local-bench speech --recognizer parakeet-tdt-0.6b-v3-coreml --cleanup s1-mini --prompt s1-mini-card-v1-lowercase \
  --pipeline asr+cleanup --dataset disfluency --ids $IDS
```

`--manifest` defaults to `~/workspace/voice-benchmark/data/disfluency_speech/test/full_manifest.csv`. Compare against `run_001/summary.json` (raw WER, clean WER, gate verdicts); timing differs by design (native MLX/Core ML vs Python).

## 50-sample expansion

```bash
clicky-local-bench speech --recognizer parakeet-tdt-0.6b-v3-coreml --cleanup s1-mini \
  --pipeline asr+cleanup --dataset disfluency --count 50 --seed 42 --warmup 2
```

`--count N --seed S` is a SplitMix64 Fisher-Yates shuffle of the manifest, so the same seed picks the same subset on any machine. Use `--ids-file f` (ids separated by newlines or commas) to pin a list. Add `--repetitions 3` to see run-to-run spread.

## Text and vision

```bash
clicky-local-bench text --model qwen3-vl-2b-instruct-4bit --prompt-file prompt.txt --max-tokens 256 --repetitions 5
clicky-local-bench vision --model qwen3-vl-4b-instruct-4bit --count 10 --seed 42
```

Vision uses deterministic synthetic screenshots (1280x800, 3-5 labeled colored buttons at seeded positions, generated with CoreGraphics; no binary fixtures in Git). The model must answer `{"label":"..","x":..,"y":..,"width":..,"height":..}` in image pixels (top-left origin). Recorded: schema compliance, target accuracy (predicted box center inside the true box) and IoU.

## Personal dataset workflow

Samples are recorded in the Lab (or added through `LocalPersonalDataset`) and stored in `Benchmarks/personal` as `p-<8 hex>.wav` + `index.json`.

1. Record, then type both references: raw (what was said, with disfluencies) and clean (what you want inserted).
2. Approve only samples with both references non-empty; unapproved samples are never benchmarked.
3. Split: `development` samples may be used to tune prompts and settings. `held-out` samples are for final comparison only; never tune on them and never move a sample from held-out to development after seeing its result.
4. Run: `clicky-local-bench speech ... --dataset personal --split held-out`.

## Controlled contention protocol (Chrome / Blender)

Manual protocol to see whether a benchmark disturbs, or is disturbed by, foreground work. CPU priority only (`--priority foreground-protected` = nice 10 for workers); GPU/ANE fairness is not implied.

1. Close other heavy apps; plug in power; record thermal state (`pmset -g therm`) and battery/power mode. Same Mac, same model files, same dataset ids for every condition.
2. Baseline: run the benchmark idle (`--priority default`), 3 repetitions. Note `--observation "idle baseline"`.
3. Chrome load: open a fixed set of heavy tabs (e.g. a 4K video + a WebGL demo), run the same command. Observe tab smoothness (dropped frames, scroll lag).
4. Blender load: run a fixed GPU/CPU render or viewport animation (same scene each time), run the same command. Observe viewport FPS and render time with and without the benchmark.
5. Repeat 3 and 4 with `--priority foreground-protected`.
6. Record per run: commit (`environment.commit`), thermal state before/after, foreground app responsiveness notes (`--observation`, repeatable), render time or FPS number, stop-to-final P50/P95, WER, combined peak memory. Do not mix conditions in one result file.

## Metric definitions

Same normalization and aggregation as `voice-benchmark` (`benchmark/normalize.py`, implemented in `Core/TranscriptText.swift` and `Core/SpeechMetrics.swift`): NFKC lowercase, curly apostrophes, digit-group commas removed, `%` to "percent", hyphens and punctuation to spaces, spelling table, spoken numbers to digits.

- WER = (substitutions + deletions + insertions) / reference words. CER likewise on normalized characters. Corpus rates are total errors / total reference units, never a mean of per-sample rates.
- Raw WER: ASR text vs `raw_reference`. Clean WER/CER: final text (cleaned, or raw for `asr`) vs `clean_reference`. `cleanup-on-reference` feeds `raw_reference` to cleanup (no ASR) and records no raw WER.
- Gate verdict: `CleanupGate.assess(raw, cleaned)` (accept/review/reject/noSpeech) with concerns; counts in `summary.verdictCounts`.
- stop-to-final (`asr+cleanup`): one monotonic host span from before transcribe to after the gate, including IPC and queueing. For `asr` it equals the host recognizer time. Worker-measured times are in `recognizerMetrics` / `cleanupMetrics` / `generationMetrics`.
- P50/P95 are reported only with at least 5 successful samples (`n/a` otherwise).
- Warm-ups run on the first sample and are excluded from results. The very first call after load (warm-up or not) is kept in `coldFirstMilliseconds` under `recognizer`, `cleanup` or `generation`. `loadMilliseconds` is keyed by catalog entry id and measured without warm-up.
- Memory: a `.memory` request on each worker after the loop. `combinedPeakFootprintBytes` = sum of both workers' peak physical footprint (both stayed loaded for the whole run, so this is a simultaneous-residency figure).
- Ctrl-C stops after the current sample and still writes partial results.
