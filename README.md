# ChatGPT Shared Link Migration

Windows-first helper scripts for migrating ChatGPT conversations, project membership, and project attachments between two ChatGPT accounts by using the ChatGPT web app, browser login state, shared links, and same-origin page APIs.

> Disclaimer: this is not an official OpenAI tool. It depends on ChatGPT Web behavior and internal endpoints that can change without notice. Always test with a small, non-sensitive batch before running a larger migration.

Languages:

- [中文说明](#中文说明)
- [English Documentation](#english-documentation)

---

## 中文说明

### 项目定位

本项目用于辅助把 ChatGPT A 账号中的对话和项目结构迁移到 B 账号。它不会读取或保存账号密码，也不需要 OpenAI API Key。脚本会启动隔离的浏览器 Profile，让用户在浏览器中自行登录 ChatGPT，然后通过浏览器当前登录态执行自动化操作。

核心目标是：

- 在 A 账号中批量发现普通对话、归档对话、项目对话和项目清单。
- 为可迁移对话创建 ChatGPT 共享链接，并导出 JSON/CSV 报告。
- 记录项目元数据和项目附件元数据，可选把 A 账号项目附件下载到本机。
- 在 B 账号中逐条打开共享链接并发送一条迁移触发消息，让 B 账号生成对话副本。
- 检查本机历史报告和 B 账号当前聊天列表，降低重复导入概率。
- 在 B 账号中匹配或创建项目，把已导入聊天移回对应项目，并可重新上传项目附件。
- 提供可双击的一键完整迁移命令，把 A 导出、B 导入、项目还原三段串起来。
- 在自动导入不可用时，提供本地 HTML 手动导航工具。

### 能迁移什么

| 类型 | 支持情况 | 说明 |
| --- | --- | --- |
| 普通聊天 | 支持 | 通过 A 账号共享链接，在 B 账号中继续对话生成副本。 |
| 归档聊天 | 尽力支持 | 能否列出取决于当前 ChatGPT Web 接口返回。 |
| 项目聊天 | 支持 | 先按共享链接导入，再用项目还原脚本移动到 B 账号项目。 |
| 空项目 | 支持 | A 导出报告中的 `projects` 可用于在 B 账号创建没有聊天的项目。 |
| 项目附件 | 支持但需验证 | A 侧可下载到 `outputs/project-files/account-a/`，B 侧可重新上传并绑定到项目。 |
| 项目名称、说明、图标、提示开头等元数据 | 尽力支持 | 取决于 ChatGPT 当前返回字段和目标账号权限。 |

### 不能保证迁移什么

本工具不是账号合并工具，不能保证迁移以下内容：

- 原始消息 ID、原始创建时间、完整时间线和系统内部状态。
- ChatGPT Memory、账号设置、订阅、Teams/Enterprise 权限、GPTs、插件或连接器。
- 文件库全局状态、不可下载附件、已失效附件、需要特殊权限的附件。
- 对话分享快照之外的隐藏状态，例如某些工具调用上下文。
- ChatGPT Web 改版后发生变化的入口、接口和字段。

### 工作原理

迁移链路分三段，建议按顺序执行。

1. A 账号导出

   `run-account-a-share-link-export.ps1` 启动 `browser-profile-account-a/`，固定使用 DevTools 端口 `9227`。用户在该窗口登录 A 账号后，脚本把 `account-a-create-share-links-cdp.js` 注入 ChatGPT 页面，列出对话、创建共享链接、识别项目，并输出报告。未指定 `-SkipProjectFiles` 时，还会尝试下载项目附件。

2. B 账号导入

   `run-account-b-shared-link-import.ps1` 启动 `browser-profile-account-b/`，默认使用 DevTools 端口 `9228`。用户在该窗口登录 B 账号后，脚本读取 A 导出 JSON，逐条打开 `https://chatgpt.com/share/...` 共享链接，并发送触发消息。只有页面进入 B 账号自己的 `/c/{id}` 对话 URL 后，才会把该条记录标记为 `imported`。

3. B 账号项目还原

   `run-account-b-restore-projects.ps1` 读取 B 导入报告和源项目清单，在 B 账号中匹配或创建项目，再通过 ChatGPT 页面同源接口移动已导入聊天。未指定 `-SkipProjectFiles` 时，会把 A 导出阶段已下载的项目附件重新上传并绑定到目标项目。

手动回退路径：

- `b-open-shared-links.html` 可在浏览器本地打开，加载 A 导出 JSON 后逐条打开共享链接，适合自动点击或自动发送不可用时使用。
- `account-a-create-share-links.js` 是可在 A 账号页面 Console 中手动运行的简化导出脚本，主要用于调试或应急。

一键完整迁移入口：

- `run-account-a-to-b-full-sync.cmd` 是项目根目录里的双击入口，适合已经完成小批量验证、并确认 A/B 两个专用浏览器 Profile 都已登录后的完整迁移。
- 它先调用 `run-full-shared-link-migration.ps1 -AssumeYes -NoPause`，完成 A 账号导出和 B 账号共享链接导入；然后调用 `run-account-b-restore-projects.ps1 -AssumeYes -NoPause`，继续还原项目、移动聊天并上传项目附件。
- 它使用自身所在目录作为项目根目录，因此可以从资源管理器双击运行，也可以从命令行运行；报告、CSV 和日志仍写入同一个 `outputs/` 目录。
- 任一阶段失败时命令会停下并保留窗口，方便查看错误；不会静默跳过失败继续执行后续阶段。

### 环境要求

- Windows 10/11。
- Windows PowerShell 5.1 或 PowerShell 7+。
- Microsoft Edge 或 Google Chrome。
- 当前网络环境可以访问 `https://chatgpt.com`。
- A、B 两个 ChatGPT 账号，并能在脚本启动的专用浏览器窗口中分别登录。
- Node.js 不是运行迁移的必需项；如果本机有 Node.js，发布验证脚本会额外执行 JavaScript 语法检查。

本项目默认不需要安装 npm 包、Python 包或第三方 PowerShell 模块。

### 网络和代理行为

脚本会读取当前 Windows 用户的 Internet Settings 代理配置，并把代理参数传给专用 Edge/Chrome 窗口。它不会关闭、停止或修改 VPN/代理客户端。

重要约束：

- 不要关闭 Upnet/VPN，除非你明确知道当前网络不再需要它。
- 如果系统代理已开启，脚本会传入 `--proxy-server`。
- 脚本会把 `localhost`、`127.0.0.1`、`::1` 放入浏览器代理绕过列表，以便本机 DevTools 通信正常工作。
- 如果 ChatGPT 当前网络不可用，先验证浏览器专用窗口能否打开 `https://chatgpt.com`。

### 安装

```powershell
git clone https://github.com/<your-org-or-user>/chatgpt-shared-link-migration.git
cd chatgpt-shared-link-migration
```

如果 PowerShell 执行策略阻止脚本，可在单次命令中临时绕过：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\validate-release.ps1
```

### 项目结构

```text
.
├── account-a-create-share-links.js          # A 账号 Console 手动脚本
├── account-a-create-share-links-cdp.js      # A 账号自动导出注入脚本
├── b-open-shared-links.html                 # B 账号手动打开共享链接的本地工具
├── run-account-a-share-link-export.ps1      # A 账号导出共享链接、项目和附件
├── run-account-b-shared-link-import.ps1     # B 账号导入共享链接并生成对话副本
├── run-account-b-restore-projects.ps1       # B 账号项目创建、聊天移动和附件转移
├── run-full-shared-link-migration.ps1       # A 导出 + B 聊天导入串联入口
├── run-account-a-to-b-full-sync.cmd         # 双击执行完整 A 到 B 迁移
├── docs/
│   ├── manual-test-checklist.md             # 发布/改动后的手动验证清单
│   └── publishing-checklist.md              # GitHub 发布检查清单
├── examples/
│   └── account-a-export.sample.json         # 可公开示例输入
├── tests/
│   └── validate-release.ps1                 # 静态发布验证
├── CHANGELOG.md
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

运行时会生成以下本地目录，这些目录默认已被 `.gitignore` 排除，不应提交到公开仓库：

```text
browser-profile-account-a/
browser-profile-account-b/
outputs/
archived-launchers/
downloads/
tmp/
temp/
```

### 推荐迁移流程

先使用 1 到 3 条非敏感对话做全链路试跑，再扩大范围。

#### 1. 发布/语法检查

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\validate-release.ps1
```

该检查会验证：

- PowerShell 脚本语法。
- JavaScript 语法，如果本机存在 Node.js。
- 手动 HTML 工具是否校验 ChatGPT 共享链接域名。
- `.gitignore` 是否排除本地 Profile、输出报告和敏感配置。
- 可发布文件中是否残留本机用户路径。

#### 2. A 账号自检

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -SelfTest -NoPause
```

预期行为：

- 打开 A 账号专用浏览器窗口。
- 如果未登录，需要在该窗口登录 A 账号。
- 验证 DevTools 注入通道、ChatGPT 登录态和只读对话接口。
- 不创建共享链接，不写入 `outputs/`。

#### 3. A 账号小批量导出

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -Limit 3 -SkipProjectFiles -NoPause
```

建议第一次加 `-SkipProjectFiles`，先验证共享链接和项目元数据是否正常。确认后再去掉该参数下载附件：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -Limit 3 -NoPause
```

输出示例：

```text
outputs/chatgpt-account-a-share-links-with-projects_yyyy-MM-dd_HH-mm-ss.json
outputs/chatgpt-account-a-share-links-with-projects_yyyy-MM-dd_HH-mm-ss.csv
outputs/project-files/account-a/<project-name--project-id>/
```

#### 4. B 账号自检

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -SelfTest -NoPause
```

预期行为：

- 打开 B 账号专用浏览器窗口。
- 如果未登录，需要在该窗口登录 B 账号。
- 验证 DevTools 注入通道和登录态。
- 不打开共享链接，不发送触发消息。

#### 5. B 账号导入 Dry Run

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -DryRun -Limit 3 -NoPause
```

Dry run 会读取 A 导出 JSON、做输入校验、生成报告，但不会打开共享链接并发送消息。

如果需要指定输入文件：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -InputJson .\outputs\<account-a-export>.json -DryRun -Limit 3 -NoPause
```

#### 6. B 账号真实导入小批量

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -Limit 3 -NoPause
```

默认触发消息为：

```text
请基于这个共享对话继续。请只回复：已接收。
```

真实导入前脚本会要求输入 `YES`。如果需要自定义触发消息：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -Limit 3 -Prompt "请继续这个共享对话，并只回复：已接收。" -NoPause
```

输出示例：

```text
outputs/chatgpt-account-b-import-report_yyyy-MM-dd_HH-mm-ss.json
outputs/chatgpt-account-b-import-report_yyyy-MM-dd_HH-mm-ss.csv
```

#### 7. B 账号项目归属和附件还原

先 dry run：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-restore-projects.ps1 -DryRun -NoPause
```

确认 dry run 报告后真实执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-restore-projects.ps1 -NoPause
```

如果只想还原项目和聊天归属，暂时跳过附件上传：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-restore-projects.ps1 -SkipProjectFiles -NoPause
```

输出示例：

```text
outputs/chatgpt-account-b-project-restore-report_yyyy-MM-dd_HH-mm-ss.json
outputs/chatgpt-account-b-project-restore-report_yyyy-MM-dd_HH-mm-ss.csv
outputs/chatgpt-account-b-project-restore-projects_yyyy-MM-dd_HH-mm-ss.csv
outputs/chatgpt-account-b-project-restore-attachments_yyyy-MM-dd_HH-mm-ss.csv
```

#### 8. 串联入口

`run-full-shared-link-migration.ps1` 只串联 A 导出和 B 聊天导入，不会自动执行项目还原。完成后仍建议运行 `run-account-b-restore-projects.ps1`。

```powershell
powershell -ExecutionPolicy Bypass -File .\run-full-shared-link-migration.ps1 -ExportLimit 3 -ImportLimit 3 -NoPause
```

如果已经有 A 导出 JSON，可跳过导出并使用 `outputs/` 中最新可用文件：

```powershell
powershell -ExecutionPolicy Bypass -File .\run-full-shared-link-migration.ps1 -SkipExport -ImportLimit 3 -NoPause
```

如果 A 导出 JSON 没有可导入 `share_url`，但包含 `projects`，串联入口会跳过 B 聊天导入；之后可直接运行项目还原脚本来创建空项目或转移附件。

#### 9. 双击一键完整迁移

项目根目录提供 `run-account-a-to-b-full-sync.cmd`。它是面向日常使用的一键入口，不替代分步验证流程；建议先按前面的自检、dry run 和小批量导入确认流程正常，再用它跑完整迁移。

双击后会连续执行：

1. A 账号创建共享链接、导出项目元数据，并下载项目附件。
2. B 账号打开共享链接并生成对话副本。
3. B 账号匹配或创建项目，把已导入聊天移回项目，并上传已下载的项目附件。

等价命令：

```cmd
run-account-a-to-b-full-sync.cmd
```

执行前请确认：

- A 账号专用浏览器 Profile `browser-profile-account-a/` 已登录 A 账号。
- B 账号专用浏览器 Profile `browser-profile-account-b/` 已登录 B 账号。
- 当前 Windows 网络可以打开 `https://chatgpt.com`。
- 你接受真实执行，不再需要每个写入阶段手动输入 `YES`，因为该入口会传入 `-AssumeYes -NoPause`。

这个命令会沿用当前 Windows 代理设置，不会关闭 Upnet/VPN。报告、CSV 和附件处理结果仍输出到 `outputs/`。如果任一阶段失败，窗口会停在错误位置并提示查看 `outputs/`。

### 脚本参数参考

#### `run-account-a-share-link-export.ps1`

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-SelfTest` | 关闭 | 只检查浏览器、DevTools、登录态和只读接口，不创建共享链接。 |
| `-DryRun` | 关闭 | 预演导出逻辑，报告文件名带 `dry-run_`，并跳过附件下载。 |
| `-SkipProjectFiles` | 关闭 | 跳过 A 账号项目附件下载，只导出 JSON/CSV。 |
| `-Skip <n>` | `0` | 跳过前 n 条对话。 |
| `-Limit <n>` | `0` | 限制处理数量；`0` 表示不限制。 |
| `-NoPause` | 关闭 | 脚本结束时不等待 Enter。 |

固定本地资源：

- Profile：`browser-profile-account-a/`
- DevTools 端口：`9227`
- 输出目录：`outputs/`

#### `run-account-b-shared-link-import.ps1`

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-InputJson <path>` | 自动查找 | 指定 A 导出 JSON；未指定时从 `outputs/` 查找最新可用 A 导出文件。 |
| `-SelfTest` | 关闭 | 只检查 B 账号浏览器和登录态，不导入。 |
| `-DryRun` | 关闭 | 生成 dry-run 报告，不打开共享链接、不发送触发消息。 |
| `-Skip <n>` | `0` | 跳过前 n 条可导入链接。 |
| `-Limit <n>` | `0` | 限制处理数量；`0` 表示不限制。 |
| `-Prompt <text>` | `请基于这个共享对话继续。请只回复：已接收。` | 导入时发送到共享链接会话中的触发消息。 |
| `-Port <n>` | `9228` | B 账号专用浏览器 DevTools 端口。 |
| `-AssumeYes` | 关闭 | 跳过真实导入前的 `YES` 确认。 |
| `-AllowDuplicates` | 关闭 | 允许重复导入，不根据历史报告和 B 账号聊天列表跳过。 |
| `-NoPause` | 关闭 | 脚本结束时不等待 Enter。 |

固定本地资源：

- Profile：`browser-profile-account-b/`
- 默认 DevTools 端口：`9228`
- 输出目录：`outputs/`

#### `run-account-b-restore-projects.ps1`

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-InputJson <path>` | 自动查找 | 指定 B 导入报告或 A 导出 JSON；未指定时从 `outputs/` 查找最新可用报告。 |
| `-DryRun` | 关闭 | 只报告将创建的项目、将移动的聊天和将处理的附件，不写入。 |
| `-SkipProjectFiles` | 关闭 | 跳过附件上传/绑定，只执行项目和聊天归属还原。 |
| `-Skip <n>` | `0` | 跳过前 n 条待还原聊天。 |
| `-Limit <n>` | `0` | 限制待还原聊天数量；`0` 表示不限制。 |
| `-Port <n>` | `9228` | B 账号专用浏览器 DevTools 端口。 |
| `-AssumeYes` | 关闭 | 跳过真实还原前的 `YES` 确认。 |
| `-NoPause` | 关闭 | 脚本结束时不等待 Enter。 |

#### `run-full-shared-link-migration.ps1`

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-SkipExport` | 关闭 | 跳过 A 导出，使用 `outputs/` 中最新可用 A 导出 JSON。 |
| `-DryRunImport` | 关闭 | B 导入阶段使用 dry run。 |
| `-ExportLimit <n>` | `0` | A 导出阶段数量限制。 |
| `-ExportSkip <n>` | `0` | A 导出阶段跳过数量。 |
| `-ImportLimit <n>` | `0` | B 导入阶段数量限制。 |
| `-ImportSkip <n>` | `0` | B 导入阶段跳过数量。 |
| `-AssumeYes` | 关闭 | 传给 B 导入阶段，跳过确认。 |
| `-AllowDuplicates` | 关闭 | 传给 B 导入阶段，允许重复导入。 |
| `-NoPause` | 关闭 | 脚本结束时不等待 Enter。 |

#### `run-account-a-to-b-full-sync.cmd`

| 项目 | 行为 |
| --- | --- |
| 启动方式 | 在项目根目录双击，或从命令行运行 `run-account-a-to-b-full-sync.cmd`。 |
| 执行阶段 | 先运行 `run-full-shared-link-migration.ps1`，再运行 `run-account-b-restore-projects.ps1`。 |
| 默认确认 | 自动传入 `-AssumeYes -NoPause`，适合已经验证过流程后的完整迁移。 |
| 输出位置 | 所有报告、CSV、附件下载和错误线索仍在 `outputs/`。 |
| 失败行为 | 任一阶段返回错误时立即停止，并保留窗口给用户查看错误。 |
| 代理/VPN | 沿用当前 Windows 代理设置，不关闭、不停止、不修改 Upnet/VPN。 |
| 自检 | 设置 `GPTSYNC_CMD_SELFTEST=1` 后运行，可只检查入口路径解析而不执行迁移。 |

### 报告和数据结构

#### A 导出报告

文件名：

```text
outputs/chatgpt-account-a-share-links-with-projects_yyyy-MM-dd_HH-mm-ss.json
outputs/chatgpt-account-a-share-links-with-projects_yyyy-MM-dd_HH-mm-ss.csv
outputs/chatgpt-account-a-dry-run_share-links-with-projects_yyyy-MM-dd_HH-mm-ss.json
outputs/chatgpt-account-a-dry-run_share-links-with-projects_yyyy-MM-dd_HH-mm-ss.csv
```

核心 JSON 字段：

| 字段 | 说明 |
| --- | --- |
| `schema` | 当前导出结构版本，例如 `chatgpt-shared-link-migration-v2`。 |
| `generated_at` | 报告生成时间。 |
| `config` | 本次运行配置，如 `dryRun`、`maxConversations`。 |
| `summary` | 数量汇总，包括成功、失败、项目发现、附件下载等。 |
| `projects` | A 账号源项目清单，可用于 B 账号项目还原。 |
| `results` | 每条对话的导出结果。 |

`results[]` 常见字段：

| 字段 | 说明 |
| --- | --- |
| `status` | `ok`、`dry-run` 或 `error` 等状态。 |
| `id` | A 账号源对话 ID。 |
| `title` | 对话标题。 |
| `source` | 对话来源分类，例如 visible/archive/project 等。 |
| `project_name` | 源项目名称；未归属时可能为空或为占位值。 |
| `project_id` | 源项目 ID。 |
| `project_source` | 项目归属识别来源。 |
| `share_id` | 共享链接 ID。 |
| `share_url` | 可导入的 ChatGPT 共享链接。 |
| `error` | 失败原因。 |

`projects[]` 常见字段：

| 字段 | 说明 |
| --- | --- |
| `id` | A 账号项目 ID。 |
| `name` | 项目名称。 |
| `description` | 项目说明。 |
| `instructions` | 项目指令，取决于接口返回。 |
| `emoji` / `theme` | 项目显示信息，取决于接口返回。 |
| `prompt_starters` | 项目提示开头。 |
| `files` | 项目附件清单。 |
| `file_count` | 项目附件数量。 |
| `mapped_conversation_count` | 识别到属于该项目的对话数量。 |

附件字段：

| 字段 | 说明 |
| --- | --- |
| `file_id` / `id` | A 账号附件 ID。 |
| `name` | 附件名。 |
| `size` | 附件大小。 |
| `local_path` | 下载到本机后的路径。 |
| `download_status` | `downloaded`、`already_downloaded`、`error` 等。 |
| `download_error` | 下载失败原因。 |

#### B 导入报告

文件名：

```text
outputs/chatgpt-account-b-import-report_yyyy-MM-dd_HH-mm-ss.json
outputs/chatgpt-account-b-import-report_yyyy-MM-dd_HH-mm-ss.csv
outputs/chatgpt-account-b-dry-run_import-report_yyyy-MM-dd_HH-mm-ss.json
outputs/chatgpt-account-b-dry-run_import-report_yyyy-MM-dd_HH-mm-ss.csv
```

核心 JSON 字段：

| 字段 | 说明 |
| --- | --- |
| `schema` | 当前导入结构版本，例如 `chatgpt-shared-link-import-v1`。 |
| `source_json` | 本次读取的 A 导出 JSON 路径。 |
| `source_projects` | 从 A 导出 JSON 传递过来的源项目清单。 |
| `config` | 导入配置，包括 prompt、延迟和重复检测设置。 |
| `summary` | 导入成功、dry run、重复、失败等汇总。 |
| `results` | 每条共享链接的导入结果。 |

`results[]` 常见状态：

| 状态 | 含义 |
| --- | --- |
| `imported` | 已发送触发消息，并确认进入 B 账号 `/c/{id}` 对话页。 |
| `dry-run` | Dry run 记录，未执行真实导入。 |
| `duplicate` | 已确认重复，已跳过。 |
| `duplicate_suspected` | 疑似重复，默认跳过以降低重复导入风险。 |
| `error` | 导入失败，查看 `error` 和 `imported_url`。 |

#### B 项目还原报告

文件名：

```text
outputs/chatgpt-account-b-project-restore-report_yyyy-MM-dd_HH-mm-ss.json
outputs/chatgpt-account-b-project-restore-report_yyyy-MM-dd_HH-mm-ss.csv
outputs/chatgpt-account-b-project-restore-projects_yyyy-MM-dd_HH-mm-ss.csv
outputs/chatgpt-account-b-project-restore-attachments_yyyy-MM-dd_HH-mm-ss.csv
```

核心 JSON 字段：

| 字段 | 说明 |
| --- | --- |
| `schema` | 当前项目还原结构版本，例如 `chatgpt-project-restore-v1`。 |
| `source_json` | 输入报告路径。 |
| `summary` | 项目创建、聊天移动、附件上传的汇总。 |
| `source_projects` | 待还原的源项目清单。 |
| `project_results` | 每个项目的匹配/创建结果。 |
| `project_map` | A 项目 ID 到 B 项目 ID 的映射。 |
| `results` | 每条聊天移动结果。 |
| `attachment_results` | 每个附件上传/绑定结果。 |

聊天还原状态：

| 状态 | 含义 |
| --- | --- |
| `restored` | 已移动到目标项目，且验证成功。 |
| `already_in_project` | 已经在目标项目中。 |
| `dry_run` | Dry run 记录，未移动。 |
| `missing_project` | 找不到目标项目。 |
| `verify_failed` | 写入完成但复查不一致。 |
| `error` | 还原失败。 |

项目状态：

| 状态 | 含义 |
| --- | --- |
| `exists` | B 账号中已存在同名项目。 |
| `created` | 已在 B 账号创建项目。 |
| `would_create` | Dry run 中将会创建。 |
| `create_error` | 项目创建失败。 |

附件状态：

| 状态 | 含义 |
| --- | --- |
| `uploaded` | 已上传并绑定到目标项目。 |
| `already_in_project` | 目标项目中已存在匹配附件。 |
| `dry_run` | Dry run 记录，未上传。 |
| `missing_local_file` | A 侧附件未下载到本机，无法上传。 |
| `missing_target_project` | 找不到 B 侧目标项目。 |
| `verify_failed` | 上传/绑定后复查未通过。 |
| `error` | 附件处理失败。 |

### 示例输入

`examples/account-a-export.sample.json` 提供可公开提交的示例结构。真实 A 导出 JSON 的最小可用结构类似：

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
      "project_id": "g-p-example",
      "share_url": "https://chatgpt.com/share/example-share-id"
    }
  ]
}
```

### 手动 HTML 回退工具

当自动导入无法点击共享链接页面中的继续入口，或 ChatGPT 页面结构发生变化时，可以使用 `b-open-shared-links.html`：

1. 确保 B 账号已在浏览器中登录 ChatGPT。
2. 直接打开 `b-open-shared-links.html`。
3. 选择 A 导出的 JSON 文件。
4. 页面会只接受 `https://chatgpt.com/share/...` 或 `https://chat.openai.com/share/...`。
5. 逐条打开链接，在 B 账号页面中手动继续对话。

