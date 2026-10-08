# Cloud validation evidence

Validated 8 October 2026 on Linux x86_64 (Debian 13), using the official Swift 6.2.3 Debian 12 toolchain. The release archive signature matched Swift 6.x signing fingerprint `52BB7E3DE28A71BE22EC05FFEF80A866B47A981F`; its signing key is now expired, and GPG verifies the historical release signature. No signature/checksum/TLS checks were disabled.

## Executed

- Root Swift package and `clicky-text` built successfully.
- `bash scripts/cloud-setup.sh` exercised the retained-toolchain path and invoked the suite successfully. The download/verification/extraction commands were executed during initial installation; a fresh machine restoration has not been tested.
- 27 XCTest tests passed with zero failures: 5 process integration, 6 image/attachment ownership, 5 typed input/geometry/TTS policy, 6 wire protocol, 5 supporting state/destination tests. The separate Swift Testing runner reported zero tests because this package's tests use XCTest; it is not the validation result.
- Real pipe fixtures cover both providers, split UTF-8/JSON, concurrent large stderr output, cancellation and a subsequent turn, failure exits, missing completion, missing authentication, and image payloads followed by a turn with no attachment. Fixtures do not contact providers.
- `clicky-text --provider preview` preserved multiline text, indentation, and Slovak characters in an offline functional request.
- The CLI was also exercised with a harmless PNG in preview and both offline provider fixtures, followed by unattached turns. Saved session files contained only provider/ID/project metadata.
- Modified/native Swift sources passed syntax parsing, shell scripts passed `bash -n`, the Xcode project parsed as a property list, and shared scheme XML/target IDs were checked.
- A Mac source snapshot was packaged with current working changes, then inspected for required app/core/project/test files and exclusion of Git metadata, caches, and Worker runtime configuration. A SHA-256 sidecar supports transfer integrity checks.

The execution sandbox initially prevented Foundation's CFSocket wakeup socket pair, causing cancellation tests to hang. With local IPC allowed, the same tests completed. No tests were skipped or weakened to obtain the passing result.

## Not executed

The macOS app has not been typechecked, built, or launched here. The four new Quick Ask UI tests, production focus restoration, global shortcut registration, scoped ScreenCaptureKit screenshots, system speech, real authenticated text/image inference/session restoration, and native permission/Space behavior remain unrun. See `MAC_VALIDATION.md`.

Codex protocol methods, including the image `url` input shape, were checked against generated schema from installed `codex-cli 0.159.0-alpha.3`. This is not an authenticated inference result. Claude images use a base64 `image/png` content block; real installed CLI compatibility is unproven. Local ASR, dictation insertion, AX tools, visual MCP, and guidance observers/rendering remain supporting work only.
