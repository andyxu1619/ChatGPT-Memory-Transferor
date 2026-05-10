# ChatGPT Memory Transferor

[English](README.md) | [中文](README.zh-CN.md)

ChatGPT Memory Transferor is an experimental Windows toolkit for copying ChatGPT conversations from one account to another through ChatGPT shared links and browser automation. It can also help restore project membership and project attachments when the source export contains project metadata.

This is not an official OpenAI or ChatGPT migration API. It uses the ChatGPT web app through your local browser login state.

Current version: v0.1.1. See [CHANGELOG.md](CHANGELOG.md).

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
- Version-aware duplicate detection and import reports.
- Local HTML helper for manual shared-link review.
- Release validation script for public repository checks.

## Technology stack

- Windows PowerShell scripts for orchestration and local validation.
- JavaScript injected through browser DevTools Protocol for ChatGPT Web automation.
- Static HTML helper for manual shared-link review.
- No npm, pip, Docker, database, or compiled build step is required.

## Current runtime notes

- Project-only conversations that ChatGPT lists but does not return from the detail endpoint are reported as `skipped_unavailable`, not as export failures.
- Account B imports are treated as successful only after the browser reaches a usable `/c/{id}` conversation URL.
- Duplicate detection compares source `current_node_id` or `update_time` when history has enough metadata, so updated source conversations can be reported as `would_update` in dry-run mode instead of being silently skipped as unchanged duplicates.
- Project attachment restore uses the current project-file binding payload and fails loudly if upload, binding, or verification still has errors.

## Requirements

- Windows.
- PowerShell.
- Chrome or Edge.
- Two ChatGPT accounts.
- Git, optional unless you clone or contribute to the repository.

## Installation

```powershell
git clone https://github.com/example-user/ChatGPT-Memory-Transferor.git
cd ChatGPT-Memory-Transferor
```

No dependency install command is required. The repository runs directly from the checked-out PowerShell, JavaScript, and HTML files.

## Environment variables

No `.env` file or real secret is required. Do not create or commit `.env` files with account data, tokens, cookies, or local paths.

Optional local-only variable:

- `GPTSYNC_CMD_SELFTEST=1` runs the root `.cmd` launcher self-test without starting the migration flow.

## Validation, tests, and build

Run the release validation check:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\validate-release.ps1
```

There is no separate build command because this is a script toolkit. Treat the release validation script, JavaScript syntax checks, and PowerShell syntax checks as the build gate.

## Local run commands

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

See [Project Details](docs/project-details.md) before running real imports or project restoration.

## Project structure

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

## Deployment and publishing

This project is published as source code. Before publishing a change, run `tests/validate-release.ps1`, confirm `git status --ignored`, and verify that browser profiles, `outputs/`, logs, reports, real shared links, and `.env` files are not tracked.

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
