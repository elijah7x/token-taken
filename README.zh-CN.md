[English](README.md) | 简体中文

# Token Taken

一款小而美的原生 macOS Token 用量统计应用——基于 SwiftUI 与 Liquid Glass，配有菜单栏速览、命令行工具与仅用于展示的 iPhone 伴侣应用。

## 缘起

起初我也用过几款别的用量统计工具，但用下来总会遇到一些让人头疼的问题：数字总有些不准，界面呈现也差了点意思；真想把最近的用量发出来分享时，还得自己一张张手动截图、裁边。被这些琐事折腾久了，我就想干脆自己做一个小而美的 Token 统计软件。希望它平时静静待在桌面与菜单栏里，界面清爽耐看，想分享时也能随手生成一张像样的卡片。

## 主要功能

- **原生 macOS 面板与菜单栏** — 按日、周（周一起始）、月、年及累计查看用量，按工具与模型细分；内置 Liquid Glass、Field 与 Cosmos 三套主题，并提供极简菜单栏今日用量速览。
- **广泛的本机工具支持** — 本地读取 Claude Code、Codex、Zcode、OpenCode、Kimi Code、Gemini CLI、pi、oh-my-pi、Factory Droid、Grok、Devin、Antigravity、MiniMax Code、DeepSeek Harness、DeepSeek CLI 与 fx，并可选开启 Cursor 账号用量采集。
- **内置分享卡片** — 支持按总览、单个工具或单个模型生成 PNG 分享卡片（复制、保存或调用系统分享），可自由开关构成明细、排名与估算费用。
- **多 Mac 与 iPhone 协同** — 可选开启 iCloud Drive 同步，合并同一 Apple ID 下多台 Mac 的用量；另有仅用于展示的 iOS 26 伴侣应用，同样支持生成 Liquid Glass 分享卡片。
- **`token-taken` 命令行工具** — 与桌面端共用同一份本地数据与同步快照，支持机器可读的 JSON 查询与 JSON/CSV 导出。

## 隐私说明

- **本地只读** — 所有本地日志与数据库均以只读方式解析，不会改动你的任何工作文件；应用本身不含遥测统计。
- **主动开启、仅同步聚合结果** — iCloud Drive 同步与向 iPhone 伴侣同步默认均为关闭状态。同步内容仅包含聚合后的用量元数据，绝不包含提示词、回复内容、文件路径、项目名称或任何凭据。
- **费用仅为估算** — 界面中的金额由内置价格表估算得出，并非服务商实际账单。

## 当前状态

目前仅公开源码，尚未发布正式 Release。打包版本很快就会到来，欢迎先点个 **Star** 收藏仓库，发版时即可收到通知。

## 从源码构建

需要 macOS 26 及以上的 Apple 芯片 Mac 与 Xcode。iPhone 伴侣应用位于 `ios/`，架构与设计文档见 [`docs/`](docs/)。

## 许可协议

采用 [MIT](LICENSE) 协议开源。Copyright (c) 2026 elijah7x。
