param(
  [switch]$SelfTest,
  [switch]$DryRun,
  [switch]$SkipProjectFiles,
  [int]$Skip = 0,
  [int]$Limit = 0,
  [int]$DelayMs = 500,
  [switch]$NoPause
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$injectScript = Join-Path $scriptDir "account-a-create-share-links-cdp.js"
$profileDir = Join-Path $scriptDir "browser-profile-account-a"
$outputDir = Join-Path $scriptDir "outputs"
$port = 9227

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "== $Message" -ForegroundColor Cyan
}

function Get-BrowserPath {
  $candidates = @(
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:LocalAppData\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
  )

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }

  throw "未找到 Microsoft Edge 或 Google Chrome。请先安装其中一个浏览器。"
}

function Get-BrowserProxyArgs {
  try {
    $internetSettings = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    if ($internetSettings.ProxyEnable -ne 1 -or [string]::IsNullOrWhiteSpace($internetSettings.ProxyServer)) {
      return @()
    }

    $proxyServer = [string]$internetSettings.ProxyServer
    $proxyValue = $proxyServer
    if ($proxyServer -notmatch "://") {
      $proxyValue = "http://$proxyServer"
    }

    return @(
      "--proxy-server=$proxyValue",
      "--proxy-bypass-list=<-loopback>;localhost;127.0.0.1;::1"
    )
  } catch {
    return @()
  }
}

function Invoke-JsonRequest {
  param([string]$Uri)
  Invoke-RestMethod -Uri $Uri -UseBasicParsing -TimeoutSec 5
}

function Wait-DevTools {
  param([int]$Port)

  $deadline = (Get-Date).AddSeconds(45)
  while ((Get-Date) -lt $deadline) {
    try {
      $version = Invoke-JsonRequest "http://127.0.0.1:$Port/json/version"
      if ($version.webSocketDebuggerUrl) {
        return $true
      }
    } catch {
      Start-Sleep -Milliseconds 500
    }
  }

  return $false
}

function Get-ChatGptTarget {
  param([int]$Port)

  $deadline = (Get-Date).AddSeconds(45)
  $fallbackTarget = $null
  while ((Get-Date) -lt $deadline) {
    $targets = Invoke-JsonRequest "http://127.0.0.1:$Port/json/list"
    $target = @($targets | Where-Object {
      $_.type -eq "page" -and $_.url -like "https://chatgpt.com*"
    } | Select-Object -First 1)

    if ($target -and $target.webSocketDebuggerUrl) {
      return $target
    }

    if (-not $fallbackTarget) {
      $fallbackTarget = @($targets | Where-Object {
        $_.type -eq "page" -and $_.webSocketDebuggerUrl
      } | Select-Object -First 1)
    }

    Start-Sleep -Milliseconds 500
  }

  if ($fallbackTarget -and $fallbackTarget.webSocketDebuggerUrl) {
    return $fallbackTarget
  }

  throw "未找到 chatgpt.com 页面。"
}

function ConvertTo-CompactJson {
  param($Value)
  $Value | ConvertTo-Json -Depth 100 -Compress
}

function Get-SafePathSegment {
  param(
    [string]$Value,
    [string]$Fallback = "item"
  )

  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) {
    $text = $Fallback
  }

  foreach ($char in [IO.Path]::GetInvalidFileNameChars()) {
    $text = $text.Replace([string]$char, "_")
  }
  $text = ($text -replace "\s+", " ").Trim()
  if ([string]::IsNullOrWhiteSpace($text)) {
    $text = $Fallback
  }
  if ($text.Length -gt 120) {
    $text = $text.Substring(0, 120).Trim()
  }
  return $text
}

function Get-ShortFileKey {
  param($File)

  $key = [string]$File.file_id
  if ([string]::IsNullOrWhiteSpace($key)) {
    $key = [string]$File.id
  }
  if ([string]::IsNullOrWhiteSpace($key)) {
    return "file"
  }

  $key = Get-SafePathSegment -Value $key -Fallback "file"
  if ($key.Length -gt 24) {
    return $key.Substring(0, 24)
  }
  return $key
}

