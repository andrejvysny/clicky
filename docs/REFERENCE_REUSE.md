# Reference reuse and licenses

The implementation keeps Clicky's original cursor and app shell. The new native composer and portable core are implemented in this repository using the inspected reference patterns below; no Electron runtime or third-party model is bundled.

| Reference | Inspected revision | Use | License |
|---|---|---|---|
| OpenClicky | `9ec439e43362560da28e0507a8e69606a417232f` | Native CLI discovery, stdin/stream-json, stderr draining and managed-session concepts; no bypass flags reused | MIT, Copyright 2026 Proyecto 26 |
| OpenWhispr | `6c41bf6c446f564f6a5072b323f32ae41710b0e7` | Composer keyboard/IME behavior, busy state and draft recovery; future layout-aware paste reference | MIT, Copyright 2024 OpenWhispr Team |
| Annotate | `61c7fa8ae3b517ce402a5b4990bb14e65ccd3dd0` | Future geometry, click-through panels, stdio/socket and peer-authorization boundaries | MIT, Copyright 2026 Annotate contributors |
| FluidAudio | `0c0f113e8db4b862b19a99ce9fd7c9da73324f5f` | Future ASR integration candidate; not linked into this build | Apache-2.0; model licenses are separate |

MIT notice for the referenced OpenClicky/OpenWhispr/Annotate implementation material:

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
