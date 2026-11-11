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

## Rust crates compiled into tokscale 4.21.0

> **Copyleft:** this tree includes `MPL-2.0` code: `option-ext` 0.2.0 (reached through `dirs` > `dirs-sys`), `colored` 2.2.0, `resvg` 0.43.0 and `usvg` 0.43.0. MPL-2.0 is file-level copyleft: the MPL-2.0 source files stay MPL-2.0, and the licence text is reproduced below. Token Taken does not modify any of them. Their exact Source Code Form at the pinned versions:
>
> - `option-ext` 0.2.0: https://crates.io/crates/option-ext/0.2.0 (download: https://static.crates.io/crates/option-ext/option-ext-0.2.0.crate), upstream https://github.com/soc/option-ext
> - `colored` 2.2.0: https://crates.io/crates/colored/2.2.0 (download: https://static.crates.io/crates/colored/colored-2.2.0.crate), upstream https://github.com/mackwic/colored
> - `resvg` 0.43.0: https://crates.io/crates/resvg/0.43.0 (download: https://static.crates.io/crates/resvg/resvg-0.43.0.crate), upstream https://github.com/RazrFalcon/resvg
> - `usvg` 0.43.0: https://crates.io/crates/usvg/0.43.0 (download: https://static.crates.io/crates/usvg/usvg-0.43.0.crate), upstream https://github.com/RazrFalcon/resvg
>
> On request, the maintainers of Token Taken will also provide a copy of each. No GPL, LGPL, EPL or CDDL crate is in the tree.

The dependency set below is the macOS (`aarch64-apple-darwin` / `x86_64-apple-darwin`) build of the `tokscale` binary defined by `crates/tokscale-cli` in the `v4.21.0` tag (commit `b26c433d`), which is the release the bundled binaries in `engine/engine.lock.json` come from. `Cargo.lock` at `v4.21.0` is byte-identical to the lockfile at current upstream `HEAD` (`82613d2f`), so either revision identifies the same graph. Crates reachable only through `[dev-dependencies]`, or only for Windows, WebAssembly, Android, Linux, Redox or EFI targets, are excluded. Build-time dependencies (proc macros and build scripts) that Cargo.lock does not distinguish from ordinary ones are included rather than dropped, so this table over-includes rather than under-includes.

Crates are grouped by identical or equivalent licence expressions; a crate appearing under a disjunction is redistributed under whichever branch Token Taken relies on, and every branch's text is reproduced below. Feature-gated optional dependencies cannot be resolved without the enabled feature set, so a crate present in `Cargo.lock` but only reachable through an optional dependency that tokscale does not enable can appear here unnecessarily.

Licence expressions were read from the `Cargo.toml` inside the crate archive published to crates.io for every one of the 348 crates, at the exact locked version (`https://static.crates.io/crates/<name>/<name>-<version>.crate`). All 348 are verified, and the licence texts below cover every expression in the table. Copyright lines come from each crate's own licence files in the same archives. The two tokscale workspace crates are covered by the MIT notice above.

### Crates grouped by licence