function New-CdpConnection {
  param([string]$WebSocketUrl)

  $ws = [System.Net.WebSockets.ClientWebSocket]::new()
  $null = $ws.ConnectAsync([Uri]$WebSocketUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
  return $ws
}

$script:cdpId = 0

function Receive-CdpMessage {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    [int]$TargetId
  )

  $buffer = New-Object byte[] 65536
  $stream = [System.IO.MemoryStream]::new()

  do {
    $segment = [ArraySegment[byte]]::new($buffer)
    $result = $WebSocket.ReceiveAsync($segment, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
      throw "DevTools WebSocket 已关闭。"
    }
    $stream.Write($buffer, 0, $result.Count)
  } while (-not $result.EndOfMessage)

  $json = [Text.Encoding]::UTF8.GetString($stream.ToArray())
  $message = $json | ConvertFrom-Json

  if ($message.method -eq "Runtime.consoleAPICalled") {
    $parts = @()
    foreach ($arg in @($message.params.args)) {
      if ($null -ne $arg.value) {
        $parts += [string]$arg.value
      } elseif ($arg.description) {
        $parts += [string]$arg.description
      }
    }
    if ($parts.Count -gt 0) {
      Write-Host ($parts -join " ")
    }
  }

  if ($message.id -eq $TargetId) {
    return $message
  }

  return $null
}

function Invoke-Cdp {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    [string]$Method,
    [hashtable]$Params = @{}
  )

  $script:cdpId += 1
  $id = $script:cdpId
  $payload = ConvertTo-CompactJson @{
    id = $id
    method = $Method
    params = $Params
  }
  $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
  $segment = [ArraySegment[byte]]::new($bytes)
  $WebSocket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()

  while ($true) {
    $message = Receive-CdpMessage -WebSocket $WebSocket -TargetId $id
    if ($null -ne $message) {
      if ($message.error) {
        throw "CDP $Method 失败：$($message.error.message)"
      }
      return $message.result
    }
  }
}

function Test-ChatGptSession {
  param([System.Net.WebSockets.ClientWebSocket]$WebSocket)

  $expression = @"
(async () => {
  try {
    const response = await fetch('/api/auth/session', { credentials: 'include' });
    if (!response.ok) return false;
    const session = await response.json();
    return Boolean(session && session.accessToken);
  } catch {
    return false;
  }
})()
"@

  $result = Invoke-Cdp -WebSocket $WebSocket -Method "Runtime.evaluate" -Params @{
    expression = $expression
    awaitPromise = $true
    returnByValue = $true
  }

  return [bool]$result.result.value
}

function Invoke-ReadOnlyApiSelfTest {
  param([System.Net.WebSockets.ClientWebSocket]$WebSocket)

  $expression = @'
(async () => {
  const result = await (async () => {
    const sessionResponse = await fetch('/api/auth/session', { credentials: 'include' });
    if (!sessionResponse.ok) {
      return { ok: false, stage: 'session', status: sessionResponse.status };
    }
    const session = await sessionResponse.json();
    const token = session && session.accessToken;
    if (!token) return { ok: false, stage: 'token' };

    const api = async (path) => {
      const response = await fetch(path, {
        credentials: 'include',
        headers: {
          accept: 'application/json',
          authorization: 'Bearer ' + token
        }
      });
      if (!response.ok) {
        return { ok: false, status: response.status, path };
      }
      return { ok: true, data: await response.json() };
    };

    const list = await api('/backend-api/conversations?offset=0&limit=5&order=updated');
    if (!list.ok) return { ok: false, stage: 'list', status: list.status, path: list.path };
    const items = Array.isArray(list.data.items) ? list.data.items : [];
    if (!items.length) {
      return { ok: true, listed: 0, detail_ok: false, current_node_ok: false };
    }

    const first = items[0];
    const detail = await api('/backend-api/conversation/' + encodeURIComponent(first.id));
    if (!detail.ok) return { ok: false, stage: 'detail', status: detail.status, path: detail.path };

    const currentNodeOk = Boolean(
      detail.data.current_node ||
      detail.data.current_node_id ||
      (detail.data.mapping && Object.keys(detail.data.mapping).length)
    );

    return {
      ok: true,
      listed: items.length,
      detail_ok: true,
      current_node_ok: currentNodeOk,
      first_has_id: Boolean(first.id)
    };
  })();

  return JSON.stringify(result);
})()
'@

  return Invoke-Cdp -WebSocket $WebSocket -Method "Runtime.evaluate" -Params @{
    expression = $expression
    awaitPromise = $true
    returnByValue = $true
  }
}

