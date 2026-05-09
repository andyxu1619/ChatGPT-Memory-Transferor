param(
  [string]$InputJson = "",
  [switch]$DryRun,
  [switch]$SkipProjectFiles,
  [int]$Skip = 0,
  [int]$Limit = 0,
  [int]$Port = 9228,
  [switch]$AssumeYes,
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

function Safe-Text {
  param($Value)
  if ($null -eq $Value) {
    return ""
  }
  return ([string]$Value).Trim()
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
  return (Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 5).Content | ConvertFrom-Json
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
    $rawTargets = Invoke-JsonRequest "http://127.0.0.1:$Port/json/list"
    $targets = @()
    foreach ($entry in $rawTargets) {
      if ($entry -is [array]) {
        $targets += @($entry)
      } else {
        $targets += $entry
      }
    }
    $target = @($targets | Where-Object {
      $_.type -eq "page" -and $_.url -like "https://chatgpt.com*"
    } | Select-Object -First 1)

    if ($target.Count -gt 0 -and $target[0].webSocketDebuggerUrl) {
      return $target[0]
    }

    if (-not $fallbackTarget) {
      $fallback = @($targets | Where-Object {
        $_.type -eq "page" -and $_.webSocketDebuggerUrl
      } | Select-Object -First 1)
      if ($fallback.Count -gt 0) {
        $fallbackTarget = $fallback[0]
      }
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
  return $Value | ConvertTo-Json -Depth 100 -Compress
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

  $buffer = New-Object byte[] 1048576
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

function Invoke-CdpJsonExpression {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    [string]$Expression
  )

  $result = Invoke-Cdp -WebSocket $WebSocket -Method "Runtime.evaluate" -Params @{
    expression = $Expression
    awaitPromise = $true
    returnByValue = $true
  }

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

function Test-ChatGptSession {
  param([System.Net.WebSockets.ClientWebSocket]$WebSocket)

  $expression = @'
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
'@

  $result = Invoke-Cdp -WebSocket $WebSocket -Method "Runtime.evaluate" -Params @{
    expression = $expression
    awaitPromise = $true
    returnByValue = $true
  }

  return [bool]$result.result.value
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

function Get-RestoreItemsFromPath {
  param([string]$Path)

  $payload = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  $source = @()
  if ($payload -is [array]) {
    $source = @($payload)
  } elseif ($payload.results) {
    $source = @($payload.results)
  } elseif ($payload.data) {
    $source = @($payload.data)
  }

  $items = @()
  foreach ($row in $source) {
    $projectName = (Safe-Text $row.project_name)
    if ([string]::IsNullOrWhiteSpace($projectName) -or $projectName -eq "未归属项目" -or $projectName -eq "未知") {
      continue
    }

    $conversationId = (Safe-Text $row.imported_id)
    if ([string]::IsNullOrWhiteSpace($conversationId)) {
      $conversationId = Get-ConversationIdFromUrl -Url (Safe-Text $row.imported_url)
    }
    if ([string]::IsNullOrWhiteSpace($conversationId)) {
      continue
    }

    $status = Safe-Text $row.status
    if ($status -eq "error" -or $status -eq "missing" -or $status -eq "dry-run" -or $status -like "duplicate*") {
      continue
    }

    $items += [pscustomobject]@{
      source_id = $row.id
      title = $row.title
      project_name = $projectName
      project_id = $row.project_id
      project_source = $row.project_source
      share_url = $row.share_url
      imported_id = $conversationId
      imported_url = $row.imported_url
      prior_status = $status
    }
  }

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
  if ($payload.source_projects) {
    return @($payload.source_projects)
  }
  if ($payload.projects) {
    return @($payload.projects)
  }
  return @()
}

function Resolve-LatestSourceProjectsPath {
  $files = Get-ChildItem -File -Path $outputDir -Filter "chatgpt-account-a-share-links-with-projects_*.json" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike "*dry-run*" } |
    Sort-Object LastWriteTime -Descending

  foreach ($file in $files) {
    try {
      $projects = @(Get-SourceProjectsFromPath -Path $file.FullName)
      if ($projects.Count -gt 0) {
        return $file.FullName
      }
    } catch {
      continue
    }
  }

  return ""
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
    Get-ChildItem -File -Path $outputDir -Filter "chatgpt-account-b-verified-import-report_*.json" -ErrorAction SilentlyContinue
    Get-ChildItem -File -Path $outputDir -Filter "chatgpt-account-b-import-report_*.json" -ErrorAction SilentlyContinue
    Get-ChildItem -File -Path $outputDir -Filter "chatgpt-account-a-share-links-with-projects_*.json" -ErrorAction SilentlyContinue
  ) | Sort-Object LastWriteTime -Descending

  foreach ($candidate in $candidates) {
    if ($candidate.Name -like "*dry-run*") {
      continue
    }

    try {
      $items = @(Get-RestoreItemsFromPath -Path $candidate.FullName)
      $projects = @(Get-SourceProjectsFromPath -Path $candidate.FullName)
      if ($items.Count -gt 0 -or $projects.Count -gt 0) {
        return $candidate.FullName
      }
    } catch {
      continue
    }
  }

  throw "没有在 outputs 里找到带项目元数据或 imported_url/imported_id 的报告。请先完成 A 账号导出或 B 账号导入。"
}

function Export-RestoreReport {
  param($Report)

  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
  $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
  $modePrefix = ""
  if ($Report.config -and $Report.config.dryRun) {
    $modePrefix = "dry-run_"
  }
  $jsonPath = Join-Path $outputDir "chatgpt-account-b-${modePrefix}project-restore-report_$stamp.json"
  $csvPath = Join-Path $outputDir "chatgpt-account-b-${modePrefix}project-restore-report_$stamp.csv"
  $projectCsvPath = Join-Path $outputDir "chatgpt-account-b-${modePrefix}project-restore-projects_$stamp.csv"
  $attachmentCsvPath = Join-Path $outputDir "chatgpt-account-b-${modePrefix}project-restore-attachments_$stamp.csv"

  $Report | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

  $rows = @($Report.results | ForEach-Object {
    [pscustomobject]@{
      status = $_.status
      project_name = $_.project_name
      target_project_id = $_.target_project_id
      previous_gizmo_id = $_.previous_gizmo_id
      after_gizmo_id = $_.after_gizmo_id
      title = $_.title
      imported_id = $_.imported_id
      imported_url = $_.imported_url
      error = $_.error
    }
  })

  $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

  $projectRows = @($Report.project_results | ForEach-Object {
    [pscustomobject]@{
      status = $_.status
      project_name = $_.project_name
      source_project_id = $_.source_project_id
      target_project_id = $_.target_project_id
      file_count = $_.file_count
      error = $_.error
    }
  })
  $projectRows | Export-Csv -LiteralPath $projectCsvPath -NoTypeInformation -Encoding UTF8

  $attachmentRows = @($Report.attachment_results | ForEach-Object {
    [pscustomobject]@{
      status = $_.status
      project_name = $_.project_name
      source_project_id = $_.source_project_id
      target_project_id = $_.target_project_id
      source_file_id = $_.source_file_id
      uploaded_file_id = $_.uploaded_file_id
      name = $_.name
      local_path = $_.local_path
      error = $_.error
    }
  })
  $attachmentRows | Export-Csv -LiteralPath $attachmentCsvPath -NoTypeInformation -Encoding UTF8

  return [pscustomobject]@{
    JsonPath = $jsonPath
    CsvPath = $csvPath
    ProjectCsvPath = $projectCsvPath
    AttachmentCsvPath = $attachmentCsvPath
  }
}

function Invoke-ProjectRestore {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    [string]$SourceJson,
    [object[]]$Items,
    [object[]]$SourceProjects,
    [bool]$DryRunMode
  )

  $itemsJson = ConvertTo-JsonArray -Value $Items
  $sourceProjectsJson = ConvertTo-JsonArray -Value $SourceProjects
  $sourceJsonLiteral = $SourceJson | ConvertTo-Json -Compress
  $dryRunLiteral = if ($DryRunMode) { "true" } else { "false" }

  $template = @'
(async () => {
  const sourceJson = __SOURCE_JSON__;
  const items = __ITEMS_JSON__;
  const sourceProjects = __SOURCE_PROJECTS_JSON__;
  const dryRun = __DRY_RUN__;
  const startedAt = new Date();
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const normalize = (value) => String(value || "").replace(/\s+/g, " ").trim();
  const normalizeKey = (value) => normalize(value).toLowerCase();
  const redact = (value) => JSON.stringify(value, (key, innerValue) => {
    return key.toLowerCase().includes("token") ? "[redacted]" : innerValue;
  });

  async function getAccessToken() {
    const response = await fetch("/api/auth/session", {
      credentials: "include",
      headers: { accept: "application/json" }
    });
    if (!response.ok) {
      throw new Error("Cannot read ChatGPT session: HTTP " + response.status);
    }
    const session = await response.json();
    if (!session || !session.accessToken) {
      throw new Error("No accessToken found. Confirm this browser window is logged in to account B.");
    }
    return {
      accessToken: session.accessToken,
      account: {
        planType: session.account && session.account.planType || "",
        structure: session.account && session.account.structure || ""
      }
    };
  }

  const session = await getAccessToken();

  async function api(path, options = {}) {
    const response = await fetch(path, {
      credentials: "include",
      ...options,
      headers: {
        accept: "application/json",
        "content-type": "application/json",
        authorization: "Bearer " + session.accessToken,
        ...(options.headers || {})
      }
    });
    const text = await response.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = text; }
    if (!response.ok) {
      const message = typeof data === "string" ? data : redact(data);
      throw new Error("HTTP " + response.status + " " + path + ": " + message.slice(0, 500));
    }
    return data;
  }

  function asArray(payload) {
    if (Array.isArray(payload)) return payload;
    if (!payload || typeof payload !== "object") return [];
    for (const key of ["items", "projects", "gizmos", "data", "results"]) {
      if (Array.isArray(payload[key])) return payload[key];
    }
    return [];
  }

  function unwrapProject(value) {
    return value && value.gizmo && value.gizmo.gizmo || value && value.gizmo || value;
  }

  function normalizeProject(value, source) {
    const project = unwrapProject(value);
    if (!project || typeof project !== "object") return null;
    const id = normalize(project.id || project.project_id || project.gizmo_id || project.conversation_template_id);
    const name = normalize(
      project.name ||
      project.title ||
      project.display_name ||
      project.display && (project.display.name || project.display.title) ||
      project.metadata && (project.metadata.name || project.metadata.title)
    );
    if (!id || !name) return null;
    return { id, name, source };
  }

  function normalizeSourceProject(value) {
    if (!value || typeof value !== "object") return null;
    const id = normalize(value.id || value.project_id || value.gizmo_id || value.conversation_template_id);
    const name = normalize(value.name || value.title || value.display_name);
    if (!id && !name) return null;
    if (id && !id.startsWith("g-p-")) return null;
    return {
      id,
      name: name || id,
      description: normalize(value.description),
      instructions: typeof value.instructions === "string" ? value.instructions : "",
      emoji: normalize(value.emoji),
      theme: normalize(value.theme),
      prompt_starters: Array.isArray(value.prompt_starters) ? value.prompt_starters : [],
      memory_scope: normalize(value.memory_scope),
      training_disabled: value.training_disabled === true,
      files: Array.isArray(value.files) ? value.files : []
    };
  }

  function getWantedProjects() {
    const byKey = new Map();
    for (const project of sourceProjects.map(normalizeSourceProject).filter(Boolean)) {
      const key = normalizeKey(project.name);
      if (key && !byKey.has(key)) byKey.set(key, project);
    }

    for (const item of items) {
      const projectName = normalize(item.project_name);
      if (!projectName || projectName === "未归属项目" || projectName === "未知") continue;
      const sourceProjectId = normalize(item.project_id);
      if (sourceProjectId && !sourceProjectId.startsWith("g-p-")) continue;
      const key = normalizeKey(projectName);
      if (!key || byKey.has(key)) continue;
      byKey.set(key, {
        id: sourceProjectId,
        name: projectName,
        description: "",
        instructions: "",
        emoji: "",
        theme: "",
        prompt_starters: [],
        memory_scope: "",
        training_disabled: false,
        files: []
      });
    }

    return Array.from(byKey.values());
  }

  function buildCreateProjectPayload(project) {
    const display = {
      name: project.name,
      description: project.description || "",
      emoji: project.emoji || null,
      theme: project.theme || null,
      profile_pic_id: null,
      profile_picture_url: null,
      prompt_starters: Array.isArray(project.prompt_starters) ? project.prompt_starters : []
    };
    return {
      instructions: project.instructions || "",
      display,
      tools: [],
      files: [],
      memory_scope: project.memory_scope || "unset",
      training_disabled: project.training_disabled === true,
      categories: undefined
    };
  }

  async function createProject(project) {
    const payload = buildCreateProjectPayload(project);
    const created = await api("/backend-api/gizmos/snorlax/upsert", {
      method: "POST",
      body: JSON.stringify(payload)
    });
    if (created && created.error) {
      throw new Error("Project upsert returned error: " + redact(created.error));
    }
    const resource = created && created.resource || created;
    const normalized = normalizeProject(resource, "gizmos/snorlax/upsert");
    if (!normalized || !normalized.id) {
      throw new Error("Project upsert completed but response did not include a project id.");
    }
    return normalized;
  }

  async function listProjects() {
    const projects = [];
    const seen = new Set();
    let cursor = null;
    for (let page = 0; page < 20; page += 1) {
      const query = new URLSearchParams({
        owned_only: "true",
        conversations_per_gizmo: "0",
        limit: "50"
      });
      if (cursor) query.set("cursor", cursor);
      const payload = await api("/backend-api/gizmos/snorlax/sidebar?" + query.toString());
      for (const item of asArray(payload)) {
        const project = normalizeProject(item, "gizmos/snorlax/sidebar");
        if (!project || seen.has(project.id)) continue;
        seen.add(project.id);
        projects.push(project);
      }
      cursor = payload && payload.cursor || null;
      if (!cursor) break;
    }
    return projects;
  }

  const projects = await listProjects();
  const projectByName = new Map();
  for (const project of projects) {
    const key = normalizeKey(project.name);
    if (key && !projectByName.has(key)) {
      projectByName.set(key, project);
    }
  }

  const wantedProjects = getWantedProjects();
  const projectResults = [];
  const projectMap = {};
  for (const wantedProject of wantedProjects) {
    const key = normalizeKey(wantedProject.name);
    const existing = projectByName.get(key);
    if (existing) {
      if (wantedProject.id) projectMap[wantedProject.id] = existing.id;
      projectResults.push({
        status: "exists",
        project_name: wantedProject.name,
        source_project_id: wantedProject.id,
        target_project_id: existing.id,
        file_count: wantedProject.files.length,
        error: ""
      });
      continue;
    }

    if (dryRun) {
      projectResults.push({
        status: "would_create",
        project_name: wantedProject.name,
        source_project_id: wantedProject.id,
        target_project_id: "",
        file_count: wantedProject.files.length,
        error: ""
      });
      continue;
    }

    try {
      const created = await createProject(wantedProject);
      projectByName.set(key, created);
      projects.push(created);
      if (wantedProject.id) projectMap[wantedProject.id] = created.id;
      projectResults.push({
        status: "created",
        project_name: wantedProject.name,
        source_project_id: wantedProject.id,
        target_project_id: created.id,
        file_count: wantedProject.files.length,
        error: ""
      });
      await sleep(500);
    } catch (error) {
      projectResults.push({
        status: "create_error",
        project_name: wantedProject.name,
        source_project_id: wantedProject.id,
        target_project_id: "",
        file_count: wantedProject.files.length,
        error: String(error && error.message || error)
      });
    }
  }

  const results = [];
  for (let index = 0; index < items.length; index += 1) {
    const item = items[index];
    const title = normalize(item.title) || normalize(item.imported_id);
    const projectName = normalize(item.project_name);
    const importedId = normalize(item.imported_id);
    const targetProject = projectByName.get(normalizeKey(projectName));

    if (!targetProject) {
      results.push({
        status: "missing_project",
        title,
        project_name: projectName,
        source_project_id: normalize(item.project_id),
        target_project_id: "",
        imported_id: importedId,
        imported_url: normalize(item.imported_url),
        previous_gizmo_id: "",
        after_gizmo_id: "",
        error: "B account project not found by name."
      });
      continue;
    }

    try {
      const before = await api("/backend-api/conversation/" + encodeURIComponent(importedId));
      const previousGizmoId = normalize(before.gizmo_id);
      if (previousGizmoId === targetProject.id) {
        results.push({
          status: "already_in_project",
          title,
          project_name: projectName,
          source_project_id: normalize(item.project_id),
          target_project_id: targetProject.id,
          imported_id: importedId,
          imported_url: normalize(item.imported_url),
          previous_gizmo_id: previousGizmoId,
          after_gizmo_id: previousGizmoId,
          error: ""
        });
        continue;
      }

      if (dryRun) {
        results.push({
          status: "dry_run",
          title,
          project_name: projectName,
          source_project_id: normalize(item.project_id),
          target_project_id: targetProject.id,
          imported_id: importedId,
          imported_url: normalize(item.imported_url),
          previous_gizmo_id: previousGizmoId,
          after_gizmo_id: previousGizmoId,
          error: ""
        });
        continue;
      }

      await api("/backend-api/conversation/" + encodeURIComponent(importedId), {
        method: "PATCH",
        body: JSON.stringify({ gizmo_id: targetProject.id })
      });
      await sleep(500);
      const after = await api("/backend-api/conversation/" + encodeURIComponent(importedId));
      const afterGizmoId = normalize(after.gizmo_id);
      results.push({
        status: afterGizmoId === targetProject.id ? "restored" : "verify_failed",
        title,
        project_name: projectName,
        source_project_id: normalize(item.project_id),
        target_project_id: targetProject.id,
        imported_id: importedId,
        imported_url: normalize(item.imported_url),
        previous_gizmo_id: previousGizmoId,
        after_gizmo_id: afterGizmoId,
        error: afterGizmoId === targetProject.id ? "" : "PATCH completed but conversation gizmo_id did not match target project."
      });
    } catch (error) {
      results.push({
        status: "error",
        title,
        project_name: projectName,
        source_project_id: normalize(item.project_id),
        target_project_id: targetProject.id,
        imported_id: importedId,
        imported_url: normalize(item.imported_url),
        previous_gizmo_id: "",
        after_gizmo_id: "",
        error: String(error && error.message || error)
      });
    }

    await sleep(300);
  }

  const counts = {};
  const byProject = {};
  for (const result of results) {
    counts[result.status] = (counts[result.status] || 0) + 1;
    byProject[result.project_name] = (byProject[result.project_name] || 0) + 1;
  }
  const projectCounts = {};
  for (const result of projectResults) {
    projectCounts[result.status] = (projectCounts[result.status] || 0) + 1;
  }

  const finishedAt = new Date();
  return JSON.stringify({
    schema: "chatgpt-project-restore-v1",
    generated_at: finishedAt.toISOString(),
    source_json: sourceJson,
    account_hint: "account B in current browser session",
    config: {
      dryRun,
      delayMs: 300
    },
    summary: {
      input: items.length,
      processed: results.length,
      restored: counts.restored || 0,
      already_in_project: counts.already_in_project || 0,
      dry_run: counts.dry_run || 0,
      missing_project: counts.missing_project || 0,
      verify_failed: counts.verify_failed || 0,
      errors: counts.error || 0,
      source_projects: wantedProjects.length,
      projects_existing: projectCounts.exists || 0,
      projects_created: projectCounts.created || 0,
      projects_would_create: projectCounts.would_create || 0,
      project_create_errors: projectCounts.create_error || 0,
      projects_available: projects.length,
      by_project: byProject,
      elapsed_seconds: Math.round((finishedAt.getTime() - startedAt.getTime()) / 1000)
    },
    source_projects: wantedProjects,
    project_results: projectResults,
    project_map: projectMap,
    projects: projects,
    results
  });
})()
'@

  $expression = $template.Replace("__SOURCE_JSON__", $sourceJsonLiteral)
  $expression = $expression.Replace("__ITEMS_JSON__", $itemsJson)
  $expression = $expression.Replace("__SOURCE_PROJECTS_JSON__", $sourceProjectsJson)
  $expression = $expression.Replace("__DRY_RUN__", $dryRunLiteral)

  return Invoke-CdpJsonExpression -WebSocket $WebSocket -Expression $expression
}