| Crate | Version | Licence |
| --- | --- | --- |
| `adler2` | 2.0.1 | 0BSD OR MIT OR Apache-2.0 |
| `ab_glyph` | 0.2.32 | Apache-2.0 |
| `ab_glyph_rasterizer` | 0.1.10 | Apache-2.0 |
| `approx` | 0.5.1 | Apache-2.0 |
| `leveldb-core` | 0.1.2 | Apache-2.0 |
| `owned_ttf_parser` | 0.25.1 | Apache-2.0 |
| `rpassword` | 7.4.0 | Apache-2.0 |
| `rtoolbox` | 0.0.3 | Apache-2.0 |
| `simba` | 0.8.1 | Apache-2.0 |
| `sync_wrapper` | 1.0.2 | Apache-2.0 |
| `ring` | 0.17.14 | Apache-2.0 AND ISC |
| `ryu` | 1.0.22 | Apache-2.0 OR BSL-1.0 |
| `hyper-rustls` | 0.27.9 | Apache-2.0 OR ISC OR MIT |
| `rustls` | 0.23.43 | Apache-2.0 OR ISC OR MIT |
| `rustls-native-certs` | 0.8.4 | Apache-2.0 OR ISC OR MIT |
| `atomic-waker` | 1.1.2 | Apache-2.0 OR MIT |
| `autocfg` | 1.5.0 | Apache-2.0 OR MIT |
| `encode_unicode` | 1.0.0 | Apache-2.0 OR MIT |
| `equivalent` | 1.0.2 | Apache-2.0 OR MIT |
| `fastrand` | 2.3.0 | Apache-2.0 OR MIT |
| `idna_adapter` | 1.2.1 | Apache-2.0 OR MIT |
| `indexmap` | 2.13.0 | Apache-2.0 OR MIT |
| `kurbo` | 0.11.3 | Apache-2.0 OR MIT |
| `pin-project-lite` | 0.2.16 | Apache-2.0 OR MIT |
| `portable-atomic` | 1.13.1 | Apache-2.0 OR MIT |
| `rustc-hash` | 2.1.3 | Apache-2.0 OR MIT |
| `simd-json` | 0.14.3 | Apache-2.0 OR MIT |
| `simplecss` | 0.2.2 | Apache-2.0 OR MIT |
| `svgtypes` | 0.15.3 | Apache-2.0 OR MIT |
| `utf8_iter` | 1.0.4 | Apache-2.0 OR MIT |
| `utf8parse` | 0.2.2 | Apache-2.0 OR MIT |
| `uuid` | 1.20.0 | Apache-2.0 OR MIT |
| `zeroize` | 1.8.2 | Apache-2.0 OR MIT |
| `rustix` | 0.38.44 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| `rustix` | 1.1.3 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| `crc32c` | 0.6.8 | Apache-2.0/MIT |
| `halfbrown` | 0.2.5 | Apache-2.0/MIT |
| `signal-hook` | 0.3.18 | Apache-2.0/MIT |
| `value-trait` | 0.10.1 | Apache-2.0/MIT |
| `aes` | 0.8.4 | MIT OR Apache-2.0 |
| `ahash` | 0.8.12 | MIT OR Apache-2.0 |
| `allocator-api2` | 0.2.21 | MIT OR Apache-2.0 |
| `anstream` | 0.6.21 | MIT OR Apache-2.0 |
| `anstyle` | 1.0.13 | MIT OR Apache-2.0 |
| `anstyle-parse` | 0.2.7 | MIT OR Apache-2.0 |
| `anyhow` | 1.0.100 | MIT OR Apache-2.0 |
| `arboard` | 3.6.1 | MIT OR Apache-2.0 |
| `arrayvec` | 0.7.6 | MIT OR Apache-2.0 |
| `base64` | 0.22.1 | MIT OR Apache-2.0 |
| `bitflags` | 2.10.0 | MIT OR Apache-2.0 |
| `block-buffer` | 0.10.4 | MIT OR Apache-2.0 |
| `block-padding` | 0.3.3 | MIT OR Apache-2.0 |
| `cbc` | 0.1.2 | MIT OR Apache-2.0 |
| `cc` | 1.2.55 | MIT OR Apache-2.0 |
| `cfg-if` | 1.0.4 | MIT OR Apache-2.0 |
| `chacha20` | 0.10.1 | MIT OR Apache-2.0 |
| `chrono` | 0.4.43 | MIT OR Apache-2.0 |
| `chrono-tz` | 0.10.4 | MIT OR Apache-2.0 |
| `cipher` | 0.4.4 | MIT OR Apache-2.0 |
| `clap` | 4.5.57 | MIT OR Apache-2.0 |
| `clap_builder` | 4.5.57 | MIT OR Apache-2.0 |
| `clap_derive` | 4.5.55 | MIT OR Apache-2.0 |
| `clap_lex` | 0.7.7 | MIT OR Apache-2.0 |
| `colorchoice` | 1.0.4 | MIT OR Apache-2.0 |
| `core-foundation` | 0.9.4 | MIT OR Apache-2.0 |
| `core-foundation` | 0.10.1 | MIT OR Apache-2.0 |
| `core-foundation-sys` | 0.8.7 | MIT OR Apache-2.0 |
| `cpufeatures` | 0.2.17 | MIT OR Apache-2.0 |
| `cpufeatures` | 0.3.0 | MIT OR Apache-2.0 |
| `crc32fast` | 1.5.0 | MIT OR Apache-2.0 |
| `crossbeam-deque` | 0.8.6 | MIT OR Apache-2.0 |
| `crossbeam-epoch` | 0.9.18 | MIT OR Apache-2.0 |
| `crossbeam-utils` | 0.8.21 | MIT OR Apache-2.0 |
| `crypto-common` | 0.1.7 | MIT OR Apache-2.0 |
| `data-url` | 0.3.2 | MIT OR Apache-2.0 |
| `deranged` | 0.5.5 | MIT OR Apache-2.0 |
| `digest` | 0.10.7 | MIT OR Apache-2.0 |
| `dirs` | 5.0.1 | MIT OR Apache-2.0 |
| `dirs-sys` | 0.4.1 | MIT OR Apache-2.0 |
| `displaydoc` | 0.2.5 | MIT OR Apache-2.0 |
| `document-features` | 0.2.12 | MIT OR Apache-2.0 |
| `either` | 1.15.0 | MIT OR Apache-2.0 |
| `errno` | 0.3.14 | MIT OR Apache-2.0 |
| `euclid` | 0.22.13 | MIT OR Apache-2.0 |
| `fdeflate` | 0.3.7 | MIT OR Apache-2.0 |
| `flate2` | 1.1.9 | MIT OR Apache-2.0 |
| `form_urlencoded` | 1.2.2 | MIT OR Apache-2.0 |
| `futures-channel` | 0.3.31 | MIT OR Apache-2.0 |
| `futures-core` | 0.3.31 | MIT OR Apache-2.0 |
| `futures-task` | 0.3.31 | MIT OR Apache-2.0 |
| `futures-util` | 0.3.31 | MIT OR Apache-2.0 |
| `getrandom` | 0.2.17 | MIT OR Apache-2.0 |
| `getrandom` | 0.3.4 | MIT OR Apache-2.0 |
| `getrandom` | 0.4.3 | MIT OR Apache-2.0 |
| `hashbrown` | 0.14.5 | MIT OR Apache-2.0 |
| `hashbrown` | 0.15.5 | MIT OR Apache-2.0 |
| `hashbrown` | 0.16.1 | MIT OR Apache-2.0 |
| `hashlink` | 0.9.1 | MIT OR Apache-2.0 |
| `heck` | 0.5.0 | MIT OR Apache-2.0 |
| `http` | 1.4.0 | MIT OR Apache-2.0 |
| `httparse` | 1.10.1 | MIT OR Apache-2.0 |
| `iana-time-zone` | 0.1.65 | MIT OR Apache-2.0 |
| `idna` | 1.1.0 | MIT OR Apache-2.0 |
| `image` | 0.25.9 | MIT OR Apache-2.0 |
| `image-webp` | 0.2.4 | MIT OR Apache-2.0 |
| `indoc` | 2.0.7 | MIT OR Apache-2.0 |
| `inout` | 0.1.4 | MIT OR Apache-2.0 |
| `ipnet` | 2.11.0 | MIT OR Apache-2.0 |
| `iri-string` | 0.7.10 | MIT OR Apache-2.0 |
| `itertools` | 0.12.1 | MIT OR Apache-2.0 |
| `itertools` | 0.13.0 | MIT OR Apache-2.0 |
| `itoa` | 1.0.17 | MIT OR Apache-2.0 |
| `jobserver` | 0.1.34 | MIT OR Apache-2.0 |
| `lazy_static` | 1.5.0 | MIT OR Apache-2.0 |
| `libc` | 0.2.180 | MIT OR Apache-2.0 |
| `litrs` | 1.0.0 | MIT OR Apache-2.0 |
| `lock_api` | 0.4.14 | MIT OR Apache-2.0 |
| `log` | 0.4.29 | MIT OR Apache-2.0 |
| `native-tls` | 0.2.14 | MIT OR Apache-2.0 |
| `num` | 0.4.3 | MIT OR Apache-2.0 |
| `num-bigint` | 0.4.6 | MIT OR Apache-2.0 |
| `num-complex` | 0.4.6 | MIT OR Apache-2.0 |
| `num-conv` | 0.2.0 | MIT OR Apache-2.0 |
| `num-integer` | 0.1.46 | MIT OR Apache-2.0 |
| `num-iter` | 0.1.45 | MIT OR Apache-2.0 |
| `num-rational` | 0.4.2 | MIT OR Apache-2.0 |
| `num-traits` | 0.2.19 | MIT OR Apache-2.0 |
| `num_threads` | 0.1.7 | MIT OR Apache-2.0 |
| `once_cell` | 1.21.3 | MIT OR Apache-2.0 |
| `openssl-probe` | 0.2.1 | MIT OR Apache-2.0 |
| `parking_lot` | 0.12.5 | MIT OR Apache-2.0 |
| `parking_lot_core` | 0.9.12 | MIT OR Apache-2.0 |
| `paste` | 1.0.15 | MIT OR Apache-2.0 |
| `percent-encoding` | 2.3.2 | MIT OR Apache-2.0 |
| `pin-utils` | 0.1.0 | MIT OR Apache-2.0 |
| `pkg-config` | 0.3.32 | MIT OR Apache-2.0 |
| `png` | 0.17.16 | MIT OR Apache-2.0 |
| `png` | 0.18.0 | MIT OR Apache-2.0 |
| `powerfmt` | 0.2.0 | MIT OR Apache-2.0 |
| `ppv-lite86` | 0.2.21 | MIT OR Apache-2.0 |
| `proc-macro2` | 1.0.106 | MIT OR Apache-2.0 |
| `qrcode` | 0.14.1 | MIT OR Apache-2.0 |
| `quinn` | 0.11.11 | MIT OR Apache-2.0 |
| `quinn-proto` | 0.11.16 | MIT OR Apache-2.0 |
| `quinn-udp` | 0.5.15 | MIT OR Apache-2.0 |
| `quote` | 1.0.44 | MIT OR Apache-2.0 |
| `rand` | 0.8.5 | MIT OR Apache-2.0 |
| `rand` | 0.10.2 | MIT OR Apache-2.0 |
| `rand_chacha` | 0.3.1 | MIT OR Apache-2.0 |
| `rand_core` | 0.6.4 | MIT OR Apache-2.0 |
| `rand_core` | 0.10.1 | MIT OR Apache-2.0 |
| `rand_distr` | 0.4.3 | MIT OR Apache-2.0 |
| `rand_pcg` | 0.10.2 | MIT OR Apache-2.0 |
| `rayon` | 1.11.0 | MIT OR Apache-2.0 |
| `rayon-core` | 1.13.0 | MIT OR Apache-2.0 |
| `ref-cast` | 1.0.25 | MIT OR Apache-2.0 |
| `ref-cast-impl` | 1.0.25 | MIT OR Apache-2.0 |
| `regex-automata` | 0.4.14 | MIT OR Apache-2.0 |
| `regex-syntax` | 0.8.9 | MIT OR Apache-2.0 |
| `reqwest` | 0.12.28 | MIT OR Apache-2.0 |
| `roxmltree` | 0.20.0 | MIT OR Apache-2.0 |
| `rustc_version` | 0.4.1 | MIT OR Apache-2.0 |
| `rustls-pki-types` | 1.14.0 | MIT OR Apache-2.0 |
| `rustversion` | 1.0.22 | MIT OR Apache-2.0 |
| `scopeguard` | 1.2.0 | MIT OR Apache-2.0 |
| `security-framework` | 2.11.1 | MIT OR Apache-2.0 |
| `security-framework` | 3.6.0 | MIT OR Apache-2.0 |
| `security-framework-sys` | 2.17.0 | MIT OR Apache-2.0 |
| `semver` | 1.0.28 | MIT OR Apache-2.0 |
| `serde` | 1.0.228 | MIT OR Apache-2.0 |
| `serde_core` | 1.0.228 | MIT OR Apache-2.0 |
| `serde_derive` | 1.0.228 | MIT OR Apache-2.0 |
| `serde_json` | 1.0.149 | MIT OR Apache-2.0 |
| `serde_spanned` | 0.6.9 | MIT OR Apache-2.0 |
| `sha2` | 0.10.9 | MIT OR Apache-2.0 |
| `shlex` | 1.3.0 | MIT OR Apache-2.0 |
| `signal-hook-mio` | 0.2.5 | MIT OR Apache-2.0 |
| `signal-hook-registry` | 1.4.8 | MIT OR Apache-2.0 |
| `simdutf8` | 0.1.5 | MIT OR Apache-2.0 |
| `smallvec` | 1.15.1 | MIT OR Apache-2.0 |
| `socket2` | 0.6.2 | MIT OR Apache-2.0 |
| `stable_deref_trait` | 1.2.1 | MIT OR Apache-2.0 |
| `static_assertions` | 1.1.0 | MIT OR Apache-2.0 |
| `syn` | 2.0.114 | MIT OR Apache-2.0 |
| `tempfile` | 3.24.0 | MIT OR Apache-2.0 |
| `thiserror` | 2.0.18 | MIT OR Apache-2.0 |
| `thiserror-impl` | 2.0.18 | MIT OR Apache-2.0 |
| `thread_local` | 1.1.9 | MIT OR Apache-2.0 |
| `time` | 0.3.46 | MIT OR Apache-2.0 |
| `time-core` | 0.1.8 | MIT OR Apache-2.0 |
| `tokio-rustls` | 0.26.4 | MIT OR Apache-2.0 |
| `toml` | 0.8.23 | MIT OR Apache-2.0 |
| `toml_datetime` | 0.6.11 | MIT OR Apache-2.0 |
| `toml_edit` | 0.22.27 | MIT OR Apache-2.0 |
| `toml_write` | 0.1.2 | MIT OR Apache-2.0 |
| `ttf-parser` | 0.25.1 | MIT OR Apache-2.0 |
| `typenum` | 1.19.0 | MIT OR Apache-2.0 |
| `unicode-normalization` | 0.1.25 | MIT OR Apache-2.0 |
| `unicode-segmentation` | 1.12.0 | MIT OR Apache-2.0 |
| `unicode-truncate` | 1.1.0 | MIT OR Apache-2.0 |
| `unicode-width` | 0.1.14 | MIT OR Apache-2.0 |
| `unicode-width` | 0.2.0 | MIT OR Apache-2.0 |
| `url` | 2.5.8 | MIT OR Apache-2.0 |
| `yaml_serde` | 0.10.7 | MIT OR Apache-2.0 |
| `zstd-safe` | 7.2.4 | MIT OR Apache-2.0 |
| `bitflags` | 1.3.2 | MIT/Apache-2.0 |
| `fallible-iterator` | 0.3.0 | MIT/Apache-2.0 |
| `fallible-streaming-iterator` | 0.1.9 | MIT/Apache-2.0 |
| `fs2` | 0.4.3 | MIT/Apache-2.0 |
| `hyper-tls` | 0.6.0 | MIT/Apache-2.0 |
| `ident_case` | 1.0.1 | MIT/Apache-2.0 |
| `matrixmultiply` | 0.3.10 | MIT/Apache-2.0 |
| `openssl-probe` | 0.1.6 | MIT/Apache-2.0 |
| `quick-error` | 2.0.1 | MIT/Apache-2.0 |
| `rawpointer` | 0.2.1 | MIT/Apache-2.0 |
| `serde_urlencoded` | 0.7.1 | MIT/Apache-2.0 |
| `siphasher` | 1.0.2 | MIT/Apache-2.0 |
| `vcpkg` | 0.2.15 | MIT/Apache-2.0 |
| `version_check` | 0.9.5 | MIT/Apache-2.0 |
| `zstd-sys` | 2.0.16+zstd.1.5.7 | MIT/Apache-2.0 |
| `cassowary` | 0.3.0 | MIT / Apache-2.0 |
| `lru-slab` | 0.1.2 | MIT OR Apache-2.0 OR Zlib |
| `tinyvec_macros` | 0.1.1 | MIT OR Apache-2.0 OR Zlib |
| `zune-core` | 0.5.1 | MIT OR Apache-2.0 OR Zlib |
| `zune-jpeg` | 0.5.12 | MIT OR Apache-2.0 OR Zlib |
| `miniz_oxide` | 0.8.9 | MIT OR Zlib OR Apache-2.0 |
| `bytemuck` | 1.25.0 | Zlib OR Apache-2.0 OR MIT |
| `dispatch2` | 0.3.0 | Zlib OR Apache-2.0 OR MIT |
| `objc2-app-kit` | 0.3.2 | Zlib OR Apache-2.0 OR MIT |
| `objc2-core-foundation` | 0.3.2 | Zlib OR Apache-2.0 OR MIT |
| `objc2-core-graphics` | 0.3.2 | Zlib OR Apache-2.0 OR MIT |
| `objc2-io-surface` | 0.3.2 | Zlib OR Apache-2.0 OR MIT |
| `safe_arch` | 0.7.4 | Zlib OR Apache-2.0 OR MIT |
| `tinyvec` | 1.10.0 | Zlib OR Apache-2.0 OR MIT |
| `wide` | 0.7.33 | Zlib OR Apache-2.0 OR MIT |
| `foldhash` | 0.1.5 | Zlib |
| `arrayref` | 0.3.9 | BSD-2-Clause |
| `zerocopy` | 0.8.38 | BSD-2-Clause OR Apache-2.0 OR MIT |
| `zerocopy-derive` | 0.8.38 | BSD-2-Clause OR Apache-2.0 OR MIT |
| `nalgebra` | 0.32.6 | BSD-3-Clause |
| `snap` | 1.1.2 | BSD-3-Clause |
| `subtle` | 2.6.1 | BSD-3-Clause |
| `tiny-skia` | 0.11.4 | BSD-3-Clause |
| `tiny-skia-path` | 0.11.4 | BSD-3-Clause |
| `moxcms` | 0.7.11 | BSD-3-Clause OR Apache-2.0 |
| `pxfm` | 0.1.27 | BSD-3-Clause OR Apache-2.0 |
| `webpki-roots` | 1.0.9 | CDLA-Permissive-2.0 |
| `rustls-webpki` | 0.103.14 | ISC |
| `untrusted` | 0.9.0 | ISC |
| `bincode` | 1.3.3 | MIT |
| `bytes` | 1.11.1 | MIT |
| `castaway` | 0.2.4 | MIT |
| `cfg_aliases` | 0.2.2 | MIT |
| `comfy-table` | 7.2.2 | MIT |
| `compact_str` | 0.8.1 | MIT |
| `console` | 0.15.11 | MIT |
| `crossterm` | 0.28.1 | MIT |
| `crossterm` | 0.29.0 | MIT |
| `darling` | 0.23.0 | MIT |
| `darling_core` | 0.23.0 | MIT |
| `darling_macro` | 0.23.0 | MIT |
| `float-cmp` | 0.9.0 | MIT |
| `float-cmp` | 0.10.0 | MIT |
| `generic-array` | 0.14.7 | MIT |
| `hostname` | 0.4.2 | MIT |
| `http-body` | 1.0.1 | MIT |
| `http-body-util` | 0.1.3 | MIT |
| `hyper` | 1.8.1 | MIT |
| `hyper-util` | 0.1.20 | MIT |
| `imageproc` | 0.25.0 | MIT |
| `imagesize` | 0.13.0 | MIT |
| `indicatif` | 0.17.11 | MIT |
| `instability` | 0.3.11 | MIT |
| `integer-encoding` | 4.1.0 | MIT |
| `libm` | 0.2.16 | MIT |
| `libsqlite3-sys` | 0.30.1 | MIT |
| `libyaml-rs` | 0.3.0 | MIT |
| `lru` | 0.12.5 | MIT |
| `matchers` | 0.2.0 | MIT |
| `mio` | 1.1.1 | MIT |
| `nu-ansi-term` | 0.50.3 | MIT |
| `number_prefix` | 0.4.0 | MIT |
| `objc2` | 0.6.3 | MIT |
| `objc2-encode` | 4.1.0 | MIT |
| `objc2-foundation` | 0.3.2 | MIT |
| `phf` | 0.12.1 | MIT |
| `phf_shared` | 0.12.1 | MIT |
| `pico-args` | 0.5.0 | MIT |
| `ratatui` | 0.29.0 | MIT |
| `rgb` | 0.8.52 | MIT |
| `rusqlite` | 0.32.1 | MIT |
| `sharded-slab` | 0.1.7 | MIT |
| `simd-adler32` | 0.3.8 | MIT |
| `slab` | 0.4.12 | MIT |
| `strict-num` | 0.1.1 | MIT |
| `strsim` | 0.11.1 | MIT |
| `strum` | 0.26.3 | MIT |
| `strum_macros` | 0.26.4 | MIT |
| `synstructure` | 0.13.2 | MIT |
| `tokio` | 1.49.0 | MIT |
| `tokio-macros` | 2.6.0 | MIT |
| `tokio-native-tls` | 0.3.1 | MIT |
| `tower` | 0.5.3 | MIT |
| `tower-http` | 0.6.8 | MIT |
| `tower-layer` | 0.3.3 | MIT |
| `tower-service` | 0.3.3 | MIT |
| `tracing` | 0.1.44 | MIT |
| `tracing-attributes` | 0.1.31 | MIT |
| `tracing-core` | 0.1.36 | MIT |
| `tracing-log` | 0.2.0 | MIT |
| `tracing-subscriber` | 0.3.22 | MIT |
| `try-lock` | 0.2.5 | MIT |
| `valuable` | 0.1.1 | MIT |
| `want` | 0.3.1 | MIT |
| `winnow` | 0.7.14 | MIT |
| `xmlwriter` | 0.1.0 | MIT |
| `zmij` | 1.0.19 | MIT |
| `zstd` | 0.13.3 | MIT |
| `icu_collections` | 2.1.1 | Unicode-3.0 |
| `icu_locale_core` | 2.1.1 | Unicode-3.0 |
| `icu_normalizer` | 2.1.1 | Unicode-3.0 |
| `icu_normalizer_data` | 2.1.1 | Unicode-3.0 |
| `icu_properties` | 2.1.2 | Unicode-3.0 |
| `icu_properties_data` | 2.1.2 | Unicode-3.0 |
| `icu_provider` | 2.1.1 | Unicode-3.0 |
| `litemap` | 0.8.1 | Unicode-3.0 |
| `potential_utf` | 0.1.4 | Unicode-3.0 |
| `tinystr` | 0.8.2 | Unicode-3.0 |
| `writeable` | 0.6.2 | Unicode-3.0 |
| `yoke` | 0.8.1 | Unicode-3.0 |
| `yoke-derive` | 0.8.1 | Unicode-3.0 |
| `zerofrom` | 0.1.6 | Unicode-3.0 |
| `zerofrom-derive` | 0.1.6 | Unicode-3.0 |
| `zerotrie` | 0.2.3 | Unicode-3.0 |
| `zerovec` | 0.11.5 | Unicode-3.0 |
| `zerovec-derive` | 0.11.2 | Unicode-3.0 |
| `unicode-ident` | 1.0.22 | (MIT OR Apache-2.0) AND Unicode-3.0 |
| `aho-corasick` | 1.1.4 | Unlicense OR MIT |
| `byteorder-lite` | 0.1.0 | Unlicense OR MIT |
| `memchr` | 2.7.6 | Unlicense OR MIT |
| `csv` | 1.4.0 | Unlicense/MIT |
| `csv-core` | 0.1.13 | Unlicense/MIT |
| `same-file` | 1.0.6 | Unlicense/MIT |
| `walkdir` | 2.5.0 | Unlicense/MIT |
| `colored` | 2.2.0 | MPL-2.0 |
| `option-ext` | 0.2.0 | MPL-2.0 |
| `resvg` | 0.43.0 | MPL-2.0 |
| `usvg` | 0.43.0 | MPL-2.0 |

