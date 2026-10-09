# Writing, saved snippets and Quick Ask commands

Executable contract for CLICKY-37/38/39/40/41/43/44. Product decisions live in the Plane page “Writing, saved snippets and Quick Ask commands”; this file documents what the code does and how it is validated.

## Routes

`QuickAskRoute.route` (Core) normalizes every explicit Quick Ask submission:

| Input | Route |
|---|---|
| `/write …`, or a leading “Write/Draft/Compose/Napíš …” with an editable bound target | `write` (draft at caret) |
| `/rewrite …`, `/fix`, `/shorten`, `/translate <language>`, AI skills with operation rewrite, or a leading “Rewrite/Rephrase/Shorten/Fix/Translate/Make this …” with a selection | `rewrite` (preview + Replace selection) |
| A saved snippet alias | `snippet` (local, no provider) |
| `/explain …`, `/guide …`, `//literal …`, any other text | existing conversation/guide path |
| Unknown or disabled alias, missing argument, selection-only command without a selection | local error; nothing is sent |

`SlashParser` recognizes a command only when the draft starts with `/` followed by a lowercase alias (`[a-z0-9][a-z0-9-]{0,31}`) and whitespace or the end. Paths (`/usr/bin/env`), uppercase (`/Write`), punctuation (`/a.txt`) and `//escape` are text. Raw `/commands` are never forwarded to Claude or Codex; provider-native slash commands and inherited skills stay disabled.

The picker (`SlashPickerState`) appears only while the draft is exactly `/` plus an alias prefix with the caret at its end and no IME marked text. ↑/↓ move, Tab and Enter complete without invoking, Enter on an already exact alias submits once, Escape hides suggestions until the query changes. Rows show the kind badge (Action / AI skill / Snippet · No AI), argument hint and availability.

## Definitions

`WritingDefinitions` (schema version 1) is stored in the app's preferences domain under `writingDefinitions` and written only by an explicit Save in Settings › Writing. Snippet bodies and skill instructions are stored byte-exact: no trimming, newline/Unicode normalization or interpolation of `$VAR`, `${x}`, `$(cmd)`, backticks or `{{x}}`. Aliases share one namespace with reserved built-ins (`write`, `rewrite`, `fix`, `shorten`, `translate`, `explain`, `guide`, `skills`, `snippets`, `settings`, `help`, `clicky`, `professional`, `reply`). Every content change bumps `revision`; a pending application checks the invoked revision and enabled state again immediately before writing (`definitionChanged`).

## Targets and application

`TextTargetSnapshot` binds application, window, pane/document and caret/selection plus an opaque content revision before Quick Ask takes focus. It carries no field content. `ExactSource` (≤ 32 768 UTF-16 units, exact length check) is read only after an explicit Rewrite (or for verifying a replacement); `SelectionQuote` is never used as replacement source. Surrounding text (≤ 1 000 UTF-16 units each side) is read only after the per-request opt-in chip.

`WritingApplyPlan.decide` (host-only):

