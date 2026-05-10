param(
  [string]$InputJson = "",
  [switch]$SelfTest,
  [switch]$DryRun,
  [int]$Skip = 0,
  [int]$Limit = 0,
  [string]$Prompt = "请基于这个共享对话继续。请只回复：已接收。",
  [int]$Port = 9228,
  [switch]$AssumeYes,
  [switch]$AllowDuplicates,
  [switch]$NoPause
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$profileDir = Join-Path $scriptDir "browser-profile-account-b"
$outputDir = Join-Path $scriptDir "outputs"

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

function ConvertTo-JsonArray {
  param([object[]]$Value)

  $array = @($Value)
  if ($array.Count -eq 0) {
    return "[]"
  }
  if ($array.Count -eq 1) {
    return "[" + ($array[0] | ConvertTo-Json -Depth 100 -Compress) + "]"
  }

  return ConvertTo-Json -InputObject $array -Depth 100 -Compress
}

function Safe-Text {
  param($Value)
  if ($null -eq $Value) {
    return ""
  }
  return ([string]$Value).Trim()
}

function Normalize-DuplicateText {
  param($Value)
  $text = (Safe-Text $Value).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($text)) {
    return ""
  }
  return ($text -replace "\s+", " ").Trim()
}

function Get-ConversationIdFromUrl {
  param([string]$Url)
  if ([string]::IsNullOrWhiteSpace($Url)) {
    return ""
  }
  if ($Url -match "/c/([0-9a-fA-F-]+)") {
    return $Matches[1]
  }
  return ""
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

function Get-DuplicateTitleKey {
  param(
    $Title,
    $ProjectName
  )

  $titleKey = Normalize-DuplicateText $Title
  if ([string]::IsNullOrWhiteSpace($titleKey)) {
    return ""
  }
  if ($titleKey -eq "untitled conversation" -or $titleKey -eq "new chat") {
    return ""
  }

  $projectKey = Normalize-DuplicateText $ProjectName
  if ([string]::IsNullOrWhiteSpace($projectKey) -or $projectKey -eq "未知") {
    $projectKey = "未归属项目"
  }

  return "$projectKey|$titleKey"
}

function New-DuplicateIndex {
  [pscustomobject]@{
    BySourceId = @{}
    ByShareUrl = @{}
    ByTitleProject = @{}
    PriorReportCount = 0
    BrowserConversationCount = 0
  }
}

function New-DuplicateRecord {
  param(
    [string]$Status,
    [string]$Reason,
    [string]$MatchSource,
    $Row
  )

  $importedUrl = Safe-Text $Row.imported_url
  $importedId = Safe-Text $Row.imported_id
  if ([string]::IsNullOrWhiteSpace($importedId)) {
    $importedId = Get-ConversationIdFromUrl -Url $importedUrl
  }

  [pscustomobject]@{
    status = $Status
    reason = $Reason
    match_source = $MatchSource
    match_status = Safe-Text $Row.status
    match_id = Safe-Text $Row.id
    match_title = Safe-Text $Row.title
    match_project_name = Safe-Text $Row.project_name
    match_share_url = Safe-Text $Row.share_url
    match_imported_id = $importedId
    match_imported_url = $importedUrl
  }
}

function Add-DuplicateRecord {
  param(
    $Index,
    $Row,
    [string]$MatchSource,
    [switch]$BrowserMatch
  )

  $status = Safe-Text $Row.status
  if ($status -match "^(error|missing|dry-run)$") {
    return
  }
  if ((Safe-Text $Row.error)) {
    return
  }

  $recordStatus = if ($BrowserMatch) { "duplicate_suspected" } else { "duplicate" }
  $recordReason = if ($BrowserMatch) {
    "B 账号现有聊天里已有相同标题/项目。"
  } else {
    "本机历史成功导入报告里已有相同 A 源记录。"
  }

  $record = New-DuplicateRecord -Status $recordStatus -Reason $recordReason -MatchSource $MatchSource -Row $Row

  if (-not $BrowserMatch -and [string]::IsNullOrWhiteSpace($record.match_imported_id)) {
    return
  }

  $sourceId = Safe-Text $Row.id
  if (-not $BrowserMatch -and -not [string]::IsNullOrWhiteSpace($sourceId) -and -not $Index.BySourceId.ContainsKey($sourceId)) {
    $Index.BySourceId[$sourceId] = $record
  }

  $shareUrl = Safe-Text $Row.share_url
  if (-not $BrowserMatch -and -not [string]::IsNullOrWhiteSpace($shareUrl) -and -not $Index.ByShareUrl.ContainsKey($shareUrl)) {
    $Index.ByShareUrl[$shareUrl] = $record
  }

  $titleKey = Get-DuplicateTitleKey -Title $Row.title -ProjectName $Row.project_name
  if (-not [string]::IsNullOrWhiteSpace($titleKey) -and -not $Index.ByTitleProject.ContainsKey($titleKey)) {
    $Index.ByTitleProject[$titleKey] = $record
  }
}

function Get-LocalDuplicateIndex {
  param([string]$OutputDirectory)

  $index = New-DuplicateIndex
  $patterns = @(
    "chatgpt-account-b-import-report_*.json",
    "chatgpt-account-b-verified-import-report_*.json",
    "chatgpt-account-b-project-restore-report_*.json"
  )

  foreach ($pattern in $patterns) {
    $files = Get-ChildItem -File -Path $OutputDirectory -Filter $pattern -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -notlike "*dry-run*" } |
      Sort-Object LastWriteTime -Descending

    foreach ($file in $files) {
      try {
        $payload = Get-Content -Raw -LiteralPath $file.FullName | ConvertFrom-Json
        $rows = @()
        if ($payload -is [array]) {
          $rows = @($payload)
        } elseif ($payload.results) {
          $rows = @($payload.results)
        } elseif ($payload.data) {
          $rows = @($payload.data)
        }

        foreach ($row in $rows) {
          Add-DuplicateRecord -Index $index -Row $row -MatchSource $file.Name
        }
        $index.PriorReportCount += 1
      } catch {
        continue
      }
    }
  }

  return $index
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

function Add-BrowserDuplicateMatches {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    $Index
  )

  $expression = @'
(async () => {
  const output = {
    ok: false,
    conversations: [],
    endpoint_errors: []
  };

  const normalizeText = (value) => String(value || "").trim();
  const asArray = (payload) => {
    if (Array.isArray(payload)) return payload;
    if (Array.isArray(payload?.items)) return payload.items;
    if (Array.isArray(payload?.conversations)) return payload.conversations;
    if (Array.isArray(payload?.data)) return payload.data;
    if (Array.isArray(payload?.results)) return payload.results;
    if (Array.isArray(payload?.gizmos)) return payload.gizmos;
    if (Array.isArray(payload?.projects)) return payload.projects;
    return [];
  };
  const getConversationId = (item) => normalizeText(
    item?.id ||
    item?.conversation_id ||
    item?.conversationId ||
    item?.conversation?.id
  );
  const getTitle = (item) => normalizeText(
    item?.title ||
    item?.name ||
    item?.conversation?.title ||
    item?.conversation?.name
  );
  const getProjectName = (project) => normalizeText(
    project?.name ||
    project?.title ||
    project?.display_name ||
    project?.gizmo?.display?.name ||
    project?.gizmo?.display?.title
  );

  const sessionResponse = await fetch("/api/auth/session", { credentials: "include" });
  if (!sessionResponse.ok) {
    output.endpoint_errors.push({ path: "/api/auth/session", status: sessionResponse.status });
    return JSON.stringify(output);
  }
  const session = await sessionResponse.json();
  const token = session && session.accessToken;
  if (!token) {
    output.endpoint_errors.push({ path: "/api/auth/session", status: "missing-token" });
    return JSON.stringify(output);
  }

  const api = async (path) => {
    const response = await fetch(path, {
      credentials: "include",
      headers: {
        accept: "application/json",
        authorization: "Bearer " + token
      }
    });
    if (!response.ok) {
      const text = await response.text().catch(() => "");
      throw new Error("HTTP " + response.status + " " + path + " " + text.slice(0, 160));
    }
    return response.json();
  };

  const seen = new Set();
  const remember = (item, source, projectName = "") => {
    const id = getConversationId(item);
    const title = getTitle(item);
    if (!id || seen.has(id)) return;
    seen.add(id);
    output.conversations.push({
      status: "browser-existing",
      id,
      title,
      project_name: projectName,
      source,
      imported_id: id,
      imported_url: "https://chatgpt.com/c/" + id,
      update_time: item?.update_time || item?.updated_at || item?.conversation?.update_time || ""
    });
  };

  const listConversations = async (archived) => {
    let offset = 0;
    let total = Infinity;
    const limit = 100;
    const source = archived ? "browser-archived" : "browser-visible";
    while (offset < total && offset < 300) {
      const params = new URLSearchParams({
        offset: String(offset),
        limit: String(limit),
        order: "updated"
      });
      if (archived) params.set("is_archived", "true");
      const path = "/backend-api/conversations?" + params.toString();
      try {
        const page = await api(path);
        const items = asArray(page);
        total = Number.isFinite(page?.total) ? page.total : offset + items.length;
        for (const item of items) remember(item, source, "");
        if (!items.length) break;
        offset += items.length;
      } catch (error) {
        output.endpoint_errors.push({ path, error: String(error && error.message || error) });
        break;
      }
    }
  };

  const listProjects = async () => {
    const paths = [
      "/backend-api/gizmos/snorlax/sidebar?owned_only=true&conversations_per_gizmo=30&limit=100",
      "/backend-api/projects",
      "/backend-api/gizmos/discovery/mine"
    ];
    for (const path of paths) {
      try {
        const payload = await api(path);
        for (const project of asArray(payload)) {
          const projectName = getProjectName(project);
          for (const conversation of asArray(project?.conversations)) {
            remember(conversation, "browser-project", projectName);
          }
        }
      } catch (error) {
        output.endpoint_errors.push({ path, error: String(error && error.message || error) });
      }
    }
  };

  await listConversations(false);
  await listConversations(true);
  await listProjects();
  output.ok = true;
  return JSON.stringify(output);
})()
'@

  try {
    $result = Invoke-Cdp -WebSocket $WebSocket -Method "Runtime.evaluate" -Params @{
      expression = $expression
      awaitPromise = $true
      returnByValue = $true
    }
    $scan = $result.result.value | ConvertFrom-Json
    foreach ($conversation in @($scan.conversations)) {
      Add-DuplicateRecord -Index $Index -Row $conversation -MatchSource "B 账号当前聊天列表" -BrowserMatch
    }
    $Index.BrowserConversationCount = @($scan.conversations).Count
    if (@($scan.endpoint_errors).Count -gt 0) {
      Write-Host "重复检测提示：部分 B 账号列表接口不可用，已使用可读取到的列表继续。详情写入调试输出。" -ForegroundColor Yellow
    }
  } catch {
    Write-Host "重复检测提示：B 账号在线列表扫描失败，只使用本机历史报告去重。$($_.Exception.Message)" -ForegroundColor Yellow
  }

  return $Index
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

function Resolve-InputJsonPath {
  param([string]$Path)

  if (-not [string]::IsNullOrWhiteSpace($Path)) {
    if (-not (Test-Path -LiteralPath $Path)) {
      throw "找不到输入 JSON：$Path"
    }
    return (Resolve-Path -LiteralPath $Path).Path
  }

  $candidates = @(
    Get-ChildItem -File -Path $outputDir -Filter "chatgpt-account-a-share-links-with-projects_*.json" -ErrorAction SilentlyContinue
    Get-ChildItem -File -Path $outputDir -Filter "chatgpt-account-a-share-links_*.json" -ErrorAction SilentlyContinue
  ) | Sort-Object LastWriteTime -Descending

  foreach ($candidate in $candidates) {
    if ($candidate.Name -like "*dry-run*") {
      continue
    }

    try {
      $payload = Get-Content -Raw -LiteralPath $candidate.FullName | ConvertFrom-Json
      $items = @($payload.results)
      $usable = @($items | Where-Object { $_.share_url -and $_.status -ne "error" -and (Test-ShareUrl -Url (Safe-Text $_.share_url)) })
      if ($usable.Count -gt 0) {
        return $candidate.FullName
      }
    } catch {
      continue
    }
  }

  throw "没有在 outputs 里找到可用的 A 账号共享链接 JSON。请先运行 A 账号导出。"
}

function Get-ImportItems {
  param([string]$Path)

  $payload = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  $source = @()
  if ($payload -is [array]) {
    $source = @($payload)
  } elseif ($payload.results) {
    $source = @($payload.results)
  } elseif ($payload.links) {
    $source = @($payload.links)
  } elseif ($payload.data) {
    $source = @($payload.data)
  }

  $invalidLinks = @($source | Where-Object {
    $_.share_url -and $_.status -ne "error" -and -not (Test-ShareUrl -Url (Safe-Text $_.share_url))
  })
  if ($invalidLinks.Count -gt 0) {
    throw "输入 JSON 包含 $($invalidLinks.Count) 条非 ChatGPT 共享链接，已拒绝加载。"
  }

  $items = @($source | Where-Object {
    $_.share_url -and $_.status -ne "error" -and (Test-ShareUrl -Url (Safe-Text $_.share_url))
  } | ForEach-Object {
    [pscustomobject]@{
      id = $_.id
      title = $_.title
      source = $_.source
      project_name = $_.project_name
      project_id = $_.project_id
      project_source = $_.project_source
      share_id = $_.share_id
      share_url = $_.share_url
    }
  })

  if ($Skip -gt 0) {
    $items = @($items | Select-Object -Skip $Skip)
  }
  if ($Limit -gt 0) {
    $items = @($items | Select-Object -First $Limit)
  }

  return $items
}

function Get-SourceProjectsFromPath {
  param([string]$Path)

  $payload = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  if ($payload.projects) {
    return @($payload.projects)
  }
  if ($payload.source_projects) {
    return @($payload.source_projects)
  }
  return @()
}

function Export-Report {
  param($Report)

  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
  $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
  $modePrefix = ""
  if ($Report.config -and $Report.config.dryRun) {
    $modePrefix = "dry-run_"
  }
  $jsonPath = Join-Path $outputDir "chatgpt-account-b-${modePrefix}import-report_$stamp.json"
  $csvPath = Join-Path $outputDir "chatgpt-account-b-${modePrefix}import-report_$stamp.csv"

  $Report | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

  $rows = @($Report.results | ForEach-Object {
    [pscustomobject]@{
      status = $_.status
      project_name = $_.project_name
      project_id = $_.project_id
      project_source = $_.project_source
      title = $_.title
      share_url = $_.share_url
      imported_id = $_.imported_id
      imported_url = $_.imported_url
      source = $_.source
      id = $_.id
      elapsed_seconds = $_.elapsed_seconds
      duplicate_reason = $_.duplicate_reason
      duplicate_match_source = $_.duplicate_match_source
      duplicate_match_status = $_.duplicate_match_status
      duplicate_match_title = $_.duplicate_match_title
      duplicate_match_project_name = $_.duplicate_match_project_name
      error = $_.error
    }
  })

  $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

  return [pscustomobject]@{
    JsonPath = $jsonPath
    CsvPath = $csvPath
  }
}

function Invoke-CdpJsonExpression {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    [string]$Expression,
    [switch]$NoAwait
  )

  $params = @{
    expression = $Expression
    returnByValue = $true
  }
  if (-not $NoAwait) {
    $params.awaitPromise = $true
  }

  $result = Invoke-Cdp -WebSocket $WebSocket -Method "Runtime.evaluate" -Params $params
  if ($result.exceptionDetails) {
    $description = $result.exceptionDetails.exception.description
    if ([string]::IsNullOrWhiteSpace($description)) {
      $description = $result.exceptionDetails.text
    }
    throw "页面脚本执行失败：$description"
  }

  $value = $result.result.value
  if ([string]::IsNullOrWhiteSpace([string]$value)) {
    return $null
  }

  return $value | ConvertFrom-Json
}