function Get-TargetProjectId {
  param(
    $Report,
    $SourceProject
  )

  $sourceProjectId = Safe-Text $SourceProject.id
  $projectName = Safe-Text $SourceProject.name
  foreach ($row in @($Report.project_results)) {
    $rowSourceId = Safe-Text $row.source_project_id
    $rowName = Safe-Text $row.project_name
    $targetId = Safe-Text $row.target_project_id
    if ([string]::IsNullOrWhiteSpace($targetId)) {
      continue
    }
    if (-not [string]::IsNullOrWhiteSpace($sourceProjectId) -and $rowSourceId -eq $sourceProjectId) {
      return $targetId
    }
    if (-not [string]::IsNullOrWhiteSpace($projectName) -and $rowName -eq $projectName) {
      return $targetId
    }
  }

  return ""
}

function Invoke-UploadProjectFile {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    [string]$ProjectId,
    [string]$FilePath,
    [string]$OriginalName,
    [string]$SourceFileId
  )

  $resolvedPath = (Resolve-Path -LiteralPath $FilePath).Path
  $inputId = "gptsync_file_$([guid]::NewGuid().ToString("N"))"
  $inputIdJson = $inputId | ConvertTo-Json -Compress
  $projectIdJson = $ProjectId | ConvertTo-Json -Compress
  $originalNameJson = $OriginalName | ConvertTo-Json -Compress
  $sourceFileIdJson = $SourceFileId | ConvertTo-Json -Compress

  Invoke-CdpJsonExpression -WebSocket $WebSocket -Expression @"
