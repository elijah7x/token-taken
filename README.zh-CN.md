[English](README.md) · **简体中文**

# Token Taken

一款小而美的 macOS Token 用量仪表盘，采用原生 Liquid Glass。

**状态：Pre-alpha（v0.1.0 开发中）。**

## v1 功能

- 按日、周（周一起始）、月、年和累计查看总用量，并按模型和来源细分。
- 汇总多台 Mac 的用量；启用 iCloud Drive 同步后，可查看各设备明细。每台 Mac 的按日记录使用该设备所在的本地日历日，因此合并后的同一天可能混合不同时区。
- 极简菜单栏项目，显示今日 Token 总量与速览。
- 原生 Liquid Glass 主题；主题系统从首版开始设计，后续加入 Geek 和 Sketchbook 主题。
- `token-taken` CLI，支持 JSON 输出和 JSON/CSV 数据导出。
- 通过 String Catalog 提供英文和简体中文界面。
- 根据带版本的价格表（`tokscale-4.21.0-2026-11-10+alias-v3`）估算费用。估算结果不是账单。

v1 支持的本机来源：Claude Code、Codex、Zcode、oh-my-pi、pi、Kimi Code、Grok、OpenCode、Gemini CLI、Factory Droid、Devin（CLI 与桌面版）、Antigravity（CLI 与 IDE 扩展）、DeepSeek Harness 和 fx。Cursor 与 Qoder 暂缓纳入 v1，见 [ADR-0003](docs/decisions/0003-usage-engine.md) 和 [ADR-0005](docs/decisions/0005-collection-granularity.md)。

## 隐私

v1 采用本地优先设计：

- Token Taken 以只读方式读取受支持 Agent 的日志。
- iCloud Drive 同步需要主动开启，默认关闭。
- 同步内容仅包含聚合用量元数据，不包含提示词、回复、文件路径、项目名称、凭据或费用。
- Token Taken 不收集遥测数据。

详见[隐私契约](docs/contracts/privacy.md)和[同步契约](docs/contracts/sync.md)。

## 系统要求

- macOS 26.0 或更高版本

## CLI

`token-taken` 与应用读取同一本地存储及可选的 iCloud Drive 设备快照：

```sh
token-taken summary --period week
token-taken models --period month --json
token-taken export --format csv --period all
```

[CLI 契约](docs/contracts/cli.md)定义了输出结构、筛选参数、告警和退出码。

## 文档

- [产品规格](docs/product.md)
- [架构](docs/architecture.md)
- 决策记录：[原生 macOS 应用](docs/decisions/0001-native-macos-app.md)、[iCloud Drive 同步](docs/decisions/0002-icloud-drive-sync.md)、[用量引擎](docs/decisions/0003-usage-engine.md)、[Developer ID 分发](docs/decisions/0004-distribution.md)、[采集粒度](docs/decisions/0005-collection-granularity.md)、[增量采集](docs/decisions/0006-incremental-collection.md)
- [契约索引](docs/contracts/README.md)
- 契约详情：[统计](docs/contracts/statistics.md)、[CLI](docs/contracts/cli.md)、[同步](docs/contracts/sync.md)、[隐私](docs/contracts/privacy.md)、[上游复用](docs/contracts/upstream.md)、[主题](docs/contracts/themes.md)
- [更新日志](CHANGELOG.md)

## 致谢

Token Taken 参考以下采用 MIT 许可证的项目：

- [tokscale](https://github.com/junhoyeo/tokscale)：采集、解析、计价和 JSON CLI 设计。
- [TokenTracker](https://github.com/xiufengsun/TokenTracker)：Node 采集器和本地 API 设计。
- [Token Monitor](https://github.com/Javis603/token-monitor)：同步和历史记录设计。

Token Taken 捆绑了锁定版本的 `tokscale` 4.21.0 二进制文件以及源自 `tokscale` 的价格表快照（`tokscale-4.21.0-2026-11-10+alias-v3`）。许可说明详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，其中包括 TokenTracker 内 React Bits 素材的独立许可排除说明。

## 许可证

[MIT](LICENSE)。Copyright (c) 2026 elijah7x。