| Situation | Plan |
|---|---|
| Write or snippet at an empty caret in a supported field | automatic |
| Write or snippet with a nonempty selection; any Rewrite | review — explicit Replace selection |
| Terminal destination, single printable line | automatic (insert-only) |
| Terminal destination with line breaks / tabs / control bytes; Rewrite of terminal history | preview + Copy |
| Any other app without a verified adapter (VS Code without the bridge, non-Chrome apps, third-party terminals) | automatic clipboard paste at the app's cursor (`pasteOnly`; terminals single-line only); Rewrite copies the selection and pastes the replacement over it automatically (⌘Z in the app undoes it) |
| No target, secure field, read-only, Local preview backend | preview + Copy |
| VS Code with both a document editor and an integrated terminal (focus unknown) | review — explicit Insert, Switch to choose |
| A later Quick Ask binding (different destination than the operation's own) | review — explicit Insert; never automatic |
| Rewrite whose destination is not the selection it was generated from | preview + Copy (`rewriteTargetChanged`) |
| Restricted snippet on the other kind of destination (also after Switch) | preview + Copy |

Each operation pins the destination it was bound to (`operationTarget`) when its own binding resolves. A new Quick Ask binding during generation or review may change the displayed destination, but never inherits automatic authority, and a rewrite only replaces the selection its source was read from. Quick Ask routes a submission only after the pending binding resolves, so a fast Write is not misrouted as chat.

`WritingCoordinator.apply` claims each `(operation, proposal revision)` once (`WritingApplyClaims`), waits for Return/keypad Enter key-up (≤ 10 s) while Quick Ask still owns the keyboard and shows Stop (the editor ignores Return auto-repeat), then closes Quick Ask without restoring focus, restores focus only when Clicky itself took it, re-reads the live target and compares it with the binding, checks Stop and the definition revision, then performs exactly one adapter write. The write receives an operation-scoped `WritingAuthorization` (false after Stop, provider reset or a newer operation) that each adapter checks at its last synchronous point before the side effect; Restore original uses the same hand-off and authorization. Outcomes: `applied` (read back), `acknowledged` (VS Code terminal API accepted, no read-back; shown as “Sent to the terminal — not executed, not verified”), `notApplied(reason)`, `deliveryUnknown` (never retried, never followed by another strategy). Results stay available for Copy.

| Adapter | Identity / revision | Write | Verification | Restore |
|---|---|---|---|---|
| `WritingAXFieldAdapter` (Chrome: textarea, contenteditable) | focused AX element, window number, `AXSelectedTextRange`, `AXNumberOfCharacters` plus an in-memory hash of `AXValue` (≤ 256 Ki units; count only above that), secure/editable state re-checked live | select exact range (wait for read-back) → stage clipboard → tagged ⌘V to the pid. Chrome ignores `AXSelectedText` writes, so paste is the only path. | count = before − replaced + inserted, caret at insertion end, `AXStringForRange` equals text | guarded: same element, unchanged revision and inserted text; replace back or select + Delete |
| `WritingTerminalAdapter` (macOS Terminal) | `osascript` read-only `id`/`tty`/`busy`/foreground process of the front tab; ready = not busy and zsh in the foreground (the natively validated combination; other shells stay Copy-only until validated) | single printable line only → caret baseline → stage clipboard → tagged ⌘V | insertion caret advanced by exactly the text from the pre-paste baseline (Terminal's AX count drops one character per soft wrap) and the tab is still not busy | none — Clicky never clears or undoes terminal input |
| `WritingVSCodeAdapter` (opt-in bridge) | document URI + version + single selection; active terminal process id and tri-state readiness (`ready` only after a shell-integration event was observed and no command runs) | `replaceRange` requires the focused window's active editor, the bound selection (`requireSelection`), version and exact expected text, then `TextEditor.edit`; terminal: `sendText(text, false)` for one printable line | edit read-back; the receipt stores the CRLF-normalized text the document actually holds | versioned replace back with the stored inserted text |

`WritingPasteAdapter` (fallback) binds process, front window and, with Accessibility, the focused element; it pastes only while all three are unchanged and the element is not secure, then restores the user's clipboard after 0.6 s if Clicky still owns it (an app stalled longer would paste the restored clipboard — accepted limitation). Outcomes are `acknowledged` (“Pasted at the cursor”): no read-back, no Restore original, and like ⌘V it replaces whatever the app had selected. For Rewrite its source is `AXSelectedText` when the app exposes it, otherwise a ⌘C posted to that process (`WritingClipboard.copySelection`, user clipboard restored while it still holds that copy); an Accessibility-reported empty selection never copies, because some editors copy the whole line. Selection commands are offered for paste-only destinations (`mayHaveSelection`) and fail with “Select the text…” when nothing is copied. Caret/selection movement is detected only where Accessibility reports the selected range.

`WritingClipboard.shared` snapshots every pasteboard item/type (≤ 8 MiB; unreadable promised data → `clipboardUnavailable`, no paste), refuses a snapshot when `changeCount` moved while reading and refuses staging when it moved since the snapshot, stages plain text late, and restores only while `changeCount` still equals the staged version. On `deliveryUnknown` it does not restore (no timer), so a late paste still inserts the intended text; the text stays unsettled and the next staging carries the user's original snapshot forward, so the next confirmed paste restores it. Residual limitation: another process can write between the last `changeCount` check and `clearContents()`; macOS has no atomic swap.

Synthetic keystrokes carry `WritingSyntheticInput.eventTag`; the walkthrough key monitor ignores them, and the composer hold that pauses guide observation is released only after the host edit finishes.

## Providers

Writing runs in its own clean process: `GuideAgentProfile(contract: .writing)` writes `WritingPrompt.prompt` (`clicky-writing-2`) and launches Claude with a schema that offers only `writing_draft` and `clarification`; Codex gets the same per-turn `outputSchema`. All existing isolation audits apply unchanged. Requests use purpose `writing` with a `writing` payload (operation, optional Clicky skill name/instructions, exact source, optional `reference` — the selection quote and pasted chips visible in Quick Ask, verbatim — optional surrounding text, destination kind, previous draft and refinement). A clarification keeps the writing session: the next plain input answers it (`refinement`, no previous draft) in the same provider conversation. A generation failure before any draft stays visible with Retry and Discard. Guide purposes never accept `writing_draft`; writing never accepts guide kinds. Drafts are byte-exact (≤ 32 KiB), subjects are separate and never inserted, clarifications and refusals are shown and never inserted. Local preview returns a labelled deterministic draft that is preview-only.

## VS Code bridge

`Tools/clicky-vscode-bridge` is a dependency-free extension installed explicitly by the user (see its README). It stays idle until Clicky Settings › Writing › VS Code creates `~/Library/Application Support/Clicky/vscode-bridge/token` (directory 0700, token 0600); it then listens on `vscode-<pid>.sock` (0600) and re-reads the token for every request. Methods: `state`, `readRange`, `replaceRange`, `insertTerminal`. It never calls `executeCommand`, never passes `true` to `sendText`, and has no shell or file APIs. Before every write it re-reads the token, confirms the requesting connection is still open, rejects replayed request ids, and re-checks focus, terminal identity and readiness after its last await. The bridge cannot tell whether the editor or the integrated terminal had keyboard focus, so such a binding is ambiguous: Quick Ask shows the destination and a switch and applies only on explicit Insert; `terminalOnly`/`editorsOnly` snippets choose their kind.

## Validation

- Portable/Core: `WritingContractTests`, `SlashCommandTests`, `WritingDefinitionsTests`, `QuickAskRouteTests`, `VSCodeBridgeTests` (fake socket server, extension source guard) and `node --test test/*.test.js` in the extension folder (`extension.test.js` drives the production request handler against a fake `vscode` module: focus/selection binding, revocation/disconnect at the commit point, readiness, replay).
- Coordinator (macOS SwiftPM, fakes): `WritingCoordinatorTests` (lifecycle), `WritingHardeningTests` (keyboard hand-off order, commit-point Stop/reset, rebinding, ambiguous VS Code, restricted snippets, clarification answers, Retry, reference payload) and `WritingClipboardTests` (private pasteboard).
- Native adapter probe (real apps, production adapter sources, no Clicky GUI): see `docs/MAC_VALIDATION.md` › Writing.
- Signed GUI and real-provider acceptance (CLICKY-42) are listed there as pending until run.