### Copyright notices

Retained from each crate's own `LICENSE*`, `COPYING` or `UNLICENSE` file, for crates whose licence requires the notice to travel with the code. Crates declaring Apache-2.0 only, and the MPL-2.0 crates covered by the copyleft note above, are not listed; Apache-2.0 does not require attribution notices in a binary distribution. Where a crate ships no licence file, or ships licence files with no copyright line, the notice is built from the crate's declared authors and upstream repository and the cell says so.

| Crate | Version | Copyright |
| --- | --- | --- |
| `adler2` | 2.0.1 | Copyright (C) Jonas Schievink <jonasschievink@gmail.com> |
| `aes` | 0.8.4 | Copyright (c) 2018 Artyom Pavlov |
| `ahash` | 0.8.12 | Copyright (c) 2018 Tom Kaitchuck |
| `aho-corasick` | 1.1.4 | Copyright (c) 2015 Andrew Gallant |
| `allocator-api2` | 0.2.21 | Copyright (c) Zakarum (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/zakarumych/allocator-api2) |
| `anstream` | 0.6.21 | Copyright (c) Individual contributors |
| `anstyle` | 1.0.13 | Copyright (c) Individual contributors |
| `anstyle-parse` | 0.2.7 | Copyright (c) Individual contributors |
| `anyhow` | 1.0.100 | Copyright (c) David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/dtolnay/anyhow) |
| `arboard` | 3.6.1 | Copyright (c) 2022 The Arboard contributors |
| `arrayref` | 0.3.9 | Copyright (c) 2015 David Roundy <roundyd@physics.oregonstate.edu> |
| `arrayvec` | 0.7.6 | Copyright (c) Ulrik Sverdrup "bluss" 2015-2023 |
| `atomic-waker` | 1.1.2 | Copyright (c) 2016 Alex Crichton<br>Copyright (c) 2017 The Tokio Authors |
| `autocfg` | 1.5.0 | Copyright (c) 2018 Josh Stone |
| `base64` | 0.22.1 | Copyright (c) 2015 Alice Maz |
| `bincode` | 1.3.3 | Copyright (c) 2014 Ty Overby |
| `bitflags` | 1.3.2 | Copyright (c) 2014 The Rust Project Developers |
| `bitflags` | 2.10.0 | Copyright (c) 2014 The Rust Project Developers |
| `block-buffer` | 0.10.4 | Copyright (c) 2018-2019 The RustCrypto Project Developers |
| `block-padding` | 0.3.3 | Copyright (c) 2018-2019 The RustCrypto Project Developers |
| `bytemuck` | 1.25.0 | Copyright (c) 2019 Daniel "Lokathor" Gee. |
| `byteorder-lite` | 0.1.0 | Copyright (c) 2015 Andrew Gallant |
| `bytes` | 1.11.1 | Copyright (c) 2018 Carl Lerche |
| `cassowary` | 0.3.0 | Copyright (c) 2016 Dylan Ede |
| `castaway` | 0.2.4 | Copyright (c) 2021 Stephen M. Coakley |
| `cbc` | 0.1.2 | Copyright (c) 2018-2022 RustCrypto Developers<br>Copyright (c) 2018 Artyom Pavlov |
| `cc` | 1.2.55 | Copyright (c) 2014 Alex Crichton |
| `cfg-if` | 1.0.4 | Copyright (c) 2014 Alex Crichton |
| `cfg_aliases` | 0.2.2 | Copyright (c) 2020 Katharos Technology |
| `chacha20` | 0.10.1 | Copyright (c) 2019-2026 The RustCrypto Project Developers |
| `chrono` | 0.4.43 | Copyright (c) 2014, Kang Seonghoon. |
| `chrono-tz` | 0.10.4 | Copyright (c) 2016-2024 Benjamin Sago & the chronotope maintainers<br>Copyright 2016 Djzin |
| `cipher` | 0.4.4 | Copyright (c) 2016-2020 RustCrypto Developers |
| `clap` | 4.5.57 | Copyright (c) Individual contributors |
| `clap_builder` | 4.5.57 | Copyright (c) Individual contributors |
| `clap_derive` | 4.5.55 | Copyright (c) Individual contributors |
| `clap_lex` | 0.7.7 | Copyright (c) Individual contributors |
| `colorchoice` | 1.0.4 | Copyright (c) Individual contributors |
| `comfy-table` | 7.2.2 | Copyright (c) 2019 Arne Beer |
| `compact_str` | 0.8.1 | Copyright (c) 2021 Parker Timmerman |
| `console` | 0.15.11 | Copyright (c) 2017 Armin Ronacher <armin.ronacher@active-4.com> |
| `core-foundation` | 0.9.4 | Copyright (c) 2012-2013 Mozilla Foundation |
| `core-foundation` | 0.10.1 | Copyright (c) 2012-2013 Mozilla Foundation |
| `core-foundation-sys` | 0.8.7 | Copyright (c) 2012-2013 Mozilla Foundation |
| `cpufeatures` | 0.2.17 | Copyright (c) 2020-2025 The RustCrypto Project Developers |
| `cpufeatures` | 0.3.0 | Copyright (c) 2020-2025 The RustCrypto Project Developers |
| `crc32c` | 0.6.8 | Copyright (c) Zack Owens (crate ships no licence file; notice from the crate's declared authors; MIT text below; upstream https://github.com/zowens/crc32c) |
| `crc32fast` | 1.5.0 | Copyright (c) 2018 Sam Rijs, Alex Crichton and contributors |
| `crossbeam-deque` | 0.8.6 | Copyright (c) 2019 The Crossbeam Project Developers |
| `crossbeam-epoch` | 0.9.18 | Copyright (c) 2019 The Crossbeam Project Developers |
| `crossbeam-utils` | 0.8.21 | Copyright (c) 2019 The Crossbeam Project Developers |
| `crossterm` | 0.28.1 | Copyright (c) 2019 Timon |
| `crossterm` | 0.29.0 | Copyright (c) 2019 Timon |
| `crypto-common` | 0.1.7 | Copyright (c) 2021 RustCrypto Developers |
| `csv` | 1.4.0 | Copyright (c) 2015 Andrew Gallant |
| `csv-core` | 0.1.13 | Copyright (c) 2015 Andrew Gallant |
| `darling` | 0.23.0 | Copyright (c) 2017 Ted Driggs |
| `darling_core` | 0.23.0 | Copyright (c) 2017 Ted Driggs |
| `darling_macro` | 0.23.0 | Copyright (c) 2017 Ted Driggs |
| `data-url` | 0.3.2 | Copyright (c) 2013-2025 The rust-url developers |
| `deranged` | 0.5.5 | Copyright (c) 2024 Jacob Pratt et al. |
| `digest` | 0.10.7 | Copyright (c) 2017 Artyom Pavlov |
| `dirs` | 5.0.1 | Copyright (c) 2018-2019 dirs-rs contributors |
| `dirs-sys` | 0.4.1 | Copyright (c) 2018-2019 dirs-rs contributors |
| `dispatch2` | 0.3.0 | Copyright (c) Mads Marquart, Mary (crate ships no licence file; notice from the crate's declared authors; MIT text below; upstream https://github.com/madsmtm/objc2) |
| `displaydoc` | 0.2.5 | Copyright (c) Jane Lusby (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/yaahc/displaydoc) |
| `document-features` | 0.2.12 | Copyright (c) 2020 Olivier Goffart <ogoffart@sixtyfps.io> |
| `either` | 1.15.0 | Copyright (c) 2015 |
| `encode_unicode` | 1.0.0 | Copyright (c) Torbjørn Birch Moltu (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/tormol/encode_unicode) |
| `equivalent` | 1.0.2 | Copyright (c) 2016--2023 |
| `errno` | 0.3.14 | Copyright (c) 2014 Chris Wong |
| `euclid` | 0.22.13 | Copyright (c) 2012-2013 Mozilla Foundation |
| `fallible-iterator` | 0.3.0 | Copyright (c) 2015 The rust-openssl-verify Developers |
| `fallible-streaming-iterator` | 0.1.9 | Copyright (c) 2016 The fallible-streaming-iterator Developers |
| `fastrand` | 2.3.0 | Copyright (c) Stjepan Glavina (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/smol-rs/fastrand) |
| `fdeflate` | 0.3.7 | Copyright (c) The image-rs Developers (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/image-rs/fdeflate) |
| `flate2` | 1.1.9 | Copyright (c) 2014-2026 Alex Crichton |
| `float-cmp` | 0.9.0 | Copyright (c) 2014-2020 Optimal Computing (NZ) Ltd |
| `float-cmp` | 0.10.0 | Copyright (c) 2014-2020 Optimal Computing (NZ) Ltd |
| `foldhash` | 0.1.5 | Copyright (c) 2024 Orson Peters |
| `form_urlencoded` | 1.2.2 | Copyright (c) 2013-2016 The rust-url developers |
| `fs2` | 0.4.3 | Copyright (c) 2015 The Rust Project Developers |
| `futures-channel` | 0.3.31 | Copyright (c) 2016 Alex Crichton<br>Copyright (c) 2017 The Tokio Authors |
| `futures-core` | 0.3.31 | Copyright (c) 2016 Alex Crichton<br>Copyright (c) 2017 The Tokio Authors |
| `futures-task` | 0.3.31 | Copyright (c) 2016 Alex Crichton<br>Copyright (c) 2017 The Tokio Authors |
| `futures-util` | 0.3.31 | Copyright (c) 2016 Alex Crichton<br>Copyright (c) 2017 The Tokio Authors |
| `generic-array` | 0.14.7 | Copyright (c) 2015 Bartłomiej Kamiński |
| `getrandom` | 0.2.17 | Copyright (c) 2018-2024 The rust-random Project Developers<br>Copyright (c) 2014 The Rust Project Developers |
| `getrandom` | 0.3.4 | Copyright (c) 2018-2025 The rust-random Project Developers<br>Copyright (c) 2014 The Rust Project Developers |
| `getrandom` | 0.4.3 | Copyright (c) 2018-2026 The rust-random Project Developers<br>Copyright (c) 2014 The Rust Project Developers |
| `halfbrown` | 0.2.5 | Copyright (c) Heinz N. Gies (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/Licenser/halfbrown) |
| `hashbrown` | 0.14.5 | Copyright (c) 2016 Amanieu d'Antras |
| `hashbrown` | 0.15.5 | Copyright (c) 2016 Amanieu d'Antras |
| `hashbrown` | 0.16.1 | Copyright (c) 2016 Amanieu d'Antras |
| `hashlink` | 0.9.1 | Copyright (c) kyren (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/kyren/hashlink) |
| `heck` | 0.5.0 | Copyright (c) 2015 The Rust Project Developers |
| `hostname` | 0.4.2 | Copyright (c) 2016 fengcen<br>Copyright (c) 2019 svartalf |
| `http` | 1.4.0 | Copyright (c) 2017 http-rs authors |
| `http-body` | 1.0.1 | Copyright (c) 2019-2024 Sean McArthur & Hyper Contributors |
| `http-body-util` | 0.1.3 | Copyright (c) 2019-2025 Sean McArthur & Hyper Contributors |
| `httparse` | 1.10.1 | Copyright (c) 2015-2025 Sean McArthur |
| `hyper` | 1.8.1 | Copyright (c) 2014-2025 Sean McArthur |
| `hyper-rustls` | 0.27.9 | Copyright (c) 2016, Joseph Birr-Pixton <jpixton@gmail.com><br>Copyright (c) 2016 Joseph Birr-Pixton <jpixton@gmail.com> |
| `hyper-tls` | 0.6.0 | Copyright (c) 2017 Sean McArthur |
| `hyper-util` | 0.1.20 | Copyright (c) 2023-2025 Sean McArthur |
| `iana-time-zone` | 0.1.65 | Copyright 2020 Andrew Straw<br>Copyright (c) 2020 Andrew D. Straw |
| `icu_collections` | 2.1.1 | Copyright © 2020-2024 Unicode, Inc. |
| `icu_locale_core` | 2.1.1 | Copyright © 2020-2024 Unicode, Inc. |
| `icu_normalizer` | 2.1.1 | Copyright © 2020-2024 Unicode, Inc. |
| `icu_normalizer_data` | 2.1.1 | Copyright © 2020-2024 Unicode, Inc. |
| `icu_properties` | 2.1.2 | Copyright © 2020-2024 Unicode, Inc. |
| `icu_properties_data` | 2.1.2 | Copyright © 2020-2024 Unicode, Inc. |
| `icu_provider` | 2.1.1 | Copyright © 2020-2024 Unicode, Inc. |
| `ident_case` | 1.0.1 | Copyright (c) Ted Driggs (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/TedDriggs/ident_case) |
| `idna` | 1.1.0 | Copyright (c) 2013-2025 The rust-url developers |
| `idna_adapter` | 1.2.1 | Copyright (c) The rust-url developers |
| `image` | 0.25.9 | Copyright (c) The image-rs Developers (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/image-rs/image) |
| `image-webp` | 0.2.4 | Copyright (c) the image-webp contributors (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/image-rs/image-webp) |
| `imageproc` | 0.25.0 | Copyright (c) 2015 PistonDevelopers |
| `imagesize` | 0.13.0 | Copyright (c) 2017 Maiddog |
| `indexmap` | 2.13.0 | Copyright (c) 2016--2017 |
| `indicatif` | 0.17.11 | Copyright (c) 2017 Armin Ronacher <armin.ronacher@active-4.com> |
| `indoc` | 2.0.7 | Copyright (c) David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/dtolnay/indoc) |
| `inout` | 0.1.4 | Copyright (c) 2022 The RustCrypto Project Developers<br>Copyright (c) 2022 Artyom Pavlov |
| `instability` | 0.3.11 | Copyright (c) 2020 Stephen M. Coakley<br>Copyright (c) The Ratatui Developers |
| `integer-encoding` | 4.1.0 | Copyright (c) 2016 Google Inc. (lewinb@google.com) -- though not an official Google product or in any way related!<br>Copyright (c) 2018-2020 Lewin Bormann (lbo@spheniscida.de) |
| `ipnet` | 2.11.0 | Copyright 2017 Juniper Networks, Inc. |
| `iri-string` | 0.7.10 | Copyright 2019-2024 YOSHIOKA Takuma |
| `itertools` | 0.12.1 | Copyright (c) 2015 |
| `itertools` | 0.13.0 | Copyright (c) 2015 |
| `itoa` | 1.0.17 | Copyright (c) David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/dtolnay/itoa) |
| `jobserver` | 0.1.34 | Copyright (c) 2014 Alex Crichton |
| `kurbo` | 0.11.3 | Copyright (c) 2018 Raph Levien |
| `lazy_static` | 1.5.0 | Copyright (c) 2010 The Rust Project Developers |
| `libc` | 0.2.180 | Copyright (c) 2014-2020 The Rust Project Developers |
| `libm` | 0.2.16 | Copyright (c) 2018 Jorge Aparicio<br>Copyright © 2005-2020 Rich Felker, et al.<br>Copyright © 1993,2004 Sun Microsystems or<br>Copyright © 2003-2011 David Schultz or<br>Copyright © 2003-2009 Steven G. Kargl or<br>Copyright © 2003-2009 Bruce D. Evans or<br>Copyright © 2008 Stephen L. Moshier or<br>Copyright © 2017-2018 Arm Limited |
| `libsqlite3-sys` | 0.30.1 | Copyright (c) 2014-2021 The rusqlite developers |
| `libyaml-rs` | 0.3.0 | Copyright (c) David Tolnay, YAML Organization (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/yaml/libyaml-rs) |
| `litemap` | 0.8.1 | Copyright © 2020-2024 Unicode, Inc. |
| `litrs` | 1.0.0 | Copyright (c) 2020 Project Developers |
| `lock_api` | 0.4.14 | Copyright (c) 2016 The Rust Project Developers |
| `log` | 0.4.29 | Copyright (c) 2014 The Rust Project Developers |
| `lru` | 0.12.5 | Copyright (c) 2016 Jerome Froelich |
| `lru-slab` | 0.1.2 | Copyright (c) 2024 The lru-slab Developers |
| `matchers` | 0.2.0 | Copyright (c) 2019 Eliza Weisman |
| `matrixmultiply` | 0.3.10 | Copyright (c) 2016 - 2023 Ulrik Sverdrup "bluss"<br>Copyright (c) 2021 DutchGhost [constparse.rs] |
| `memchr` | 2.7.6 | Copyright (c) 2015 Andrew Gallant |
| `miniz_oxide` | 0.8.9 | Copyright 2013-2014 RAD Game Tools and Valve Software<br>Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC<br>Copyright (c) 2017 Frommi<br>Copyright (c) 2017-2024 oyvindln<br>Copyright (c) 2020 Frommi |
| `mio` | 1.1.1 | Copyright (c) 2014 Carl Lerche and other MIO contributors |
| `moxcms` | 0.7.11 | Copyright (c) Radzivon Bartoshyk. All rights reserved. |
| `nalgebra` | 0.32.6 | Copyright 2020 Sébastien Crozet |
| `native-tls` | 0.2.14 | Copyright (c) 2016 The rust-native-tls Developers |
| `nu-ansi-term` | 0.50.3 | Copyright (c) 2014 Benjamin Sago<br>Copyright (c) 2021-2022 The Nushell Project Developers |
| `num` | 0.4.3 | Copyright (c) 2014 The Rust Project Developers |
| `num-bigint` | 0.4.6 | Copyright (c) 2014 The Rust Project Developers |
| `num-complex` | 0.4.6 | Copyright (c) 2014 The Rust Project Developers |
| `num-conv` | 0.2.0 | Copyright (c) 2023 Jacob Pratt |
| `num-integer` | 0.1.46 | Copyright (c) 2014 The Rust Project Developers |
| `num-iter` | 0.1.45 | Copyright (c) 2014 The Rust Project Developers |
| `num-rational` | 0.4.2 | Copyright (c) 2014 The Rust Project Developers |
| `num-traits` | 0.2.19 | Copyright (c) 2014 The Rust Project Developers |
| `num_threads` | 0.1.7 | Copyright (c) 2021 Jacob Pratt |
| `number_prefix` | 0.4.0 | Copyright (c) Benjamin Sago (crate ships no licence file; notice from the crate's declared authors; MIT text below; upstream https://github.com/ogham/rust-number-prefix) |
| `objc2` | 0.6.3 | Copyright (c) Mads Marquart (crate ships no licence file; notice from the crate's declared authors; MIT text below; upstream https://github.com/madsmtm/objc2) |
| `objc2-app-kit` | 0.3.2 | Copyright (c) the objc2-app-kit contributors (crate ships no licence file; notice from the crate's declared authors; MIT text below; upstream https://github.com/madsmtm/objc2) |
| `objc2-core-foundation` | 0.3.2 | Copyright (c) the objc2-core-foundation contributors (crate ships no licence file; notice from the crate's declared authors; MIT text below; upstream https://github.com/madsmtm/objc2) |
| `objc2-core-graphics` | 0.3.2 | Copyright (c) the objc2-core-graphics contributors (crate ships no licence file; notice from the crate's declared authors; MIT text below; upstream https://github.com/madsmtm/objc2) |
| `objc2-encode` | 4.1.0 | Copyright (c) Mads Marquart and the objc2 contributors (crate ships no licence file; notice from the crate's declared author, MIT text below; upstream https://github.com/madsmtm/objc2) |
| `objc2-foundation` | 0.3.2 | Copyright (c) Mads Marquart and the objc2 contributors (crate ships no licence file; notice from the upstream project, MIT text below; upstream https://github.com/madsmtm/objc2) |
| `objc2-io-surface` | 0.3.2 | Copyright (c) the objc2-io-surface contributors (crate ships no licence file; notice from the crate's declared authors; MIT text below; upstream https://github.com/madsmtm/objc2) |
| `once_cell` | 1.21.3 | Copyright (c) Aleksey Kladov (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/matklad/once_cell) |
| `openssl-probe` | 0.1.6 | Copyright (c) 2014 Alex Crichton |
| `openssl-probe` | 0.2.1 | Copyright (c) 2014 Alex Crichton |
| `parking_lot` | 0.12.5 | Copyright (c) 2016 The Rust Project Developers |
| `parking_lot_core` | 0.9.12 | Copyright (c) 2016 The Rust Project Developers |
| `paste` | 1.0.15 | Copyright (c) David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/dtolnay/paste) |
| `percent-encoding` | 2.3.2 | Copyright (c) 2013-2025 The rust-url developers |
| `phf` | 0.12.1 | Copyright (c) 2014-2022 Steven Fackler, Yuki Okushi |
| `phf_shared` | 0.12.1 | Copyright (c) 2014-2022 Steven Fackler, Yuki Okushi |
| `pico-args` | 0.5.0 | Copyright (c) 2019 Yevhenii Reizner |
| `pin-project-lite` | 0.2.16 | Copyright (c) the pin-project-lite contributors (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/taiki-e/pin-project-lite) |
| `pin-utils` | 0.1.0 | Copyright (c) 2018 The pin-utils authors |
| `pkg-config` | 0.3.32 | Copyright (c) 2014 Alex Crichton |
| `png` | 0.17.16 | Copyright (c) 2015 nwin |
| `png` | 0.18.0 | Copyright (c) 2015 nwin |
| `portable-atomic` | 1.13.1 | Copyright (c) the portable-atomic contributors (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/taiki-e/portable-atomic) |
| `potential_utf` | 0.1.4 | Copyright © 2020-2024 Unicode, Inc. |
| `powerfmt` | 0.2.0 | Copyright 2023 Jacob Pratt et al.<br>Copyright (c) 2023 Jacob Pratt et al. |
| `ppv-lite86` | 0.2.21 | Copyright 2019 The CryptoCorrosion Contributors<br>Copyright (c) 2019 The CryptoCorrosion Contributors |
| `proc-macro2` | 1.0.106 | Copyright (c) David Tolnay, Alex Crichton (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/dtolnay/proc-macro2) |
| `pxfm` | 0.1.27 | Copyright (c) Radzivon Bartoshyk. All rights reserved. |
| `qrcode` | 0.14.1 | Copyright (c) 2016 kennytm |
| `quick-error` | 2.0.1 | Copyright (c) 2015 The quick-error Developers |
| `quinn` | 0.11.11 | Copyright (c) 2018 The quinn Developers |
| `quinn-proto` | 0.11.16 | Copyright (c) 2018 The quinn Developers |
| `quinn-udp` | 0.5.15 | Copyright (c) 2018 The quinn Developers |
| `quote` | 1.0.44 | Copyright (c) David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/dtolnay/quote) |
| `rand` | 0.8.5 | Copyright 2018 Developers of the Rand project<br>Copyright (c) 2014 The Rust Project Developers |
| `rand` | 0.10.2 | Copyright 2018 Developers of the Rand project<br>Copyright (c) 2014 The Rust Project Developers |
| `rand_chacha` | 0.3.1 | Copyright 2018 Developers of the Rand project<br>Copyright (c) 2014 The Rust Project Developers |
| `rand_core` | 0.6.4 | Copyright 2018 Developers of the Rand project<br>Copyright (c) 2014 The Rust Project Developers |
| `rand_core` | 0.10.1 | Copyright (c) 2018-2026 The Rand Project Developers |
| `rand_distr` | 0.4.3 | Copyright 2018 Developers of the Rand project |
| `rand_pcg` | 0.10.2 | Copyright (c) 2014-2017 Melissa O'Neill and PCG Project contributors<br>Copyright 2018 Developers of the Rand project |
| `ratatui` | 0.29.0 | Copyright (c) 2016-2022 Florian Dehau<br>Copyright (c) 2023-2024 The Ratatui Developers |
| `rawpointer` | 0.2.1 | Copyright (c) 2015 |
| `rayon` | 1.11.0 | Copyright (c) 2010 The Rust Project Developers |
| `rayon-core` | 1.13.0 | Copyright (c) 2010 The Rust Project Developers |
| `ref-cast` | 1.0.25 | Copyright (c) David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/dtolnay/ref-cast) |
| `ref-cast-impl` | 1.0.25 | Copyright (c) David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/dtolnay/ref-cast) |
| `regex-automata` | 0.4.14 | Copyright (c) 2014 The Rust Project Developers |
| `regex-syntax` | 0.8.9 | Copyright (c) 2014 The Rust Project Developers |
| `reqwest` | 0.12.28 | Copyright (c) 2016-2025 Sean McArthur |
| `rgb` | 0.8.52 | Copyright (c) 2019 Kornel |
| `ring` | 0.17.14 | Copyright (c) 2009 The Go Authors. All rights reserved.<br>Copyright 2015 The Chromium Authors. All rights reserved.<br>Copyright 2015-2025 Brian Smith. |
| `roxmltree` | 0.20.0 | Copyright (c) 2018 Yevhenii Reizner |
| `rusqlite` | 0.32.1 | Copyright (c) 2014-2021 The rusqlite developers |
| `rustc-hash` | 2.1.3 | Copyright (c) The Rust Project Developers (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/rust-lang/rustc-hash) |
| `rustc_version` | 0.4.1 | Copyright (c) 2016 The Rust Project Developers |
| `rustix` | 0.38.44 | Copyright (c) Dan Gohman, Jakub Konka (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/bytecodealliance/rustix) |
| `rustix` | 1.1.3 | Copyright (c) Dan Gohman, Jakub Konka (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/bytecodealliance/rustix) |
| `rustls` | 0.23.43 | Copyright (c) 2016, Joseph Birr-Pixton <jpixton@gmail.com><br>Copyright (c) 2016 Joseph Birr-Pixton <jpixton@gmail.com> |
| `rustls-native-certs` | 0.8.4 | Copyright (c) 2016, Joseph Birr-Pixton <jpixton@gmail.com><br>Copyright (c) 2016 Joseph Birr-Pixton <jpixton@gmail.com> |
| `rustls-pki-types` | 1.14.0 | Copyright (c) 2023 Dirkjan Ochtman <dirkjan@ochtman.nl> |
| `rustls-webpki` | 0.103.14 | Copyright 2015 Brian Smith. |
| `rustversion` | 1.0.22 | Copyright (c) David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/dtolnay/rustversion) |
| `safe_arch` | 0.7.4 | Copyright (c) 2023 Daniel "Lokathor" Gee.<br>Copyright (c) 2020 Daniel "Lokathor" Gee. |
| `same-file` | 1.0.6 | Copyright (c) 2017 Andrew Gallant |
| `scopeguard` | 1.2.0 | Copyright (c) 2016-2019 Ulrik Sverdrup "bluss" and scopeguard developers |
| `security-framework` | 2.11.1 | Copyright (c) 2015 Steven Fackler |
| `security-framework` | 3.6.0 | Copyright (c) 2015 Steven Fackler |
| `security-framework-sys` | 2.17.0 | Copyright (c) 2015 Steven Fackler |
| `semver` | 1.0.28 | Copyright (c) David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/dtolnay/semver) |
| `serde` | 1.0.228 | Copyright (c) Erick Tryzelaar, David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/serde-rs/serde) |
| `serde_core` | 1.0.228 | Copyright (c) Erick Tryzelaar, David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/serde-rs/serde) |
| `serde_derive` | 1.0.228 | Copyright (c) Erick Tryzelaar, David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/serde-rs/serde) |
| `serde_json` | 1.0.149 | Copyright (c) Erick Tryzelaar, David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/serde-rs/json) |
| `serde_spanned` | 0.6.9 | Copyright (c) Individual contributors |
| `serde_urlencoded` | 0.7.1 | Copyright (c) 2016 Anthony Ramine |
| `sha2` | 0.10.9 | Copyright (c) 2006-2009 Graydon Hoare<br>Copyright (c) 2009-2013 Mozilla Foundation<br>Copyright (c) 2016 Artyom Pavlov |
| `sharded-slab` | 0.1.7 | Copyright (c) 2019 Eliza Weisman |
| `shlex` | 1.3.0 | Copyright (c) 2015 Nicholas Allegra (comex). |
| `signal-hook` | 0.3.18 | Copyright (c) 2017 tokio-jsonrpc developers |
| `signal-hook-mio` | 0.2.5 | Copyright (c) 2017 tokio-jsonrpc developers |
| `signal-hook-registry` | 1.4.8 | Copyright (c) 2017 tokio-jsonrpc developers |
| `simd-adler32` | 0.3.8 | Copyright (c) [2021] [Marvin Countryman] |
| `simd-json` | 0.14.3 | Copyright (c) Heinz N. Gies, Sunny Gleason (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/simd-lite/simd-json) |
| `simdutf8` | 0.1.5 | Copyright (c) Hans Kratz (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/rusticstuff/simdutf8) |
| `simplecss` | 0.2.2 | Copyright (c) 2018 Reizner Evgeniy |
| `siphasher` | 1.0.2 | Copyright 2012-2016 The Rust Project Developers.<br>Copyright 2016-2026 Frank Denis. |
| `slab` | 0.4.12 | Copyright (c) 2019 Carl Lerche |
| `smallvec` | 1.15.1 | Copyright (c) 2018 The Servo Project Developers |
| `snap` | 1.1.2 | Copyright 2011, The Snappy-Rust Authors. All rights reserved. |
| `socket2` | 0.6.2 | Copyright (c) 2014 Alex Crichton |
| `stable_deref_trait` | 1.2.1 | Copyright (c) 2017 Robert Grosse |
| `static_assertions` | 1.1.0 | Copyright (c) 2017 Nikolai Vazquez |
| `strict-num` | 0.1.1 | Copyright (c) 2022 Yevhenii Reizner |
| `strsim` | 0.11.1 | Copyright (c) 2015 Danny Guo<br>Copyright (c) 2016 Titus Wormer <tituswormer@gmail.com><br>Copyright (c) 2018 Akash Kurdekar |
| `strum` | 0.26.3 | Copyright (c) 2019 Peter Glotfelty |
| `strum_macros` | 0.26.4 | Copyright (c) 2019 Peter Glotfelty |
| `subtle` | 2.6.1 | Copyright (c) 2016-2017 Isis Agora Lovecruft, Henry de Valence. All rights reserved.<br>Copyright (c) 2016-2024 Isis Agora Lovecruft. All rights reserved. |
| `svgtypes` | 0.15.3 | Copyright (c) 2018 Yevhenii Reizner |
| `syn` | 2.0.114 | Copyright (c) David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/dtolnay/syn) |
| `synstructure` | 0.13.2 | Copyright 2016 Nika Layzell |
| `tempfile` | 3.24.0 | Copyright (c) 2015 Steven Allen |
| `thiserror` | 2.0.18 | Copyright (c) David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/dtolnay/thiserror) |
| `thiserror-impl` | 2.0.18 | Copyright (c) David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/dtolnay/thiserror) |
| `thread_local` | 1.1.9 | Copyright (c) 2016 The Rust Project Developers |
| `time` | 0.3.46 | Copyright (c) Jacob Pratt et al. |
| `time-core` | 0.1.8 | Copyright (c) Jacob Pratt et al. |
| `tiny-skia` | 0.11.4 | Copyright (c) 2011 Google Inc. All rights reserved.<br>Copyright (c) 2020 Yevhenii Reizner All rights reserved. |
| `tiny-skia-path` | 0.11.4 | Copyright (c) 2011 Google Inc. All rights reserved.<br>Copyright (c) 2020 Yevhenii Reizner All rights reserved. |
| `tinystr` | 0.8.2 | Copyright © 2020-2024 Unicode, Inc. |
| `tinyvec` | 1.10.0 | Copyright (c) 2019 Daniel "Lokathor" Gee. |
| `tinyvec_macros` | 0.1.1 | Copyright 2020 Tomasz "Soveu" Marx<br>Copyright (c) 2020 Soveu |
| `tokio` | 1.49.0 | Copyright (c) Tokio Contributors |
| `tokio-macros` | 2.6.0 | Copyright (c) 2019 Yoshua Wuyts<br>Copyright (c) Tokio Contributors |
| `tokio-native-tls` | 0.3.1 | Copyright (c) 2019 Tokio Contributors |
| `tokio-rustls` | 0.26.4 | Copyright 2017 quininer kel<br>Copyright (c) 2017 quininer kel |
| `toml` | 0.8.23 | Copyright (c) Individual contributors |
| `toml_datetime` | 0.6.11 | Copyright (c) Individual contributors |
| `toml_edit` | 0.22.27 | Copyright (c) Individual contributors |
| `toml_write` | 0.1.2 | Copyright (c) Individual contributors |
| `tower` | 0.5.3 | Copyright (c) 2019 Tower Contributors |
| `tower-http` | 0.6.8 | Copyright (c) 2019-2021 Tower Contributors |
| `tower-layer` | 0.3.3 | Copyright (c) 2019 Tower Contributors |
| `tower-service` | 0.3.3 | Copyright (c) 2019 Tower Contributors |
| `tracing` | 0.1.44 | Copyright (c) 2019 Tokio Contributors |
| `tracing-attributes` | 0.1.31 | Copyright (c) 2019 Tokio Contributors |
| `tracing-core` | 0.1.36 | Copyright (c) 2019 Tokio Contributors |
| `tracing-log` | 0.2.0 | Copyright (c) 2019 Tokio Contributors |
| `tracing-subscriber` | 0.3.22 | Copyright (c) 2019 Tokio Contributors |
| `try-lock` | 0.2.5 | Copyright (c) 2018-2023 Sean McArthur<br>Copyright (c) 2016 Alex Crichton |
| `ttf-parser` | 0.25.1 | Copyright (c) 2018 Yevhenii Reizner |
| `typenum` | 1.19.0 | Copyright (c) 2014 Paho Lurie-Gregg |
| `unicode-ident` | 1.0.22 | Copyright © 1991-2023 Unicode, Inc. |
| `unicode-normalization` | 0.1.25 | Copyright (c) 2015 The Rust Project Developers |
| `unicode-segmentation` | 1.12.0 | Copyright (c) 2015 The Rust Project Developers |
| `unicode-truncate` | 1.1.0 | Copyright (c) 2019 Aetf <aetf at unlimitedcodeworks dot xyz> |
| `unicode-width` | 0.1.14 | Copyright (c) 2015 The Rust Project Developers |
| `unicode-width` | 0.2.0 | Copyright (c) 2015 The Rust Project Developers |
| `untrusted` | 0.9.0 | Copyright 2015-2016 Brian Smith |
| `url` | 2.5.8 | Copyright (c) 2013-2025 The rust-url developers |
| `utf8_iter` | 1.0.4 | Copyright Mozilla Foundation |
| `utf8parse` | 0.2.2 | Copyright (c) 2016 Joe Wilm |
| `uuid` | 1.20.0 | Copyright (c) 2014 The Rust Project Developers<br>Copyright (c) 2018 Ashley Mannix, Christopher Armstrong, Dylan DPC, Hunar Roop Kahlon |
| `valuable` | 0.1.1 | Copyright (c) the valuable contributors (crate ships no licence file; notice from the crate's declared authors; MIT text below; upstream https://github.com/tokio-rs/valuable) |
| `value-trait` | 0.10.1 | Copyright (c) Heinz N. Gies (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/simd-lite/value-trait) |
| `vcpkg` | 0.2.15 | Copyright (c) 2017 Jim McGrath |
| `version_check` | 0.9.5 | Copyright (c) 2017-2018 Sergio Benitez |
| `walkdir` | 2.5.0 | Copyright (c) 2015 Andrew Gallant |
| `want` | 0.3.1 | Copyright (c) 2018-2019 Sean McArthur |
| `wide` | 0.7.33 | Copyright (c) 2020 Daniel "Lokathor" Gee. |
| `winnow` | 0.7.14 | Copyright (c) the winnow contributors (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/winnow-rs/winnow) |
| `writeable` | 0.6.2 | Copyright © 2020-2024 Unicode, Inc. |
| `xmlwriter` | 0.1.0 | Copyright (c) 2019 Reizner Evgeniy |
| `yaml_serde` | 0.10.7 | Copyright (c) YAML Organization (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/yaml/yaml-serde) |
| `yoke` | 0.8.1 | Copyright © 2020-2024 Unicode, Inc. |
| `yoke-derive` | 0.8.1 | Copyright © 2020-2024 Unicode, Inc. |
| `zerocopy` | 0.8.38 | Copyright 2019 The Fuchsia Authors.<br>Copyright 2023 The Fuchsia Authors |
| `zerocopy-derive` | 0.8.38 | Copyright 2019 The Fuchsia Authors.<br>Copyright 2023 The Fuchsia Authors |
| `zerofrom` | 0.1.6 | Copyright © 2020-2024 Unicode, Inc. |
| `zerofrom-derive` | 0.1.6 | Copyright © 2020-2024 Unicode, Inc. |
| `zeroize` | 1.8.2 | Copyright (c) 2018-2021 The RustCrypto Project Developers |
| `zerotrie` | 0.2.3 | Copyright © 2020-2024 Unicode, Inc. |
| `zerovec` | 0.11.5 | Copyright © 2020-2024 Unicode, Inc. |
| `zerovec-derive` | 0.11.2 | Copyright © 2020-2024 Unicode, Inc. |
| `zmij` | 1.0.19 | Copyright (c) David Tolnay (licence files carry no copyright line; notice from the crate's declared authors; MIT text below; upstream https://github.com/dtolnay/zmij) |
| `zstd` | 0.13.3 | Copyright (c) 2016 Alexandre Bury |
| `zstd-safe` | 7.2.4 | Copyright (c) 2016 Alexandre Bury |
| `zstd-sys` | 2.0.16+zstd.1.5.7 | Copyright (c) 2016-present, Facebook, Inc. All rights reserved.<br>Copyright (c) 2016 Alexandre Bury |
| `zune-core` | 0.5.1 | Copyright (c) zune-image developers |
| `zune-jpeg` | 0.5.12 | Copyright (c) zune-image developers |

### Licence texts

Each text below is reproduced from the crate named in its caption.

#### MIT

Source: `cfg-if-1.0.4/LICENSE-MIT`.

```text
Copyright (c) 2014 Alex Crichton

Permission is hereby granted, free of charge, to any
person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the
Software without restriction, including without
limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice
shall be included in all copies or substantial portions
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

#### Apache-2.0

Source: `cfg-if-1.0.4/LICENSE-APACHE`.

```text
                              Apache License
                        Version 2.0, January 2004
                     http://www.apache.org/licenses/

TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

1. Definitions.

   "License" shall mean the terms and conditions for use, reproduction,
   and distribution as defined by Sections 1 through 9 of this document.

   "Licensor" shall mean the copyright owner or entity authorized by
   the copyright owner that is granting the License.

   "Legal Entity" shall mean the union of the acting entity and all
   other entities that control, are controlled by, or are under common
   control with that entity. For the purposes of this definition,
   "control" means (i) the power, direct or indirect, to cause the
   direction or management of such entity, whether by contract or
   otherwise, or (ii) ownership of fifty percent (50%) or more of the
   outstanding shares, or (iii) beneficial ownership of such entity.

   "You" (or "Your") shall mean an individual or Legal Entity
   exercising permissions granted by this License.

   "Source" form shall mean the preferred form for making modifications,
   including but not limited to software source code, documentation
   source, and configuration files.

   "Object" form shall mean any form resulting from mechanical
   transformation or translation of a Source form, including but
   not limited to compiled object code, generated documentation,
   and conversions to other media types.

   "Work" shall mean the work of authorship, whether in Source or
   Object form, made available under the License, as indicated by a
   copyright notice that is included in or attached to the work
   (an example is provided in the Appendix below).

   "Derivative Works" shall mean any work, whether in Source or Object
   form, that is based on (or derived from) the Work and for which the
   editorial revisions, annotations, elaborations, or other modifications
   represent, as a whole, an original work of authorship. For the purposes
   of this License, Derivative Works shall not include works that remain
   separable from, or merely link (or bind by name) to the interfaces of,
   the Work and Derivative Works thereof.

   "Contribution" shall mean any work of authorship, including
   the original version of the Work and any modifications or additions
   to that Work or Derivative Works thereof, that is intentionally
   submitted to Licensor for inclusion in the Work by the copyright owner
   or by an individual or Legal Entity authorized to submit on behalf of
   the copyright owner. For the purposes of this definition, "submitted"
   means any form of electronic, verbal, or written communication sent
   to the Licensor or its representatives, including but not limited to
   communication on electronic mailing lists, source code control systems,
   and issue tracking systems that are managed by, or on behalf of, the
   Licensor for the purpose of discussing and improving the Work, but
   excluding communication that is conspicuously marked or otherwise
   designated in writing by the copyright owner as "Not a Contribution."

   "Contributor" shall mean Licensor and any individual or Legal Entity
   on behalf of whom a Contribution has been received by Licensor and
   subsequently incorporated within the Work.

2. Grant of Copyright License. Subject to the terms and conditions of
   this License, each Contributor hereby grants to You a perpetual,
   worldwide, non-exclusive, no-charge, royalty-free, irrevocable
   copyright license to reproduce, prepare Derivative Works of,
   publicly display, publicly perform, sublicense, and distribute the
   Work and such Derivative Works in Source or Object form.

3. Grant of Patent License. Subject to the terms and conditions of
   this License, each Contributor hereby grants to You a perpetual,
   worldwide, non-exclusive, no-charge, royalty-free, irrevocable
   (except as stated in this section) patent license to make, have made,
   use, offer to sell, sell, import, and otherwise transfer the Work,
   where such license applies only to those patent claims licensable
   by such Contributor that are necessarily infringed by their
   Contribution(s) alone or by combination of their Contribution(s)
   with the Work to which such Contribution(s) was submitted. If You
   institute patent litigation against any entity (including a
   cross-claim or counterclaim in a lawsuit) alleging that the Work
   or a Contribution incorporated within the Work constitutes direct
   or contributory patent infringement, then any patent licenses
   granted to You under this License for that Work shall terminate
   as of the date such litigation is filed.

4. Redistribution. You may reproduce and distribute copies of the
   Work or Derivative Works thereof in any medium, with or without
   modifications, and in Source or Object form, provided that You
   meet the following conditions:

   (a) You must give any other recipients of the Work or
       Derivative Works a copy of this License; and

   (b) You must cause any modified files to carry prominent notices
       stating that You changed the files; and

   (c) You must retain, in the Source form of any Derivative Works
       that You distribute, all copyright, patent, trademark, and
       attribution notices from the Source form of the Work,
       excluding those notices that do not pertain to any part of
       the Derivative Works; and

   (d) If the Work includes a "NOTICE" text file as part of its
       distribution, then any Derivative Works that You distribute must
       include a readable copy of the attribution notices contained
       within such NOTICE file, excluding those notices that do not
       pertain to any part of the Derivative Works, in at least one
       of the following places: within a NOTICE text file distributed
       as part of the Derivative Works; within the Source form or
       documentation, if provided along with the Derivative Works; or,
       within a display generated by the Derivative Works, if and
       wherever such third-party notices normally appear. The contents
       of the NOTICE file are for informational purposes only and
       do not modify the License. You may add Your own attribution
       notices within Derivative Works that You distribute, alongside
       or as an addendum to the NOTICE text from the Work, provided
       that such additional attribution notices cannot be construed
       as modifying the License.

   You may add Your own copyright statement to Your modifications and
   may provide additional or different license terms and conditions
   for use, reproduction, or distribution of Your modifications, or
   for any such Derivative Works as a whole, provided Your use,
   reproduction, and distribution of the Work otherwise complies with
   the conditions stated in this License.

5. Submission of Contributions. Unless You explicitly state otherwise,
   any Contribution intentionally submitted for inclusion in the Work
   by You to the Licensor shall be under the terms and conditions of
   this License, without any additional terms or conditions.
   Notwithstanding the above, nothing herein shall supersede or modify
   the terms of any separate license agreement you may have executed
   with Licensor regarding such Contributions.

6. Trademarks. This License does not grant permission to use the trade
   names, trademarks, service marks, or product names of the Licensor,
   except as required for reasonable and customary use in describing the
   origin of the Work and reproducing the content of the NOTICE file.

7. Disclaimer of Warranty. Unless required by applicable law or
   agreed to in writing, Licensor provides the Work (and each
   Contributor provides its Contributions) on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
   implied, including, without limitation, any warranties or conditions
   of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
   PARTICULAR PURPOSE. You are solely responsible for determining the
   appropriateness of using or redistributing the Work and assume any
   risks associated with Your exercise of permissions under this License.

8. Limitation of Liability. In no event and under no legal theory,
   whether in tort (including negligence), contract, or otherwise,
   unless required by applicable law (such as deliberate and grossly
   negligent acts) or agreed to in writing, shall any Contributor be
   liable to You for damages, including any direct, indirect, special,
   incidental, or consequential damages of any character arising as a
   result of this License or out of the use or inability to use the
   Work (including but not limited to damages for loss of goodwill,
   work stoppage, computer failure or malfunction, or any and all
   other commercial damages or losses), even if such Contributor
   has been advised of the possibility of such damages.

9. Accepting Warranty or Additional Liability. While redistributing
   the Work or Derivative Works thereof, You may choose to offer,
   and charge a fee for, acceptance of support, warranty, indemnity,
   or other liability obligations and/or rights consistent with this
   License. However, in accepting such obligations, You may act only
   on Your own behalf and on Your sole responsibility, not on behalf
   of any other Contributor, and only if You agree to indemnify,
   defend, and hold each Contributor harmless for any liability
   incurred by, or claims asserted against, such Contributor by reason
   of your accepting any such warranty or additional liability.

END OF TERMS AND CONDITIONS

APPENDIX: How to apply the Apache License to your work.

   To apply the Apache License to your work, attach the following
   boilerplate notice, with the fields enclosed by brackets "[]"
   replaced with your own identifying information. (Don't include
   the brackets!)  The text should be enclosed in the appropriate
   comment syntax for the file format. We also recommend that a
   file or class name and description of purpose be included on the
   same "printed page" as the copyright notice for easier
   identification within third-party archives.

Copyright [yyyy] [name of copyright owner]

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

#### Apache-2.0 WITH LLVM-exception

Source: `rustix-1.1.3/LICENSE-Apache-2.0_WITH_LLVM-exception`.

The crate's file reproduces the Apache-2.0 text above and then appends this exception.

```text
--- LLVM Exceptions to the Apache 2.0 License ----

As an exception, if, as a result of your compiling your source code, portions
of this Software are embedded into an Object form of such source code, you
may redistribute such embedded portions in such Object form without complying
with the conditions of Sections 4(a), 4(b) and 4(d) of the License.

In addition, if you combine or link compiled forms of this Software with
software that is licensed under the GPLv2 ("Combined Software") and if a
court of competent jurisdiction determines that the patent provision (Section
3), the indemnity provision (Section 9) or other Section of the License
conflicts with the conditions of the GPLv2, you may retroactively and
prospectively choose to deem waived or otherwise exclude such Section(s) of
the License, but only in their entirety and only with respect to the Combined
Software.
```

#### ISC

Source: `rustls-webpki-0.103.14/LICENSE`.

```text
Except as otherwise noted, this project is licensed under the following
(ISC-style) terms:

Copyright 2015 Brian Smith.

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHORS DISCLAIM ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

The files under third-party/chromium are licensed as described in
third-party/chromium/LICENSE.
```

#### BSD-3-Clause

Source: `subtle-2.6.1/LICENSE`.

```text
Copyright (c) 2016-2017 Isis Agora Lovecruft, Henry de Valence. All rights reserved.
Copyright (c) 2016-2024 Isis Agora Lovecruft. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

1. Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

#### BSD-2-Clause

Source: `arrayref-0.3.9/LICENSE`.

```text
Copyright (c) 2015 David Roundy <roundyd@physics.oregonstate.edu>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the
   distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

#### Zlib

Source: `miniz_oxide-0.8.9/LICENSE-ZLIB.md`.

```text
Copyright 2013-2014 RAD Game Tools and Valve Software
Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC
Copyright (c) 2020 Frommi
Copyright (c) 2017-2024 oyvindln

This software is provided 'as-is', without any express or implied warranty. In no event will the authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the original software. If you use this software in a product, an acknowledgment in the product documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.

3. This notice may not be removed or altered from any source distribution.
```

#### BSL-1.0

Source: `ryu-1.0.22/LICENSE-BOOST`.

```text
Boost Software License - Version 1.0 - August 17th, 2003

Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

#### 0BSD

Source: `adler2-2.0.1/LICENSE-0BSD`.

```text
Copyright (C) Jonas Schievink <jonasschievink@gmail.com>

Permission to use, copy, modify, and/or distribute this software for
any purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN
AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT
OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

#### Unlicense

Source: `walkdir-2.5.0/UNLICENSE`.

```text
This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or
distribute this software, either in source code form or as a compiled
binary, for any purpose, commercial or non-commercial, and by any
means.

In jurisdictions that recognize copyright laws, the author or authors
of this software dedicate any and all copyright interest in the
software to the public domain. We make this dedication for the benefit
of the public at large and to the detriment of our heirs and
successors. We intend this dedication to be an overt act of
relinquishment in perpetuity of all present and future rights to this
software under copyright law.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

For more information, please refer to <http://unlicense.org/>
```

#### Unicode-3.0

Source: `icu_collections-2.1.1/LICENSE`.

```text
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 2020-2024 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.

SPDX-License-Identifier: Unicode-3.0

—

Portions of ICU4X may have been adapted from ICU4C and/or ICU4J.
ICU 1.8.1 to ICU 57.1 © 1995-2016 International Business Machines Corporation and others.
```

#### CDLA-Permissive-2.0

Source: `webpki-roots-1.0.9/LICENSE`.

```text
# Community Data License Agreement - Permissive - Version 2.0

This is the Community Data License Agreement - Permissive, Version
2.0 (the "agreement"). Data Provider(s) and Data Recipient(s) agree
as follows:

## 1. Provision of the Data

1.1. A Data Recipient may use, modify, and share the Data made
available by Data Provider(s) under this agreement if that Data
Recipient follows the terms of this agreement.

1.2. This agreement does not impose any restriction on a Data
Recipient's use, modification, or sharing of any portions of the
Data that are in the public domain or that may be used, modified,
or shared under any other legal exception or limitation.

## 2. Conditions for Sharing Data

2.1. A Data Recipient may share Data, with or without modifications, so
long as the Data Recipient makes available the text of this agreement
with the shared Data.

## 3. No Restrictions on Results

3.1. This agreement does not impose any restriction or obligations
with respect to the use, modification, or sharing of Results.

## 4. No Warranty; Limitation of Liability

4.1. All Data Recipients receive the Data subject to the following
terms:

THE DATA IS PROVIDED ON AN "AS IS" BASIS, WITHOUT REPRESENTATIONS,
WARRANTIES OR CONDITIONS OF ANY KIND, EITHER EXPRESS OR IMPLIED
INCLUDING, WITHOUT LIMITATION, ANY WARRANTIES OR CONDITIONS OF TITLE,
NON-INFRINGEMENT, MERCHANTABILITY OR FITNESS FOR A PARTICULAR PURPOSE.

NO DATA PROVIDER SHALL HAVE ANY LIABILITY FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING
WITHOUT LIMITATION LOST PROFITS), HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE DATA OR RESULTS,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.

## 5. Definitions

5.1. "Data" means the material received by a Data Recipient under
this agreement.

5.2. "Data Provider" means any person who is the source of Data
provided under this agreement and in reliance on a Data Recipient's
agreement to its terms.

5.3. "Data Recipient" means any person who receives Data directly
or indirectly from a Data Provider and agrees to the terms of this
agreement.

5.4. "Results" means any outcome obtained by computational analysis
of Data, including for example machine learning models and models'
insights.
```

#### MPL-2.0

Source: `option-ext-0.2.0/LICENSE.txt`.

```text
Mozilla Public License Version 2.0
==================================

1. Definitions
--------------

1.1. "Contributor"
    means each individual or legal entity that creates, contributes to
    the creation of, or owns Covered Software.

1.2. "Contributor Version"
    means the combination of the Contributions of others (if any) used
    by a Contributor and that particular Contributor's Contribution.

1.3. "Contribution"
    means Covered Software of a particular Contributor.

1.4. "Covered Software"
    means Source Code Form to which the initial Contributor has attached
    the notice in Exhibit A, the Executable Form of such Source Code
    Form, and Modifications of such Source Code Form, in each case
    including portions thereof.

1.5. "Incompatible With Secondary Licenses"
    means

    (a) that the initial Contributor has attached the notice described
        in Exhibit B to the Covered Software; or

    (b) that the Covered Software was made available under the terms of
        version 1.1 or earlier of the License, but not also under the
        terms of a Secondary License.

1.6. "Executable Form"
    means any form of the work other than Source Code Form.

1.7. "Larger Work"
    means a work that combines Covered Software with other material, in 
    a separate file or files, that is not Covered Software.

1.8. "License"
    means this document.

1.9. "Licensable"
    means having the right to grant, to the maximum extent possible,
    whether at the time of the initial grant or subsequently, any and
    all of the rights conveyed by this License.

1.10. "Modifications"
    means any of the following:

    (a) any file in Source Code Form that results from an addition to,
        deletion from, or modification of the contents of Covered
        Software; or

    (b) any new file in Source Code Form that contains any Covered
        Software.

1.11. "Patent Claims" of a Contributor
    means any patent claim(s), including without limitation, method,
    process, and apparatus claims, in any patent Licensable by such
    Contributor that would be infringed, but for the grant of the
    License, by the making, using, selling, offering for sale, having
    made, import, or transfer of either its Contributions or its
    Contributor Version.

1.12. "Secondary License"
    means either the GNU General Public License, Version 2.0, the GNU
    Lesser General Public License, Version 2.1, the GNU Affero General
    Public License, Version 3.0, or any later versions of those
    licenses.

1.13. "Source Code Form"
    means the form of the work preferred for making modifications.

1.14. "You" (or "Your")
    means an individual or a legal entity exercising rights under this
    License. For legal entities, "You" includes any entity that
    controls, is controlled by, or is under common control with You. For
    purposes of this definition, "control" means (a) the power, direct
    or indirect, to cause the direction or management of such entity,
    whether by contract or otherwise, or (b) ownership of more than
    fifty percent (50%) of the outstanding shares or beneficial
    ownership of such entity.

2. License Grants and Conditions
--------------------------------

2.1. Grants

Each Contributor hereby grants You a world-wide, royalty-free,
non-exclusive license:

(a) under intellectual property rights (other than patent or trademark)
    Licensable by such Contributor to use, reproduce, make available,
    modify, display, perform, distribute, and otherwise exploit its
    Contributions, either on an unmodified basis, with Modifications, or
    as part of a Larger Work; and

(b) under Patent Claims of such Contributor to make, use, sell, offer
    for sale, have made, import, and otherwise transfer either its
    Contributions or its Contributor Version.

2.2. Effective Date

The licenses granted in Section 2.1 with respect to any Contribution
become effective for each Contribution on the date the Contributor first
distributes such Contribution.

2.3. Limitations on Grant Scope

The licenses granted in this Section 2 are the only rights granted under
this License. No additional rights or licenses will be implied from the
distribution or licensing of Covered Software under this License.
Notwithstanding Section 2.1(b) above, no patent license is granted by a
Contributor:

(a) for any code that a Contributor has removed from Covered Software;
    or

(b) for infringements caused by: (i) Your and any other third party's
    modifications of Covered Software, or (ii) the combination of its
    Contributions with other software (except as part of its Contributor
    Version); or

(c) under Patent Claims infringed by Covered Software in the absence of
    its Contributions.

This License does not grant any rights in the trademarks, service marks,
or logos of any Contributor (except as may be necessary to comply with
the notice requirements in Section 3.4).

2.4. Subsequent Licenses

No Contributor makes additional grants as a result of Your choice to
distribute the Covered Software under a subsequent version of this
License (see Section 10.2) or under the terms of a Secondary License (if
permitted under the terms of Section 3.3).

2.5. Representation

Each Contributor represents that the Contributor believes its
Contributions are its original creation(s) or it has sufficient rights
to grant the rights to its Contributions conveyed by this License.

2.6. Fair Use

This License is not intended to limit any rights You have under
applicable copyright doctrines of fair use, fair dealing, or other
equivalents.

2.7. Conditions

Sections 3.1, 3.2, 3.3, and 3.4 are conditions of the licenses granted
in Section 2.1.

3. Responsibilities
-------------------

3.1. Distribution of Source Form

All distribution of Covered Software in Source Code Form, including any
Modifications that You create or to which You contribute, must be under
the terms of this License. You must inform recipients that the Source
Code Form of the Covered Software is governed by the terms of this
License, and how they can obtain a copy of this License. You may not
attempt to alter or restrict the recipients' rights in the Source Code
Form.

3.2. Distribution of Executable Form

If You distribute Covered Software in Executable Form then:

(a) such Covered Software must also be made available in Source Code
    Form, as described in Section 3.1, and You must inform recipients of
    the Executable Form how they can obtain a copy of such Source Code
    Form by reasonable means in a timely manner, at a charge no more
    than the cost of distribution to the recipient; and

(b) You may distribute such Executable Form under the terms of this
    License, or sublicense it under different terms, provided that the
    license for the Executable Form does not attempt to limit or alter
    the recipients' rights in the Source Code Form under this License.

3.3. Distribution of a Larger Work

You may create and distribute a Larger Work under terms of Your choice,
provided that You also comply with the requirements of this License for
the Covered Software. If the Larger Work is a combination of Covered
Software with a work governed by one or more Secondary Licenses, and the
Covered Software is not Incompatible With Secondary Licenses, this
License permits You to additionally distribute such Covered Software
under the terms of such Secondary License(s), so that the recipient of
the Larger Work may, at their option, further distribute the Covered
Software under the terms of either this License or such Secondary
License(s).

3.4. Notices

You may not remove or alter the substance of any license notices
(including copyright notices, patent notices, disclaimers of warranty,
or limitations of liability) contained within the Source Code Form of
the Covered Software, except that You may alter any license notices to
the extent required to remedy known factual inaccuracies.

3.5. Application of Additional Terms

You may choose to offer, and to charge a fee for, warranty, support,
indemnity or liability obligations to one or more recipients of Covered
Software. However, You may do so only on Your own behalf, and not on
behalf of any Contributor. You must make it absolutely clear that any
such warranty, support, indemnity, or liability obligation is offered by
You alone, and You hereby agree to indemnify every Contributor for any
liability incurred by such Contributor as a result of warranty, support,
indemnity or liability terms You offer. You may include additional
disclaimers of warranty and limitations of liability specific to any
jurisdiction.

4. Inability to Comply Due to Statute or Regulation
---------------------------------------------------

If it is impossible for You to comply with any of the terms of this
License with respect to some or all of the Covered Software due to
statute, judicial order, or regulation then You must: (a) comply with
the terms of this License to the maximum extent possible; and (b)
describe the limitations and the code they affect. Such description must
be placed in a text file included with all distributions of the Covered
Software under this License. Except to the extent prohibited by statute
or regulation, such description must be sufficiently detailed for a
recipient of ordinary skill to be able to understand it.

5. Termination
--------------

5.1. The rights granted under this License will terminate automatically
if You fail to comply with any of its terms. However, if You become
compliant, then the rights granted under this License from a particular
Contributor are reinstated (a) provisionally, unless and until such
Contributor explicitly and finally terminates Your grants, and (b) on an
ongoing basis, if such Contributor fails to notify You of the
non-compliance by some reasonable means prior to 60 days after You have
come back into compliance. Moreover, Your grants from a particular
Contributor are reinstated on an ongoing basis if such Contributor
notifies You of the non-compliance by some reasonable means, this is the
first time You have received notice of non-compliance with this License
from such Contributor, and You become compliant prior to 30 days after
Your receipt of the notice.

5.2. If You initiate litigation against any entity by asserting a patent
infringement claim (excluding declaratory judgment actions,
counter-claims, and cross-claims) alleging that a Contributor Version
directly or indirectly infringes any patent, then the rights granted to
You by any and all Contributors for the Covered Software under Section
2.1 of this License shall terminate.

5.3. In the event of termination under Sections 5.1 or 5.2 above, all
end user license agreements (excluding distributors and resellers) which
have been validly granted by You or Your distributors under this License
prior to termination shall survive termination.

************************************************************************
*                                                                      *
*  6. Disclaimer of Warranty                                           *
*  -------------------------                                           *
*                                                                      *
*  Covered Software is provided under this License on an "as is"       *
*  basis, without warranty of any kind, either expressed, implied, or  *
*  statutory, including, without limitation, warranties that the       *
*  Covered Software is free of defects, merchantable, fit for a        *
*  particular purpose or non-infringing. The entire risk as to the     *
*  quality and performance of the Covered Software is with You.        *
*  Should any Covered Software prove defective in any respect, You     *
*  (not any Contributor) assume the cost of any necessary servicing,   *
*  repair, or correction. This disclaimer of warranty constitutes an   *
*  essential part of this License. No use of any Covered Software is   *
*  authorized under this License except under this disclaimer.         *
*                                                                      *
************************************************************************

************************************************************************
*                                                                      *
*  7. Limitation of Liability                                          *
*  --------------------------                                          *
*                                                                      *
*  Under no circumstances and under no legal theory, whether tort      *
*  (including negligence), contract, or otherwise, shall any           *
*  Contributor, or anyone who distributes Covered Software as          *
*  permitted above, be liable to You for any direct, indirect,         *
*  special, incidental, or consequential damages of any character      *
*  including, without limitation, damages for lost profits, loss of    *
*  goodwill, work stoppage, computer failure or malfunction, or any    *
*  and all other commercial damages or losses, even if such party      *
*  shall have been informed of the possibility of such damages. This   *
*  limitation of liability shall not apply to liability for death or   *
*  personal injury resulting from such party's negligence to the       *
*  extent applicable law prohibits such limitation. Some               *
*  jurisdictions do not allow the exclusion or limitation of           *
*  incidental or consequential damages, so this exclusion and          *
*  limitation may not apply to You.                                    *
*                                                                      *
************************************************************************

8. Litigation
-------------

Any litigation relating to this License may be brought only in the
courts of a jurisdiction where the defendant maintains its principal
place of business and such litigation shall be governed by laws of that
jurisdiction, without reference to its conflict-of-law provisions.
Nothing in this Section shall prevent a party's ability to bring
cross-claims or counter-claims.

9. Miscellaneous
----------------

This License represents the complete agreement concerning the subject
matter hereof. If any provision of this License is held to be
unenforceable, such provision shall be reformed only to the extent
necessary to make it enforceable. Any law or regulation which provides
that the language of a contract shall be construed against the drafter
shall not be used to construe this License against a Contributor.

10. Versions of the License
---------------------------

10.1. New Versions

Mozilla Foundation is the license steward. Except as provided in Section
10.3, no one other than the license steward has the right to modify or
publish new versions of this License. Each version will be given a
distinguishing version number.

10.2. Effect of New Versions

You may distribute the Covered Software under the terms of the version
of the License under which You originally received the Covered Software,
or under the terms of any subsequent version published by the license
steward.

10.3. Modified Versions

If you create software not governed by this License, and you want to
create a new license for such software, you may create and use a
modified version of this License if you rename the license and remove
any references to the name of the license steward (except to note that
such modified license differs from this License).

10.4. Distributing Source Code Form that is Incompatible With Secondary
Licenses

If You choose to distribute Source Code Form that is Incompatible With
Secondary Licenses under the terms of this version of the License, the
notice described in Exhibit B of this License must be attached.

Exhibit A - Source Code Form License Notice
-------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at https://mozilla.org/MPL/2.0/.

If it is not possible or desirable to put the notice in a particular
file, then You may include the notice in a location (such as a LICENSE
file in a relevant directory) where a recipient would be likely to look
for such a notice.

You may add additional accurate notices of copyright ownership.

Exhibit B - "Incompatible With Secondary Licenses" Notice
---------------------------------------------------------

  This Source Code Form is "Incompatible With Secondary Licenses", as
  defined by the Mozilla Public License, v. 2.0.
```
