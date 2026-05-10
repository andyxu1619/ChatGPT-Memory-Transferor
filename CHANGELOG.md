# Changelog

## Unreleased

- No unreleased changes.

## v0.1.1 - 2026-05-10

### Added

- Added a concise Chinese README and linked it from the English README.
- Added `VERSION` for explicit version tracking.
- Added README sections for technology stack, installation, environment variables, validation, build boundary, local run commands, project structure, and publishing guidance.

### Fixed

- Classified project-only conversations whose detail endpoint is unavailable as `skipped_unavailable` instead of export errors, while preserving project metadata in the report.
- Improved duplicate detection so historical imports can be compared against source `current_node_id` or `update_time`; dry-run import reports updated source conversations as `would_update`.
- Hardened account B import so shared-link pages are not treated as successful imports unless a durable target conversation ID is found, including a recent-conversation fallback after sending the migration prompt.
- Updated project attachment upload and binding for the current ChatGPT project-file API, including valid `location` values and strict failure reporting when upload or binding verification fails.

### Security

- Reconfirmed that tracked files contain no real shared links, local user paths, browser profiles, outputs, logs, reports, or unauthorized email addresses.
- Kept `andyxu3076@gmail.com` as the only public contact email in tracked project files.

### Validation

- Verified release validation, JavaScript syntax checks, PowerShell syntax checks, account A self-test, account B dry-run import, project restore dry run, root `.cmd` self-test, and `git diff --check`.

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
