# Mac validation: visual task guide

The visual guide is a development implementation. Release guidance remains disabled until both providers pass native acceptance. Portable transport/state tests and app-source typechecking do not establish native screen, Accessibility, or walkthrough correctness.

## Evidence — 8 October 2026

Environment: Apple Silicon, macOS 26.6.2, Xcode 26.6, Swift 6.3.3, Python 3.14.7, Codex 0.160.1. Claude's installed symlink advanced from 2.1.294 to 2.1.295 during implementation; both versions underwent isolation marker checks.

| Check | Evidence |
|---|---|
| Mac preflight | Baseline passed |
| Portable suite | 69 tests passed (adds effort/selection/paste composition and Claude launch effort); covers strict schema/variant semantics, limits, grants/cancellation, transforms, stale/duplicate evidence and provider messages, double-clicks/keys, manual provenance, side-question purposes, process continuity/crash recovery/cancellation/timeouts; fixture asserts exact models and low effort |
| App-source typecheck | Release and DEBUG checks passed using `scripts/typecheck-app.sh`; existing concurrency/deprecation warnings remain |
| Xcode build | Native signed Debug build succeeded through Xcode; no terminal `xcodebuild` |
| Xcode tests | 11 native tests passed through Xcode, including preview editor/response and deterministic no-AI guide pause/manual provenance. Earlier failing runs exposed a stale test host/import, actor isolation, and preview accessibility/focus harness assumptions; corrections verified |
| Claude 2.1.294–2.1.295 transport | Haiku 5.5 at low effort: two validated, correlated structured turns per process, effective policy audit, no Clicky task JSONL transcripts found |
| Claude marker controls | 2.1.294 and 2.1.295: instruction/skill/hook markers present in control, absent in safe isolated run |
| Codex 0.160.1 diagnostics | Effective disabled capabilities, enumerated host skills, ephemeral thread, empty instruction sources verified without model inference |
| Codex native inference | Requires official sign-in in Clicky's separate profile; personal credentials were not copied |
| Blender/browser/TextEdit walkthroughs | Pending native acceptance; release gate remains closed |

The previous 44-test text-client/provider transport evidence concerned `clicky-text`, personal CLI authentication, project directories and managed resume. It does not establish clean visual-guide isolation or native walkthrough acceptance.

## Build and checks

Use Xcode 26+ / Swift 6.2+ with the shared `leanring-buddy` scheme and My Mac destination. Set the user's signing team, Cmd+B to build, Cmd+R to run, Cmd+U to test. The product is `Clicky.app`; test host/module settings use Clicky while the legacy directory/scheme stay unchanged. Never invoke terminal `xcodebuild`, which can alter the application's TCC identity.

For native provider setup, temporarily add `--clicky-show-settings` to the Xcode Run arguments. DEBUG only: it opens the full composer with Settings using the ordinary provider/authentication paths. Remove the launch argument after validation. It does not grant capture or Accessibility access. Requested model defaults are Haiku 5.5 and GPT-6 Luna, both low effort; no model substitution is enabled.

```bash
bash scripts/mac-preflight.sh
bash scripts/test-core.sh
bash scripts/typecheck-app.sh
bash scripts/typecheck-app.sh --debug
```

If the execution host already sandboxes SwiftPM and nested sandbox creation reports `sandbox_apply: Operation not permitted`, use `bash scripts/test-core.sh --disable-sandbox`; it disables only SwiftPM's nested sandbox, not tests. The typecheck harness uses a temporary Sparkle type stub; Xcode validates the real dependency and signing. Native tests use a dedicated `ClickyUITests` preference domain and do not validate production focus restoration.

## Provider compatibility

Supported versions are explicitly audited, not accepted by a broad version prefix. Unsupported versions fail with an actionable backend error. Repeat after a CLI, profile, or prompt/schema upgrade.

