# Manual Test Checklist

Use non-sensitive conversations for every release test.

See [Project Details](project-details.md) for workflow context and [Security Policy](../SECURITY.md) for data-handling rules.

## Preflight

- Confirm `browser-profile-account-a/`, `browser-profile-account-b/`, and `outputs/` are ignored by Git.
- Run `powershell -ExecutionPolicy Bypass -File .\tests\validate-release.ps1`.
- Confirm Edge or Chrome is installed.
- Confirm `https://chatgpt.com` opens through the current network/proxy environment.

## A Account Export

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -SelfTest -NoPause
powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -Limit 1 -SkipProjectFiles -NoPause
```

Expected result:

- Dedicated browser window opens.
- Login state is detected after signing in.
- A JSON and CSV report are written under `outputs/`.
- The JSON contains at least one `results[].share_url` with `https://chatgpt.com/share/`.
- Any `skipped_unavailable` rows are limited to unreadable project-only conversations and do not increase `summary.errors`.
- `summary.project_files_download_errors` is `0` when attachment download is included.
- Use one non-sensitive conversation for the first export test.

## B Account Import

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -DryRun -Limit 1 -NoPause
powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -Limit 1 -NoPause
```

Expected result:

- Dry run writes a report without opening shared links or sending messages.
- Real run asks for `YES` before sending.
- B account history shows the imported conversation after completion.
- Report status is `imported`, `updated`, `duplicate`, `would_update` in dry-run update cases, or a clear `error`.
- Real import reports have `summary.errors` equal to `0`; duplicate skips should preserve usable imported IDs when they exist.
- When a previously imported A conversation has new messages, dry run should report `would_update`; a real run should report `updated` and `superseded_action=hidden_previous`, leaving only the latest target copy visible unless `-KeepSuperseded` was intentionally used.
- Use 1 to 3 non-sensitive shared links for the first import test.
- Confirm dry-run mode does not perform real imports or overwrite target-account content.

## Project Restore

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-restore-projects.ps1 -DryRun -NoPause
```

Expected result:

- Script reads the latest import/export report.
- Dry run lists projects that would be created and chats that would be moved.
- No projects, chats, or files are changed in dry run mode.
- Test a conversation with no project membership.
- Test an empty project or a source project with no imported conversations.
- Test a conversation with project membership and confirm it is restored to the expected target project.
- Test one non-sensitive small attachment sample before trying larger attachment batches.
- Real restore reports have `summary.errors`, `summary.verify_failed`, `summary.project_create_errors`, and `summary.attachment_errors` equal to `0`.
- Attachment restore should end as `uploaded` or `already_in_project`; inspect `attachment_results[].error` if `File uploaded but attach failed` appears.

## Manual HTML Fallback

- Open `b-open-shared-links.html` locally.
- Load `examples/account-a-export.sample.json`.
- Confirm the sample link appears.
- Confirm malformed or non-ChatGPT share URLs are rejected.

## Security And Git Hygiene

- Confirm illegal shared-link domains are rejected by import and manual fallback flows.
- Confirm `outputs/` remains untracked after export, import, restore, and validation runs.
- Confirm `browser-profile-account-a/`, `browser-profile-account-b/`, and `browser-profile-*/` remain ignored.
- Confirm `logs/`, `reports/`, `.cache/`, and `.env` files remain ignored.
- Confirm no real shared links, account identifiers, attachment paths, cookies, tokens, or local storage data are staged before commit.
