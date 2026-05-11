param()

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = New-Object System.Collections.Generic.List[string]
$currentUserName = ""
$expectedCloneUrl = "https://github.com/example-user/ChatGPT-Memory-Transferor.git"
$securityEmail = "andyxu3076@gmail.com"

if ($env:USERPROFILE) {
  $currentUserName = Split-Path -Leaf $env:USERPROFILE
}

function Add-Failure {
  param([string]$Message)
  $failures.Add($Message) | Out-Null
}

function ConvertTo-RepoPath {
  param([string]$Path)

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $rootPath = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd("\")
  if ($fullPath.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $fullPath.Substring($rootPath.Length).TrimStart("\") -replace "\\", "/"
  }

  return $Path -replace "\\", "/"
}

function Invoke-GitLines {
  param([string[]]$Arguments)

  $output = & git @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    Add-Failure "Git command failed: git $($Arguments -join ' ')"
    return @()
  }

  return @($output) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Test-PowerShellSyntax {
  param([string]$Path)

  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
  foreach ($errorItem in @($errors)) {
    Add-Failure "PowerShell syntax error in $(ConvertTo-RepoPath $Path): $($errorItem.Message)"
  }
}

function Test-NodeSyntax {
  param([string]$Path)

  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) {
    Write-Host "Node.js not found; skipping JavaScript syntax check."
    return
  }

  $process = Start-Process -FilePath $node.Source -ArgumentList @("--check", $Path) -Wait -NoNewWindow -PassThru
  if ($process.ExitCode -ne 0) {
    Add-Failure "JavaScript syntax check failed: $(ConvertTo-RepoPath $Path)"
  }
}

function Assert-Contains {
  param(
    [string]$Content,
    [string]$Pattern,
    [string]$Message
  )

  if ($Content -notmatch [regex]::Escape($Pattern)) {
    Add-Failure $Message
  }
}

function Get-TrackedTextFiles {
  param([string[]]$TrackedFiles)

  foreach ($trackedFile in $TrackedFiles) {
    $extension = [System.IO.Path]::GetExtension($trackedFile).ToLowerInvariant()
    if ($extension -notin @(".md", ".ps1", ".js", ".html", ".json", ".gitignore", ".cmd", "")) {
      continue
    }

    $path = Join-Path $repoRoot $trackedFile
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      [pscustomobject]@{
        Path = $path
        RepoPath = $trackedFile -replace "\\", "/"
        Content = Get-Content -Raw -LiteralPath $path -ErrorAction SilentlyContinue
      }
    }
  }
}

function Test-TrackedPathSafety {
  param([string[]]$TrackedFiles)

  $sensitivePathPatterns = @(
    @{ Name = "browser profile path"; Pattern = "(^|/)browser-profile-account-a(/|$)" },
    @{ Name = "browser profile path"; Pattern = "(^|/)browser-profile-account-b(/|$)" },
    @{ Name = "browser profile wildcard path"; Pattern = "(^|/)browser-profile-[^/]+(/|$)" },
    @{ Name = "outputs path"; Pattern = "(^|/)outputs(/|$)" },
    @{ Name = "archived launchers path"; Pattern = "(^|/)archived-launchers(/|$)" },
    @{ Name = "environment file"; Pattern = "(^|/)\.env($|\.|/)" },
    @{ Name = "logs path"; Pattern = "(^|/)logs(/|$)" },
    @{ Name = "reports path"; Pattern = "(^|/)reports(/|$)" },
    @{ Name = "cache path"; Pattern = "(^|/)\.cache(/|$)" }
  )

  foreach ($trackedFile in $TrackedFiles) {
    $repoPath = $trackedFile -replace "\\", "/"
    foreach ($entry in $sensitivePathPatterns) {
      if ($repoPath -match $entry.Pattern) {
        Add-Failure "Tracked file is in a sensitive location ($($entry.Name)): $repoPath"
      }
    }
  }
}

function Test-TrackedIgnoredFiles {
  $trackedIgnoredFiles = Invoke-GitLines -Arguments @("ls-files", "-ci", "--exclude-standard")
  foreach ($trackedIgnoredFile in $trackedIgnoredFiles) {
    Add-Failure "Tracked file is ignored by .gitignore: $($trackedIgnoredFile -replace '\\', '/')"
  }
}