function Wait-DocumentReady {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    [int]$TimeoutSec = 60
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $state = Invoke-CdpJsonExpression -WebSocket $WebSocket -Expression @'
(() => JSON.stringify({
  href: location.href,
  readyState: document.readyState,
  hasBody: Boolean(document.body)
}))()
'@
      if ($state.hasBody -and ($state.readyState -eq "interactive" -or $state.readyState -eq "complete")) {
        return $state
      }
    } catch {
      Start-Sleep -Milliseconds 500
    }

    Start-Sleep -Milliseconds 500
  }

  throw "页面加载超时。"
}

function Invoke-OpenSharedComposer {
  param([System.Net.WebSockets.ClientWebSocket]$WebSocket)

  $expression = @'
(() => {
  const safeText = (value) => String(value ?? "").replace(/\s+/g, " ").trim();
  const isVisible = (element) => {
    if (!element) return false;
    const style = window.getComputedStyle(element);
    if (style.visibility === "hidden" || style.display === "none" || Number(style.opacity) === 0) return false;
    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };
  const isDisabled = (element) => Boolean(
    element?.disabled ||
    element?.getAttribute("aria-disabled") === "true" ||
    element?.closest("[aria-disabled='true']")
  );
  const findComposer = () => {
    const selectors = [
      "#prompt-textarea",
      "[data-testid='prompt-textarea']",
      "textarea",
      "[contenteditable='true']"
    ];
    for (const selector of selectors) {
      const element = Array.from(document.querySelectorAll(selector))
        .find((candidate) => isVisible(candidate) && !isDisabled(candidate));
      if (element) return element;
    }
    return null;
  };
  const findClickableByText = (patterns) => {
    const candidates = Array.from(document.querySelectorAll("button, a, [role='button']"));
    return candidates.find((element) => {
      if (!isVisible(element) || isDisabled(element)) return false;
      const text = safeText([
        element.innerText,
        element.textContent,
        element.getAttribute("aria-label"),
        element.getAttribute("title")
      ].filter(Boolean).join(" "));
      return patterns.some((pattern) => pattern.test(text));
    }) || null;
  };

  const text = safeText(document.body?.innerText || "");
  const lower = text.toLowerCase();
  if (lower.includes("not found") || lower.includes("404") || text.includes("链接不存在")) {
    return JSON.stringify({
      ok: false,
      unavailable: true,
      href: location.href,
      message: "Shared link page says the conversation is unavailable."
    });
  }

  const button = findClickableByText([
    /continue\s+this\s+conversation/i,
    /continue\s+conversation/i,
    /continue/i,
    /start\s+(a\s+)?new\s+chat/i,
    /继续此对话/,
    /继续对话/,
    /继续/,
    /开始聊天/,
    /开始新对话/
  ]);

  const onSharePage = location.pathname.startsWith("/share/");
  if (onSharePage && button) {
    button.click();
    return JSON.stringify({ ok: true, hasComposer: false, clicked: true, href: location.href });
  }

  const composer = findComposer();
  if (composer) {
    return JSON.stringify({ ok: true, hasComposer: true, clicked: false, href: location.href, sharePage: onSharePage });
  }

  if (button) {
    button.click();
    return JSON.stringify({ ok: true, hasComposer: false, clicked: true, href: location.href });
  }

  return JSON.stringify({
    ok: false,
    hasComposer: false,
    clicked: false,
    href: location.href,
    pageText: text.slice(0, 500)
  });
})()
'@

  return Invoke-CdpJsonExpression -WebSocket $WebSocket -Expression $expression
}

