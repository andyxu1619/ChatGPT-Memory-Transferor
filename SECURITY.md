# Security Policy

## Reporting a Vulnerability

Please report security issues by email instead of opening a public issue if the report contains sensitive information.

Security contact: andyxu3076@gmail.com

Do not include browser profiles, cookies, session data, real shared links, account identifiers, attachment paths, or other sensitive data in public issues, pull requests, screenshots, or logs.

## Sensitive Data

Do not commit or share:

- Browser profiles.
- Cookies.
- Session storage.
- Local storage.
- `.env` files.
- Outputs.
- Logs.
- Reports.
- Real shared links.
- Account identifiers.
- Attachment paths.

Browser profiles can contain login state. Runtime outputs can contain conversation titles, project names, shared links, attachment names, local paths, and error details.

## Scope

This project is an experimental browser-automation toolkit. It does not use an official ChatGPT migration API and may depend on ChatGPT Web behavior, shared-link behavior, and browser flows that can change without notice.

## Recommended Practices

- Use non-sensitive test conversations first.
- Keep browser profile directories local.
- Keep `outputs/`, logs, reports, and downloaded attachments out of Git.
- Review `git status --ignored` before committing.
- Run `powershell -ExecutionPolicy Bypass -File .\tests\validate-release.ps1` before publishing.
- Delete ChatGPT shared links after migration if you no longer need them.