该工具不会上传文件，也不会保存凭据。

### 安全和隐私

不要提交以下内容：

- `browser-profile-account-a/`
- `browser-profile-account-b/`
- `outputs/`
- 下载下来的项目附件
- 真实共享链接
- 调试日志
- `.env`、本地启动器、临时文件

原因：

- 浏览器 Profile 可能包含 cookie、登录态、本地存储、扩展数据和浏览历史。
- `outputs/` 可能包含对话标题、项目名称、共享链接、附件名、本机路径和错误日志。
- 共享链接不是私密备份；任何拿到链接的人都可能看到对应快照。
- 迁移完成后如不再需要共享链接，建议在 ChatGPT 的共享链接管理页面删除。

### 常见问题

#### 这个工具会合并两个账号吗？

不会。它只是用共享链接在 B 账号里生成对话副本，并尽力恢复项目归属和项目附件。

#### 为什么要用两个独立浏览器 Profile？

A 和 B 账号必须隔离登录态，避免同一个浏览器窗口频繁切换账号导致脚本把操作发到错误账号。A 默认使用 `browser-profile-account-a/` 和端口 `9227`，B 默认使用 `browser-profile-account-b/` 和端口 `9228`。

#### 为什么导入成功必须出现 `/c/{id}`？

共享链接页面本身不是 B 账号中的对话副本。只有发送触发消息后，页面进入 B 账号自己的 `/c/{id}` 对话 URL，才能把该条记录当作可用于后续项目还原的导入结果。