(() => {
  const inputId = $inputIdJson;
  let input = document.getElementById(inputId);
  if (!input) {
    input = document.createElement("input");
    input.id = inputId;
    input.type = "file";
    input.style.position = "fixed";
    input.style.left = "-10000px";
    input.style.top = "-10000px";
    document.body.appendChild(input);
  }
  return JSON.stringify({ ok: true, inputId });
})()
"@ | Out-Null

  $document = Invoke-Cdp -WebSocket $WebSocket -Method "DOM.getDocument" -Params @{ depth = 1 }
  $node = Invoke-Cdp -WebSocket $WebSocket -Method "DOM.querySelector" -Params @{
    nodeId = $document.root.nodeId
    selector = "#$inputId"
  }
  if (-not $node.nodeId -or $node.nodeId -le 0) {
    throw "没有找到页面里的临时文件输入框。"
  }

  Invoke-Cdp -WebSocket $WebSocket -Method "DOM.setFileInputFiles" -Params @{
    nodeId = $node.nodeId
    files = @($resolvedPath)
  } | Out-Null

  $expression = @"
(async () => {
  const inputId = $inputIdJson;
  const projectId = $projectIdJson;
  const originalName = $originalNameJson;
  const sourceFileId = $sourceFileIdJson;
  const input = document.getElementById(inputId);
  if (!input || !input.files || input.files.length === 0) {
    throw new Error("No local file selected for upload.");
  }

  const localFile = input.files[0];
  const uploadName = originalName || localFile.name;
  const uploadFile = new File([localFile], uploadName, {
    type: localFile.type || "application/octet-stream",
    lastModified: localFile.lastModified
  });

  async function getAccessToken() {
    const response = await fetch("/api/auth/session", {
      credentials: "include",
      headers: { accept: "application/json" }
    });
    if (!response.ok) throw new Error("Cannot read ChatGPT session: HTTP " + response.status);
    const session = await response.json();
    if (!session || !session.accessToken) throw new Error("No accessToken found.");
    return session.accessToken;
  }

  const accessToken = await getAccessToken();
  const redact = (value) => JSON.stringify(value, (key, innerValue) => {
    return key.toLowerCase().includes("token") ? "[redacted]" : innerValue;
  });

  async function api(path, options = {}) {
    const response = await fetch(path, {
      credentials: "include",
      ...options,
      headers: {
        accept: "application/json",
        "content-type": "application/json",
        authorization: "Bearer " + accessToken,
        ...(options.headers || {})
      }
    });
    const text = await response.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = text; }
    if (!response.ok) {
      const message = typeof data === "string" ? data : redact(data);
      throw new Error("HTTP " + response.status + " " + path + ": " + message.slice(0, 800));
    }
    return data;
  }

  function asArray(payload) {
    if (Array.isArray(payload)) return payload;
    if (!payload || typeof payload !== "object") return [];
    for (const key of ["files", "items", "data", "results"]) {
      if (Array.isArray(payload[key])) return payload[key];
    }
    return [];
  }

  const before = await api("/backend-api/gizmos/" + encodeURIComponent(projectId) + "?include_files=true");
  const beforeFiles = asArray(before.files);
  const duplicate = beforeFiles.find((file) => {
    const sameName = String(file.name || "") === uploadFile.name;
    const sameSize = Number(file.size || 0) === Number(uploadFile.size || 0);
    return sameName && (!uploadFile.size || sameSize);
  });
  if (duplicate) {
    return JSON.stringify({
      status: "already_in_project",
      project_id: projectId,
      source_file_id: sourceFileId,
      uploaded_file_id: duplicate.file_id || duplicate.id || "",
      name: uploadFile.name,
      size: uploadFile.size,
      error: ""
    });
  }

  async function readUploadResponse(response, label) {
    const text = await response.text();
    if (!response.ok) {
      throw new Error(label + " failed: HTTP " + response.status + " " + text.slice(0, 800));
    }
    return text;
  }

  async function processUploadedFile(fileId) {
    const response = await fetch("/backend-api/files/process_upload_stream", {
      method: "POST",
      credentials: "include",
      headers: {
        accept: "application/json",
        "content-type": "application/json",
        authorization: "Bearer " + accessToken
      },
      body: JSON.stringify({
        file_id: fileId,
        use_case: "agent",
        gizmo_id: projectId,
        index_for_retrieval: true,
        file_name: uploadFile.name
      })
    });
    return readUploadResponse(response, "process_upload_stream");
  }

  const created = await api("/backend-api/files", {
    method: "POST",
    body: JSON.stringify({
      file_name: uploadFile.name,
      file_size: uploadFile.size,
      use_case: "agent",
      gizmo_id: projectId,
      timezone_offset_min: new Date().getTimezoneOffset(),
      reset_rate_limits: false
    })
  });
  if (created.status === "error") {
    throw new Error("Could not create B account file: " + (created.error_code || "unknown"));
  }

  const fileId = created.file_id;
  const uploadUrl = created.upload_url;
  if (!fileId || !uploadUrl) {
    throw new Error("File create response did not include file_id/upload_url.");
  }

  const uploadTarget = new URL(uploadUrl, location.origin);
  const isEstuaryFinalize = uploadTarget.href.toLowerCase().includes("/api/estuary/upload_content_and_finalize");
  const isEstuaryBytes = uploadTarget.href.toLowerCase().includes("/api/estuary/upload_content_bytes");

  if (isEstuaryFinalize || isEstuaryBytes) {
    const form = new FormData();
    form.append("file", uploadFile);
    form.append("upload_url", uploadTarget.searchParams.get("upload_url") || uploadTarget.href);
    form.append("file_id", fileId);
    form.append("file_name", uploadFile.name);
    form.append("use_case", "agent");
    form.append("index_for_retrieval", "true");
    form.append("gizmo_id", projectId);

    const response = await fetch(uploadTarget.href, {
      method: "POST",
      credentials: "include",
      headers: { authorization: "Bearer " + accessToken },
      body: form
    });
    await readUploadResponse(response, isEstuaryFinalize ? "estuary_finalize_upload" : "estuary_bytes_upload");
    if (isEstuaryBytes) {
      await processUploadedFile(fileId);
    }
  } else {
    const response = await fetch(uploadTarget.href, {
      method: "PUT",
      credentials: uploadTarget.origin === location.origin ? "include" : "omit",
      headers: { "content-type": uploadFile.type || "application/octet-stream" },
      body: uploadFile
    });
    await readUploadResponse(response, "blob_upload");
    await processUploadedFile(fileId);
  }

  const fileRecord = {
    file_response_type: "full_file_response",
    id: fileId,
    file_id: fileId,
    name: uploadFile.name,
    type: uploadFile.type || "application/octet-stream",
    size: uploadFile.size,
    location: "file_service"
  };

  const attachBodies = [
    { files: [fileRecord] },
    { files: [{ id: fileId, file_id: fileId, name: uploadFile.name, type: uploadFile.type || "application/octet-stream", size: uploadFile.size, location: "file_service" }] },
    { file_ids: [fileId] },
    { files: [fileId] }
  ];

  let attachError = "";
  for (const body of attachBodies) {
    try {
      await api("/backend-api/projects/" + encodeURIComponent(projectId) + "/files", {
        method: "POST",
        body: JSON.stringify(body)
      });
      attachError = "";
      break;
    } catch (error) {
      attachError = String(error && error.message || error);
    }
  }
  if (attachError) {
    throw new Error("File uploaded but attach failed: " + attachError);
  }

  const after = await api("/backend-api/gizmos/" + encodeURIComponent(projectId) + "?include_files=true");
  const afterFiles = asArray(after.files);
  const matched = afterFiles.some((file) => {
    return String(file.file_id || file.id || "") === fileId ||
      (String(file.name || "") === uploadFile.name && Number(file.size || 0) === Number(uploadFile.size || 0));
  });

  return JSON.stringify({
    status: matched ? "uploaded" : "verify_failed",
    project_id: projectId,
    source_file_id: sourceFileId,
    uploaded_file_id: fileId,
    name: uploadFile.name,
    size: uploadFile.size,
    error: matched ? "" : "Attachment endpoint completed but project detail did not show the uploaded file."
  });
})()
"@

  try {
    return Invoke-CdpJsonExpression -WebSocket $WebSocket -Expression $expression
  } finally {
    try {
      Invoke-CdpJsonExpression -WebSocket $WebSocket -Expression @"
(() => {
  const input = document.getElementById($inputIdJson);
  if (input) input.remove();
  return JSON.stringify({ ok: true });
})()
"@ | Out-Null
    } catch {
    }
  }
}

