# Mac validation: visual task guide

The visual guide is a development implementation. Release guidance remains disabled until both providers pass native acceptance. Portable transport/state tests and app-source typechecking do not establish native screen, Accessibility, or walkthrough correctness.

## Hardening validation — 9 October 2026

Environment: Apple Silicon, macOS 26.6.2, Xcode 26.6, Swift 6.3.3, Claude 2.1.295, Codex 0.162.0. This work follows the native QA baseline at `9baeb1554ca796f867183aba5ba67d78fa210ace`; source changes were built and launched through Xcode. Whole-display screenshots and native mouse/keyboard input were used for guide acceptance. App-bound automation can change application focus and therefore must not be used to observe an otherwise waiting guide.

| QA finding | Change and evidence |
|---|---|
| QA-01: native Settings scene was empty | The native scene uses the same live controller and grouped settings as the companion menu. Cmd+, opened populated backend, shortcut, screen and speech settings in the signed app. |
| QA-02: initial shortcut failure | Carbon rebinding is transactional: registration failure preserves the previous working shortcut. Native Option+Shift+Space opened Quick Ask repeatedly after permissions and relaunch. The original physical-shortcut failure's cause was not isolated; portable registration tests do not prove that historical cause. |
| QA-03: Codex 0.162.0 rejected | Kept unavailable with a specific isolation error. All owned effective configuration and runtime restrictions are audited before a user turn. A temporary unauthenticated audit established that configuration alone cannot exclude model-required code/patch tools; no user request or inference was sent. |
| QA-04: layout diagnostics | Deferred/coalesced fitting and finite initial frames harden the island, composer and menu panel. A symbolic breakpoint traced the remaining recursion warning to AppKit's `NSStatusBarContentView` during a system scene resize, with no Clicky layout callback on the stack. That platform warning remains; no blanket warning-free claim is made. |
| QA-05: malformed provider variants | Prompt `clicky-guide-7` uses kind-specific structured output requiring step action/outcome and verification capture/verdict/evidence/evidence region. Purpose checks and safe field-path diagnostics reject malformed or inappropriate output without automatic replay. Native Claude workflows completed through strict variants. |
| QA-06: value `12` truncated to an ellipsis | Native text-cell sizing and single-line measurement fixed the value plate. The signed app displayed the complete `12`. |
| QA-07: labels covered nearby controls | Placement avoids approved-window control frames, marks and other plates, and omits a plate if no safe position exists. Native value/label plates remained clear of Quantity and Apply. |
| QA-08: stable steps immediately invalidated | Freshness captures reuse the original region and output dimensions before cropping. Native stable targets held beyond 30 seconds; unrelated clicks were ignored. Paired mouse release normalization addresses the separately reproduced zero-count release that blocked Apply. At 06:10 local time, Open → Quantity `12` + Tab → Apply completed automatically, without Next, Retry or Check now. |

Native annotation checks exercised circle, underline, highlight, arrow and value against the disposable browser fixture. Field editing remained on the current step until Tab; a wrong value did not count as success. These checks do not cover the full release matrix, multiple monitors, every native control, or both providers.

The final prompt-7 browser repeat reached “Task complete · verified” at 06:41 without Next, Retry or Check now. Its first synthetic Apply click focused the button but did not submit the form, and the target guard reported changed pixels. A second native click submitted the form and completion followed automatically. This repeat establishes recovery and automatic completion, not a clean single-click pass. The earlier 06:10 browser run and 06:31 desktop run completed without that interruption. At 06:43, zooming the focused scratch form removed its stale highlight and paused the guide without advancing; the observed invalidation was window geometry, so this does not independently prove the field-only geometry branch.

Additional hardening rechecks the original field's identity, owner and geometry while editing, and retains verified completion text in Last reply. Completion provenance remains separate from manual acknowledgement. At 06:31 local time, the native desktop Apple menu → About This Mac workflow completed automatically, with “Task complete · verified” visible in Last reply. No manual Next, Retry or Check now was used in the successful run.