function Invoke-SendMigrationPrompt {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    [string]$PromptText
  )

  $promptJson = $PromptText | ConvertTo-Json -Compress
  $expression = @"
(async () => {
  const promptText = $promptJson;
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const isVisible = (element) => {
    if (!element) return false;
    const style = window.getComputedStyle(element);
    if (style.visibility === "hidden" || style.display === "none" || Number(style.opacity) === 0) return false;
    const rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  };
  const isDisabled = (element) => Boolean(
    element?.disabled ||
    element?.getAttribute("aria-disabled") === "true" ||
    element?.closest("[aria-disabled='true']")
  );
  const waitFor = async (check, timeoutMs, label) => {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const value = check();
      if (value) return value;
      await sleep(350);
    }
    throw new Error(label + " timed out");
  };
  const findComposer = () => {
    const selectors = [
      "#prompt-textarea",
      "[data-testid='prompt-textarea']",
      "textarea",
      "[contenteditable='true']"
    ];
    for (const selector of selectors) {
      const element = Array.from(document.querySelectorAll(selector))
        .find((candidate) => isVisible(candidate) && !isDisabled(candidate));
      if (element) return element;
    }
    return null;
  };
  const setComposerText = (composer, text) => {
    composer.focus();
    if ("value" in composer) {
      composer.value = text;
      composer.dispatchEvent(new Event("input", { bubbles: true }));
      composer.dispatchEvent(new Event("change", { bubbles: true }));
      return;
    }

    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(composer);
    selection.removeAllRanges();
    selection.addRange(range);

    let inserted = false;
    try {
      inserted = document.execCommand("insertText", false, text);
    } catch {
      inserted = false;
    }
    if (!inserted) composer.textContent = text;

    composer.dispatchEvent(new InputEvent("input", {
      bubbles: true,
      cancelable: true,
      inputType: "insertText",
      data: text
    }));
  };
  const composerText = () => {
    const composer = findComposer();
    if (!composer) return "";
    return String(("value" in composer ? composer.value : composer.textContent) || "").trim();
  };
  const findSendButton = () => {
    const selectors = [
      "[data-testid='send-button']",
      "button[aria-label*='Send']",
      "button[aria-label*='send']",
      "button[aria-label*='发送']",
      "button[type='submit']"
    ];
    for (const selector of selectors) {
      const button = Array.from(document.querySelectorAll(selector))
        .find((candidate) => isVisible(candidate) && !isDisabled(candidate));
      if (button) return button;
    }
    const textButtons = Array.from(document.querySelectorAll("button, [role='button']"));
    return textButtons.find((button) => {
      if (!isVisible(button) || isDisabled(button)) return false;
      const text = String(button.innerText || button.textContent || button.getAttribute("aria-label") || "").trim();
      return /^send$/i.test(text) || /发送/.test(text);
    }) || null;
  };
  const hasStopButton = () => {
    const selectors = [
      "[data-testid='stop-button']",
      "button[aria-label*='Stop']",
      "button[aria-label*='stop']",
      "button[aria-label*='停止']"
    ];
    return selectors.some((selector) => Array.from(document.querySelectorAll(selector)).some(isVisible));
  };

  const composer = await waitFor(findComposer, 45000, "message composer");
  const startedOnSharePage = location.pathname.startsWith("/share/");
  setComposerText(composer, promptText);
  const sendButton = await waitFor(findSendButton, 45000, "send button");
  sendButton.click();

  const started = Date.now();
  const timeoutMs = startedOnSharePage ? 300000 : 90000;
  let sawStop = false;
  while (Date.now() - started < timeoutMs) {
    if (hasStopButton()) sawStop = true;
    if (sawStop && !hasStopButton()) {
      return JSON.stringify({ ok: true, href: location.href, evidence: "response-complete" });
    }
    if (Date.now() - started > 6000 && !composerText()) {
      if (startedOnSharePage) {
        await sleep(500);
        continue;
      }
      return JSON.stringify({ ok: true, href: location.href, evidence: "prompt-cleared" });
    }
    await sleep(500);
  }

  return JSON.stringify({ ok: true, href: location.href, evidence: "send-clicked" });
})()
"@

  return Invoke-CdpJsonExpression -WebSocket $WebSocket -Expression $expression
}

