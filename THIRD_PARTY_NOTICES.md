# Third-party notices

Token Taken does not bundle third-party code or binaries yet. The following projects are local references for the design and the pending engine spike.

| Project | Reference area | Repository license |
| --- | --- | --- |
| [tokscale](https://github.com/junhoyeo/tokscale) | Collection, parsing, pricing, and JSON CLI | MIT |
| [TokenTracker](https://github.com/xiufengsun/TokenTracker) | Node collectors and local API | MIT, except separately licensed assets noted below |
| [Token Monitor](https://github.com/Javis603/token-monitor) | Desktop integration, history, and synchronization | MIT |
| [Javis603/tokscale](https://github.com/Javis603/tokscale) | Tokscale fork used by Token Monitor | MIT |

TokenTracker includes React Bits assets under a separate license. Those assets are outside the repository's general MIT license and must not be copied into Token Taken.

## Policy for vendored code and binaries

Before adding an engine or any other third-party component:

1. Check the license at the exact pinned version or commit. Do not assume that the current repository license covers every file, asset, or transitive dependency.
2. Record the project name, repository URL, pinned version or commit, copied components, license, and local modifications in this file.
3. Preserve copyright notices and include the full license text where the license requires it.
4. Review assets and transitive dependencies separately and add their notices.
5. Keep the same notices with distributed app and CLI binaries when required.

React Bits assets from TokenTracker must not be copied. Other separately licensed material requires an explicit license review before use.
