# Third-party notices

Token Taken bundles the pinned `tokscale` CLI binary and a versioned price snapshot derived from `tokscale`'s pricing output, and ports collector rules from MIT-licensed reference projects as documented in [ADR-0003](docs/decisions/0003-usage-engine.md) and [ADR-0005](docs/decisions/0005-collection-granularity.md).

## Bundled binaries and data

### tokscale

- **Name:** tokscale (`@tokscale/cli-darwin-arm64` and `@tokscale/cli-darwin-x64`)
- **Version:** `4.21.0` (pinned with SHA-256 checksums in `engine/engine.lock.json`)
- **Upstream URL:** <https://github.com/junhoyeo/tokscale>
- **Bundled component:** Universal macOS executable assembled from the unmodified `bin/tokscale` binaries in `@tokscale/cli-darwin-arm64` `4.21.0` and `@tokscale/cli-darwin-x64` `4.21.0`, packaged at `Contents/Helpers/tokscale`
- **Local modifications:** None to the binary
- **License:** MIT

```text
MIT License

Copyright (c) 2025 Junho Yeo

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Bundled price snapshot (`tokscale-4.21.0-2026-11-10`)

- **Files:** `engine/price-snapshot-2026-11-10.json` and the generated Swift table `TokenTakenKit/PriceSnapshot.swift` (`PriceTable.bundled`)
- **Version:** `tokscale-4.21.0-2026-11-10`
- **Upstream source:** Model token rates reported by [tokscale](https://github.com/junhoyeo/tokscale) `4.21.0` on 2026-11-10 (MIT), which resolves per-model pricing from [LiteLLM](https://github.com/BerriAI/litellm), [models.dev](https://models.dev), [OpenRouter](https://openrouter.ai), and Cursor pricing tables

## Reference projects and ported rules

| Project | Role in Token Taken | Repository license |
| --- | --- | --- |
| [tokscale](https://github.com/junhoyeo/tokscale) | Bundled `4.21.0` collection engine, pricing snapshot source, and JSON CLI reference | MIT |
| [TokenTracker](https://github.com/xiufengsun/TokenTracker) | Reference for Zcode, `pi`, and `oh-my-pi` deduplication and category-splitting rules reimplemented in Swift ([ADR-0003](docs/decisions/0003-usage-engine.md)) | MIT, except separately licensed assets noted below |
| [Token Monitor](https://github.com/Javis603/token-monitor) | Reference for desktop integration, history, and atomic file-write patterns | MIT |
| [Javis603/tokscale](https://github.com/Javis603/tokscale) | Tokscale fork studied during the ADR-0003 engine evaluation (not bundled) | MIT |

TokenTracker includes React Bits assets under a separate license. Those assets are outside the repository's general MIT license and must not be copied into Token Taken.

## Policy for vendored code and binaries

Before adding an engine or any other third-party component:

1. Check the license at the exact pinned version or commit. Do not assume that the current repository license covers every file, asset, or transitive dependency.
2. Record the project name, repository URL, pinned version or commit, copied components, license, and local modifications in this file.
3. Preserve copyright notices and include the full license text where the license requires it.
4. Review assets and transitive dependencies separately and add their notices.
5. Keep the same notices with distributed app and CLI binaries when required.

React Bits assets from TokenTracker must not be copied. Other separately licensed material requires an explicit license review before use.
