# ChatGPT Shared Link Migration

一个面向 Windows 的 ChatGPT 双账号迁移辅助工具。它使用本机浏览器登录态，在 A 账号中批量创建共享链接，再让 B 账号逐条打开共享链接并发送一条确认消息，从而在 B 账号历史中生成对话副本；随后可按项目名创建/匹配 B 账号项目，并把导入后的聊天移动回对应项目。

> 免责声明：本项目不是 OpenAI 官方工具，依赖 ChatGPT Web 页面和内部接口，接口可能随时变化。请先用少量非敏感对话测试，确认行为符合预期后再扩大范围。

## 主要功能

- 批量读取 A 账号普通对话、归档对话和项目对话。
- 为 A 账号对话创建匿名共享链接，并导出 JSON/CSV 报告。
- 尽量识别对话所属项目，并导出项目清单和项目附件元数据。
- 可选下载 A 账号项目附件到本机，供后续转移。
- 使用 B 账号专用浏览器 profile 打开共享链接并发送触发消息。
- 基于历史报告和 B 账号当前列表做重复记录检测。
- 在 B 账号中创建缺失项目、移动已导入聊天，并可上传项目附件。
- 提供本地 HTML 手动导航工具作为自动导入失败时的回退方案。

## 项目结构

```text
.
├── account-a-create-share-links.js          # 手动在 A 账号 Console 运行的简化脚本
├── account-a-create-share-links-cdp.js      # 自动导出时注入到 ChatGPT 页面的脚本
├── b-open-shared-links.html                 # 手动打开共享链接的本地导航页
├── run-account-a-share-link-export.ps1      # A 账号导出共享链接和项目附件
├── run-account-b-shared-link-import.ps1     # B 账号导入共享链接并生成副本
├── run-account-b-restore-projects.ps1       # B 账号项目创建、聊天移动和附件转移
├── run-full-shared-link-migration.ps1       # A 导出 + B 导入的串联入口
├── examples/                                # 可公开的示例输入
├── tests/                                   # 发布前静态验证脚本
├── docs/                                    # 手动测试和发布检查文档
├── .gitignore
├── CHANGELOG.md
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

以下目录会由运行过程生成，默认已在 `.gitignore` 中排除，不能提交到公开仓库：

```text
browser-profile-account-a/
browser-profile-account-b/
outputs/
archived-launchers/
```

## 环境要求

- Windows 10/11。
- PowerShell 5.1 或 PowerShell 7+。
- Microsoft Edge 或 Google Chrome。
- 可正常访问 `https://chatgpt.com` 的网络环境。
- A、B 两个 ChatGPT 账号，需要在脚本启动的专用浏览器窗口中分别登录。

本项目不需要 Node.js、Python 包或第三方 PowerShell 模块。测试脚本会在检测到 Node.js 时额外执行 JavaScript 语法检查；没有 Node.js 时会跳过这一步。

## 安装

```powershell
git clone https://github.com/<your-org-or-user>/chatgpt-shared-link-migration.git
cd chatgpt-shared-link-migration
```

如果 PowerShell 执行策略阻止本地脚本，可在当前终端临时绕过：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -SelfTest -NoPause
```

## 配置说明

项目没有 `.env` 配置需求，也不需要保存 API key、token、cookie 或密码。脚本通过本机浏览器的 ChatGPT 登录态访问同源接口。

脚本会读取当前 Windows 用户代理设置，并把代理参数传给专用浏览器窗口；它不会关闭、停止或修改 VPN/代理客户端。

常用参数：

| 参数 | 适用脚本 | 说明 |
| --- | --- | --- |
| `-SelfTest` | A 导出、B 导入 | 只检查浏览器/CDP/登录态，不创建共享链接、不发送消息 |
| `-DryRun` | A 导出、B 导入、项目还原 | 预演流程，不执行真实写入 |
| `-Limit <n>` | 分步脚本 | 限制处理数量，适合小批量测试 |
| `-Skip <n>` | 分步脚本 | 跳过前 n 条 |
| `-SkipProjectFiles` | A 导出、项目还原 | 跳过项目附件下载或上传 |
| `-AssumeYes` | B 导入、项目还原 | 跳过交互确认，适合明确知道后果的自动化运行 |
| `-AllowDuplicates` | B 导入、全流程 | 允许重复导入已出现的记录 |
| `-NoPause` | 所有 PowerShell 入口 | 结束后不等待 Enter |

## 使用方法

建议先做自检和小批量 dry run，再执行真实迁移。

### 1. A 账号导出自检

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -SelfTest -NoPause
```