#### 没有 `share_url` 但有 `projects` 怎么办？

这通常表示当前导出中没有可导入聊天，但仍有项目清单。可以跳过 B 聊天导入，直接运行项目还原脚本，用于创建空项目或转移已下载附件。

#### B 导入报告中出现重复怎么办？

默认行为会用历史导入报告和 B 账号聊天列表做重复检测，并跳过确定重复或疑似重复项。如果你明确要重复导入，可使用 `-AllowDuplicates`。

#### 附件出现 `missing_local_file` 怎么办？

说明 B 侧尝试上传附件时，A 导出 JSON 中记录的 `local_path` 不存在。重新运行 A 导出且不要使用 `-SkipProjectFiles`，确认附件已下载到 `outputs/project-files/account-a/` 后再执行项目还原。

#### 可以在 macOS 或 Linux 上运行吗？

当前脚本按 Windows 浏览器路径、Windows 代理设置和 PowerShell 使用习惯编写，未适配 macOS/Linux。

#### 是否需要 `.env`？

不需要。项目不读取 `.env`，也不要求保存 token、cookie、账号密码或 API Key。

#### ChatGPT 页面或接口变化后怎么办？

先停止批量执行，保留最新 `outputs/*.json` 报告。用 `-SelfTest`、`-DryRun` 和 `-Limit 1` 缩小问题范围。如果共享链接页面不再提供继续入口，可使用 HTML 手动工具迁移重要对话。

