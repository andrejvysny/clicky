# Specification analysis and implementation roadmap

The uploaded `Clicky_Final_Specification.md` defines the intended product. It is a design baseline, not evidence of implemented features or authorization to publish to external systems. This delivery follows the user's separate request to prioritize typed input, implement what can be validated in the cloud, and prepare Mac testing. No Plane project or work items were created.

## Architecture decisions

Keep the original native SwiftUI/AppKit companion. Introduce a portable core compiled from the same source by the app and the root Swift package, so validation, protocol handling, process cancellation, geometry, and supporting state transitions can run on Linux without duplicating the implementation. AppKit owns the temporary editor, key window, shortcut, and focus restoration.

Use the installed official agent processes and their account authentication. Prompts travel over stdin rather than shell commands or process arguments. Managed sessions store only provider/project/session metadata. They do not attach to an existing terminal. The initial text client disables Claude tools and declines Codex action approvals; a complete authorized MCP/approval experience remains future integration work.

Keep Ask and Dictate separate. Supporting state machines do not start microphone capture, insert text, or monitor guidance events. Quick Ask can capture its originating window only after an explicit Attach button press, preview the snapshot, and transmit it with a submitted turn. System reply speech is optional and typed requests remain silent by default. These native additions need Mac acceptance; cloud tests cover snapshot ownership and provider payloads.

Reference reuse is documented with pinned revisions and licenses in `REFERENCE_REUSE.md`: OpenWhispr informs editor behavior, OpenClicky informs managed streaming, Annotate informs coordinate/overlay/IPC design, and FluidAudio is a local-ASR integration candidate. No Electron migration or ASR model download is required for this text slice.

## Requirement coverage

| Specification area | Current delivery | Acceptance still needed |
|---|---|---|
| §§3B, 4.2 Quick Ask | Plain multiline editor, paste, IME-aware Enter/Shift+Enter/Escape, validation, pointer placement, temporary key panel | Native editing, focus restoration, dialogs, Spaces, mixed displays |
| §§4.1, 13 companion/migration | Original blue companion, streamed compact reply, full reply/Copy menu; new startup excludes cloud/voice/onboarding/telemetry | Visual comparison, signed app launch; legacy source retirement after replacements |
| §§6, 11 managed agents | Claude/Codex text/image transports, streaming, session metadata/resume, serialized turns, cancellation/recovery, timeout | Real authenticated text/image compatibility and restart/session tests |
| §§3D, 9.5 recording gesture | Tested independent tap/hold/cancel transitions | Shortcut/audio capture integration and native timing |
| §9 local ASR and cleanup | Provider contract and pinned integration guidance | Model selection/download UX, microphone, cleanup, English technical-speech benchmark |
| §9.4 dictation insertion | Tested destination identity/selection eligibility, stale and secure destination rejection | AX identity producer, safe insertion, clipboard conflict handling, preview/Undo |
| §§7, 10 MCP/context | Explicit originating-window snapshot and preview, cancellation leases, in-memory image payloads; socket/tool design | Native capture/permission tests; MCP executable/server, AX grounding, agent registration |
| §8 guidance | Tested expected-action/outcome transitions, stale generations, explicit manual override | Native event producers, evidence verifier, annotations, continuation and manual UI |
| §4.4 spoken replies | Tested preference policy, native system speech, settings and Stop Speaking | Native playback/voice/cancellation tests |
| §§14, 17 quality | 29 portable tests, offline text/image transport diagnostic, Mac app-source typecheck, real CLI provider turns | Native build/UI suite, provider sessions, app matrix, performance/ASR measurements |

Cloud passing tests establish portable behavior only. See `CLOUD_VALIDATION.md` for executed checks and their limits.

## Next implementation stages and exit gates

1. **Validate the text slice on the Mac.** Follow `MAC_VALIDATION.md`; resolve native compile issues, then verify preview focus/keyboard behavior and both signed-in providers. Record Mac/Xcode/CLI versions. Exit when the four new UI tests and the manual Quick Ask/provider matrix pass.
2. **Validate scoped visual context and add MCP.** Test the originating-window snapshot implementation, own-overlay exclusion, permission denial, and cancellation. Add a private versioned socket, the MCP tool executable, fresh geometry, and explicit provider configuration. Exit when each provider can locate and annotate a consenting real application window without desktop actions.
3. **Connect verified guidance.** Render persistent non-key overlays and step cards; feed only active expected events into the existing verifier, then independently verify outcomes. Add Next/Previous/Retry/Cancel and bounded wait/resume behavior. Exit when Blender and browser actions advance only after matching evidence, with a usable manual fallback.
4. **Integrate local voice and independent dictation.** Evaluate FluidAudio on the target Mac before choosing the model; connect recording gestures, cleanup policies, destination validation, insertion/Copy/Undo, and voice-initiated reply speech. Exit when technical English benchmarks and browser/terminal/native-field scenarios pass, including no agent installed and changed/secure destinations.
5. **Harden and expand.** Measure latency/memory, verify packaged-app permissions and repeated lifecycle/cancellation, then add extended displays, Slovak, app profiles, and a separately proven live-terminal adapter. Never advertise managed resume as live attachment.

The specification proposes a voice-first vertical slice. The ordering above reflects the user's explicit text-first request and the available Linux environment. Voice, dictation, MCP, and guidance remain incomplete product features until their native integration gates pass.
