# ChatGPT Memory Transferor

[English](README.md) | [中文](README.zh-CN.md)

ChatGPT Memory Transferor is an experimental Windows toolkit for copying ChatGPT conversations from one account to another through ChatGPT shared links and browser automation. It can also help restore project membership and project attachments when the source export contains project metadata.

This is not an official OpenAI or ChatGPT migration API. It uses the ChatGPT web app through your local browser login state.

## What it does

- Creates shared links from source-account conversations.
- Imports shared-link conversations into a target account by opening them in a dedicated browser profile.
- Exports project metadata from the source account.
- Restores imported conversations into target-account projects when possible.
- Handles project attachment download and re-upload helpers for non-sensitive testable samples.

## Important notice

This project is experimental and depends on ChatGPT Web behavior, shared-link behavior, and browser automation. These interfaces may change without notice.

本项目为实验性工具，依赖 ChatGPT Web 页面行为、共享链接机制和浏览器自动化流程。相关接口和页面结构可能随时变化，因此不保证长期稳定。

- Windows-only.
- Depends on Chrome or Edge browser automation.
- Depends on ChatGPT Web behavior and shared-link behavior.
- Not an official OpenAI or ChatGPT migration API.
- Use small, non-sensitive test conversations before any larger run.

## Features

- Account A shared-link export flow.
- Account B shared-link import flow.
- Dedicated browser profiles for source and target accounts.
- Project metadata export and restore helpers.
- Project attachment transfer helpers.
- Duplicate-aware import reports.
- Local HTML helper for manual shared-link review.
- Release validation script for public repository checks.

## Requirements

- Windows.
- PowerShell.
- Chrome or Edge.
- Two ChatGPT accounts.
- Git, optional unless you clone or contribute to the repository.

## Quick start

```powershell
git clone https://github.com/example-user/ChatGPT-Memory-Transferor.git
cd ChatGPT-Memory-Transferor
powershell -ExecutionPolicy Bypass -File .\tests\validate-release.ps1
```

Run a source-account self-test:

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -SelfTest -NoPause
```

Export a small non-sensitive sample:

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -Limit 1 -SkipProjectFiles -NoPause
```

Dry-run target-account import:

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -DryRun -Limit 1 -NoPause
```

Safe speedup parameters:

```powershell
powershell -ExecutionPolicy Bypass -File .\run-full-shared-link-migration.ps1 -ExportDelayMs 500 -ImportPostItemDelayMs 500
```

`-ExportDelayMs` controls the base wait after account A creates each shared link; rate-limit and server-error retries still back off. `-ImportPostItemDelayMs` only controls the extra wait after each account B import item finishes, and does not bypass the `/c/{id}` success check. Account B import reads prior reports by default and skips shared links that were already imported.

See [Project Details](docs/project-details.md) before running real imports or project restoration.

## Documentation

- [Chinese README](README.zh-CN.md)
- [Project details](docs/project-details.md)
- [Manual test checklist](docs/manual-test-checklist.md)
- [Publishing checklist](docs/publishing-checklist.md)
- [Security policy](SECURITY.md)
- [Contributing guide](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)

## Security

Do not commit or publish browser profiles, cookies, session storage, local storage, `outputs/`, logs, reports, real shared links, account identifiers, attachment paths, or `.env` files. These artifacts may expose ChatGPT login state, conversation metadata, project names, file names, local paths, or share URLs.

Security contact: andyxu3076@gmail.com

See [SECURITY.md](SECURITY.md) for reporting instructions and recommended handling.

## License

MIT License.