function Find-RecentConversationByTitle {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    [string]$Title,
    [string]$StartedAfterIso
  )

  $titleJson = $Title | ConvertTo-Json -Compress
  $startedAfterJson = $StartedAfterIso | ConvertTo-Json -Compress
  $expression = @"
(async () => {
  const title = $titleJson;
  const startedAfter = Date.parse($startedAfterJson);
  const safeText = (value) => String(value ?? "").replace(/\s+/g, " ").trim();
  const sessionResponse = await fetch("/api/auth/session", { credentials: "include" });
  if (!sessionResponse.ok) {
    return JSON.stringify({ ok: false, status: sessionResponse.status, stage: "session" });
  }
  const session = await sessionResponse.json();
  const token = session && session.accessToken;
  if (!token) return JSON.stringify({ ok: false, stage: "token" });

  const response = await fetch("/backend-api/conversations?offset=0&limit=50&order=updated&is_archived=false&is_starred=false", {
    credentials: "include",
    headers: { accept: "application/json", authorization: "Bearer " + token }
  });
  if (!response.ok) {
    return JSON.stringify({ ok: false, status: response.status, stage: "list" });
  }

  const data = await response.json();
  const targetTitle = safeText(title).toLowerCase();
  const items = Array.isArray(data.items) ? data.items : [];
  const candidates = items
    .map((item) => ({
      id: item && item.id || "",
      title: safeText(item && item.title),
      create_time: item && item.create_time || "",
      update_time: item && item.update_time || ""
    }))
    .filter((item) => item.id && safeText(item.title).toLowerCase() === targetTitle)
    .filter((item) => {
      const updated = Date.parse(item.update_time || item.create_time || "");
      return Number.isFinite(updated) && Number.isFinite(startedAfter) && updated >= startedAfter;
    })
    .sort((a, b) => Date.parse(b.update_time || b.create_time || "") - Date.parse(a.update_time || a.create_time || ""));

  if (!candidates.length) {
    return JSON.stringify({ ok: true, found: false, scanned: items.length });
  }

  const match = candidates[0];
  return JSON.stringify({
    ok: true,
    found: true,
    id: match.id,
    url: "https://chatgpt.com/c/" + match.id,
    title: match.title,
    update_time: match.update_time,
    create_time: match.create_time,
    scanned: items.length
  });
})()
"@

  return Invoke-CdpJsonExpression -WebSocket $WebSocket -Expression $expression
}

