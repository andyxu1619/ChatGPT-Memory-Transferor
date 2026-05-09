# GitHub Publishing Checklist

- [ ] Browser profiles are not committed.
- [ ] `outputs/` reports, logs, debug captures, downloaded attachments, and real shared links are not committed.
- [ ] `.gitignore` is present and covers local runtime artifacts.
- [ ] `README.md` describes installation, configuration, usage, safety notes, FAQ, license, and maintenance status.
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
