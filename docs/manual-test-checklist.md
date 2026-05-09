# Manual Test Checklist

Use non-sensitive conversations for every release test.

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

## B Account Import

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -DryRun -Limit 1 -NoPause
powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -Limit 1 -NoPause
```

Expected result:

- Dry run writes a report without opening shared links or sending messages.
- Real run asks for `YES` before sending.
- B account history shows the imported conversation after completion.
- Report status is `imported`, `duplicate`, or a clear `error`.

## Project Restore

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-b-restore-projects.ps1 -DryRun -NoPause
```

Expected result:

- Script reads the latest import/export report.
- Dry run lists projects that would be created and chats that would be moved.
- No projects, chats, or files are changed in dry run mode.

## Manual HTML Fallback

- Open `b-open-shared-links.html` locally.
- Load `examples/account-a-export.sample.json`.
- Confirm the sample link appears.
- Confirm malformed or non-ChatGPT share URLs are rejected.