function Invoke-ProjectAttachmentTransfer {
  param(
    [System.Net.WebSockets.ClientWebSocket]$WebSocket,
    $Report,
    [object[]]$SourceProjects,
    [bool]$DryRunMode,
    [bool]$SkipFiles
  )

  $results = @()
  if ($SkipFiles) {
    $Report | Add-Member -NotePropertyName attachment_results -NotePropertyValue $results -Force
    $Report.summary | Add-Member -NotePropertyName attachment_uploaded -NotePropertyValue 0 -Force
    $Report.summary | Add-Member -NotePropertyName attachment_already_present -NotePropertyValue 0 -Force
    $Report.summary | Add-Member -NotePropertyName attachment_dry_run -NotePropertyValue 0 -Force
    $Report.summary | Add-Member -NotePropertyName attachment_errors -NotePropertyValue 0 -Force
    return $results
  }

  foreach ($project in @($SourceProjects)) {
    $targetProjectId = Get-TargetProjectId -Report $Report -SourceProject $project
    foreach ($file in @($project.files)) {
      $projectName = Safe-Text $project.name
      $sourceProjectId = Safe-Text $project.id
      $sourceFileId = Safe-Text $file.file_id
      if ([string]::IsNullOrWhiteSpace($sourceFileId)) {
        $sourceFileId = Safe-Text $file.id
      }
      $fileName = Safe-Text $file.name
      $localPath = Safe-Text $file.local_path

      if ($DryRunMode) {
        $results += [pscustomobject]@{
          status = "dry_run"
          project_name = $projectName
          source_project_id = $sourceProjectId
          target_project_id = $targetProjectId
          source_file_id = $sourceFileId
          uploaded_file_id = ""
          name = $fileName
          local_path = $localPath
          error = ""
        }
        continue
      }

      if ([string]::IsNullOrWhiteSpace($targetProjectId)) {
        $results += [pscustomobject]@{
          status = "missing_target_project"
          project_name = $projectName
          source_project_id = $sourceProjectId
          target_project_id = ""
          source_file_id = $sourceFileId
          uploaded_file_id = ""
          name = $fileName
          local_path = $localPath
          error = "No target B account project id."
        }
        continue
      }

      if ([string]::IsNullOrWhiteSpace($localPath) -or -not (Test-Path -LiteralPath $localPath)) {
        $results += [pscustomobject]@{
          status = "missing_local_file"
          project_name = $projectName
          source_project_id = $sourceProjectId
          target_project_id = $targetProjectId
          source_file_id = $sourceFileId
          uploaded_file_id = ""
          name = $fileName
          local_path = $localPath
          error = "A account project file was not downloaded locally."
        }
        continue
      }

      try {
        Write-Host "[file] 上传项目附件：$projectName / $fileName"
        $upload = Invoke-UploadProjectFile -WebSocket $WebSocket -ProjectId $targetProjectId -FilePath $localPath -OriginalName $fileName -SourceFileId $sourceFileId
        $results += [pscustomobject]@{
          status = $upload.status
          project_name = $projectName
          source_project_id = $sourceProjectId
          target_project_id = $targetProjectId
          source_file_id = $sourceFileId
          uploaded_file_id = $upload.uploaded_file_id
          name = $fileName
          local_path = $localPath
          error = $upload.error
        }
      } catch {
        $message = $_.Exception.Message
        Write-Host "[file:error] $projectName / $fileName :: $message" -ForegroundColor Yellow
        $results += [pscustomobject]@{
          status = "error"
          project_name = $projectName
          source_project_id = $sourceProjectId
          target_project_id = $targetProjectId
          source_file_id = $sourceFileId
          uploaded_file_id = ""
          name = $fileName
          local_path = $localPath
          error = $message
        }
      }
    }
  }

  $uploaded = @($results | Where-Object { $_.status -eq "uploaded" }).Count
  $alreadyPresent = @($results | Where-Object { $_.status -eq "already_in_project" }).Count
  $dryRun = @($results | Where-Object { $_.status -eq "dry_run" }).Count
  $errors = @($results | Where-Object { $_.status -eq "error" -or $_.status -eq "missing_local_file" -or $_.status -eq "missing_target_project" -or $_.status -eq "verify_failed" }).Count

  $Report | Add-Member -NotePropertyName attachment_results -NotePropertyValue $results -Force
  $Report.summary | Add-Member -NotePropertyName attachment_total -NotePropertyValue @($results).Count -Force
  $Report.summary | Add-Member -NotePropertyName attachment_uploaded -NotePropertyValue $uploaded -Force
  $Report.summary | Add-Member -NotePropertyName attachment_already_present -NotePropertyValue $alreadyPresent -Force
  $Report.summary | Add-Member -NotePropertyName attachment_dry_run -NotePropertyValue $dryRun -Force
  $Report.summary | Add-Member -NotePropertyName attachment_errors -NotePropertyValue $errors -Force

  return $results
}