function Get-PageHref {
  param([System.Net.WebSockets.ClientWebSocket]$WebSocket)

  $result = Invoke-Cdp -WebSocket $WebSocket -Method "Runtime.evaluate" -Params @{
    expression = "location.href"
    returnByValue = $true
  }

  return [string]$result.result.value
}

function Ensure-ChatGptPage {
  param([System.Net.WebSockets.ClientWebSocket]$WebSocket)

  $href = Get-PageHref -WebSocket $WebSocket
  if ($href -notlike "https://chatgpt.com*") {
    Write-Host "当前页面不是 chatgpt.com，正在导航：$href"
    Invoke-Cdp -WebSocket $WebSocket -Method "Page.navigate" -Params @{
      url = "https://chatgpt.com"
    } | Out-Null
  }

  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-Date) -lt $deadline) {
    try {
      $href = Get-PageHref -WebSocket $WebSocket
      if ($href -like "https://chatgpt.com*") {
        return $href
      }
    } catch {
      Start-Sleep -Milliseconds 500
    }
    Start-Sleep -Milliseconds 500
  }

  throw "专用浏览器没有成功进入 https://chatgpt.com。最后页面：$href"
}

function Get-ProjectFileDownloadUrl {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    [string]$ProjectId,
    [string]$FileId
  )

  $projectIdJson = $ProjectId | ConvertTo-Json -Compress
  $fileIdJson = $FileId | ConvertTo-Json -Compress
  $expression = @"
(async () => {
  const projectId = $projectIdJson;
  const fileId = $fileIdJson;
  const sessionResponse = await fetch("/api/auth/session", {
    credentials: "include",
    headers: { accept: "application/json" }
  });
  if (!sessionResponse.ok) {
    return JSON.stringify({ ok: false, status: sessionResponse.status, error: "Cannot read ChatGPT session." });
  }
  const session = await sessionResponse.json();
  if (!session || !session.accessToken) {
    return JSON.stringify({ ok: false, status: 0, error: "No accessToken found." });
  }

  const query = new URLSearchParams({ gizmo_id: projectId });
  const response = await fetch("/backend-api/files/download/" + encodeURIComponent(fileId) + "?" + query.toString(), {
    credentials: "include",
    headers: {
      accept: "application/json",
      authorization: "Bearer " + session.accessToken
    }
  });
  const text = await response.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  const downloadUrl = data && (data.download_url || data.url);
  return JSON.stringify({
    ok: response.ok && Boolean(downloadUrl),
    status: response.status,
    download_url: downloadUrl || "",
    file_status: data && data.status || "",
    error_code: data && data.error_code || "",
    error: response.ok ? "" : (typeof data === "string" ? data : JSON.stringify(data)).slice(0, 500)
  });
})()
"@

  $result = Invoke-Cdp -WebSocket $WebSocket -Method "Runtime.evaluate" -Params @{
    expression = $expression
    awaitPromise = $true
    returnByValue = $true
  }
  if ($result.exceptionDetails) {
    $description = $result.exceptionDetails.exception.description
    if ([string]::IsNullOrWhiteSpace($description)) {
      $description = $result.exceptionDetails.text
    }
    throw "获取文件下载地址失败：$description"
  }

  $value = $result.result.value | ConvertFrom-Json
  if (-not $value.ok) {
    throw "HTTP $($value.status), file_status=$($value.file_status), error_code=$($value.error_code), error=$($value.error)"
  }
  return [string]$value.download_url
}