function Find-DuplicateImportItem {
  param(
    $Item,
    $Index
  )

  if ($null -eq $Index) {
    return $null
  }

  $sourceId = Safe-Text $Item.id
  if (-not [string]::IsNullOrWhiteSpace($sourceId) -and $Index.BySourceId.ContainsKey($sourceId)) {
    return $Index.BySourceId[$sourceId]
  }

  $shareUrl = Safe-Text $Item.share_url
  if (-not [string]::IsNullOrWhiteSpace($shareUrl) -and $Index.ByShareUrl.ContainsKey($shareUrl)) {
    return $Index.ByShareUrl[$shareUrl]
  }

  $titleKey = Get-DuplicateTitleKey -Title $Item.title -ProjectName $Item.project_name
  if (-not [string]::IsNullOrWhiteSpace($titleKey) -and $Index.ByTitleProject.ContainsKey($titleKey)) {
    return $Index.ByTitleProject[$titleKey]
  }

  return $null
}

function Invoke-OrchestratedImport {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    [object[]]$Items,
    [bool]$DryRunMode,
    [string]$PromptText,
    $DuplicateIndex,
    [bool]$AllowDuplicateItems
  )

  $startedAt = Get-Date
  $results = @()
  $total = @($Items).Count

  for ($index = 0; $index -lt $total; $index += 1) {
    $item = $Items[$index]
    $title = [string]$item.title
    if ([string]::IsNullOrWhiteSpace($title)) {
      $title = [string]$item.id
    }

    Write-Host "[import] $($index + 1)/$total $title"
    $timer = [Diagnostics.Stopwatch]::StartNew()

    $duplicate = $null
    if (-not $AllowDuplicateItems) {
      $duplicate = Find-DuplicateImportItem -Item $item -Index $DuplicateIndex
    }

    if ($duplicate) {
      $timer.Stop()
      Write-Host "[skip:$($duplicate.status)] $title :: $($duplicate.reason)" -ForegroundColor Yellow
      $results += [pscustomobject]@{
        status = $duplicate.status
        id = $item.id
        title = $title
        project_name = $item.project_name
        project_id = $item.project_id
        project_source = $item.project_source
        source = $item.source
        share_url = $item.share_url
        imported_id = $duplicate.match_imported_id
        imported_url = $duplicate.match_imported_url
        elapsed_seconds = [math]::Round($timer.Elapsed.TotalSeconds)
        duplicate_reason = $duplicate.reason
        duplicate_match_source = $duplicate.match_source
        duplicate_match_status = $duplicate.match_status
        duplicate_match_title = $duplicate.match_title
        duplicate_match_project_name = $duplicate.match_project_name
        error = ""
      }
      continue
    }

    if ($DryRunMode) {
      $results += [pscustomobject]@{
        status = "dry-run"
        id = $item.id
        title = $title
        project_name = $item.project_name
        project_id = $item.project_id
        project_source = $item.project_source
        source = $item.source
        share_url = $item.share_url
        imported_id = ""
        imported_url = ""
        elapsed_seconds = 0
        duplicate_reason = ""
        duplicate_match_source = ""
        duplicate_match_status = ""
        duplicate_match_title = ""
        duplicate_match_project_name = ""
        error = ""
      }
      continue
    }

    try {
      Invoke-Cdp -WebSocket $WebSocket -Method "Page.navigate" -Params @{
        url = [string]$item.share_url
      } | Out-Null
      Start-Sleep -Seconds 1
      Wait-DocumentReady -WebSocket $WebSocket -TimeoutSec 60 | Out-Null

      $composerState = $null
      for ($attempt = 1; $attempt -le 8; $attempt += 1) {
        try {
          $composerState = Invoke-OpenSharedComposer -WebSocket $WebSocket
          if ($composerState.unavailable) {
            throw $composerState.message
          }
          if ($composerState.hasComposer) {
            break
          }
          if ($composerState.clicked) {
            Write-Host "[step] 已点击继续按钮，等待对话页准备完成。"
            Start-Sleep -Seconds 3
            Wait-DocumentReady -WebSocket $WebSocket -TimeoutSec 60 | Out-Null
          } else {
            Start-Sleep -Seconds 2
          }
        } catch {
          if ($attempt -ge 8) {
            throw
          }
          Start-Sleep -Seconds 2
          try {
            Wait-DocumentReady -WebSocket $WebSocket -TimeoutSec 30 | Out-Null
          } catch {
            Start-Sleep -Seconds 2
          }
        }
      }

      if (-not $composerState -or -not $composerState.hasComposer) {
        throw "没有找到可发送消息的输入框。"
      }

      $sendStartedAfter = (Get-Date).ToUniversalTime().AddSeconds(-5).ToString("o")
      $sendResult = Invoke-SendMigrationPrompt -WebSocket $WebSocket -PromptText $PromptText
      if (-not $sendResult.ok) {
        throw "发送触发消息失败。"
      }

      $importedUrl = [string]$sendResult.href
      if ([string]::IsNullOrWhiteSpace($importedUrl)) {
        $importedUrl = Get-PageHref -WebSocket $WebSocket
      }
      $importedId = Get-ConversationIdFromUrl -Url $importedUrl
      $redirectDeadline = (Get-Date).AddSeconds(30)
      while ([string]::IsNullOrWhiteSpace($importedId) -and (Get-Date) -lt $redirectDeadline) {
        Start-Sleep -Seconds 1
        $importedUrl = Get-PageHref -WebSocket $WebSocket
        $importedId = Get-ConversationIdFromUrl -Url $importedUrl
      }

      if ([string]::IsNullOrWhiteSpace($importedId)) {
        $recentMatch = Find-RecentConversationByTitle -WebSocket $WebSocket -Title $title -StartedAfterIso $sendStartedAfter
        if ($recentMatch -and $recentMatch.found -and -not [string]::IsNullOrWhiteSpace([string]$recentMatch.id)) {
          $importedId = [string]$recentMatch.id
          $importedUrl = [string]$recentMatch.url
          $sendResult.evidence = "$($sendResult.evidence);recent-list-match"
        }
      }

      if ([string]::IsNullOrWhiteSpace($importedId)) {
        throw "发送触发消息后没有进入 B 账号 /c/{id} 对话页，当前页面：$importedUrl，证据：$($sendResult.evidence)。不会把共享链接页当作导入成功。"
      }

      $timer.Stop()

      Write-Host "[ok] $title -> $importedUrl ($($sendResult.evidence))"
      $results += [pscustomobject]@{
        status = "imported"
        id = $item.id
        title = $title
        project_name = $item.project_name
        project_id = $item.project_id
        project_source = $item.project_source
        source = $item.source
        share_url = $item.share_url
        imported_id = $importedId
        imported_url = $importedUrl
        elapsed_seconds = [math]::Round($timer.Elapsed.TotalSeconds)
        duplicate_reason = ""
        duplicate_match_source = ""
        duplicate_match_status = ""
        duplicate_match_title = ""
        duplicate_match_project_name = ""
        error = ""
      }
    } catch {
      $timer.Stop()
      $message = $_.Exception.Message
      $currentHref = ""
      try {
        $currentHref = Get-PageHref -WebSocket $WebSocket
      } catch {
        $currentHref = ""
      }
      Write-Host "[error] $title :: $message" -ForegroundColor Red
      $results += [pscustomobject]@{
        status = "error"
        id = $item.id
        title = $title
        project_name = $item.project_name
        project_id = $item.project_id
        project_source = $item.project_source
        source = $item.source
        share_url = $item.share_url
        imported_id = Get-ConversationIdFromUrl -Url $currentHref
        imported_url = $currentHref
        elapsed_seconds = [math]::Round($timer.Elapsed.TotalSeconds)
        duplicate_reason = ""
        duplicate_match_source = ""
        duplicate_match_status = ""
        duplicate_match_title = ""
        duplicate_match_project_name = ""
        error = $message
      }
    }

    Start-Sleep -Milliseconds 1500
  }

  $finishedAt = Get-Date
  $importedCount = @($results | Where-Object { $_.status -eq "imported" }).Count
  $dryRunCount = @($results | Where-Object { $_.status -eq "dry-run" }).Count
  $duplicateCount = @($results | Where-Object { $_.status -eq "duplicate" }).Count
  $duplicateSuspectedCount = @($results | Where-Object { $_.status -eq "duplicate_suspected" }).Count
  $errorCount = @($results | Where-Object { $_.status -eq "error" }).Count
  $byProject = @{}
  foreach ($result in $results) {
    $name = [string]$result.project_name
    if ([string]::IsNullOrWhiteSpace($name)) {
      $name = "未归属项目"
    }
    if ($byProject.ContainsKey($name)) {
      $byProject[$name] += 1
    } else {
      $byProject[$name] = 1
    }
  }

  return [pscustomobject]@{
    schema = "chatgpt-shared-link-import-v1"
    generated_at = $finishedAt.ToString("o")
    account_hint = "account B in current browser session"
    config = [pscustomobject]@{
      dryRun = $DryRunMode
      promptText = $PromptText
      delayMs = 1500
      duplicateCheck = (-not $AllowDuplicateItems)
      priorDuplicateReports = if ($DuplicateIndex) { $DuplicateIndex.PriorReportCount } else { 0 }
      browserConversationsScanned = if ($DuplicateIndex) { $DuplicateIndex.BrowserConversationCount } else { 0 }
    }
    summary = [pscustomobject]@{
      input = $total
      processed = @($results).Count
      imported = $importedCount
      dry_run = $dryRunCount
      duplicates = $duplicateCount
      duplicate_suspected = $duplicateSuspectedCount
      errors = $errorCount
      elapsed_seconds = [math]::Round(($finishedAt - $startedAt).TotalSeconds)
      by_project = $byProject
    }
    results = $results
  }
}