New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

Write-Step "读取 B 账号导入报告"
$resolvedInputJson = Resolve-InputJsonPath -Path $InputJson
$items = @(Get-RestoreItemsFromPath -Path $resolvedInputJson)
$sourceProjects = @(Get-SourceProjectsFromPath -Path $resolvedInputJson)
if ($sourceProjects.Count -eq 0) {
  $fallbackSourceProjectsPath = Resolve-LatestSourceProjectsPath
  if (-not [string]::IsNullOrWhiteSpace($fallbackSourceProjectsPath) -and $fallbackSourceProjectsPath -ne $resolvedInputJson) {
    $sourceProjects = @(Get-SourceProjectsFromPath -Path $fallbackSourceProjectsPath)
    Write-Host "源项目清单来自：$fallbackSourceProjectsPath"
  }
}
Write-Host "输入 JSON：$resolvedInputJson"
Write-Host "待还原到项目的聊天：$($items.Count) 条"
Write-Host "源项目清单：$($sourceProjects.Count) 个"
if ($Skip -gt 0) {
  Write-Host "已跳过前 $Skip 条。"
}
if ($Limit -gt 0) {
  Write-Host "本次限制处理 $Limit 条。"
}

if ($items.Count -eq 0 -and $sourceProjects.Count -eq 0) {
  throw "输入报告里没有需要还原到项目的聊天，也没有源项目清单。"
}