function Invoke-BrowserDownloadFile {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    [string]$DownloadUrl,
    [string]$TargetPath,
    [int64]$ExpectedSize
  )

  if ([string]::IsNullOrWhiteSpace($DownloadUrl)) {
    throw "下载地址为空。"
  }

  $targetDir = Split-Path -Parent $TargetPath
  $downloadDir = Join-Path $targetDir (".download-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

  try {
    $downloadBehaviorParams = @{
      behavior = "allow"
      downloadPath = $downloadDir
    }
    try {
      Invoke-Cdp -WebSocket $WebSocket -Method "Browser.setDownloadBehavior" -Params $downloadBehaviorParams | Out-Null
    } catch {
      Invoke-Cdp -WebSocket $WebSocket -Method "Page.setDownloadBehavior" -Params $downloadBehaviorParams | Out-Null
    }

    $downloadUrlJson = $DownloadUrl | ConvertTo-Json -Compress
    $targetNameJson = (Split-Path -Leaf $TargetPath) | ConvertTo-Json -Compress
    $expression = @"
(() => {
  const url = $downloadUrlJson;
  const fileName = $targetNameJson;
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = fileName;
  anchor.rel = "noopener";
  anchor.style.display = "none";
  document.body.appendChild(anchor);
  anchor.click();
  setTimeout(() => anchor.remove(), 1000);
  return true;
})()
"@

    Invoke-Cdp -WebSocket $WebSocket -Method "Runtime.evaluate" -Params @{
      expression = $expression
      returnByValue = $true
    } | Out-Null

    $deadline = (Get-Date).AddSeconds(1800)
    while ((Get-Date) -lt $deadline) {
      $partialFiles = @(Get-ChildItem -File -Path $downloadDir -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*.crdownload" })
      $completeFiles = @(Get-ChildItem -File -Path $downloadDir -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*.crdownload" })
      if ($completeFiles.Count -gt 0 -and $partialFiles.Count -eq 0) {
        $candidate = $completeFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($ExpectedSize -le 0 -or $candidate.Length -eq $ExpectedSize) {
          if (Test-Path -LiteralPath $TargetPath) {
            Remove-Item -LiteralPath $TargetPath -Force
          }
          Move-Item -LiteralPath $candidate.FullName -Destination $TargetPath
          return
        }
        throw "浏览器下载完成但文件大小不匹配：期望 $ExpectedSize，实际 $($candidate.Length)。"
      }
      Start-Sleep -Milliseconds 500
    }

    throw "等待浏览器下载完成超时。"
  } finally {
    try {
      if ((Test-Path -LiteralPath $downloadDir) -and @((Get-ChildItem -LiteralPath $downloadDir -Force -ErrorAction SilentlyContinue)).Count -eq 0) {
        Remove-Item -LiteralPath $downloadDir -Force
      }
    } catch {
    }
  }
}

function Save-ProjectFiles {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    $Report
  )

  $projects = @($Report.projects)
  $root = Join-Path $outputDir "project-files"
  $accountRoot = Join-Path $root "account-a"
  New-Item -ItemType Directory -Force -Path $accountRoot | Out-Null

  $downloaded = 0
  $reused = 0
  $errors = 0
  $total = 0

  foreach ($project in $projects) {
    $projectId = [string]$project.id
    if ([string]::IsNullOrWhiteSpace($projectId)) {
      continue
    }

    $projectName = Get-SafePathSegment -Value ([string]$project.name) -Fallback $projectId
    $projectDir = Join-Path $accountRoot "$projectName--$projectId"
    New-Item -ItemType Directory -Force -Path $projectDir | Out-Null

    foreach ($file in @($project.files)) {
      $total += 1
      $fileId = [string]$file.file_id
      if ([string]::IsNullOrWhiteSpace($fileId)) {
        $fileId = [string]$file.id
      }
      if ([string]::IsNullOrWhiteSpace($fileId)) {
        $errors += 1
        $file | Add-Member -NotePropertyName download_status -NotePropertyValue "error" -Force
        $file | Add-Member -NotePropertyName download_error -NotePropertyValue "No file_id found in project file metadata." -Force
        continue
      }

      $safeName = Get-SafePathSegment -Value ([string]$file.name) -Fallback $fileId
      $targetName = "$(Get-ShortFileKey -File $file)__$safeName"
      $targetPath = Join-Path $projectDir $targetName

      try {
        [int64]$expectedSize = 0
        if ($null -ne $file.size) {
          [int64]::TryParse([string]$file.size, [ref]$expectedSize) | Out-Null
        }

        if ((Test-Path -LiteralPath $targetPath) -and $expectedSize -gt 0) {
          $existing = Get-Item -LiteralPath $targetPath
          if ($existing.Length -eq $expectedSize) {
            $reused += 1
            $file | Add-Member -NotePropertyName local_path -NotePropertyValue $targetPath -Force
            $file | Add-Member -NotePropertyName download_status -NotePropertyValue "already_downloaded" -Force
            $file | Add-Member -NotePropertyName download_error -NotePropertyValue "" -Force
            continue
          }
        }

        Write-Host "[file] 下载项目附件：$($project.name) / $($file.name)"
        $downloadUrl = Get-ProjectFileDownloadUrl -WebSocket $WebSocket -ProjectId $projectId -FileId $fileId
        $downloadUri = $downloadUrl
        if ($downloadUri.StartsWith("/")) {
          $downloadUri = "https://chatgpt.com$downloadUri"
        }
        try {
          Invoke-WebRequest -Uri $downloadUri -UseBasicParsing -OutFile $targetPath -TimeoutSec 1800 | Out-Null
        } catch {
          Write-Host "[file:fallback] PowerShell 下载失败，改用浏览器下载：$($_.Exception.Message)" -ForegroundColor Yellow
          Invoke-BrowserDownloadFile -WebSocket $WebSocket -DownloadUrl $downloadUrl -TargetPath $targetPath -ExpectedSize $expectedSize
        }

        $downloaded += 1
        $file | Add-Member -NotePropertyName local_path -NotePropertyValue $targetPath -Force
        $file | Add-Member -NotePropertyName download_status -NotePropertyValue "downloaded" -Force
        $file | Add-Member -NotePropertyName download_error -NotePropertyValue "" -Force
      } catch {
        $errors += 1
        $message = $_.Exception.Message
        Write-Host "[file:error] $($project.name) / $($file.name) :: $message" -ForegroundColor Yellow
        $file | Add-Member -NotePropertyName local_path -NotePropertyValue $targetPath -Force
        $file | Add-Member -NotePropertyName download_status -NotePropertyValue "error" -Force
        $file | Add-Member -NotePropertyName download_error -NotePropertyValue $message -Force
      }
    }
  }

  $Report.config | Add-Member -NotePropertyName projectFilesRoot -NotePropertyValue $accountRoot -Force
  $Report.summary | Add-Member -NotePropertyName project_files_total -NotePropertyValue $total -Force
  $Report.summary | Add-Member -NotePropertyName project_files_downloaded -NotePropertyValue $downloaded -Force
  $Report.summary | Add-Member -NotePropertyName project_files_reused -NotePropertyValue $reused -Force
  $Report.summary | Add-Member -NotePropertyName project_files_download_errors -NotePropertyValue $errors -Force

  return [pscustomobject]@{
    Total = $total
    Downloaded = $downloaded
    Reused = $reused
    Errors = $errors
    Root = $accountRoot
  }
}

function Export-Report {
  param($Report)

  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
  $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
  $modePrefix = ""
  if ($Report.config -and $Report.config.dryRun) {
    $modePrefix = "dry-run_"
  }
  $jsonPath = Join-Path $outputDir "chatgpt-account-a-${modePrefix}share-links-with-projects_$stamp.json"
  $csvPath = Join-Path $outputDir "chatgpt-account-a-${modePrefix}share-links-with-projects_$stamp.csv"

  $Report | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

  $rows = @($Report.results | ForEach-Object {
    [pscustomobject]@{
      status = $_.status
      project_name = $_.project_name
      project_id = $_.project_id
      project_source = $_.project_source
      title = $_.title
      share_url = $_.share_url
      source = $_.source
      id = $_.id
      share_id = $_.share_id
      create_time = $_.create_time
      update_time = $_.update_time
      error = $_.error
    }
  })

  $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

  return [pscustomobject]@{
    JsonPath = $jsonPath
    CsvPath = $csvPath
  }
}

function Invoke-BackgroundExport {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    [string]$Source,
    [bool]$DryRunMode,
    [int]$MaxItems,
    [int]$ItemDelayMs
  )

  if ($ItemDelayMs -lt 0) {
    throw "-DelayMs 不能小于 0。"
  }

  $options = @{
    dryRun = $DryRunMode
    delayMs = $ItemDelayMs
  }
  if ($MaxItems -gt 0) {
    $options.maxConversations = $MaxItems
  }
  if ($Skip -gt 0) {
    $options.skipConversations = $Skip
  }

  $sourceJson = $Source | ConvertTo-Json -Compress
  $optionsJson = $options | ConvertTo-Json -Compress

  $startExpression = @"
(() => {
  const source = $sourceJson;
  const options = $optionsJson;
  const state = {
    startedAt: new Date().toISOString(),
    done: false,
    error: null,
    logs: [],
    summary: null,
    reportJson: null,
    lastLogAt: null
  };

  window.__CHATGPT_SHARE_EXPORT_STATE__ = state;
  window.__CHATGPT_SHARE_EXPORT_OPTIONS__ = options || {};

  const originals = {
    log: console.log.bind(console),
    warn: console.warn.bind(console),
    error: console.error.bind(console)
  };

  const toText = (value) => {
    if (typeof value === "string") return value;
    try { return JSON.stringify(value); } catch { return String(value); }
  };

  const push = (level, args) => {
    const text = args.map(toText).join(" ");
    state.logs.push({ ts: new Date().toISOString(), level, text });
    state.lastLogAt = new Date().toISOString();
    originals[level](...args);
  };

  console.log = (...args) => push("log", args);
  console.warn = (...args) => push("warn", args);
  console.error = (...args) => push("error", args);

  Promise.resolve()
    .then(() => eval(source))
    .then((report) => {
      state.summary = report && report.summary ? report.summary : null;
      state.reportJson = JSON.stringify(report);
      state.done = true;
    })
    .catch((error) => {
      state.error = String((error && error.stack) || (error && error.message) || error);
      state.done = true;
    })
    .finally(() => {
      console.log = originals.log;
      console.warn = originals.warn;
      console.error = originals.error;
    });

  return JSON.stringify({ started: true, dryRun: Boolean(options && options.dryRun), maxConversations: options && options.maxConversations || null });
})()
"@

  $start = Invoke-Cdp -WebSocket $WebSocket -Method "Runtime.evaluate" -Params @{
    expression = $startExpression
    returnByValue = $true
  }
  Write-Host "后台导出任务：$($start.result.value)"

  $idleTicks = 0
  while ($true) {
    Start-Sleep -Seconds 2
    $stateExpression = @'
(() => {
  const state = window.__CHATGPT_SHARE_EXPORT_STATE__;
  if (!state) return JSON.stringify({ exists: false });
  const logs = state.logs.splice(0, state.logs.length);
  return JSON.stringify({
    exists: true,
    done: state.done,
    error: state.error,
    summary: state.summary,
    lastLogAt: state.lastLogAt,
    logs
  });
})()
'@

    $stateResult = Invoke-Cdp -WebSocket $WebSocket -Method "Runtime.evaluate" -Params @{
      expression = $stateExpression
      returnByValue = $true
    }

    $state = $stateResult.result.value | ConvertFrom-Json
    if (-not $state.exists) {
      throw "页面里没有找到导出任务状态。"
    }

    $logCount = 0
    foreach ($log in @($state.logs)) {
      $logCount += 1
      Write-Host "[$($log.level)] $($log.text)"
    }

    if ($state.done) {
      if ($state.error) {
        throw "页面导出脚本失败：$($state.error)"
      }
      break
    }

    if ($logCount -eq 0) {
      $idleTicks += 1
      if ($idleTicks -ge 5) {
        Write-Host "仍在运行，最近没有新日志；lastLogAt=$($state.lastLogAt)"
        $idleTicks = 0
      }
    } else {
      $idleTicks = 0
    }
  }

  $reportResult = Invoke-Cdp -WebSocket $WebSocket -Method "Runtime.evaluate" -Params @{
    expression = "window.__CHATGPT_SHARE_EXPORT_STATE__ && window.__CHATGPT_SHARE_EXPORT_STATE__.reportJson || ''"
    returnByValue = $true
  }

  if ([string]::IsNullOrWhiteSpace($reportResult.result.value)) {
    throw "页面导出完成，但没有返回报告 JSON。"
  }

  return $reportResult.result.value | ConvertFrom-Json
}