New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

Write-Step "读取共享链接清单"
try {
  $resolvedInputJson = Resolve-InputJsonPath -Path $InputJson
  $items = @(Get-ImportItems -Path $resolvedInputJson)
  $sourceProjects = @(Get-SourceProjectsFromPath -Path $resolvedInputJson)
  Write-Host "输入 JSON：$resolvedInputJson"
} catch {
  if (-not $SelfTest) {
    throw
  }
  $resolvedInputJson = ""
  $items = @()
  $sourceProjects = @()
  Write-Host "SelfTest 模式：未找到输入 JSON，跳过清单检查。"
  Write-Host "原因：$($_.Exception.Message)"
}
Write-Host "待处理链接：$($items.Count) 条"
Write-Host "源项目清单：$($sourceProjects.Count) 个"
if ($Skip -gt 0) {
  Write-Host "已跳过前 $Skip 条。"
}
if ($Limit -gt 0) {
  Write-Host "本次限制处理 $Limit 条。"
}

if ($items.Count -eq 0 -and -not $SelfTest) {
  throw "输入 JSON 中没有可用的 share_url。"
}

$duplicateIndex = $null
if (-not $AllowDuplicates) {
  $duplicateIndex = Get-LocalDuplicateIndex -OutputDirectory $outputDir
}