### 维护和发布

发布或修改行为前建议执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\validate-release.ps1
```

再按 `docs/manual-test-checklist.md` 用 1 到 3 条非敏感对话做手动验证。

维护原则：

- 保持依赖尽量少。
- 不提交浏览器 Profile、真实报告、附件、日志和共享链接。
- 内部接口变化时优先给出清晰错误和小范围 fallback。
- 任何导入成功判断都必须有稳定证据，例如 B 账号 `/c/{id}`。
- 项目迁移的成功标准包括空项目、项目元数据和附件处理，不只包括聊天复制。

### 许可证

本项目使用 MIT License，见 `LICENSE`。

---

## English Documentation

### Purpose

This project helps migrate ChatGPT conversations and project structure from one ChatGPT account to another on Windows. It uses the local browser session instead of account passwords or API keys. The scripts launch isolated browser profiles, you sign in manually, and the automation runs through the authenticated ChatGPT web page.

Primary goals:

- Discover regular, archived, and project conversations in account A.
- Create shared links in account A and export JSON/CSV reports.
- Export project metadata and project-file metadata.
- Optionally download account A project attachments to local `outputs/project-files/account-a/`.
- Open shared links in account B, send a migration prompt, and create account B conversation copies.
- Detect likely duplicates from local reports and account B's visible conversation list.
- Recreate or match projects in account B, move imported conversations back into projects, and optionally re-upload project attachments.
- Provide a double-click full migration launcher that chains account A export, account B import, and project restore.
- Provide a local HTML fallback when automatic import is not available.

### What Is Supported

| Item | Support | Notes |
| --- | --- | --- |
| Regular chats | Supported | Imported through ChatGPT shared links. |
| Archived chats | Best effort | Depends on the current ChatGPT web API response. |
| Project chats | Supported | Import the chat first, then restore project membership. |
| Empty projects | Supported | Source `projects` can create account B projects even without chats. |
| Project attachments | Supported, verify carefully | Download from account A, then upload and bind to account B projects. |
| Project metadata | Best effort | Depends on available fields and target-account permissions. |

### Not Guaranteed

This is not an account-merge tool. It cannot guarantee migration of:

- Original message IDs, exact original timestamps, and internal conversation state.
- ChatGPT Memory, account settings, subscription details, GPTs, plugins, connectors, or organization permissions.
- Global file-library state or files that cannot be downloaded from the source account.
- Hidden state outside the shared-link snapshot.
- Any behavior that changes after ChatGPT Web updates.

### How It Works

The workflow has three main stages.

1. Account A export

   `run-account-a-share-link-export.ps1` launches `browser-profile-account-a/` on DevTools port `9227`. After you sign in to account A, it injects `account-a-create-share-links-cdp.js` into the ChatGPT page, lists conversations, creates shared links, discovers projects, and writes reports. Unless `-SkipProjectFiles` is used, it also tries to download project attachments.

2. Account B import

   `run-account-b-shared-link-import.ps1` launches `browser-profile-account-b/` on DevTools port `9228` by default. After you sign in to account B, it reads account A's export JSON, opens each shared link, and sends a prompt. A row is marked `imported` only after the page reaches an account B `/c/{id}` conversation URL.

3. Account B project restore

   `run-account-b-restore-projects.ps1` reads the account B import report and source project list, matches or creates account B projects, moves imported conversations into those projects, and optionally uploads the downloaded project attachments.

Manual fallback:

- `b-open-shared-links.html` opens an export JSON locally and lets you manually step through shared links.
- `account-a-create-share-links.js` is a simplified script for manual use in the account A browser console.

One-click full migration launcher:

- `run-account-a-to-b-full-sync.cmd` is the double-click entrypoint in the repository root. It is intended for full migrations after you have already completed a small-batch validation and confirmed both dedicated browser profiles are signed in.
- It first calls `run-full-shared-link-migration.ps1 -AssumeYes -NoPause` to run account A export and account B shared-link import. It then calls `run-account-b-restore-projects.ps1 -AssumeYes -NoPause` to restore projects, move imported chats, and upload project attachments.
- It resolves the repository root from its own file location, so it can be launched from File Explorer or a terminal. Reports, CSV files, and logs still go to the same `outputs/` directory.
- If any stage fails, the command stops and keeps the window open so you can inspect the error instead of silently continuing to the next stage.

### Requirements

- Windows 10/11.
- Windows PowerShell 5.1 or PowerShell 7+.
- Microsoft Edge or Google Chrome.
- Network access to `https://chatgpt.com`.
- Two ChatGPT accounts, signed in through the dedicated browser windows.
- Node.js is optional. If available, the release validation script uses it for JavaScript syntax checks.