Display verification exposed two independent changes outside the outcome: animated Computer Use pointer overlays (their Window Server frames matched the differing pixel bounds), then a macOS status indicator changing 17 pixels. Removing test overlays isolated the latter. Prompt 7 requires a provider-grounded region encompassing all visible outcome evidence; the host compares exact pixels in that region, rejects missing or out-of-image evidence regions, and retains scope/capture/generation/focus checks. Changes within the outcome still invalidate verification. No percentage threshold or automatic success from input was introduced.

Final portable checks: 156 tests passed, release and DEBUG app-source typechecks passed; existing warnings remain. The signed Debug application built and ran through Xcode. Native results cover 18 distinct passing cases across runs (19 executions including the light/dark launch case), not one clean final combined run:

- `Test-leanring-buddy-2026.10.09_06-44-10-+0200.xcresult`: all nine UI executions passed, including the five Quick Ask/editor/demo tests. Seven native unit cases passed; three new freshness cases exposed the synthetic-image fixture defect described below.
- `Test-leanring-buddy-2026.10.09_06-48-46-+0200.xcresult`: all ten native unit cases passed after the fixture-only correction. UI automation could not initialize: `Timed out while enabling automation mode.` No application source changed between these runs.
- Subsequent combined reruns remained blocked at native automation startup. Stopping the session's Computer Use helper, restarting the user XCTest service, and reopening Xcode did not establish another completed combined result. Xcode/Computer Use recovery itself timed out. This is an outstanding validation-environment limitation, not a passing rerun.

Result bundles are under Xcode DerivedData's `leanring-buddy-bjfejiaxjzwttofionkqobpyndho/Logs/Test`. The first native run exposed a synthetic-image fixture defect: `NSBitmapImageRep.setColor` rejected the color conversion and encoded identical transparent PNGs. The fixture now writes explicit opaque RGBA pixels through ImageIO and requires distinct input PNGs before testing the production comparator; production fingerprint code was unchanged.

### Codex 0.162.0 isolation result

`node scripts/audit-codex-isolation.mjs /absolute/path/to/codex` audited 39 owned configuration values, disabled 13 discovered host skills, found no MCP servers, and established an ephemeral thread with empty instruction sources without authentication or model inference. Its final result is deliberately failing: `model_tool_boundary_unproven`.

The runtime's `unified_exec=true` is an implementation-selector normalization when `shell_tool=false`, not proof that shell execution is available. The actual blocker is model-required tooling. In official `rust-v0.162.0` source (`c1382380de69521303b416720a52f42d51af6248`), the [model catalog](https://github.com/openai/codex/blob/c1382380de69521303b416720a52f42d51af6248/codex-rs/models-manager/models.json#L524-L544) supplies code-mode and freeform patch behavior, [model tool mode overrides feature selection](https://github.com/openai/codex/blob/c1382380de69521303b416720a52f42d51af6248/codex-rs/core/src/tools/mod.rs#L75-L95), and [patch registration](https://github.com/openai/codex/blob/c1382380de69521303b416720a52f42d51af6248/codex-rs/core/src/tools/spec_plan.rs#L1344-L1347) remains model-driven. No supported `include_apply_patch_tool` configuration switch or verified effective tool-inventory RPC was found. Clicky must not broaden its allowlist on configuration echoes alone. The older allowlisted version has not been revalidated against the new runtime gate in this run.

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
| Setup consent / Off | One alert at first launch (Allow = Automatic + display-fallback preference, Not now = Off); Confirm per task migrates to Automatic |
| Display with no window | First display-needed request asks before any capture (Share display / Text only); same display and provider not asked again this session; relaunch with legacy `displaySharingApproved=true` asks again; Text only sends no image and does not loop; Settings toggle off revokes immediately |
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
- Failed action: initial check plus one fresh recheck per episode; then the target stays observed and Re-check is primary. Mark done stays explicitly unverified.
- Wrong target: selecting a scratch Delete/Reset button in correction mode must not invoke its handler (activation counter unchanged), must not count as an attempt, and the selection panel must be absent from the next capture.
- Hover: keep the pointer on a hover-highlighting target across several guard intervals; no re-location or uncertainty. Move or scroll the window: the step is re-grounded without progress.
- Interruptions: open/Escape Quick Ask, ask and dismiss a side question, and visit another app briefly; each resumes without Resume. Explicit Pause during the visit stays paused.
- Denied Accessibility/custom controls: visual/manual path and Check now; no periodic cloud screenshots.
- Related question: pause, answer readably, retain step/process; Resume relocates against current evidence.
- Distinct goal: Keep current task/Start new task; replacement starts fresh session only after the choice.
- Completion: fresh outcome evidence or explicit Finished manually, visible provenance, process ended.