Write-Step "启动 B 账号专用浏览器窗口"
$browserPath = Get-BrowserPath
$proxyArgs = Get-BrowserProxyArgs
$browserArgs = @(
  "--remote-debugging-port=$Port",
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
Write-Host "B 账号使用独立配置目录：$profileDir"
Write-Host "此脚本不会关闭 Upnet/VPN。"

$browserProcess = Start-Process -FilePath $browserPath -ArgumentList $browserArgs -PassThru

if (-not (Wait-DevTools -Port $Port)) {
  throw "浏览器 DevTools 端口没有启动。请关闭刚打开的 B 账号专用浏览器窗口后再试。"
}

$target = Get-ChatGptTarget -Port $Port
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
      Write-Host "B 账号登录态：已检测到"
    } else {
      Write-Host "B 账号登录态：未检测到；正式导入前会要求你在专用窗口登录。" -ForegroundColor Yellow
    }

    Write-Step "自检完成"
    Write-Host "没有打开共享链接，没有发送触发消息。"
    return
  }

  Write-Step "检查 B 账号登录状态"
  if (-not (Test-ChatGptSession -WebSocket $ws)) {
    Write-Host "请在刚打开的专用浏览器窗口里登录 B 账号。" -ForegroundColor Yellow
    Write-Host "登录完成并看到 ChatGPT 首页后，回到这个窗口按 Enter 继续。"
    Read-Host | Out-Null

    if (-not (Test-ChatGptSession -WebSocket $ws)) {
      throw "仍然没有检测到 B 账号登录状态。请确认专用浏览器窗口已经登录 chatgpt.com。"
    }
  }

  if (-not $AllowDuplicates) {
    Write-Step "重复记录检测"
    Write-Host "本机历史导入报告：$($duplicateIndex.PriorReportCount) 个"
    $duplicateIndex = Add-BrowserDuplicateMatches -WebSocket $ws -Index $duplicateIndex
    Write-Host "B 账号已扫描聊天：$($duplicateIndex.BrowserConversationCount) 条"

    $duplicatePreview = @($items | ForEach-Object {
      Find-DuplicateImportItem -Item $_ -Index $duplicateIndex
    } | Where-Object { $_ })
    $confirmedPreview = @($duplicatePreview | Where-Object { $_.status -eq "duplicate" }).Count
    $suspectedPreview = @($duplicatePreview | Where-Object { $_.status -eq "duplicate_suspected" }).Count
    Write-Host "将跳过确定重复：$confirmedPreview 条"
    Write-Host "将跳过疑似重复：$suspectedPreview 条"
  } else {
    Write-Step "重复记录检测"
    Write-Host "已使用 -AllowDuplicates，允许重复导入。"
  }

  if (-not $DryRun -and -not $AssumeYes) {
    Write-Step "确认开始自动导入"
    Write-Host "脚本将用 B 账号逐条打开 $($items.Count) 个共享链接，并发送触发消息："
    Write-Host $Prompt
    Write-Host "输入 YES 开始；直接回车会取消。"
    $confirmation = Read-Host
    if ($confirmation -ne "YES") {
      throw "用户取消，未发送任何触发消息。"
    }
  }

  Write-Step "开始 B 账号自动导入"
  $report = Invoke-OrchestratedImport -WebSocket $ws -Items $items -DryRunMode ([bool]$DryRun) -PromptText $Prompt -DuplicateIndex $duplicateIndex -AllowDuplicateItems ([bool]$AllowDuplicates)
  $report | Add-Member -NotePropertyName source_json -NotePropertyValue $resolvedInputJson -Force
  $report | Add-Member -NotePropertyName source_projects -NotePropertyValue $sourceProjects -Force
  $report.summary | Add-Member -NotePropertyName source_projects -NotePropertyValue @($sourceProjects).Count -Force

  $paths = Export-Report -Report $report

  Write-Step "完成"
  Write-Host "导入成功：$($report.summary.imported) 条"
  Write-Host "Dry run：$($report.summary.dry_run) 条"
  Write-Host "确定重复跳过：$($report.summary.duplicates) 条"
  Write-Host "疑似重复跳过：$($report.summary.duplicate_suspected) 条"
  Write-Host "失败：$($report.summary.errors) 条"
  Write-Host "JSON：$($paths.JsonPath)"
  Write-Host "CSV ：$($paths.CsvPath)"
  if (-not $DryRun -and $report.summary.errors -gt 0) {
    throw "B 账号导入完成但仍有 $($report.summary.errors) 条失败。请查看报告：$($paths.JsonPath)"
  }
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
