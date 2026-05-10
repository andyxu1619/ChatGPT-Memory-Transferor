# ChatGPT Memory Transferor

[English](README.md) | [中文](README.zh-CN.md)

ChatGPT Memory Transferor 是一个实验性的 Windows 工具包，用于通过 ChatGPT 共享链接和浏览器自动化，把一个 ChatGPT 账号中的对话复制到另一个账号。它也提供项目归属和项目附件还原辅助能力，前提是源账号导出结果中包含项目元数据。

本项目不是 OpenAI 或 ChatGPT 官方迁移 API。它依赖本机浏览器登录态、ChatGPT Web 页面行为和共享链接机制。

## 它能做什么

- 在源账号中为可迁移对话创建共享链接。
- 在目标账号专用浏览器 Profile 中打开共享链接并生成对话副本。
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
- 带重复检测的导入报告。
- 用于手动检查共享链接输入的本地 HTML 工具。
- 用于公开发布前检查的 release validation 脚本。

## 环境要求

- Windows。
- PowerShell。
- Chrome 或 Edge。
- 两个 ChatGPT 账号。
- Git，可选；仅在 clone 或参与贡献时需要。

## 快速开始

```powershell
git clone https://github.com/example-user/ChatGPT-Memory-Transferor.git
cd ChatGPT-Memory-Transferor
powershell -ExecutionPolicy Bypass -File .\tests\validate-release.ps1
```

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
