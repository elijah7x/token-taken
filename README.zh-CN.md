[English](README.md) · **简体中文**

# Token Taken

一款小而美的 macOS Token 用量仪表盘，采用原生 Liquid Glass。

**状态：Pre-alpha：规格制定阶段，尚无可安装版本。**

## 计划中的 v1 功能

- 按日、月、年和累计查看总用量，并按模型和来源细分。
- 汇总多台 Mac 的用量；启用 iCloud 同步后，可查看各设备明细。
- 极简菜单栏项目，显示今日 Token 总量。
- 原生 Liquid Glass 主题；主题系统从首版开始设计，后续加入 Geek 和 Sketchbook 主题。
- `token-taken` CLI，支持 JSON 输出和 JSON/CSV 数据导出。
- 通过 String Catalog 提供英文和简体中文界面。
- 根据带版本的价格表估算费用。估算结果不是账单。

Agent 覆盖范围仍待确定，见 [ADR-0003](docs/decisions/0003-usage-engine.md) 中的引擎验证计划。

## 隐私

v1 采用本地优先设计：

- Token Taken 以只读方式读取受支持 Agent 的日志。
- iCloud Drive 同步需要主动开启，默认关闭。
- 同步内容仅包含聚合用量元数据，不包含提示词、回复、文件路径、项目名称、凭据或费用。
- Token Taken 不收集遥测数据。

详见[隐私契约](docs/contracts/privacy.md)和[同步契约](docs/contracts/sync.md)。

## 系统要求

- macOS 26.0 或更高版本

## 计划中的 CLI 预览

CLI 尚不存在。计划中的接口包含如下命令：

```sh
token-taken models --period month --json
```

[CLI 契约](docs/contracts/cli.md)定义了计划中的输出和错误行为。

## 文档

- [产品规格](docs/product.md)
- [架构](docs/architecture.md)
- 决策记录：[原生 macOS 应用](docs/decisions/0001-native-macos-app.md)、[iCloud Drive 同步](docs/decisions/0002-icloud-drive-sync.md)、[用量引擎](docs/decisions/0003-usage-engine.md)
- [契约索引](docs/contracts/README.md)
- 契约详情：[统计](docs/contracts/statistics.md)、[CLI](docs/contracts/cli.md)、[同步](docs/contracts/sync.md)、[隐私](docs/contracts/privacy.md)、[上游复用](docs/contracts/upstream.md)、[主题](docs/contracts/themes.md)
- [更新日志](CHANGELOG.md)

## 致谢

Token Taken 参考以下采用 MIT 许可证的项目：

- [tokscale](https://github.com/junhoyeo/tokscale)：采集、解析、计价和 JSON CLI 设计。
- [TokenTracker](https://github.com/xiufengsun/TokenTracker)：Node 采集器和本地 API 设计。
- [Token Monitor](https://github.com/Javis603/token-monitor)：同步和历史记录设计。

目前尚未捆绑任何上游代码或二进制文件。详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，其中包括 TokenTracker 内 React Bits 素材的独立许可说明。

## 许可证

[MIT](LICENSE)。Copyright (c) 2026 elijah7x。