No npm package, Python package, third-party PowerShell module, API key, or `.env` file is required for normal migration.

### Network And Proxy Behavior

The scripts read the current Windows user proxy settings and pass them to the dedicated browser window. They do not stop, close, or modify VPN/proxy clients.

Operational notes:

- Do not close Upnet/VPN unless you intentionally no longer need it.
- If a system proxy is enabled, the browser receives a `--proxy-server` argument.
- `localhost`, `127.0.0.1`, and `::1` are placed in the browser proxy bypass list so local DevTools communication still works.
- If migration fails at network startup, first confirm the dedicated browser window can open `https://chatgpt.com`.

### Installation

```powershell
git clone https://github.com/<your-org-or-user>/chatgpt-shared-link-migration.git
cd chatgpt-shared-link-migration
```

Run scripts with a temporary execution-policy bypass when needed:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\validate-release.ps1
```

### Repository Layout

```text
.
├── account-a-create-share-links.js
├── account-a-create-share-links-cdp.js
├── b-open-shared-links.html
├── run-account-a-share-link-export.ps1
├── run-account-b-shared-link-import.ps1
├── run-account-b-restore-projects.ps1
├── run-full-shared-link-migration.ps1
├── run-account-a-to-b-full-sync.cmd
├── docs/
├── examples/
├── tests/
├── CHANGELOG.md
├── CONTRIBUTING.md
├── LICENSE
└── README.md
```

Generated local directories are ignored by Git and must not be published:

```text
browser-profile-account-a/
browser-profile-account-b/
outputs/
archived-launchers/
downloads/
tmp/
temp/
```

### Recommended Workflow

Start with 1 to 3 non-sensitive conversations before running a larger migration.

1. Validate the repository:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\tests\validate-release.ps1
   ```

