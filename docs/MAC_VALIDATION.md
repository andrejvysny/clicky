# Mac validation: text-first Clicky

Status: the portable Swift suite is tested in Linux. The AppKit/SwiftUI app, four new UI tests, real provider inference, and focus restoration need validation on macOS. Syntax parsing alone does not establish a successful Mac build.

This development build also implements explicit single-window screenshots and local system reply speech. Both require the native acceptance checks below before being considered validated.

## Build and launch

You can use the prepared `clicky-mac-source.tar.gz` snapshot, which includes the current modified and new source files, Xcode project, portable tests, and documentation. Extract it into a new folder; it contains a `clicky/` directory. It excludes Git metadata, credentials, caches, Worker runtime files, and Xcode user data. It is source code, not a signed app or a preserved Git history. To create an updated archive from the Git checkout, run `bash scripts/package-mac-source.sh /absolute/path/clicky-mac-source.tar.gz` (Python 3.9+).

Optional transfer integrity check from the archive directory: `shasum -a 256 -c clicky-mac-source.tar.gz.sha256`.

1. Use an Apple Silicon Mac on macOS 14.2+, with Xcode 16+ and Swift 6+.
2. Run `bash scripts/mac-preflight.sh` from the checkout. If `xcode-select -p` selects Command Line Tools, select the installed Xcode developer directory before proceeding.
3. Run `bash scripts/test-core.sh`. These tests launch offline Python fixtures, so `python3` must be installed. They make no provider requests. They do not launch the app or use TCC permissions.
4. Open `leanring-buddy.xcodeproj` in Xcode. Keep the existing scheme name `leanring-buddy` and set your own signing team. Build and launch with **Cmd+R**. Do not run terminal `xcodebuild`; the repository prohibits it because of TCC behavior.
5. Check that the menu-bar icon and original blue companion appear. No microphone, Accessibility, screen-recording, email onboarding, or login-item registration is required by this startup path. Use the menu to hide the blue companion if desired.

The Xcode target uses filesystem-synchronized folders, so `leanring-buddy/TextInput/` is automatically included. The same Core source files are compiled by the root Swift package; do not add a second copy of ClickyCore to the app target.

## Offline Quick Ask acceptance

The first launch selects **Local preview (no AI)**. This deliberately echoes the prompt to validate the UI without account access or billable inference.

| Scenario | Expected result |
|---|---|
| Trigger Option+Shift+Space in a browser | Popup appears beside the pointer; text can be entered immediately |
| Move the pointer while editing | Popup remains stationary |
| Type `first`, Shift+Enter, then `second` | Multiline prompt; Shift+Enter does not submit |
| Press Enter or Send | Exactly one preview; popup closes and prior app regains keyboard focus |
| Press Escape or Cancel | Popup closes; no request is sent; in-memory draft remains available |
| Enter only whitespace | Send disabled; Enter reports a validation error without submitting |
| Paste code, paths, emoji, Slovak text, or a long prompt | Indentation, Unicode, and line breaks preserved; editor scrolls; prompts above 64 KiB report an error without silent truncation |
| Use an IME and press Enter during composition | Commit composition; do not prematurely send the prompt |
| Click another application or use Cmd+Tab | Popup closes without reactivating the originating application |
| Close the originating app while Quick Ask is open | No attempt to reactivate a terminated app |
| Open near each screen edge, in fullscreen, or on a second display | Popup stays within the visible display bounds; verify mixed Retina scales and negative screen coordinates |
| Rebind shortcut in Settings | New binding works, old binding stops; conflicts produce a visible warning and menu fallback |
| Read or Copy last reply from menu | Full reply available even if the compact bubble clipped or disappeared |

Focus behavior with open/save sheets and fullscreen Spaces is specifically unvalidated. Check that Choose Folder/Executable dialogs do not prematurely dismiss the parent panel. If focus is lost, report originating app, active Space, action, and expected focus destination; no screenshots containing private content are needed.

## Real agent validation

Install/sign in using official tools before testing. Clicky never reads credential files or stores tokens. The cloud environment's agent binary and authentication are not your Mac's installation.

1. Confirm `claude --version` / `codex --version` and a normal signed-in conversation in your terminal. No API key or Cloudflare deployment is needed.
2. In Clicky Settings choose the backend, its executable, and a specific project folder. GUI application PATH can differ from terminal PATH; manual executable selection is supported.
3. Ask a harmless text question, such as “Reply with a short greeting.” Confirm incremental response text and a **Managed session** ID.
4. Ask “Remember the word sapphire,” then “What word did I ask you to remember?” Confirm continuity. Restart Clicky and repeat; saved session IDs are advisory until the backend reconnects.
5. Switch backend or project folder. Check that the session identity changes. New Conversation should reset only the selected provider/project binding.
6. Request a longer explanation, Stop Reply, and send another question. Confirm no late text leaks into the new reply, no duplicate requests, and the stopped prompt is available to retry.
7. Test missing executable, invalid folder, signed-out provider, expired session, network loss, and provider exit. Confirm actionable error and editable recovery draft. Retry is manual because an interrupted request may already have reached the provider.

Current limits: managed text/image turns only, no live terminal attachment, no microphone input, no visual MCP/guidance tools, and a five-minute turn timeout. Claude is launched with `--tools ""` and normal account authentication. Codex uses a read-only sandbox with untrusted approval policy; execution/edit approval requests are explicitly declined and surfaced as status. This is not the specification's complete approval UI. Use the official CLI for agent actions.

The Claude stream flags and tools flag require compatibility testing against your installed release. Codex wire methods were checked against generated schemas from cloud `codex-cli 0.159.0-alpha.3`; compatibility with your Mac version must still be established. Do not resolve protocol differences by adding permission bypass flags.

