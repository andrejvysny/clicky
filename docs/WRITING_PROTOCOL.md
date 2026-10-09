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
| No target, secure field, read-only, unsupported app, bridge missing, Local preview backend | preview + Copy |

`WritingCoordinator.apply` claims each `(operation, proposal revision)` once (`WritingApplyClaims`), closes Quick Ask without restoring focus, waits for Return/keypad Enter key-up (≤ 10 s), restores focus only when Clicky itself took it, re-reads the live target and compares it with the binding, checks Stop and the definition revision, then performs exactly one adapter write. Outcomes: `applied` (read back), `acknowledged` (VS Code terminal API accepted, no read-back), `notApplied(reason)`, `deliveryUnknown` (never retried, never followed by another strategy). Results stay available for Copy.

| Adapter | Identity / revision | Write | Verification | Restore |
|---|---|---|---|---|
| `WritingAXFieldAdapter` (Chrome: textarea, contenteditable) | focused AX element, window number, `AXSelectedTextRange`, `AXNumberOfCharacters` | select exact range (wait for read-back) → stage clipboard → tagged ⌘V to the pid. Chrome ignores `AXSelectedText` writes, so paste is the only path. | count = before − replaced + inserted, caret at insertion end, `AXStringForRange` equals text | guarded: same element, unchanged count and inserted text; replace back or select + Delete |
| `WritingTerminalAdapter` (macOS Terminal) | `osascript` read-only `id`/`tty`/`busy`/foreground process of the front tab; ready = not busy and a shell (zsh, bash, fish, sh, ksh, tcsh, dash) | single printable line only → stage clipboard → tagged ⌘V | insertion caret advanced by exactly the text (Terminal's AX count drops one character per soft wrap) and the tab is still not busy | none — Clicky never clears or undoes terminal input |
| `WritingVSCodeAdapter` (opt-in bridge) | document URI + version + single selection; active terminal process id, shell integration and busy state | `replaceRange` checks version and exact expected text, then `TextEditor.edit`; terminal: `sendText(text, false)` for one printable line | edit read-back (CRLF documents may normalize line endings) | versioned replace back with expected inserted text |

`WritingClipboard` snapshots every pasteboard item/type (≤ 8 MiB; unreadable promised data → `clipboardUnavailable`, no paste), stages plain text late, and restores only while `changeCount` still equals the staged version. On `deliveryUnknown` it does not restore, so a late paste still inserts the intended text instead of the user's old clipboard.

Synthetic keystrokes carry `WritingSyntheticInput.eventTag`; the walkthrough key monitor ignores them, and the composer hold that pauses guide observation is released only after the host edit finishes.

## Providers

Writing runs in its own clean process: `GuideAgentProfile(contract: .writing)` writes `WritingPrompt.prompt` (`clicky-writing-1`) and launches Claude with a schema that offers only `writing_draft` and `clarification`; Codex gets the same per-turn `outputSchema`. All existing isolation audits apply unchanged. Requests use purpose `writing` with a `writing` payload (operation, optional Clicky skill name/instructions, exact source, optional surrounding text, destination kind, previous draft and refinement). Guide purposes never accept `writing_draft`; writing never accepts guide kinds. Drafts are byte-exact (≤ 32 KiB), subjects are separate and never inserted, clarifications and refusals are shown and never inserted. Local preview returns a labelled deterministic draft that is preview-only.

## VS Code bridge

`Tools/clicky-vscode-bridge` is a dependency-free extension installed explicitly by the user (see its README). It stays idle until Clicky Settings › Writing › VS Code creates `~/Library/Application Support/Clicky/vscode-bridge/token` (directory 0700, token 0600); it then listens on `vscode-<pid>.sock` (0600) and re-reads the token for every request. Methods: `state`, `readRange`, `replaceRange`, `insertTerminal`. It never calls `executeCommand`, never passes `true` to `sendText`, and has no shell or file APIs. The bridge cannot tell whether the editor or the integrated terminal had keyboard focus, so Quick Ask shows the destination and a switch; `terminalOnly` snippets choose the terminal.

## Validation

- Portable/Core: `WritingContractTests`, `SlashCommandTests`, `WritingDefinitionsTests`, `QuickAskRouteTests`, `VSCodeBridgeTests` (fake socket server, extension source guard) and `node --test` in the extension folder.
- Coordinator (macOS SwiftPM, fakes): `WritingCoordinatorTests` — 18 lifecycle cases.
- Native adapter probe (real apps, production adapter sources, no Clicky GUI): see `docs/MAC_VALIDATION.md` › Writing.
- Signed GUI and real-provider acceptance (CLICKY-42) are listed there as pending until run.
