# Clicky Bridge (VS Code)

Opt-in local bridge so Clicky can read the focused VS Code window's editor/terminal state, apply one versioned range edit, and insert (never execute) one single line into the active integrated terminal.

## Install (opt-in, manual)
No vsix is built, so `code --install-extension` is not possible. From the repo root:

```
ln -s "$PWD/Tools/clicky-vscode-bridge" ~/.vscode/extensions/clicky-local.clicky-bridge-0.1.0
```

Then run "Developer: Reload Window". The extension stays idle until you enable it.

- Enable: Clicky Settings creates `~/Library/Application Support/Clicky/vscode-bridge/token` (mode 0600, directory 0700). The extension polls every 5 s (stat only).
- Disable: delete the token file (the socket is closed within 5 s) or remove the symlink and reload.

Nothing modifies VS Code settings or shell startup files.

## Security model
- Unix socket only: `.../vscode-bridge/vscode-<pid>.sock`, mode 0600. No network listeners.
- Idle unless the directory is 0700 and the token is 0600, both owned by the current user.
- Every request carries the token; it is re-read on each request and compared in constant time.
- One request per connection, max 262144 bytes, one response line.
- No arbitrary command RPC. The extension never runs VS Code commands, tasks, child processes, or shell-integration execution, and never calls `sendText` with execute. Writes are limited to the socket path.
- Document text, terminal text and the token are never logged. Errors never echo user text.

## Protocol
Request line: `{"v":1,"id":"<=64 chars","token":"hex","method":"...","params":{...}}`.
Response line: `{"v":1,"id":...,"ok":true,"result":...}` or `{"v":1,"id":...,"ok":false,"error":"code"}`.
Offsets are UTF-16 code units. Only `file` and `untitled` documents.

| method | params | result |
|---|---|---|
| `state` | `{}` | `{focused, focusedAt (ms epoch of last focus gain, 0 if never), editor: null\|{uri, version, eol, languageId, selections:[{start,end,active}], isUntitled}, terminal: null\|{id, name, shellIntegration, busy, shell, readiness: ready\|busy\|unknown}}` |
| `readRange` | `{uri, version, start, end}` (<= 32768 units) | `{text}` |
| `replaceRange` | `{uri, version, start, end, text, expected, requireSelection?}` (text <= 65536 units; the window must be focused and the document must be the active editor; with `requireSelection` its single selection must equal `[start,end)`; `expected` must equal current range text) | `{applied, verified, normalizedLineEndings, version, start, end}` |
| `insertTerminal` | `{terminalId, text}` | `{sent:true, verified:false}` |

Errors: `unauthorized`, `badRequest`, `badVersion`, `unknownMethod`, `duplicate`, `notFound`, `stale`, `badRange`, `sourceChanged`, `selectionChanged`, `focusChanged`, `terminalChanged`, `noShellIntegration`, `busy`, `readinessUnknown`, `revoked`, `canceled`, `unsafeText`, `internal`.

`insertTerminal` requires the focused window, the active terminal's process id to match (re-checked after awaiting it), shell integration, readiness `ready`, and single-line text without control characters, line separators or bracketed-paste markers. Readiness is `unknown` until a shell-integration event (integration activated, command started or ended) was observed for that terminal in this extension host, so a command started before activation cannot look idle; run any command once to establish it.

Every write re-reads the token and checks that the requesting connection is still open immediately before the side effect (`revoked`/`canceled` otherwise), and a request id is executed at most once per extension host (`duplicate`).

## Limitations
- Cannot tell whether the editor or the terminal had keyboard focus; Clicky treats that binding as ambiguous (explicit Insert only).
- `sendText` has no read-back; insertion into the terminal is unverified.
- Inserted text follows the document EOL (`normalizedLineEndings` reports conversion).

## Tests
`cd Tools/clicky-vscode-bridge && node --test test/*.test.js`