2. Self-test account A:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -SelfTest -NoPause
   ```

3. Export a small account A batch:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -Limit 3 -SkipProjectFiles -NoPause
   ```

   Re-run without `-SkipProjectFiles` when you are ready to download project attachments.

4. Self-test account B:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -SelfTest -NoPause
   ```

5. Dry-run account B import:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -DryRun -Limit 3 -NoPause
   ```

6. Run a real account B import:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -Limit 3 -NoPause
   ```

7. Dry-run and then run project restore:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\run-account-b-restore-projects.ps1 -DryRun -NoPause
   powershell -ExecutionPolicy Bypass -File .\run-account-b-restore-projects.ps1 -NoPause
   ```

8. Optional combined export/import entrypoint:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\run-full-shared-link-migration.ps1 -ExportLimit 3 -ImportLimit 3 -NoPause
   ```

   This combined entrypoint runs account A export and account B chat import only. Run `run-account-b-restore-projects.ps1` separately for project membership and attachment restore.

9. Optional one-click full migration:

   Double-click `run-account-a-to-b-full-sync.cmd` from the repository root after the self-tests, dry runs, and a small real import have succeeded.

   It runs these stages in sequence:

   1. Account A creates shared links, exports project metadata, and downloads project attachments.
   2. Account B opens shared links and creates conversation copies.
   3. Account B matches or creates projects, moves imported chats back into projects, and uploads downloaded project attachments.

   Equivalent command:

   ```cmd
   run-account-a-to-b-full-sync.cmd
   ```

   Before using it, confirm `browser-profile-account-a/` is signed in to account A, `browser-profile-account-b/` is signed in to account B, and the current Windows network can open `https://chatgpt.com`. The launcher passes `-AssumeYes -NoPause`, uses the current Windows proxy settings, and does not close Upnet/VPN. Reports and failure details still go to `outputs/`.