## Release workflows

Run all workflows with each real provider, without application-name branches or repeated “continue” prompts:

1. Blender scratch scene: select and rename an object, commit a numeric transform, open properties.
2. Browser scratch fixture: open a panel and commit a form field. A deterministic fixture is under `Tests/NativeFixtures/guide.html`.
3. TextEdit scratch document: open and save through a sheet.

### Development gate B: automatic 5–10-step workflow

`Tests/NativeFixtures/workflow.html` is a disposable six-step click/double-click flow: New report → double-click Q3 → Options (outcome after 2 s) → Include charts → double-click Summary → Publish to team. Ask in Quick Ask: “Create a new report, open the Q3 folder, open Options, turn on Include charts, open Summary and publish it.” Pass criteria: completion reaches “Task complete · verified” using only application clicks (no Next/Mark done, Re-check, Find again or Resume); Publish shows a consequence warning beside the target; “Delete activations” stays 0. Repeat with a real settings flow (for example System Settings › Appearance) and record the task metrics line from the unified log (`log stream --level info --predicate 'subsystem == "clicky" AND category == "guide"'`; without `--level info` only errors appear, DEBUG builds; counts and P50/P95 only, no content). Before a native run, `scripts/replay-guide-fixture.sh` replays the fixture states through the real provider (prompt `clicky-guide-11`, 5 runs at 1512×840: 30/30 positives confirmed, 30/30 negatives including hover contradicted, 5/5 spinner pending, 5/5 goals verified, 0 false confirms, 5 wrong-purpose replies recovered; Summary chosen as double-click in 4/5 runs, a single click otherwise). Debug builds also log content-free `turn`, `attempt`, `verdict`, `recovery`, `relocate` and `task metrics` lines (`log show --predicate 'subsystem == "clicky"' --info`). Coordinator coverage of the same loop (`GuideLoopTests.testFiveStepClickAndDoubleClickWorkflowNeedsNoGuideControls`) uses fakes and is not this gate.

Record per run (results go to the Plane Validation page, not Git): revision, provider and version, steps completed, guide-control actions used, false advances (judged by the fixture/human, never by Clicky), “Delete activations” count, and the task metrics line (counts plus `firstInstruction`, `acknowledgement`, `verification`, `nextStep`, `cancellation` P50/P95; metrics reset per task). Then run the adversarial cases and record pass/fail with the observed status line:

1. **Replaced control under a stationary pointer:** with a step marked, keep the pointer on the target and replace the control (fixture reload or DOM change). Expected today: undetected while hovering (known gap); after moving the pointer away it re-grounds or clears within ~2 s.
2. **Replaced control while uncertain:** force uncertainty (e.g. click elsewhere twice), then change the control with the pointer away. Expected: mark clears with “View changed · Find again or Re-check”, no provider turn.
3. **Related-dialog checkbox:** a step whose outcome is a checkbox inside a sheet/dialog (TextEdit or browser). Record whether AX confirmed it or vision did (`localConfirmations` vs `visionChecks`).
4. **Multi-page goal:** change one option on one page, another elsewhere, then finish. Record whether final verification confirms, contradicts or loops.
5. **Cancel during focus recovery:** switch apps during “Checking the control”, then press End. Expected: ends immediately, nothing sent afterwards.

Also verify IME/multiline/Unicode/indentation, focus restoration, shortcut rebinding, nonactivating controls, click-through annotations, and quiet memory-only storage. Native no-AI demo acceptance is separate from real outcome verification. Keep release flags false until every required native case passes.

## Writing, snippets and terminal insertion (CLICKY-42) — 9 October 2026

Protocol and adapter design: [WRITING_PROTOCOL.md](WRITING_PROTOCOL.md). Evidence is separated by layer; nothing below is signed-GUI or real-provider evidence unless it says so.

Environment: macOS 26.6.2 (Apple Silicon), Chrome 154.0.8037.98, Terminal 2.15 with zsh 5.9, VS Code 1.141.0.