if (-not (Test-Path -LiteralPath $injectScript)) {
  throw "缺少注入脚本：$injectScript"
}

New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

Write-Step "启动专用浏览器窗口"
$browserPath = Get-BrowserPath
$proxyArgs = Get-BrowserProxyArgs
$browserArgs = @(
  "--remote-debugging-port=$port",
  "--user-data-dir=$profileDir",
  "--no-first-run",
  "--new-window"
)
$browserArgs += $proxyArgs
$browserArgs += "https://chatgpt.com"

Write-Host "浏览器：$browserPath"
if ($proxyArgs.Count -gt 0) {
  Write-Host "浏览器代理：$($proxyArgs -join ' ')"
} else {
  Write-Host "浏览器代理：使用系统默认设置"
}
Write-Host "如果看到 OpenAI.ChatGPT-Desktop 或 Statsig 日志，那是 ChatGPT 桌面端输出，不是这个导出脚本。"

$browserProcess = Start-Process -FilePath $browserPath -ArgumentList $browserArgs -PassThru

if (-not (Wait-DevTools -Port $port)) {
  throw "浏览器 DevTools 端口没有启动。请关闭刚打开的专用浏览器窗口后再试。"
}

$target = Get-ChatGptTarget -Port $port
$ws = New-CdpConnection -WebSocketUrl $target.webSocketDebuggerUrl