### Command Reference

#### `run-account-a-share-link-export.ps1`

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-SelfTest` | Off | Test browser, DevTools, login state, and read-only APIs only. |
| `-DryRun` | Off | Produce a dry-run report and skip attachment download. |
| `-SkipProjectFiles` | Off | Skip account A project-file downloads. |
| `-Skip <n>` | `0` | Skip the first n conversations. |
| `-Limit <n>` | `0` | Limit processed conversations; `0` means unlimited. |
| `-NoPause` | Off | Do not wait for Enter at the end. |

#### `run-account-b-shared-link-import.ps1`

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-InputJson <path>` | Auto-detect | Use a specific account A export JSON. |
| `-SelfTest` | Off | Test account B browser and login state only. |
| `-DryRun` | Off | Write a report without opening links or sending prompts. |
| `-Skip <n>` | `0` | Skip the first n importable links. |
| `-Limit <n>` | `0` | Limit processed links; `0` means unlimited. |
| `-Prompt <text>` | Chinese acknowledgement prompt | Prompt sent to each shared-link conversation. |
| `-Port <n>` | `9228` | DevTools port for the account B browser. |
| `-AssumeYes` | Off | Skip the `YES` confirmation. |
| `-AllowDuplicates` | Off | Import even when duplicates are detected. |
| `-NoPause` | Off | Do not wait for Enter at the end. |

