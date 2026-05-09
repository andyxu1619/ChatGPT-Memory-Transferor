# Contributing

Thanks for considering a contribution. This project is an experimental Windows automation tool that interacts with the ChatGPT web app, so changes should be conservative and easy to validate.

## Development Rules

- Do not commit browser profiles, cookies, exported reports, logs, downloaded files, or real shared links.
- Keep the project dependency-free unless a new dependency is clearly necessary.
- Prefer small, focused changes over broad rewrites.
- Keep Windows PowerShell compatibility in mind.
- Treat ChatGPT internal endpoints as unstable; add fallback behavior or clear error messages when changing endpoint usage.
- Run the release validation script before opening a pull request:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\validate-release.ps1
```

## Manual Validation

For behavior changes, test with a small, non-sensitive sample:

```powershell
powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -SelfTest -NoPause
powershell -ExecutionPolicy Bypass -File .\run-account-a-share-link-export.ps1 -Limit 1 -SkipProjectFiles -NoPause
powershell -ExecutionPolicy Bypass -File .\run-account-b-shared-link-import.ps1 -DryRun -Limit 1 -NoPause
```

Only run real import/restore operations after confirming the dry run result.
