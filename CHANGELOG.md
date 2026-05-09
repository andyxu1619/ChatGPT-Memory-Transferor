# Changelog

## Unreleased

- Added release-oriented `.gitignore` rules for browser profiles, outputs, logs, local launchers, and environment files.
- Rewrote `README.md` for public GitHub usage, including installation, configuration, usage, safety notes, FAQ, and maintenance status.
- Added MIT license, contribution guide, release validation script, manual test checklist, and sample export JSON.
- Added ChatGPT shared-link URL validation to the B-account import flow and the manual HTML navigator.
- Removed an unused background import helper from `run-account-b-shared-link-import.ps1`.
- Hardened B-account import success detection so shared-link pages are not reported as imported unless a `/c/{id}` conversation URL is observed.
- Restored project recovery for duplicate rows that already contain usable imported conversation IDs.
- Added the required `sharing` payload for project creation through `gizmos/snorlax/upsert`.
- Added a browser-download fallback for A-account project attachments when direct PowerShell downloads fail.