Write-Step "连接 B 账号专用浏览器"
if (-not (Wait-DevTools -Port $Port)) {
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
  Start-Process -FilePath $browserPath -ArgumentList $browserArgs | Out-Null

  if (-not (Wait-DevTools -Port $Port)) {
    throw "浏览器 DevTools 端口没有启动。请关闭刚打开的 B 账号专用浏览器窗口后再试。"
  }
} else {
  Write-Host "复用已打开的 B 账号专用浏览器 DevTools 端口：$Port"
  Write-Host "此脚本不会关闭 Upnet/VPN。"
}

$target = Get-ChatGptTarget -Port $Port
Write-Host "DevTools 目标：$($target.title) $($target.url)"
$ws = New-CdpConnection -WebSocketUrl $target.webSocketDebuggerUrl

try {
  Invoke-Cdp -WebSocket $ws -Method "Runtime.enable" | Out-Null
  Invoke-Cdp -WebSocket $ws -Method "Page.enable" | Out-Null
  Invoke-Cdp -WebSocket $ws -Method "DOM.enable" | Out-Null
  $chatGptHref = Ensure-ChatGptPage -WebSocket $ws
  Write-Host "当前页面：$chatGptHref"

  Write-Step "检查 B 账号登录状态"
  if (-not (Test-ChatGptSession -WebSocket $ws)) {
    Write-Host "请在刚打开的专用浏览器窗口里登录 B 账号。" -ForegroundColor Yellow
    Write-Host "登录完成并看到 ChatGPT 首页后，回到这个窗口按 Enter 继续。"
    Read-Host | Out-Null

    if (-not (Test-ChatGptSession -WebSocket $ws)) {
      throw "仍然没有检测到 B 账号登录状态。请确认专用浏览器窗口已经登录 chatgpt.com。"
    }
  }

  if (-not $DryRun -and -not $AssumeYes) {
    Write-Step "确认开始项目还原"
    Write-Host "脚本将确保 B 账号存在 $($sourceProjects.Count) 个源项目，把 $($items.Count) 条已导入聊天移回项目，并转移已下载的项目附件。"
    Write-Host "输入 YES 开始；直接回车会取消。"
    $confirmation = Read-Host
    if ($confirmation -ne "YES") {
      throw "用户取消，未创建项目、移动聊天或上传附件。"
    }
  }

  Write-Step "开始还原项目归属"
  $report = Invoke-ProjectRestore -WebSocket $ws -SourceJson $resolvedInputJson -Items $items -SourceProjects $sourceProjects -DryRunMode ([bool]$DryRun)

  if ($SkipProjectFiles) {
    Write-Host "已指定 -SkipProjectFiles：跳过项目附件转移。"
    Invoke-ProjectAttachmentTransfer -WebSocket $ws -Report $report -SourceProjects $sourceProjects -DryRunMode ([bool]$DryRun) -SkipFiles $true | Out-Null
  } else {
    Write-Step "转移项目附件"
    $attachmentResults = @(Invoke-ProjectAttachmentTransfer -WebSocket $ws -Report $report -SourceProjects $sourceProjects -DryRunMode ([bool]$DryRun) -SkipFiles $false)
    Write-Host "项目附件：总计 $($attachmentResults.Count)，上传 $($report.summary.attachment_uploaded)，已存在 $($report.summary.attachment_already_present)，失败 $($report.summary.attachment_errors)"
  }

  $paths = Export-RestoreReport -Report $report

  Write-Step "完成"
  Write-Host "项目已存在：$($report.summary.projects_existing) 个"
  Write-Host "项目新建：$($report.summary.projects_created) 个"
  Write-Host "项目待新建 Dry run：$($report.summary.projects_would_create) 个"
  Write-Host "项目新建失败：$($report.summary.project_create_errors) 个"
  Write-Host "已还原：$($report.summary.restored) 条"
  Write-Host "原本已在项目中：$($report.summary.already_in_project) 条"
  Write-Host "Dry run：$($report.summary.dry_run) 条"
  Write-Host "缺少目标项目：$($report.summary.missing_project) 条"
  Write-Host "验证失败：$($report.summary.verify_failed) 条"
  Write-Host "失败：$($report.summary.errors) 条"
  if ($null -ne $report.summary.attachment_total) {
    Write-Host "项目附件上传：$($report.summary.attachment_uploaded) 个，已存在 $($report.summary.attachment_already_present) 个，失败 $($report.summary.attachment_errors) 个"
  }
  Write-Host "JSON：$($paths.JsonPath)"
  Write-Host "CSV ：$($paths.CsvPath)"
  Write-Host "项目CSV：$($paths.ProjectCsvPath)"
  Write-Host "附件CSV：$($paths.AttachmentCsvPath)"
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