For transport-only diagnosis, the root package also builds `clicky-text`. It uses the same runner as the app and reads UTF-8 from stdin (or `--prompt-file`) so prompts do not enter process arguments. Example from the checkout:

```bash
swift run clicky-text --provider preview <<'PROMPT'
Explain this function.
PROMPT
```

Select `--provider claude --executable /absolute/path/to/claude` or `--provider codex --executable /absolute/path/to/codex`, with `--directory /absolute/project/path`, for a real inference test. `--image-file /absolute/path/to/image.png` optionally attaches a PNG (3 MiB maximum, dimensions up to 4096 pixels). The CLI checks the PNG container/header bounds; actual image decoding is the provider's responsibility. `--session-file /tmp/clicky-session.json` stores provider/session/project metadata only, never image data; use a separate file for each provider/project. Real inference consumes your account limits. This diagnostic does not test GUI focus or permissions.

## Single-window screenshot acceptance

Use a harmless test page with a distinctive shape/text and no sensitive content. Screen Recording is optional: ordinary text Ask must still work with it denied.

1. Activate the target window, then invoke Quick Ask. Click **Attach window screenshot**. Only this action may request Screen Recording access. Deny it first and confirm an actionable error, no request to the provider, and ordinary text submission still works. Grant it in System Settings for the signed Clicky app; restart if macOS requires it.
2. Attach again. Confirm the thumbnail, app name, capture time, dimensions, and Remove action. The attachment is a snapshot, not a live feed. It should show only the original application window, excluding Clicky overlays and other applications overlapping it. No display-capture fallback is allowed.
3. With preview selected, submit “What is in this image?” Confirm an explicit preview message with image dimensions and no claim of image analysis. With each real provider, attach again and confirm it can describe the harmless content.
4. Remove the snapshot and submit another turn. Confirm no old screenshot is reattached. The provider can remember earlier images in its own conversation history; that does not mean Clicky sent the attachment again. Use New Conversation when checking isolated image behavior.
5. Cancel capture, close the popup, switch app, provider, or folder during capture, then reopen. No late snapshot may appear. The question draft should remain. Submission is disabled while capture is pending.
6. Close/minimize the original target window before attaching, or move/resize it during capture. Capture should fail without selecting a different window or monitor. Reopen Quick Ask in the desired window to resolve a fresh target.
7. Stop a real image turn, or cause a provider failure. Confirm text recovery and no automatic image retry. Explicitly attach a new snapshot before retrying with an image.
8. Check fullscreen apps, negative display coordinates, mixed display scales, and windows crossing displays. Inspect text readability at the 1600-pixel capture limit and the scrollable popup on small screens. Native window enumeration, permission timing, geometry, and overlay exclusion remain unverified in Linux.

Clicky creates no screenshot files and does not persist attachments in settings or session metadata. Sending an attachment explicitly shares it with the selected provider, whose own storage/session behavior applies. The 3 MiB bound can reject visually complex captures; it must not silently omit the image.

## Local reply speech acceptance

1. Confirm **Speak replies → Voice requests only** is the default. Typed preview and real typed replies must stay silent. Voice input is not implemented yet.
2. Select **Always** and submit a real typed request. Speech should begin once, after a successful complete reply, using an installed system voice. Preview never automatically speaks, even with Always selected.
3. Use **Speak last reply** in the menu for an explicit playback test, including an offline preview response. **Stop speaking** must stop promptly. Check long replies and non-English text with the available system voices.
4. Start a new request while speech is playing, stop a reply, switch backend/project, start New Conversation, select Never/Voice requests only, or quit. Prior speech must stop. No stale completion callback may mark a newer utterance stopped.
5. Restart the app and confirm the preference persists. Test offline playback using installed voices; no ElevenLabs key, speech-service request, or microphone permission is required.

## Xcode UI tests

Use **Cmd+U** or the Test navigator to run `QuickAskUITests` (four tests), along with the existing tests. The UI fixture launches with `--clicky-ui-test`, uses a dedicated `ClickyUITests` preferences domain, defaults to preview, disables the global shortcut/companion and capture target, and keeps the popup open after submit so response content can be inspected. Production submit/focus/capture behavior must be tested manually; the fixture does not validate it.

## Supporting features and remaining work

| Component | Prepared | Still required |
|---|---|---|
| Local voice | Provider contract; tested tap/hold gesture and mode separation | FluidAudio/WhisperKit integration, mic capture, model/download UX, cleanup benchmarks |
| Dictation | Destination/selection identity and tested stale/secure-field rejection | AX resolver, insertion, clipboard conflict restoration, preview/Undo |
| Visual context | Explicit originating-window screenshot, preview/removal, lease cancellation, in-memory provider image payloads | Mac permissions/overlay/geometry checks; MCP capture authority and AX grounding |
| Guidance | Tested target/action/outcome verification and cancellation generations | AX/screenshot evidence producers, observers, renderer, manual UI |
| MCP | Proposed socket/tool contract documented | Swift MCP server, peer authorization, socket lifetime, payload schema integration |
| TTS | Tested preference policy; system speech, preference picker, Speak/Stop controls | Mac voice/playback/cancellation checks and voice-input integration |

Legacy voice/provider files and `worker/` are retained for reference but are not called by the text-first startup. PostHog is removed from app dependencies, and legacy telemetry methods are no-ops. Retire remaining legacy code only as each replacement is integrated and tested.

Record Mac model, macOS/Xcode/agent versions, test name, pass/fail, and reproduction steps. All performance and ASR quality targets in the specification remain unmeasured.