1. Use official provider authentication. Claude retains normal authentication. Codex requires Clicky Settings → Codex → Sign in; complete the official browser flow. Never copy personal credentials/history or use an API key workaround.
2. Send a harmless screen-independent question. Confirm a readable answer and no image transmission. Provider output remains buffered until strict schema and semantic validation pass.
3. Send a second question in the same task/side-question flow; verify process/session continuity. Let the task wait longer than the turn timeout; local waiting must not terminate it.
4. Inspect effective source/capability diagnostics. Claude must report clean settings, no skills/MCP/custom tools/plugins, with only the schema adapter and known bundled plugin metadata. Codex must report disabled capabilities, empty instruction sources, an ephemeral thread, and every discovered host skill disabled in the owned profile/thread configuration.
5. In disposable owned control directories, add harmless instruction, skill and hook markers. Confirm they load in a normal control run, disappear in isolated runs, and that clean mode rejects incompatible managed hooks/helpers/customization. Never change the user's personal profile for this test.
6. Inspect only Clicky-owned runtime paths for prompt/image/JSONL/history transcripts; check Claude's matching Clicky task project directories without opening unrelated history. Authentication/preferences may persist; walkthrough contents may not.
7. Kill/stop the provider during an active turn. Confirm text-only recovery, stale callbacks ignored, no automatic replay. Explicit Retry starts fresh with in-memory task context. End must terminate the child process.

The clean diagnostic prints presentation kinds, not content:

```bash
printf '%s\n' 'Explain what a checkbox is.' 'Explain a radio button.' |
  swift run clicky-guide claude /absolute/path/to/claude /tmp/clicky-owned-profile
```

Use `codex` with its executable/profile root for the other provider. The portable fixture is offline and never proves real provider isolation. The old `clicky-text` diagnostic is retained for legacy protocol tests; the app no longer uses that runner.

## Native sharing matrix

Use scratch data only. Test both providers and record OS/CLI/prompt versions, permissions, target PID/window ID, step/context revisions, actual behavior and pass/fail. Do not log raw prompts, replies, screenshots, credentials, or AX values.

| Scenario | Required behavior |
|---|---|
| Open/close Quick Ask without sending | No capture/provider request; popup stays beside its opening position |
| Screen-independent answer | Text only, even with Task window enabled |
| First visual task | Text-first request, fresh exact originating-window evidence when requested |
| Confirm per task / Off | Explicit approval / no automatic sharing; preserve migrated preferences |
| Menus/sheets/dialogs | Include only established related windows; explicit window list, child inclusion off |
| Unrelated same-app window | Excluded; selecting another window requires one grant |
| Another app or ambiguous relationship | Pause; choose/approve exact target |
| Broader once | Separate confirmation; exact approved display, one transmission, no grant expansion/grounding |
| Pause/revoke during delayed capture/response | Cancel queued work; no stale images, annotations or verdicts |
| Close/minimize target | Pause and require fresh target validation |
| Move/resize/scroll/change tab or panel | Remove annotations; Retry/refresh before reusing coordinates |
| Retina/negative coordinates/monitor move | Correct crop/envelope transforms; no display/application fallback |
| Denied Screen Recording | Actionable error; ordinary text Ask still works |

PNGs remain capped at 3 MiB and 4096 px per axis. Overviews are at most 1568 px long side and 1.15 MP. Detail crops have independent transforms. Inspect only the explicitly granted window; a complex capture limit must not silently omit evidence.

## Native interaction matrix

- Click/right-click/double-click: recorded event coordinates/time/count; one click cannot satisfy a double-click step. Repeats and duplicate callbacks do not advance twice.
- Expected keys/combinations only: unrelated Enter and Quick Ask Enter never satisfy target steps. No character reconstruction or keylogging.
- Committed nonsecure fields: verify scoped AX values after commit or fresh vision; never read secure fields or reconstruct typing.
- Alternative route: an independently satisfied intended outcome can advance without the prescribed click.
- Failed action: initial check plus one fresh recheck; then Retry/manual Next. Manual Next stays explicitly unverified.
- Denied Accessibility/custom controls: visual/manual path and Check now; no periodic cloud screenshots.
- Related question: pause, answer readably, retain step/process; Resume relocates against current evidence.
- Distinct goal: Keep current task/Start new task; replacement starts fresh session only after the choice.
- Completion: fresh outcome evidence or explicit Finished manually, visible provenance, process ended.

## Release workflows

Run all workflows with each real provider, without application-name branches or repeated “continue” prompts:

1. Blender scratch scene: select and rename an object, commit a numeric transform, open properties.
2. Browser scratch fixture: open a panel and commit a form field. A deterministic fixture is under `Tests/NativeFixtures/guide.html`.
3. TextEdit scratch document: open and save through a sheet.

Also verify IME/multiline/Unicode/indentation, focus restoration, shortcut rebinding, nonactivating controls, click-through annotations, and quiet memory-only storage. Native no-AI demo acceptance is separate from real outcome verification. Keep release flags false until every required native case passes.