try {
  Invoke-Cdp -WebSocket $ws -Method "Runtime.enable" | Out-Null
  Invoke-Cdp -WebSocket $ws -Method "Page.enable" | Out-Null
  $chatGptHref = Ensure-ChatGptPage -WebSocket $ws

  if ($SelfTest) {
    Write-Step "自检：验证页面注入通道"
    $probe = Invoke-Cdp -WebSocket $ws -Method "Runtime.evaluate" -Params @{
      expression = "({ ok: true, href: location.href, userAgent: navigator.userAgent })"
      returnByValue = $true
    }

    Write-Host "DevTools 注入：OK"
    Write-Host "当前页面：$chatGptHref"

    Write-Step "自检：检查 ChatGPT 登录态"
    if (Test-ChatGptSession -WebSocket $ws) {
      Write-Host "A 账号登录态：已检测到"
      Write-Step "自检：只读检查对话接口"
      $apiProbe = Invoke-ReadOnlyApiSelfTest -WebSocket $ws
      $apiValue = $apiProbe.result.value | ConvertFrom-Json
      if ($apiValue.ok) {
        Write-Host "对话列表读取：OK，样本数量 $($apiValue.listed)"
        Write-Host "对话详情读取：$($apiValue.detail_ok)"
        Write-Host "当前节点识别：$($apiValue.current_node_ok)"
      } else {
        throw "只读 API 自检失败：stage=$($apiValue.stage), status=$($apiValue.status), path=$($apiValue.path)"
      }
    } else {
      Write-Host "A 账号登录态：未检测到；这只影响正式导出，不影响本地工具自检。" -ForegroundColor Yellow
    }

    Write-Step "自检完成"
    Write-Host "没有创建共享链接，没有写入 outputs。"
    return
  }

  Write-Step "检查 A 账号登录状态"
  if (-not (Test-ChatGptSession -WebSocket $ws)) {
    Write-Host "请在刚打开的专用浏览器窗口里登录 A 账号。" -ForegroundColor Yellow
    Write-Host "登录完成并看到 ChatGPT 首页后，回到这个窗口按 Enter 继续。"
    Read-Host | Out-Null

    if (-not (Test-ChatGptSession -WebSocket $ws)) {
      throw "仍然没有检测到 A 账号登录状态。请确认专用浏览器窗口已经登录 chatgpt.com。"
    }
  }

  Write-Step "开始批量生成全部共享链接并识别项目"
  $expression = Get-Content -Raw -LiteralPath $injectScript
  $report = Invoke-BackgroundExport -WebSocket $ws -Source $expression -DryRunMode ([bool]$DryRun) -MaxItems $Limit -ItemDelayMs $DelayMs

  if ($DryRun) {
    Write-Host "Dry run：跳过项目附件下载。"
  } elseif ($SkipProjectFiles) {
    Write-Host "已指定 -SkipProjectFiles：跳过项目附件下载。"
  } else {
    Write-Step "下载 A 账号项目附件到本机"
    $fileSummary = Save-ProjectFiles -WebSocket $ws -Report $report
    Write-Host "项目附件：总计 $($fileSummary.Total)，新下载 $($fileSummary.Downloaded)，复用 $($fileSummary.Reused)，失败 $($fileSummary.Errors)"
    Write-Host "附件目录：$($fileSummary.Root)"
  }

  $paths = Export-Report -Report $report

  Write-Step "完成"
  Write-Host "成功：$($report.summary.ok) 条"
  Write-Host "失败：$($report.summary.errors) 条"
  Write-Host "项目识别：$($report.summary.projects_discovered) 个项目/自定义 GPT 记录，$($report.summary.project_conversation_mappings) 条对话映射"
  if ($null -ne $report.summary.project_files_total) {
    Write-Host "项目附件：$($report.summary.project_files_downloaded) 个已下载，$($report.summary.project_files_download_errors) 个失败"
  }
  Write-Host "JSON：$($paths.JsonPath)"
  Write-Host "CSV ：$($paths.CsvPath)"
  Write-Host ""
  Write-Host "下一步可用 b-open-shared-links.html 导入这个 JSON，用 B 账号逐条打开链接。"
} finally {
  if ($ws) {
    try {
      $ws.Dispose()
    } catch {
      Write-Host "DevTools WebSocket 释放失败，可忽略：$($_.Exception.Message)" -ForegroundColor Yellow
    }
  }
}

if (-not $NoPause) {
  Write-Host ""
  Write-Host "按 Enter 关闭窗口。"
  Read-Host | Out-Null
}
