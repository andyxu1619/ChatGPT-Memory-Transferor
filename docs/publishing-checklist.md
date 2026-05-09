# GitHub Publishing Checklist

- [ ] Browser profiles are not committed.
- [ ] `outputs/` reports, logs, debug captures, downloaded attachments, and real shared links are not committed.
- [ ] `.gitignore` is present and covers local runtime artifacts.
- [ ] `README.md` is a concise project entrypoint and links to `docs/project-details.md`.
- [ ] `docs/project-details.md` contains detailed workflow, configuration, command, security, limitation, and troubleshooting notes.
- [ ] `SECURITY.md` is present and lists `andyxu3076@gmail.com` as the security contact.
- [ ] `LICENSE` is present.
- [ ] `CHANGELOG.md` is present.
- [ ] `CONTRIBUTING.md` is present.
- [ ] Release validation passes:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\validate-release.ps1
```

- [ ] Manual test with 1 to 3 non-sensitive conversations has passed.
- [ ] Repository description and topics are set.
- [ ] First commit contains only publishable source, docs, tests, examples, and metadata.