#### `run-account-b-restore-projects.ps1`

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-InputJson <path>` | Auto-detect | Use a specific import/export report. |
| `-DryRun` | Off | Report planned changes without writing. |
| `-SkipProjectFiles` | Off | Skip attachment upload and binding. |
| `-Skip <n>` | `0` | Skip the first n restorable chats. |
| `-Limit <n>` | `0` | Limit restorable chats; `0` means unlimited. |
| `-Port <n>` | `9228` | DevTools port for the account B browser. |
| `-AssumeYes` | Off | Skip the `YES` confirmation. |
| `-NoPause` | Off | Do not wait for Enter at the end. |

#### `run-full-shared-link-migration.ps1`

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-SkipExport` | Off | Reuse the latest account A export JSON from `outputs/`. |
| `-DryRunImport` | Off | Dry-run the account B import stage. |
| `-ExportLimit <n>` | `0` | Limit account A export. |
| `-ExportSkip <n>` | `0` | Skip account A export rows. |
| `-ImportLimit <n>` | `0` | Limit account B import. |
| `-ImportSkip <n>` | `0` | Skip account B import rows. |
| `-AssumeYes` | Off | Passed to account B import. |
| `-AllowDuplicates` | Off | Passed to account B import. |
| `-NoPause` | Off | Do not wait for Enter at the end. |

#### `run-account-a-to-b-full-sync.cmd`

| Item | Behavior |
| --- | --- |
| Launch method | Double-click from the repository root, or run `run-account-a-to-b-full-sync.cmd` from a terminal. |
| Stages | Runs `run-full-shared-link-migration.ps1`, then `run-account-b-restore-projects.ps1`. |
| Confirmation | Passes `-AssumeYes -NoPause`, so it is meant for full migrations after validation. |
| Output | Reports, CSV files, downloaded attachments, and failure clues remain under `outputs/`. |
| Failure behavior | Stops immediately when a stage exits with an error and keeps the window open. |
| Proxy/VPN | Reuses the current Windows proxy settings and does not stop, close, or modify Upnet/VPN. |
| Self-test | Set `GPTSYNC_CMD_SELFTEST=1` before running it to check launcher path resolution without running a migration. |

### Reports

Account A export:

```text
outputs/chatgpt-account-a-share-links-with-projects_yyyy-MM-dd_HH-mm-ss.json
outputs/chatgpt-account-a-share-links-with-projects_yyyy-MM-dd_HH-mm-ss.csv
```

Important fields:

- `projects`: source project list for account B restore.
- `results[].share_url`: ChatGPT shared link.
- `results[].project_name` and `results[].project_id`: source project mapping.
- `projects[].files[].local_path`: downloaded local attachment path.
- `summary.project_files_downloaded` and `summary.project_files_download_errors`: attachment download health.

Account B import:

```text
outputs/chatgpt-account-b-import-report_yyyy-MM-dd_HH-mm-ss.json
outputs/chatgpt-account-b-import-report_yyyy-MM-dd_HH-mm-ss.csv
```

Important statuses:

- `imported`: prompt sent and account B `/c/{id}` observed.
- `dry-run`: no real import was performed.
- `duplicate`: confirmed duplicate skipped.
- `duplicate_suspected`: likely duplicate skipped.
- `error`: import failed.

Project restore:

```text
outputs/chatgpt-account-b-project-restore-report_yyyy-MM-dd_HH-mm-ss.json
outputs/chatgpt-account-b-project-restore-report_yyyy-MM-dd_HH-mm-ss.csv
outputs/chatgpt-account-b-project-restore-projects_yyyy-MM-dd_HH-mm-ss.csv
outputs/chatgpt-account-b-project-restore-attachments_yyyy-MM-dd_HH-mm-ss.csv
```

Important statuses:

- Chat restore: `restored`, `already_in_project`, `dry_run`, `missing_project`, `verify_failed`, `error`.
- Project restore: `exists`, `created`, `would_create`, `create_error`.
- Attachment restore: `uploaded`, `already_in_project`, `dry_run`, `missing_local_file`, `missing_target_project`, `verify_failed`, `error`.

### Safety Notes

Never publish:

- Browser profiles.
- `outputs/` reports.
- Downloaded attachments.
- Real shared links.
- Debug logs.
- Local launchers or `.env` files.

Browser profiles may contain cookies and login state. Reports may contain chat titles, project names, shared links, local file paths, and error logs. Shared links are not private backups; delete them in ChatGPT after migration if they are no longer needed.

### Troubleshooting

| Symptom | Action |
| --- | --- |
| Browser not found | Install Microsoft Edge or Google Chrome. |
| DevTools port does not start | Close the dedicated browser window for that account and retry. |
| Login state not detected | Sign in inside the dedicated browser window, then return to the PowerShell prompt. |
| No usable `share_url` | Check the account A export report; project-only reports can still be used by project restore. |
| Import does not become `imported` | The page did not reach a B-account `/c/{id}` URL; inspect `error` and try a single-link manual test. |
| Duplicate rows are skipped | This is the default safety behavior; use `-AllowDuplicates` only if duplicate copies are acceptable. |
| `missing_local_file` during attachment restore | Re-run account A export without `-SkipProjectFiles`, then restore again. |
| Project creation fails | Check whether the target account supports projects and whether ChatGPT Web changed project APIs. |
| Network/proxy issue | Keep Upnet/VPN running if that is the current working route, and verify ChatGPT opens in the dedicated browser. |

### Validation And Release

Before publishing or after behavior changes:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\validate-release.ps1
```

Then follow `docs/manual-test-checklist.md` with 1 to 3 non-sensitive conversations.

### License

MIT License. See `LICENSE`.
