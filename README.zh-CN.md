# ChatGPT Memory Transferor

[English](README.md) | [中文](README.zh-CN.md)

ChatGPT Memory Transferor 是一个实验性的 Windows 工具包，用于通过 ChatGPT 共享链接和浏览器自动化，把一个 ChatGPT 账号中的对话复制到另一个账号。它也提供项目归属和项目附件还原辅助能力，前提是源账号导出结果中包含项目元数据。

本项目不是 OpenAI 或 ChatGPT 官方迁移 API。它依赖本机浏览器登录态、ChatGPT Web 页面行为和共享链接机制。

当前版本：v0.1.2。详见 [CHANGELOG.md](CHANGELOG.md)。

## 它能做什么

- 在源账号中为可迁移对话创建共享链接。
- 在目标账号专用浏览器 Profile 中打开共享链接并生成对话副本。
- 当源账号已导入对话出现新消息时，替换目标账号中的旧副本。
- 导出源账号项目元数据。
- 在可行时把已导入对话还原到目标账号项目中。
- 为非敏感测试样本提供项目附件下载和重新上传辅助流程。

## 重要说明

This project is experimental and depends on ChatGPT Web behavior, shared-link behavior, and browser automation. These interfaces may change without notice.

本项目为实验性工具，依赖 ChatGPT Web 页面行为、共享链接机制和浏览器自动化流程。相关接口和页面结构可能随时变化，因此不保证长期稳定。

- 仅面向 Windows。
- 依赖 Chrome 或 Edge 浏览器自动化。
- 依赖 ChatGPT Web 页面行为和共享链接行为。
- 不是 OpenAI 或 ChatGPT 官方迁移 API。
- 在大批量运行前，必须先使用少量非敏感对话测试。

## 功能

- A 账号共享链接导出流程。
- B 账号共享链接导入流程。
- 为源账号和目标账号使用独立浏览器 Profile。
- 项目元数据导出和还原辅助。
- 项目附件转移辅助。
- 带源版本判断的重复检测和导入报告。
- 用于手动检查共享链接输入的本地 HTML 工具。
- 用于公开发布前检查的 release validation 脚本。

## 技术栈

- Windows PowerShell 脚本负责编排和本地验证。
- 通过浏览器 DevTools Protocol 注入 JavaScript，驱动 ChatGPT Web 自动化。
- 静态 HTML 辅助页用于手动检查共享链接。
- 不需要 npm、pip、Docker、数据库或编译型 build 步骤。

## 当前运行说明

- ChatGPT 项目列表能看到、但详情接口暂时不可读的项目内对话，会记录为 `skipped_unavailable`，不会把整次 A 导出判定为失败。
- B 账号导入只有在浏览器进入可用的 `/c/{id}` 对话地址后才算成功。
- 重复检测会在历史记录有足够元数据时比较源对话的 `current_node_id` 或 `update_time`。源对话已更新时 dry run 会报告 `would_update`；真实导入会生成最新目标副本、标记为 `updated`，并默认隐藏被替换的旧副本，除非使用 `-KeepSuperseded`。
- 项目附件还原使用当前项目文件绑定接口要求的 payload；上传、绑定或复查仍有错误时会明确失败。

## 环境要求

- Windows。
- PowerShell。
- Chrome 或 Edge。
- 两个 ChatGPT 账号。
- Git，可选；仅在 clone 或参与贡献时需要。

## 安装

```powershell
git clone https://github.com/example-user/ChatGPT-Memory-Transferor.git
cd ChatGPT-Memory-Transferor
```

请把 `example-user` 替换为你要使用的仓库所有者或 fork 地址。

不需要执行依赖安装命令。仓库中的 PowerShell、JavaScript 和 HTML 文件可直接运行。

## 环境变量

不需要 `.env` 文件或真实密钥。不要创建或提交包含账号数据、token、cookie 或本机路径的 `.env` 文件。

可选的本地变量：

- `GPTSYNC_CMD_SELFTEST=1`：只运行根目录 `.cmd` 启动器自检，不启动迁移流程。

## 验证、测试和构建

运行 release validation：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\validate-release.ps1
```

本项目是脚本工具包，没有单独 build 命令。请把 release validation、JavaScript 语法检查和 PowerShell 语法检查作为 build gate。

## 本地运行命令

运行源账号自检：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -SelfTest -NoPause
```

导出一条非敏感样本：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -Limit 1 -SkipProjectFiles -NoPause
```

对目标账号导入做 dry run：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -DryRun -Limit 1 -NoPause
```

真实导入或项目还原前，请先阅读 [项目详细说明](docs/project-details.md)。

## 项目目录结构

```text
.
|-- account-a-create-share-links-cdp.js
|-- b-open-shared-links.html
|-- run-account-a-share-link-export.ps1
|-- run-account-b-shared-link-import.ps1
|-- run-account-b-restore-projects.ps1
|-- run-full-shared-link-migration.ps1
|-- tests/validate-release.ps1
|-- docs/
|-- examples/
|-- VERSION
`-- CHANGELOG.md
```

## 部署和发布

本项目以源码形式发布。发布前请运行 `tests\validate-release.ps1`，检查 `git status --ignored`，并确认浏览器 Profile、`outputs/`、logs、reports、真实共享链接和 `.env` 文件没有被 Git 跟踪。

## 文档

- [英文 README](README.md)
- [项目详细说明](docs/project-details.md)
- [手动测试清单](docs/manual-test-checklist.md)
- [发布检查清单](docs/publishing-checklist.md)
- [安全策略](SECURITY.md)
- [贡献指南](CONTRIBUTING.md)
- [变更日志](CHANGELOG.md)

## 安全

不要提交或公开发布 browser profiles、cookies、session storage、local storage、`outputs/`、logs、reports、真实 shared links、账号标识、附件路径或 `.env` 文件。这些内容可能暴露 ChatGPT 登录态、对话元数据、项目名称、文件名、本机路径或共享链接。

安全联系邮箱：andyxu3076@gmail.com

安全问题报告方式和数据处理建议见 [SECURITY.md](SECURITY.md)。

## 许可证

MIT License.