| Layer | Command | Result |
|---|---|---|
| Portable + coordinator | `bash scripts/test-core.sh` | 338 XCTest cases pass, including `WritingContractTests`, `SlashCommandTests`, `WritingDefinitionsTests`, `QuickAskRouteTests`, `VSCodeBridgeTests` and 22 `WritingCoordinatorTests` (fakes; production coordinator) |
| Bridge logic | `cd Tools/clicky-vscode-bridge && node --test` | 7 pass |
| App typecheck | `bash scripts/typecheck-app.sh` and `--debug` | no errors; no new warnings |
| Native adapters (production adapter sources driven by `Tools/ClickyWritingProbe`, no Clicky GUI) | `scripts/probe-writing-native.sh chrome` | Pass: textarea capture, focus gate, exact insertion of Unicode/emoji/combining marks/tabs/blank lines/`$(x)`/backticks at the caret, user clipboard (string + custom type) restored, guarded restore, exact substring source read, replace only the selected range, caret move detected as `selectionChanged`, stale expected source refused |
| | `scripts/probe-writing-native.sh terminal` | Pass: ready zsh prompt bound by window id + tty, complex single-line command inserted verbatim with no confirmation, execution-counter file absent after insertion, present only after the tester's separate Return; multiline refused; busy tab (`sleep`) bound as not ready |
| | `scripts/probe-writing-native.sh chrome-rich` | **Not passed.** Contenteditable located and focused, but another application became frontmost during the run; the adapter refused both writes (`focusChanged`) and the content stayed unchanged. Rerun on an idle desktop |
| | `scripts/probe-writing-native.sh vscode`, `vscode-terminal` | **Not run.** An isolated VS Code instance could not start from the session scratch directory (IPC socket path > 103 bytes), and installing the bridge into the user's VS Code needs explicit approval |
| Signed GUI (Xcode, `leanring-buddy` scheme) | Quick Ask picker, Write/Rewrite/snippet end to end, key hold/repeat, notice panel, Settings › Writing | **Not run** |
| Real provider | Claude/Codex `writing` contract (`clicky-writing-1`) drafts, rewrites, clarifications | **Not run** |

Findings fixed during native probing: Chrome applies AX selection asynchronously (the adapter now waits for the exact range to read back); Chrome ignores `AXSelectedText` and `AXReplaceRangeWithText` writes even though they report success (paste is the only write path); Terminal's `processes` must be bound to a variable before `last item` and `tab` inside `tell application "Terminal"` is Terminal's tab class; Terminal's AX character count drops one character per soft-wrapped line (the insertion caret delta is the evidence instead); key events reach only the frontmost application (every adapter re-checks frontmost and the focused control immediately before ⌘V).

Remaining native acceptance (run in the signed app, on an otherwise idle desktop):

1. Chrome `Tests/NativeFixtures/writing.html`: Write into the empty composer body and between paragraphs of the textarea (auto-insert, no confirmation); `/rewrite` on one of the two duplicate passages in the contenteditable (preview → Replace selection → only that range changes); signature, To and Subject unchanged; Send count stays 0; switch tabs or click another field during generation → preview kept, nothing inserted; Restore original after a later edit is refused.
2. Snippets with Local preview and no signed-in provider: `/docker-logs` (`docker compose logs --follow --tail 200`) at a ready Terminal prompt and in VS Code's integrated terminal; hold Return through submission (nothing reaches the shell); execution counter changes only on the tester's Return; multiline and tab snippets stay preview + Copy.
3. VS Code with the bridge installed per `Tools/clicky-vscode-bridge/README.md`: insertion at a caret and selected-range replacement in a scratch document, version change during generation → refused, destination switch to the integrated terminal, `sendText(…, false)` insertion without execution.
4. Picker: `/` lists, ↑↓/Tab/↩ complete without invoking, exact alias ↩ submits once, Escape hides then closes, IME composition (e.g. Japanese) never submits, `/usr/bin/env` and `//write` are sent as text.
5. A walkthrough waiting on a step while a snippet is inserted: the step does not advance and resumes after the host edit.
6. Real provider (Claude Haiku 5.5 / Codex): email body only with a separate subject, rewrite preserving facts and source language, clarification shown and never inserted.