function Test-ContentSafety {
  param([object[]]$TextFiles)

  $realShareUrlPattern = "https://(?:chatgpt\.com|chat\.openai\.com)/share/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
  $hardcodedSecretPatterns = @(
    @{ Name = "hardcoded bearer token"; Pattern = "(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{20,}" },
    @{ Name = "hardcoded API key"; Pattern = '(?i)\b(api[_-]?key|apikey)\b\s*[:=]\s*["\x27][^"\x27]{12,}["\x27]' },
    @{ Name = "hardcoded password"; Pattern = '(?i)\bpassword\b\s*[:=]\s*["\x27][^"\x27]{8,}["\x27]' },
    @{ Name = "hardcoded secret"; Pattern = '(?i)\bsecret\b\s*[:=]\s*["\x27][^"\x27]{8,}["\x27]' },
    @{ Name = "hardcoded authorization header"; Pattern = '(?i)\bauthorization\b\s*[:=]\s*["\x27](?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{20,}["\x27]' },
    @{ Name = "hardcoded cookie"; Pattern = '(?i)\bcookie\b\s*[:=]\s*["\x27][^"\x27]{12,}["\x27]' }
  )

  foreach ($file in $TextFiles) {
    $content = [string]$file.Content
    if ([string]::IsNullOrEmpty($content)) {
      continue
    }

    if ($content -match $realShareUrlPattern) {
      Add-Failure "Tracked file may contain a real ChatGPT shared link: $($file.RepoPath)"
    }

    if ($content -match "[A-Za-z]:\\Users\\") {
      Add-Failure "Tracked file contains a local Windows user path: $($file.RepoPath)"
    }

    if (-not [string]::IsNullOrWhiteSpace($currentUserName) -and $content -match [regex]::Escape($currentUserName)) {
      Add-Failure "Tracked file contains the current local username: $($file.RepoPath)"
    }

    foreach ($entry in $hardcodedSecretPatterns) {
      if ($content -match $entry.Pattern) {
        Add-Failure "Tracked file may contain $($entry.Name): $($file.RepoPath)"
      }
    }
  }
}

function Test-RepositoryPlaceholders {
  param([object[]]$TextFiles)

  $placeholderPatterns = @(
    ("your-" + "name"),
    ("your-" + "repo"),
    ("user" + "name/" + "repo" + "-name"),
    ("<your-" + "org-or-user>"),
    ("github.com/" + "<")
  )

  foreach ($file in $TextFiles) {
    $content = [string]$file.Content
    foreach ($pattern in $placeholderPatterns) {
      if ($content -match [regex]::Escape($pattern)) {
        Add-Failure "Tracked file contains repository placeholder '$pattern': $($file.RepoPath)"
      }
    }
  }
}

