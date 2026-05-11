param(
  [switch]$SkipExport,
  [switch]$DryRunImport,
  [int]$ExportLimit = 0,
  [int]$ExportSkip = 0,
  [int]$ImportLimit = 0,
  [int]$ImportSkip = 0,
  [switch]$AssumeYes,
  [switch]$AllowDuplicates,
  [switch]$KeepSuperseded,
  [switch]$NoPause
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputDir = Join-Path $scriptDir "outputs"
$exportScript = Join-Path $scriptDir "run-account-a-share-link-export.ps1"
$importScript = Join-Path $scriptDir "run-account-b-shared-link-import.ps1"

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "== $Message" -ForegroundColor Cyan
}

function Test-ShareUrl {
  param([string]$Url)

  if ([string]::IsNullOrWhiteSpace($Url)) {
    return $false
  }

  try {
    $uri = [Uri]$Url
    $hostName = $uri.Host.ToLowerInvariant()
    return (
      $uri.Scheme -eq "https" -and
      ($hostName -eq "chatgpt.com" -or $hostName -eq "chat.openai.com") -and
      $uri.AbsolutePath -like "/share/*"
    )
  } catch {
    return $false
  }
}

function Get-LatestExportJson {
  $files = Get-ChildItem -File -Path $outputDir -Filter "chatgpt-account-a-share-links-with-projects_*.json" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike "*dry-run*" } |
    Sort-Object LastWriteTime -Descending

  foreach ($file in $files) {
    try {
      $payload = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
      $usable = @($payload.results | Where-Object { $_.share_url -and $_.status -ne "error" -and (Test-ShareUrl -Url ([string]$_.share_url)) })
      $projects = @($payload.projects)
      if ($usable.Count -gt 0 -or $projects.Count -gt 0) {
        return $file.FullName
      }
    } catch {
      continue
    }
  }

  throw "outputs 里没有找到可用的 A 账号共享链接/项目 JSON。"
}

function Get-ImportableLinkCount {
  param([string]$Path)

  $payload = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  return @($payload.results | Where-Object { $_.share_url -and $_.status -ne "error" -and (Test-ShareUrl -Url ([string]$_.share_url)) }).Count
}

if (-not (Test-Path -LiteralPath $exportScript)) {
  throw "缺少 A 账号导出脚本：$exportScript"
}
if (-not (Test-Path -LiteralPath $importScript)) {
  throw "缺少 B 账号导入脚本：$importScript"
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

try {
  if (-not $SkipExport) {
    Write-Step "阶段 1/2：A 账号生成共享链接"
    $exportArgs = @{
      NoPause = $true
    }
    if ($ExportLimit -gt 0) {
      $exportArgs["Limit"] = $ExportLimit
    }
    if ($ExportSkip -gt 0) {
      $exportArgs["Skip"] = $ExportSkip
    }
    & $exportScript @exportArgs
  } else {
    Write-Step "阶段 1/2：跳过 A 账号导出，使用 outputs 里的最新 JSON"
  }

  $latestJson = Get-LatestExportJson
  Write-Host "B 账号导入输入：$latestJson"
  $importableLinkCount = Get-ImportableLinkCount -Path $latestJson

  if ($importableLinkCount -eq 0) {
    Write-Step "阶段 2/2：没有可导入共享链接，跳过 B 账号聊天导入"
    Write-Host "A 账号 JSON 仍可交给项目还原脚本，用于创建空项目和转移项目附件。"
  } else {
    Write-Step "阶段 2/2：B 账号自动打开共享链接并生成副本"
    $importArgs = @{
      InputJson = $latestJson
      NoPause = $true
    }
    if ($DryRunImport) {
      $importArgs["DryRun"] = $true
    }
    if ($ImportLimit -gt 0) {
      $importArgs["Limit"] = $ImportLimit
    }
    if ($ImportSkip -gt 0) {
      $importArgs["Skip"] = $ImportSkip
    }
    if ($AssumeYes) {
      $importArgs["AssumeYes"] = $true
    }
    if ($AllowDuplicates) {
      $importArgs["AllowDuplicates"] = $true
    }
    if ($KeepSuperseded) {
      $importArgs["KeepSuperseded"] = $true
    }

    & $importScript @importArgs
  }

  Write-Step "全流程结束"
} finally {
  if (-not $NoPause) {
    Write-Host ""
    Write-Host "按 Enter 关闭窗口。"
    Read-Host | Out-Null
  }
}