脚本会打开专用浏览器窗口。如果未登录，请在该窗口登录 A 账号后继续。

### 2. A 账号小批量导出

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -Limit 3 -SkipProjectFiles -NoPause
```

输出会写入 `outputs/`，包括共享链接 JSON/CSV。

### 3. B 账号导入 dry run

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -DryRun -Limit 3 -NoPause
```

### 4. B 账号真实导入小批量

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -Limit 3 -NoPause
```

脚本会要求输入 `YES` 后才会逐条打开共享链接并发送触发消息：

```text
请基于这个共享对话继续。请只回复：已接收。
```

### 5. 项目归属还原

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-restore-projects.ps1 -DryRun -NoPause
powershell -ExecutionPolicy Bypass -File .\run-account-b-restore-projects.ps1 -NoPause
```

### 6. 全流程入口

```powershell
powershell -ExecutionPolicy Bypass -File .\run-full-shared-link-migration.ps1 -ExportLimit 3 -ImportLimit 3 -NoPause
```

## 示例输入输出

示例输入见 `examples/account-a-export.sample.json`。真实 A 账号导出 JSON 的核心结构如下：

```json
{
  "schema": "chatgpt-shared-link-migration-v2",
  "projects": [
    {
      "id": "g-p-example",
      "name": "Example Project",
      "files": []
    }
  ],
  "results": [
    {
      "status": "ok",
      "id": "source-conversation-id",
      "title": "Example conversation",
      "project_name": "Example Project",
      "share_url": "https://chatgpt.com/share/example-share-id"
    }
  ]
}
```

B 账号导入报告会包含 `status`、`share_url`、`imported_url`、`duplicate_reason`、`error` 等字段。项目还原报告会额外包含项目创建结果、聊天移动结果和附件上传结果。

## 测试与验证

运行发布前静态检查：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\validate-release.ps1
```

该检查会验证：

- PowerShell 脚本语法。
- JavaScript 文件语法（如果本机有 Node.js）。
- HTML 手动工具是否包含共享链接域名校验。
- `.gitignore` 是否排除浏览器 profile、输出目录和本地敏感配置。
- README 和发布文件中是否残留本机用户绝对路径。

真实迁移属于浏览器自动化流程，无法完全脱离账号登录态做自动化单元测试。发布前请按 `docs/manual-test-checklist.md` 做一次 1 到 3 条对话的小批量验证。

## 安全说明

- 不要提交 `browser-profile-account-a/`、`browser-profile-account-b/`、`outputs/` 或任何真实导出报告。
- 浏览器 profile 可能包含 cookie、登录态、本地存储、浏览历史和扩展数据。
- `outputs/` 可能包含共享链接、聊天标题、项目名、附件路径和调试日志。
- 共享链接不是私密备份；任何拿到链接的人都可能看到对应对话快照。
- 如果迁移完成后不再需要共享链接，请到 ChatGPT 的 shared links 管理页删除。
- 不要在第三方网站或陌生脚本中粘贴 ChatGPT token。
- 本项目的 B 账号导入脚本只接受 `https://chatgpt.com/share/` 和 `https://chat.openai.com/share/` 链接。

## 常见问题

### 这个工具会合并两个账号吗？

不会。它只是借助共享链接在 B 账号里生成对话副本。原始 message id、时间线、记忆、文件库、GPTs、订阅、部分项目元数据都不能保证一比一迁移。

### 为什么要用专用浏览器 profile？

专用 profile 可以把 A、B 账号登录态隔离开，避免在同一个浏览器窗口频繁切换账号。

### B 账号没有出现副本怎么办？

先停止批量执行。可能是 ChatGPT 共享链接页面当前没有开放“继续此对话”入口，或该入口对账号/地区/版本不可用。此时可以使用 `b-open-shared-links.html` 手动验证，或改为本地归档/手动迁移重要对话。

### 可以在 macOS/Linux 上运行吗？

当前 PowerShell 脚本按 Windows 浏览器路径、Windows 代理设置和本地路径习惯编写。macOS/Linux 未适配。

### 是否需要 `.env.example`？

不需要。项目不读取环境变量，也不要求用户保存凭据。真实敏感状态只存在于本机浏览器 profile 中，并已通过 `.gitignore` 排除。

## 许可证

本项目使用 MIT License，见 `LICENSE`。

MIT 适合这类个人自动化工具：允许别人使用、修改、分发和商用，限制较少，同时保留免责声明。

## 维护状态

当前维护状态：实验性维护。由于 ChatGPT Web 内部接口可能变化，建议每次大批量迁移前先运行 `-SelfTest` 和小批量 `-Limit` 测试。