function Test-EmailConsistency {
  param([object[]]$TextFiles)

  $emailPattern = "\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"
  foreach ($file in $TextFiles) {
    foreach ($match in [regex]::Matches([string]$file.Content, $emailPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
      if ($match.Value -ne $securityEmail) {
        Add-Failure "Tracked file contains an unexpected email address: $($file.RepoPath)"
      }
    }
  }

  foreach ($requiredEmailFile in @("README.md", "SECURITY.md", "CONTRIBUTING.md")) {
    $path = Join-Path $repoRoot $requiredEmailFile
    if ((Test-Path -LiteralPath $path) -and ((Get-Content -Raw -LiteralPath $path) -notmatch [regex]::Escape($securityEmail))) {
      Add-Failure "$requiredEmailFile must contain the security contact email."
    }
  }
}

function Test-MarkdownLocalLinks {
  param([object[]]$TextFiles)

  foreach ($file in $TextFiles) {
    if ([System.IO.Path]::GetExtension($file.RepoPath).ToLowerInvariant() -ne ".md") {
      continue
    }

    $baseDir = Split-Path -Parent $file.Path
    foreach ($match in [regex]::Matches([string]$file.Content, "\[[^\]]+\]\(([^)]+)\)")) {
      $target = $match.Groups[1].Value.Trim()
      if ([string]::IsNullOrWhiteSpace($target)) {
        continue
      }

      if ($target.StartsWith("#") -or
          $target -match "^[a-z][a-z0-9+.-]*:" -or
          $target.StartsWith("mailto:", [System.StringComparison]::OrdinalIgnoreCase)) {
        continue
      }

      $targetPath = ($target -split "#", 2)[0].Trim()
      if ([string]::IsNullOrWhiteSpace($targetPath)) {
        continue
      }

      $normalizedTarget = $targetPath -replace "/", [System.IO.Path]::DirectorySeparatorChar
      $resolvedPath = [System.IO.Path]::GetFullPath((Join-Path $baseDir $normalizedTarget))
      if (-not (Test-Path -LiteralPath $resolvedPath)) {
        Add-Failure "Markdown local link target is missing in $($file.RepoPath): $target"
      }
    }
  }
}

function Test-VersionAwareImportBehavior {
  $scriptPath = Join-Path $repoRoot "run-account-b-shared-link-import.ps1"
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
  foreach ($errorItem in @($errors)) {
    Add-Failure "Cannot load B import functions for behavior test: $($errorItem.Message)"
  }
  if (@($errors).Count -gt 0) {
    return
  }

  try {
    $functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    $functionBlock = [scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n`n")
    . $functionBlock

    function Assert-Behavior {
      param(
        [bool]$Condition,
        [string]$Message
      )

      if (-not $Condition) {
        Add-Failure $Message
      }
    }

    function New-TestDuplicateIndex {
      $index = New-DuplicateIndex
      $oldRow = [pscustomobject]@{
        status = "imported"
        id = "source-1"
        title = "Changed Chat"
        project_name = "Demo Project"
        share_url = "https://chatgpt.com/share/synthetic-update-check"
        imported_id = "11111111-1111-1111-1111-111111111111"
        imported_url = "https://chatgpt.com/c/11111111-1111-1111-1111-111111111111"
        source_update_time = "2026-05-10T10:00:00Z"
        source_current_node_id = "old-node"
        source_share_id = "share-1"
        source_share_url = "https://chatgpt.com/share/synthetic-update-check"
      }
      Add-DuplicateRecord -Index $index -Row $oldRow -MatchSource "synthetic-history.json" -SourceState (Get-SourceState -Row $oldRow)
      return $index
    }

    function New-TestImportItem {
      param(
        [string]$NodeId,
        [string]$UpdateTime
      )

      [pscustomobject]@{
        id = "source-1"
        title = "Changed Chat"
        project_name = "Demo Project"
        project_id = "project-1"
        project_source = "project"
        source = "account-a"
        share_id = "share-1"
        share_url = "https://chatgpt.com/share/synthetic-update-check"
        source_update_time = $UpdateTime
        source_current_node_id = $NodeId
        source_share_id = "share-1"
      }
    }

    $changedItem = New-TestImportItem -NodeId "new-node" -UpdateTime "2026-05-10T11:00:00Z"
    $dryRunReport = Invoke-OrchestratedImport -WebSocket $null -Items @($changedItem) -DryRunMode $true -PromptText "test" -DuplicateIndex (New-TestDuplicateIndex) -AllowDuplicateItems $false -KeepSupersededItems $false 6>$null
    $dryRunRow = @($dryRunReport.results)[0]
    Assert-Behavior ($dryRunRow.status -eq "would_update") "Changed source conversation must be reported as would_update in dry-run."
    Assert-Behavior ($dryRunRow.sync_mode -eq "update_replace") "Default changed-source dry-run must plan update_replace."
    Assert-Behavior ($dryRunRow.superseded_action -eq "would_hide_previous") "Default changed-source dry-run must plan to hide the previous target copy."
    Assert-Behavior ($dryRunRow.previous_imported_id -eq "11111111-1111-1111-1111-111111111111") "Changed-source dry-run must preserve the previous imported_id."
    Assert-Behavior ($dryRunReport.summary.would_update -eq 1 -and $dryRunReport.summary.duplicates -eq 0 -and $dryRunReport.summary.errors -eq 0) "Changed-source dry-run summary counts are incorrect."

    $sameItem = New-TestImportItem -NodeId "old-node" -UpdateTime "2026-05-10T10:00:00Z"
    $duplicateReport = Invoke-OrchestratedImport -WebSocket $null -Items @($sameItem) -DryRunMode $true -PromptText "test" -DuplicateIndex (New-TestDuplicateIndex) -AllowDuplicateItems $false -KeepSupersededItems $false 6>$null
    $duplicateRow = @($duplicateReport.results)[0]
    Assert-Behavior ($duplicateRow.status -eq "duplicate") "Unchanged source conversation must still be skipped as duplicate."
    Assert-Behavior ($duplicateRow.sync_mode -eq "skip") "Unchanged duplicate must use skip sync_mode."
    Assert-Behavior ($duplicateReport.summary.duplicates -eq 1 -and $duplicateReport.summary.would_update -eq 0 -and $duplicateReport.summary.errors -eq 0) "Unchanged duplicate summary counts are incorrect."

    function Start-Sleep {
      param(
        [int]$Seconds,
        [int]$Milliseconds
      )
    }
    function Invoke-Cdp {
      param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [string]$Method,
        [hashtable]$Params = @{}
      )
      [pscustomobject]@{}
    }
    function Wait-DocumentReady {
      param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [int]$TimeoutSec
      )
      return $true
    }
    function Invoke-OpenSharedComposer {
      param([System.Net.WebSockets.ClientWebSocket]$WebSocket)
      [pscustomobject]@{
        unavailable = $false
        hasComposer = $true
        clicked = $false
        message = ""
      }
    }
    function Invoke-SendMigrationPrompt {
      param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [string]$PromptText
      )
      [pscustomobject]@{
        ok = $true
        href = "https://chatgpt.com/c/22222222-2222-2222-2222-222222222222"
        evidence = "mock"
      }
    }
    function Get-PageHref {
      param([System.Net.WebSockets.ClientWebSocket]$WebSocket)
      return "https://chatgpt.com/c/22222222-2222-2222-2222-222222222222"
    }
    function Invoke-HideSupersededConversation {
      param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [string]$ConversationId
      )
      [pscustomobject]@{
        ok = $true
        stage = "hide"
        status = 200
        error = ""
      }
    }

    $updatedReport = Invoke-OrchestratedImport -WebSocket $null -Items @($changedItem) -DryRunMode $false -PromptText "test" -DuplicateIndex (New-TestDuplicateIndex) -AllowDuplicateItems $false -KeepSupersededItems $false 6>$null
    $updatedRow = @($updatedReport.results)[0]
    Assert-Behavior ($updatedRow.status -eq "updated") "Changed source real import must report updated after a successful replacement."
    Assert-Behavior ($updatedRow.superseded_action -eq "hidden_previous") "Successful changed-source replacement must record hidden_previous."
    Assert-Behavior ($updatedReport.summary.updated -eq 1 -and $updatedReport.summary.errors -eq 0) "Successful changed-source replacement summary counts are incorrect."

    function Invoke-HideSupersededConversation {
      param(
        [System.Net.WebSockets.ClientWebSocket]$WebSocket,
        [string]$ConversationId
      )
      [pscustomobject]@{
        ok = $false
        stage = "hide"
        status = 500
        error = "mock-hide-failed"
      }
    }

    $failedHideReport = Invoke-OrchestratedImport -WebSocket $null -Items @($changedItem) -DryRunMode $false -PromptText "test" -DuplicateIndex (New-TestDuplicateIndex) -AllowDuplicateItems $false -KeepSupersededItems $false 6>$null
    $failedHideRow = @($failedHideReport.results)[0]
    Assert-Behavior ($failedHideRow.status -eq "error") "Changed source import must report error if hiding the previous target copy fails."
    Assert-Behavior ($failedHideRow.error -match "隐藏旧副本失败") "Hide failure error must explain that the previous target copy was not hidden."
    Assert-Behavior ($failedHideReport.summary.updated -eq 0 -and $failedHideReport.summary.errors -eq 1) "Hide failure summary counts must not pretend the update succeeded."
  } catch {
    Add-Failure "Version-aware import behavior test failed unexpectedly: $($_.Exception.Message)"
  }
}

Set-Location -LiteralPath $repoRoot

$trackedFiles = Invoke-GitLines -Arguments @("ls-files")
$requiredContentFiles = @(
  "README.md",
  "README.zh-CN.md",
  "VERSION",
  "CHANGELOG.md",
  "CONTRIBUTING.md",
  "SECURITY.md",
  "docs/project-details.md",
  "docs/manual-test-checklist.md",
  "docs/publishing-checklist.md"
)
$contentScanFiles = @($trackedFiles + $requiredContentFiles) | Sort-Object -Unique
$trackedTextFiles = @(Get-TrackedTextFiles -TrackedFiles $contentScanFiles)

Get-ChildItem -File -Filter "*.ps1" | ForEach-Object { Test-PowerShellSyntax -Path $_.FullName }
Get-ChildItem -File -Filter "*.js" | ForEach-Object { Test-NodeSyntax -Path $_.FullName }

$htmlPath = Join-Path $repoRoot "b-open-shared-links.html"
$html = Get-Content -Raw -LiteralPath $htmlPath
Assert-Contains -Content $html -Pattern "normalizeShareUrl" -Message "Manual HTML tool must validate shared-link URLs."
Assert-Contains -Content $html -Pattern "chatgpt.com" -Message "Manual HTML tool must allow ChatGPT share links explicitly."

$bImportScript = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "run-account-b-shared-link-import.ps1")
Assert-Contains -Content $bImportScript -Pattern "不会把共享链接页当作导入成功" -Message "B import must require a durable /c/{id} URL before reporting imported."
Assert-Contains -Content $bImportScript -Pattern "match_imported_id" -Message "Duplicate detection must preserve imported conversation IDs."
Assert-Contains -Content $bImportScript -Pattern "Compare-SourceVersion" -Message "Duplicate detection must compare source version metadata."
Assert-Contains -Content $bImportScript -Pattern "would_update" -Message "Duplicate dry runs must report updated source conversations."
Assert-Contains -Content $bImportScript -Pattern "Invoke-HideSupersededConversation" -Message "B import must hide superseded target copies after updated imports."

$aExportScript = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "run-account-a-share-link-export.ps1")
Assert-Contains -Content $aExportScript -Pattern "Invoke-BrowserDownloadFile" -Message "A export must have a browser-download fallback for project files."
Assert-Contains -Content $aExportScript -Pattern "gptsync_account_a_selftest" -Message "A export self-test must retry session refresh before failing."

$aExportInjector = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "account-a-create-share-links-cdp.js")
Assert-Contains -Content $aExportInjector -Pattern "skipped_unavailable" -Message "A export must classify unreadable project-only conversations as skipped, not export errors."
Assert-Contains -Content $aExportInjector -Pattern "gptsync_account_a_export" -Message "A CDP export must retry session refresh before failing."

$restoreScript = Get-Content -Raw -LiteralPath (Join-Path $repoRoot "run-account-b-restore-projects.ps1")
Assert-Contains -Content $restoreScript -Pattern "Duplicate rows can carry usable imported IDs" -Message "Project restore must keep duplicate rows with usable imported IDs eligible."
Assert-Contains -Content $restoreScript -Pattern "sharing: normalizeSharing" -Message "Project creation must send the required sharing payload."
Assert-Contains -Content $restoreScript -Pattern "File uploaded but attach failed" -Message "Project attachment upload must fail loudly when upload succeeds but project binding cannot be verified."
Assert-Contains -Content $restoreScript -Pattern "gptsync_project_restore_api_retry" -Message "Project restore must refresh session before failing on transient API authorization errors."

$gitignorePath = Join-Path $repoRoot ".gitignore"
if (-not (Test-Path -LiteralPath $gitignorePath)) {
  Add-Failure ".gitignore is missing."
} else {
  $gitignore = Get-Content -Raw -LiteralPath $gitignorePath
  foreach ($required in @(
    "browser-profile-account-a/",
    "browser-profile-account-b/",
    "browser-profile-*/",
    "outputs/",
    "archived-launchers/",
    ".env",
    ".env.*",
    "*.log",
    "logs/",
    "reports/",
    ".cache/",
    "node_modules/",
    "__pycache__/",
    ".DS_Store"
  )) {
    Assert-Contains -Content $gitignore -Pattern $required -Message ".gitignore must contain $required"
  }
}

foreach ($requiredFile in @(
  "README.md",
  "README.zh-CN.md",
  "VERSION",
  "LICENSE",
  "CHANGELOG.md",
  "CONTRIBUTING.md",
  "SECURITY.md",
  "docs/project-details.md",
  "docs/manual-test-checklist.md",
  "docs/publishing-checklist.md"
)) {
  if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $requiredFile))) {
    Add-Failure "$requiredFile is missing."
  }
}

$readmePath = Join-Path $repoRoot "README.md"
if (Test-Path -LiteralPath $readmePath) {
  $readme = Get-Content -Raw -LiteralPath $readmePath
  Assert-Contains -Content $readme -Pattern "# ChatGPT Memory Transferor" -Message "README must use the official project name."
  Assert-Contains -Content $readme -Pattern $expectedCloneUrl -Message "README clone URL must use the public placeholder repository address."
  Assert-Contains -Content $readme -Pattern "README.zh-CN.md" -Message "README must link to the Chinese README."
  Assert-Contains -Content $readme -Pattern "docs/project-details.md" -Message "README must link to docs/project-details.md."

  foreach ($pattern in @(
    ("your-" + "name"),
    ("your-" + "repo"),
    ("user" + "name/" + "repo" + "-name"),
    ("<your-" + "org-or-user>"),
    ("github.com/" + "<")
  )) {
    if ($readme -match [regex]::Escape($pattern)) {
      Add-Failure "README contains a placeholder repository address."
    }
  }
}

$versionPath = Join-Path $repoRoot "VERSION"
if (Test-Path -LiteralPath $versionPath) {
  $version = (Get-Content -Raw -LiteralPath $versionPath).Trim()
  if ($version -notmatch "^\d+\.\d+\.\d+$") {
    Add-Failure "VERSION must contain a semantic version such as 0.1.1."
  } else {
    foreach ($versionedFile in @("README.md", "README.zh-CN.md", "CHANGELOG.md")) {
      $path = Join-Path $repoRoot $versionedFile
      if ((Test-Path -LiteralPath $path) -and ((Get-Content -Raw -LiteralPath $path) -notmatch [regex]::Escape($version))) {
        Add-Failure "$versionedFile must mention current version $version."
      }
    }

    $changelogPath = Join-Path $repoRoot "CHANGELOG.md"
    if ((Test-Path -LiteralPath $changelogPath) -and ((Get-Content -Raw -LiteralPath $changelogPath) -notmatch [regex]::Escape("## v$version - "))) {
      Add-Failure "CHANGELOG.md must contain a release section for v$version."
    }
  }
}

$chineseReadmePath = Join-Path $repoRoot "README.zh-CN.md"
if (Test-Path -LiteralPath $chineseReadmePath) {
  $chineseReadme = Get-Content -Raw -LiteralPath $chineseReadmePath
  Assert-Contains -Content $chineseReadme -Pattern "# ChatGPT Memory Transferor" -Message "Chinese README must use the official project name."
  Assert-Contains -Content $chineseReadme -Pattern $expectedCloneUrl -Message "Chinese README clone URL must use the public placeholder repository address."
  Assert-Contains -Content $chineseReadme -Pattern "README.md" -Message "Chinese README must link back to the English README."
  Assert-Contains -Content $chineseReadme -Pattern "docs/project-details.md" -Message "Chinese README must link to docs/project-details.md."
  Assert-Contains -Content $chineseReadme -Pattern $securityEmail -Message "Chinese README must contain the security contact email."
}

$projectDetailsPath = Join-Path $repoRoot "docs/project-details.md"
if (Test-Path -LiteralPath $projectDetailsPath) {
  $projectDetails = Get-Content -Raw -LiteralPath $projectDetailsPath
  Assert-Contains -Content $projectDetails -Pattern "[Back to README](../README.md)" -Message "Project details must link back to README."
}

Test-TrackedPathSafety -TrackedFiles $trackedFiles
Test-TrackedIgnoredFiles
Test-ContentSafety -TextFiles $trackedTextFiles
Test-RepositoryPlaceholders -TextFiles $trackedTextFiles
Test-EmailConsistency -TextFiles $trackedTextFiles
Test-MarkdownLocalLinks -TextFiles $trackedTextFiles
Test-VersionAwareImportBehavior

if ($failures.Count -gt 0) {
  Write-Host "Release validation failed:" -ForegroundColor Red
  foreach ($failure in $failures) {
    Write-Host " - $failure" -ForegroundColor Red
  }
  exit 1
}

Write-Host "Release validation passed." -ForegroundColor Green
