param()

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$failures = New-Object System.Collections.Generic.List[string]
$currentUserName = ""
if ($env:USERPROFILE) {
  $currentUserName = Split-Path -Leaf $env:USERPROFILE
}

function Add-Failure {
  param([string]$Message)
  $failures.Add($Message) | Out-Null
}

function Test-PowerShellSyntax {
  param([string]$Path)

  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
  foreach ($errorItem in @($errors)) {
    Add-Failure "PowerShell syntax error in ${Path}: $($errorItem.Message)"
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
    Add-Failure "JavaScript syntax check failed: $Path"
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

Set-Location -LiteralPath $repoRoot

Get-ChildItem -File -Filter "*.ps1" | ForEach-Object { Test-PowerShellSyntax -Path $_.FullName }
Get-ChildItem -File -Filter "*.js" | ForEach-Object { Test-NodeSyntax -Path $_.FullName }

$htmlPath = Join-Path $repoRoot "b-open-shared-links.html"
$html = Get-Content -Raw -LiteralPath $htmlPath
Assert-Contains -Content $html -Pattern "normalizeShareUrl" -Message "Manual HTML tool must validate shared-link URLs."
Assert-Contains -Content $html -Pattern "chatgpt.com" -Message "Manual HTML tool must allow ChatGPT share links explicitly."

$gitignorePath = Join-Path $repoRoot ".gitignore"
if (-not (Test-Path -LiteralPath $gitignorePath)) {
  Add-Failure ".gitignore is missing."
} else {
  $gitignore = Get-Content -Raw -LiteralPath $gitignorePath
  foreach ($required in @(
    "browser-profile-account-a/",
    "browser-profile-account-b/",
    "outputs/",
    ".env",
    "node_modules/",
    "__pycache__/",
    ".DS_Store"
  )) {
    Assert-Contains -Content $gitignore -Pattern $required -Message ".gitignore must contain $required"
  }
}

foreach ($requiredFile in @("README.md", "LICENSE", "CHANGELOG.md", "CONTRIBUTING.md")) {
  if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $requiredFile))) {
    Add-Failure "$requiredFile is missing."
  }
}

$publishableFiles = Get-ChildItem -Recurse -File |
  Where-Object {
    $_.FullName -notmatch "\\browser-profile-account-[ab]\\" -and
    $_.FullName -notmatch "\\outputs\\" -and
    $_.FullName -notmatch "\\archived-launchers\\"
  }

foreach ($file in $publishableFiles) {
  $extension = $file.Extension.ToLowerInvariant()
  if ($extension -notin @(".md", ".ps1", ".js", ".html", ".json", ".gitignore", "")) {
    continue
  }

  $content = Get-Content -Raw -LiteralPath $file.FullName -ErrorAction SilentlyContinue
  $containsLocalUserName = $false
  if (-not [string]::IsNullOrWhiteSpace($currentUserName)) {
    $containsLocalUserName = $content -match [regex]::Escape($currentUserName)
  }

  if ($content -match "[A-Za-z]:\\Users\\" -or $containsLocalUserName) {
    Add-Failure "Publishable file contains a local user path or username: $($file.FullName)"
  }
}

if ($failures.Count -gt 0) {
  Write-Host "Release validation failed:" -ForegroundColor Red
  foreach ($failure in $failures) {
    Write-Host " - $failure" -ForegroundColor Red
  }
  exit 1
}

Write-Host "Release validation passed." -ForegroundColor Green
