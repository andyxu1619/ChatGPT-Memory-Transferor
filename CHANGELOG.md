# Changelog

## Unreleased

### Added

- Added a concise Chinese README and linked it from the English README.
- Added conservative speedup controls for account A export and account B import waits, plus import report timing metrics.

### Fixed

- Validated speedup delay parameters before opening browser windows and made recent imported-conversation fallback handle numeric ChatGPT timestamps.
- Classified project-only conversations whose detail endpoint is unavailable as `skipped_unavailable` instead of export errors, while preserving project metadata in the report.
- Hardened account B import so shared-link pages are not treated as successful imports unless a durable target conversation ID is found, including a recent-conversation fallback after sending the migration prompt.
- Updated project attachment upload and binding for the current ChatGPT project-file API, including valid `location` values and strict failure reporting when upload or binding verification fails.

### Validation

- Verified syntax checks, `tests/validate-release.ps1`, and `git diff --check` for the speedup branch after syncing the runtime fixes.

## v0.1.0 - 2026-05-10

### Added

- Initial experimental Windows PowerShell toolkit for migrating ChatGPT conversations through shared links.
- Browser automation workflow using Chrome/Edge DevTools Protocol.
- Account A shared-link export flow.
- Account B shared-link import flow.
- Project and attachment restoration helpers.
- Local HTML helper for reviewing shared-link import input.
- Release validation script.
- Documentation, examples, publishing checklist, and manual test checklist.
- Added release-oriented `.gitignore` rules for browser profiles, outputs, logs, local launchers, and environment files.
- Rewrote `README.md` for public GitHub usage, including installation, configuration, usage, safety notes, FAQ, and maintenance status.
- Added MIT license, contribution guide, release validation script, manual test checklist, and sample export JSON.
- Added ChatGPT shared-link URL validation to the B-account import flow and the manual HTML navigator.
- Removed an unused background import helper from `run-account-b-shared-link-import.ps1`.
- Hardened B-account import success detection so shared-link pages are not reported as imported unless a `/c/{id}` conversation URL is observed.
- Restored project recovery for duplicate rows that already contain usable imported conversation IDs.
- Added the required `sharing` payload for project creation through `gizmos/snorlax/upsert`.
- Added a browser-download fallback for A-account project attachments when direct PowerShell downloads fail.

### Security

- Added `.gitignore` rules for browser profiles, outputs, logs, environment files, and local runtime artifacts.
- Added shared-link domain validation for import flows.
- Added release guidance for avoiding committed browser state, logs, outputs, and real shared links.
