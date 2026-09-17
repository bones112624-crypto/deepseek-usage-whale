<#
.SYNOPSIS
  DeepSeek 余额小鲸鱼挂件（桌面版）。

.DESCRIPTION
  把 DSH 版「DeepSeek-Balance-Whale-Widget」的外观与交互搬到 Windows 桌面：
  小鲸鱼 cut-out 立绘 + 代码绘制的对话气泡 + 余额/今日已用/本轮缓存命中率，
  支持拖拽、四边四分之一吸附、左吸附镜像翻转、按压 Q 弹、数字滚动、
  随机台词气泡与音效（音效开关、大小、用量模式等改由配置文件与 CLI 设置）。

  生命周期：跟着 Codex 启停 —— Codex 打开（其 MCP 服务被拉起）时自动放出，
  Codex 退出后自动收起；手动独立启动（Codex 未运行时）则不会被自动收掉。
  退出快捷键 Ctrl+Shift+Z 只关挂件，不影响 Codex。

  鼠标：左键拖拽或点击出气泡，右键直接打开 DeepSeek 用量监控面板
  （只启动面板服务本身，不会顺带拉起悬浮球；node 的控制台窗口是隐藏的）。

  素材（立绘 / gif / 音效）沿用上游 MIT 许可的原始文件。

  用法：
      powershell -NoProfile -ExecutionPolicy Bypass -File whale.ps1
#>
[CmdletBinding()]
param(
  [string]$DataDir = (Join-Path $env:USERPROFILE '.deepseek-whale'),
  [string]$AssetDir,
  [string]$UsagePanelUrl = 'http://127.0.0.1:8788',   # 右键打开的 DeepSeek 用量监控面板
  [string]$RenderOnly,      # 调试用：只渲染一帧存成 PNG 后退出
  [switch]$RenderBubble,    # 调试用：渲染时把气泡打开
  [switch]$RenderFlip,      # 调试用：渲染左吸附镜像态
  [switch]$TestOpenPanel,   # 调试用：只跑一次"右键打开面板"的服务启动逻辑后退出
  [string]$CodexProcessName = 'ChatGPT',        # 跟随模式下用来识别 Codex 的进程名
  [string]$CodexPathFilter = '*OpenAI.Codex_*', # 再按路径筛一次，避免认错同名进程
  [string]$QuitHotkey,                          # 退出快捷键；不传就用 config.json 里的 quitHotkey
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# 常量（对齐上游规格）
# ---------------------------------------------------------------------------
$MIN_SCALE = 0.6
$MAX_SCALE = 2.5
$CLICK_SQ = 9          # 位移平方 < 9（>3px）判定为点击
$REFRESH_MS = 60000    # 余额自动刷新
$BUBBLE_MS = 5000      # 气泡自动收起
$ANIM_MS = 700         # 数字滚动
$TURN_POLL_MS = 1500   # 每轮消耗轮询

$C_TEXT = '#536ba9'    # 文字
$C_HINT = '#9fb0d9'    # 提示行
$C_STROKE = '#203170'  # 气泡描边
$C_PEAK = '#e0433f'
$C_OFF = '#2fa24c'

$WIDGET_W = 1026       # 气泡画布
$WIDGET_H = 700
$WHALE_RATIO = 0.5945  # 立绘占挂件宽度比例
$TEXT_X = 0.4425       # 文字块中心
$TEXT_Y = 0.38

if (-not $AssetDir) {
  $AssetDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets'
}
if (-not (Test-Path -LiteralPath $DataDir)) {
  New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

$configFile = Join-Path $DataDir 'config.json'
$usageFile = Join-Path $DataDir 'usage.json'
$costFile = Join-Path $DataDir 'last-turn.json'
$logFile = Join-Path $DataDir 'whale.log'
# 跟随脚本用它来"优雅关闭"：写这个文件 → 挂件自己走完关闭流程后退出
$stopFile = Join-Path $DataDir 'whale-stop'
$pidFile = Join-Path $DataDir 'widget.pid'
$userStopFile = Join-Path $DataDir 'user-stop.json'   # 用户主动 Ctrl+Shift+Z 关掉的记号

function Write-Log {
  param([string]$Message)
  if ($Quiet) { return }
  try {
    if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 512KB) {
      $kept = Get-Content -LiteralPath $logFile -Tail 150 -ErrorAction SilentlyContinue
      [System.IO.File]::WriteAllLines($logFile, $kept, (New-Object System.Text.UTF8Encoding($false)))
    }
    Add-Content -LiteralPath $logFile -Value ("[{0}] {1}" -f (Get-Date).ToString('MM-dd HH:mm:ss'), $Message) -Encoding UTF8
  } catch { }
}

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------
# 把 "Ctrl+Shift+Z" 这类写法解析成 RegisterHotKey 需要的修饰键位+虚拟键码。
# 认不出来或者没有任何修饰键时返回 $null（调用方会记一条日志并跳过注册）。
function Parse-QuitHotkey {
  param([string]$Text)
  if (-not $Text) { return $null }
  $mods = 0
  $vk = 0
  foreach ($raw in ($Text -split '\+')) {
    $t = $raw.Trim()
    if ($t -match '^(?i)(ctrl|control)$') { $mods = $mods -bor 0x0002 }
    elseif ($t -match '^(?i)shift$') { $mods = $mods -bor 0x0004 }
    elseif ($t -match '^(?i)alt$') { $mods = $mods -bor 0x0001 }
    elseif ($t -match '^(?i)win$') { $mods = $mods -bor 0x0008 }
    elseif ($t -match '^[A-Za-z]$') { $vk = [int][char]$t.ToUpper() }
    elseif ($t -match '^[0-9]$') { $vk = [int][char]$t }
    else { return $null }
  }
  if ($mods -eq 0 -or $vk -eq 0) { return $null }
  return [pscustomobject]@{ Mods = $mods; Vk = $vk }
}

$defaults = [ordered]@{
  scale           = 1.5
  sound           = $true
  vol             = 1.0
  soundSet        = 'duck'
  usageMode       = 'ledger'
  peakMode        = 'default'
  bubbleOn        = $true
  turnCostOn      = $true
  turnCostCloseSec = 5
  followCodex     = $true      # 由 Codex 的 MCP 服务拉起时跟随 Codex 启停
  quitHotkey      = 'Ctrl+Shift+Z'   # 退出快捷键，留空字符串可禁用
  x               = $null
  y               = $null
}

function Read-Config {
  $cfg = [ordered]@{}
  foreach ($k in $defaults.Keys) { $cfg[$k] = $defaults[$k] }
  if (Test-Path -LiteralPath $configFile) {
    try {
      $raw = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($k in $defaults.Keys) {
        if ($null -ne $raw.$k) { $cfg[$k] = $raw.$k }
      }
    } catch { }
  }
  return $cfg
}

function Save-Config {
  try {
    # 以磁盘上的当前内容为底，再覆盖"本次会话真正改过"的键。
    # 这样挂件运行期间你在 config.json 里手改的值（比如 quitHotkey、followCodex）
    # 不会在挂件退出时被它内存里的旧值悄悄写回去。
    $out = [ordered]@{}
    if (Test-Path -LiteralPath $configFile) {
      try {
        $disk = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $disk.PSObject.Properties) { $out[$p.Name] = $p.Value }
      } catch { }
    }
    foreach ($k in $script:cfg.Keys) {
      $changedHere = (-not $script:cfgAtStart.ContainsKey($k)) -or
                     ([string]$script:cfg[$k] -ne [string]$script:cfgAtStart[$k])
      if ($changedHere -or -not $out.Contains($k)) { $out[$k] = $script:cfg[$k] }
    }
    [System.IO.File]::WriteAllText($configFile, ($out | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

$script:cfg = Read-Config
$script:cfgAtStart = @{}
foreach ($k in $script:cfg.Keys) { $script:cfgAtStart[$k] = $script:cfg[$k] }

# 退出快捷键：命令行显式传了就用命令行的，否则用 config.json 里的 quitHotkey
$script:quitHotkey = if ($PSBoundParameters.ContainsKey('QuitHotkey')) { $QuitHotkey } else { [string]$script:cfg.quitHotkey }

# ---------------------------------------------------------------------------
# 凭据（沿用 Codex 的 DeepSeek provider）
# ---------------------------------------------------------------------------
function Get-ApiKey {
  $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
  $toml = Join-Path $codexHome 'config.toml'
  if (-not (Test-Path -LiteralPath $toml)) { return $null }
  $providers = @{}
  $cur = $null
  foreach ($rawLine in (Get-Content -LiteralPath $toml -Encoding UTF8)) {
    $line = ($rawLine -replace '#.*$', '').Trim()
    if (-not $line) { continue }
    if ($line -match '^\[([^\]]+)\]$') {
      $name = $matches[1].Trim()
      if ($name.StartsWith('model_providers.')) {
        $cur = $name.Substring('model_providers.'.Length).Trim('"')
        if (-not $providers.ContainsKey($cur)) { $providers[$cur] = @{} }
      } else { $cur = $null }
      continue
    }
    if (-not $cur) { continue }
    if ($line -match '^([A-Za-z0-9_."-]+)\s*=\s*(.+)$') {
      $k = $matches[1].Trim('"'); $v = $matches[2].Trim()
      if ($v -match '^([''"])(.*)\1$') { $v = $matches[2] }
      $providers[$cur][$k] = $v
    }
  }
  foreach ($info in $providers.Values) {
    $base = [string]$info['base_url']; $name = [string]$info['name']
    if ($base -notmatch 'deepseek' -and $name -notmatch 'deepseek') { continue }
    foreach ($k in @('experimental_bearer_token', 'api_key', 'bearer_token')) {
      if ($info[$k]) { return [string]$info[$k] }
    }
  }
  return $null
}

$script:apiKey = Get-ApiKey

# ---------------------------------------------------------------------------
# 峰谷定价（元 / 百万 token，[空闲, 高峰]）
# 上游 BASE_PRICE 是 2026-09-10 调价前的旧价，这里按官方定价页更新过。
# ---------------------------------------------------------------------------
$BASE_PRICE = @{ hit = @(0.02, 0.04); miss = @(1.0, 2.0); out = @(4.0, 8.0) }
$PRO_PRICE = @{ hit = @(0.15, 0.30); miss = @(4.5, 9.0); out = @(13.5, 27.0) }

function Get-Price {
  param([string]$Model)
  if ($Model -match '(?i)reasoner|pro') { return $PRO_PRICE }
  return $BASE_PRICE
}

function Test-Peak {
  param([datetime]$When = (Get-Date))
  $beijing = $When.ToUniversalTime().AddHours(8)
  $wd = [int]$beijing.DayOfWeek
  if ($wd -eq 0 -or $wd -eq 6) { return $false }   # 周末全天谷价
  $m = $beijing.Hour * 60 + $beijing.Minute
  return (($m -ge 540 -and $m -lt 720) -or ($m -ge 840 -and $m -lt 1080))
}

function Get-Cost {
  param([string]$Model, [double]$Hit, [double]$Miss, [double]$Out, [datetime]$When = (Get-Date))
  $p = Get-Price $Model
  $i = if (Test-Peak $When) { 1 } else { 0 }
  return ($Hit * $p.hit[$i] + $Miss * $p.miss[$i] + $Out * $p.out[$i]) / 1000000
}

function Format-Money {
  param([double]$Value, [string]$Currency = 'CNY')
  $sym = switch ($Currency) { 'CNY' { '¥' } 'USD' { '$' } 'EUR' { '€' } default { '' } }
  if ($sym) { return ("{0} {1:N2}" -f $sym, $Value) }
  return ("{0:N2} {1}" -f $Value, $Currency)
}

# ---------------------------------------------------------------------------
# 余额
# ---------------------------------------------------------------------------
$script:balance = $null          # 最近一次成功值
$script:shown = $null            # 滚动动画当前显示值
$script:currency = 'CNY'
$script:status = 'loading'       # loading | ok | error
$script:message = ''
$script:todayUsage = $null
$script:lastBalanceAt = $null
$script:lastAnimAt = $null

function Get-LocalDay {
  $b = (Get-Date).ToUniversalTime().AddHours(8)
  return $b.ToString('yyyy-MM-dd')
}

function Update-Ledger {
  param([double]$Total, [string]$Currency)
  $state = $null
  if (Test-Path -LiteralPath $usageFile) {
    try { $state = Get-Content -LiteralPath $usageFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  }
  $today = Get-LocalDay
  if (-not $state) {
    $state = [pscustomobject]@{ date = $today; lastBalance = $null; lastCurrency = $null; todayUsage = 0; history = @() }
  }
  if ($state.date -ne $today) {
    $hist = @($state.history) + @([pscustomobject]@{ date = $state.date; usage = [double]$state.todayUsage })
    $state.history = @($hist | Select-Object -Last 30)
    $state.date = $today
    $state.todayUsage = 0
    $state.lastBalance = $Total
    $state.lastCurrency = $Currency
  } elseif ($null -eq $state.lastBalance -or $null -eq $state.lastCurrency) {
    $state.lastBalance = $Total; $state.lastCurrency = $Currency
  } elseif ($state.lastCurrency -ne $Currency) {
    # 币种变化只重置基准，不记差值
    $state.lastBalance = $Total; $state.lastCurrency = $Currency
  } elseif ($Total -lt [double]$state.lastBalance) {
    $state.todayUsage = [double]$state.todayUsage + ([double]$state.lastBalance - $Total)
    $state.lastBalance = $Total
  } else {
    $state.lastBalance = $Total
  }
  try {
    [System.IO.File]::WriteAllText($usageFile, ($state | ConvertTo-Json -Depth 5 -Compress), (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
  return [double]$state.todayUsage
}

function Get-ReadLedger {
  if (-not (Test-Path -LiteralPath $usageFile)) { return 0 }
  try {
    $s = Get-Content -LiteralPath $usageFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($s.date -eq (Get-LocalDay)) { return [double]$s.todayUsage }
  } catch { }
  return 0
}

# 挑展示项：优先 CNY 且 >0，其次任意非零，再退 CNY，最后第一项
function Select-BalanceInfo {
  param($Infos)
  $list = @($Infos)
  if ($list.Count -eq 0) { return $null }
  $cny = $list | Where-Object { ([string]$_.currency).ToUpper() -eq 'CNY' } | Select-Object -First 1
  if ($cny -and [double]$cny.total_balance -gt 0) { return $cny }
  $nz = $list | Where-Object { [double]$_.total_balance -gt 0 } | Select-Object -First 1
  if ($nz) { return $nz }
  if ($cny) { return $cny }
  return $list[0]
}

# ---------------------------------------------------------------------------
# 余额：异步取数
#   Invoke-RestMethod 是同步的，在 UI 线程上等一个跨公网的 HTTPS 请求会把整个
#   挂件冻住（正常也要几百毫秒，网络抽风时能到 20 秒 ×2 次）。改成 HttpClient
#   异步：请求跑在线程池，UI 定时器只负责看 Task 有没有完成，界面全程可交互。
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

$script:http = $null
$script:balanceTask = $null
$script:balanceManual = $false
$script:lastBalanceRequestAt = [datetime]::MinValue

function Get-HttpClient {
  if (-not $script:http) {
    $client = New-Object System.Net.Http.HttpClient   # 沿用系统代理设置
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    $script:http = $client
  }
  return $script:http
}

function Start-BalanceFetch {
  param([switch]$Manual)
  if (-not $script:apiKey) {
    $script:status = 'error'; $script:message = '未配置 API Key · 点击重试'
    return $false
  }
  if ($script:balanceTask) { return $false }    # 上一个还没回来，别叠加请求
  try {
    $client = Get-HttpClient
    $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList `
      ([System.Net.Http.HttpMethod]::Get), 'https://api.deepseek.com/user/balance'
    $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue -ArgumentList 'Bearer', $script:apiKey
    $req.Headers.Accept.Add((New-Object System.Net.Http.Headers.MediaTypeWithQualityHeaderValue -ArgumentList 'application/json'))
    # ResponseContentRead：Task 完成时正文已经读完，之后读 Result 不会阻塞
    $script:balanceTask = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseContentRead)
    $script:balanceManual = [bool]$Manual
  } catch {
    $script:balanceTask = $null
    if ($null -ne $script:balance) { $script:status = 'ok' } else { $script:status = 'error'; $script:message = '网络异常 · 点击重试' }
  }
  return $true
}

function Complete-BalanceFetch {
  $task = $script:balanceTask
  if (-not $task -or -not $task.IsCompleted) { return $false }
  $script:balanceTask = $null
  $manual = $script:balanceManual
  $resp = $null
  try {
    if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
    if ($task.IsCanceled) { throw '请求超时' }
    $resp = $task.Result
  } catch {
    # 瞬时失败：沿用最近余额，不闪错误
    if ($null -ne $script:balance) { $script:status = 'ok' }
    else { $script:status = 'error'; $script:message = '网络异常 · 点击重试' }
    return $true
  }
  $code = [int]$resp.StatusCode
  if ($code -lt 200 -or $code -ge 300) {
    if ($code -ge 400 -and $code -lt 500) {
      $script:status = 'error'; $script:message = "HTTP $code · 点击重试"
      Write-Log "余额请求 4xx: $code"
    } elseif ($null -ne $script:balance) { $script:status = 'ok' }
    else { $script:status = 'error'; $script:message = "HTTP $code · 点击重试" }
    try { $resp.Dispose() } catch { }
    return $true
  }
  $result = $null
  try {
    $json = $resp.Content.ReadAsStringAsync().Result
    $result = $json | ConvertFrom-Json
  } catch {
    if ($null -ne $script:balance) { $script:status = 'ok' } else { $script:status = 'error'; $script:message = '响应解析失败 · 点击重试' }
  } finally {
    try { $resp.Dispose() } catch { }
  }
  if ($result) { Apply-Balance -Result $result -Manual:$manual }
  return $true
}

function Apply-Balance {
  param($Result, [switch]$Manual)
  $info = Select-BalanceInfo $Result.balance_infos
  if (-not $info) {
    $script:status = 'error'; $script:message = '接口未返回余额'
    return
  }

  $newTotal = [double]$info.total_balance
  $newCurrency = [string]$info.currency
  $changed = ($null -ne $script:balance) -and ([Math]::Abs($newTotal - $script:balance) -gt 0.0000001)

  $script:balance = $newTotal
  $script:currency = $newCurrency
  $script:status = 'ok'
  $script:lastBalanceAt = Get-Date
  if ($script:cfg.usageMode -eq 'ledger') {
    $script:todayUsage = Update-Ledger -Total $newTotal -Currency $newCurrency
  }

  if ($changed) {
    $script:animFrom = $script:shown
    if ($null -eq $script:animFrom) { $script:animFrom = $newTotal }
    $script:animTo = $newTotal
    $script:animStart = Get-Date
    $script:animating = $true
    # 原来这里只设了 animStart 却没启动重绘定时器，数字得等到下一次点击
    # （Start-Bounce 会顺手启动它）才会滚到新值。显式启动，余额一变就滚动。
    if ($script:animTimer -and -not $script:animTimer.Enabled) { $script:animTimer.Start() }
    if (-not $Manual) { Show-Bubble }
  } else {
    $script:shown = $newTotal
  }
}

# 兼容原有调用点：发一次异步请求就返回，不再阻塞
function Refresh-Balance {
  param([switch]$Manual)
  $script:lastBalanceRequestAt = Get-Date
  return (Start-BalanceFetch -Manual:$Manual)
}

# ---------------------------------------------------------------------------
# 每轮对话消耗：读 Codex 会话日志尾部（真实 usage，非估算）
# ---------------------------------------------------------------------------
$script:lastTurnSeq = 0
$script:lastTurnSeen = $false
$script:costBubble = $false
$script:costAmount = 0
$script:costShownAt = $null
$script:costRate = $null         # "上一轮对话消耗"那颗气泡自己的命中率（那一轮跑完的完整值）
$script:cacheRate = $null        # 最近一轮的缓存命中率（百分数），气泡第四行用
$script:threadRate = $null       # 整个会话累计的缓存命中率（百分数），悬停详情里显示
$script:loggedTurn = $null       # 已经记过日志的轮次，避免重复刷日志

# 轮询缓存：整目录递归扫描 + 读 768KB 尾部 + 逐行 JSON，一次要几十毫秒。
# 记下上次用的文件，8 秒内直接复用（仍会 stat 一次确认没被删）；
# 文件长度没变过就连读都不读。空闲时轮询成本降到接近 0。
$script:turnFiles = $null
$script:turnScanAt = [datetime]::MinValue
$script:turnStamp = $null
$script:turnCache = $null
$script:activeThreads = @()
$script:activeScanAt = [datetime]::MinValue

function Read-RolloutTail {
  param([string]$Path, [int]$Bytes = 786432)
  try {
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
      $len = $fs.Length
      $read = [Math]::Min($Bytes, $len)
      $fs.Seek($len - $read, 'Begin') | Out-Null
      $buf = New-Object byte[] $read
      $null = $fs.Read($buf, 0, $read)
    } finally { $fs.Close() }
    return [pscustomobject]@{ Text = [System.Text.Encoding]::UTF8.GetString($buf); Length = $len; Read = $read }
  } catch { return $null }
}

# 读属性；字段不存在返回 $null —— 这样才能把"字段缺失"和"值为 0"区分开
function Get-JsonProp {
  param($Obj, [string]$Name)
  if ($null -eq $Obj) { return $null }
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

# 把一段 usage（单次请求）或聚合（turn_token_usage / thread_token_usage）规范化成
# 「命中 / 未命中 / 输出」三个数。
#   · input_tokens 缺失、cached_input_tokens 缺失、input <= 0 → 返回 $null（显示 "—"），
#     绝不把缺失当成 0%，否则会错显成 0% 命中率
#   · cached 做安全截断：负值归 0，超过 input 时按 input 计，保证命中率不超过 100%
function Convert-TokenAgg {
  param($Usage)
  if ($null -eq $Usage) { return $null }
  $inRaw = Get-JsonProp $Usage 'input_tokens'
  $cRaw = Get-JsonProp $Usage 'cached_input_tokens'
  if ($null -eq $inRaw -or $null -eq $cRaw) { return $null }
  $input = [double]$inRaw
  $cached = [double]$cRaw
  if ($input -le 0) { return $null }
  if ($cached -lt 0) { $cached = 0 }
  if ($cached -gt $input) { $cached = $input }
  $out = 0.0
  $reason = 0.0
  $oRaw = Get-JsonProp $Usage 'output_tokens'
  if ($null -ne $oRaw) { $out = [double]$oRaw }
  $rRaw = Get-JsonProp $Usage 'reasoning_output_tokens'
  if ($null -ne $rRaw) { $reason = [double]$rRaw }
  return [pscustomobject]@{
    input  = $input
    cached = $cached
    miss   = $input - $cached
    out    = $out
    reason = $reason
    rate   = 100.0 * $cached / $input
  }
}

# 倒着找最后一条 token_usage_record，只解析那一行（用来判断"哪个文件里有最新的一轮"）
function Get-LastUsageEvent {
  param([string]$Text)
  $lines = $Text -split "`n"
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    if (-not $lines[$i].Contains('"token_usage_record"')) { continue }
    try { return ($lines[$i].Trim() | ConvertFrom-Json) } catch { continue }
  }
  return $null
}

# Codex 正在写哪个会话？~/.codex/thread-writer-locks/<threadId>.lock 只在该会话
# 被写入期间存在（正在跑一轮），这是"当前正在使用的会话"的可靠信号，比"全局最新
# 时间戳"准。锁目录读不到时返回空数组，调用方会退回旧规则。
function Get-ActiveThreadIds {
  $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
  $lockDir = Join-Path $codexHome 'thread-writer-locks'
  $now = Get-Date
  if ((($now - $script:activeScanAt).TotalSeconds -lt 2)) { return $script:activeThreads }
  $ids = @()
  try {
    foreach ($f in (Get-ChildItem -LiteralPath $lockDir -Filter '*.lock' -File -ErrorAction SilentlyContinue)) {
      $name = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
      if ($name -and -not $name.StartsWith('.')) { $ids += $name }
    }
  } catch { }
  $script:activeThreads = $ids
  $script:activeScanAt = $now
  return $ids
}

function Get-RecentRolloutFiles {
  param([int]$Count = 6)
  $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
  $root = Join-Path $codexHome 'sessions'
  if (-not (Test-Path -LiteralPath $root)) { return @() }
  $now = Get-Date
  if ($script:turnFiles -and (($now - $script:turnScanAt).TotalSeconds -lt 8)) { return $script:turnFiles }
  $files = @(Get-ChildItem -LiteralPath $root -Recurse -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First $Count)
  $script:turnScanAt = $now
  $script:turnFiles = $files
  return $files
}

# 决定"最近一轮"取自哪个会话文件。
# 第一优先：Codex 正在写的那个会话（thread-writer-locks 里有锁的 thread id）。
# 拿不到锁（例如刚打开还没发消息、或锁目录不可读）时，退回"各文件最后一条 usage
# 记录的时间戳最新者"。这两条规则都是 Codex 自己写下来的事实，不做额外猜测。
function Resolve-TurnSource {
  $active = @(Get-ActiveThreadIds)
  $best = $null
  $bestActive = $null
  foreach ($f in (Get-RecentRolloutFiles -Count 6)) {
    $tail = Read-RolloutTail -Path $f.FullName -Bytes 131072
    if (-not $tail) { continue }
    $ev = Get-LastUsageEvent $tail.Text
    if (-not $ev) { continue }
    $threadId = [string](Get-JsonProp $ev.payload 'thread_id')
    if (-not $threadId) {
      # 文件名里也带 thread id：rollout-<时间>-<threadId>[_<fork>].jsonl
      $m = [regex]::Match($f.Name, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')
      if ($m.Success) { $threadId = $m.Groups[1].Value }
    }
    $cand = [pscustomobject]@{
      File   = $f.FullName
      Turn   = [string](Get-JsonProp $ev.payload 'turn_id')
      Thread = $threadId
      Ts     = [string]$ev.timestamp
      Length = $f.Length
      IsActive = [bool]($threadId -and ($active -contains $threadId))
    }
    if ($cand.IsActive -and ((-not $bestActive) -or $cand.Ts -gt $bestActive.Ts)) { $bestActive = $cand }
    if ((-not $best) -or $cand.Ts -gt $best.Ts) { $best = $cand }
  }
  if ($bestActive) { return $bestActive }
  return $best
}

function Get-LastTurn {
  $src = Resolve-TurnSource
  if (-not $src) { return $null }
  # 复用键带上"文件当前长度"：同一轮进行中日志一长就重算，不会冻结在第一次看到的值。
  # 长度必须现取一次：候选文件列表本身是缓存过的，FileInfo.Length 会是旧的。
  $lenNow = $src.Length
  try { $lenNow = (Get-Item -LiteralPath $src.File -ErrorAction Stop).Length } catch { }
  $stamp = "$($src.File)|$lenNow"
  if ($script:turnStamp -eq $stamp -and $script:turnCache) { return $script:turnCache }
  $script:turnStamp = $stamp
  $script:turnCache = $null

  # 只读尾部：一轮对话的记录总在文件末尾，避免全量解析大文件
  $tailBytes = 786432
  $tail = Read-RolloutTail -Path $src.File -Bytes $tailBytes
  if (-not $tail) { return $null }
  $len = $tail.Length
  $text = $tail.Text
  if (-not $text) { return $null }

  $lines = $text -split "`n"
  if ($lines.Count -gt 1 -and $len -gt $tailBytes) { $lines[0] = '' }  # 首行可能是半截

  $turnId = $src.Turn
  $records = @()
  $prevTurnId = $null
  $prevRecords = @()
  $turnAggRaw = $null
  $threadAggRaw = $null
  $prevAggRaw = $null
  $model = $null
  # 从尾部倒着扫：先取当前轮（最新一条记录的 turn_token_usage 就是本轮累计），
  # 越过边界后再取上一轮（用于"上一轮对话消耗"）。
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    $line = $lines[$i].Trim()
    if (-not $line) { continue }
    $isUsage = $line.Contains('"token_usage_record"')
    $isCtx = $line.Contains('"turn_context"')
    if (-not $isUsage -and -not $isCtx) { continue }
    $ev = $null
    try { $ev = $line | ConvertFrom-Json } catch { continue }   # 半条/坏行直接跳过

    if ($isCtx) {
      if (-not $model -and $ev.payload.model) { $model = [string]$ev.payload.model }
      continue
    }
    $tid = [string](Get-JsonProp $ev.payload 'turn_id')
    if (-not $prevTurnId -and $tid -ne $turnId) { $prevTurnId = $tid }   # 进入上一轮
    if ($prevTurnId -and $tid -ne $prevTurnId) { break }                 # 再往前是更早的轮次
    if (-not $prevTurnId) {
      if ($null -eq $turnAggRaw) { $turnAggRaw = Get-JsonProp $ev.payload 'turn_token_usage' }
      if ($null -eq $threadAggRaw) { $threadAggRaw = Get-JsonProp $ev.payload 'thread_token_usage' }
    } elseif ($null -eq $prevAggRaw) {
      $prevAggRaw = Get-JsonProp $ev.payload 'turn_token_usage'
    }
    $agg = Convert-TokenAgg (Get-JsonProp $ev.payload 'usage')
    if (-not $agg) { continue }
    $rec = [pscustomobject]@{ ts = [string]$ev.timestamp; agg = $agg }
    if ($prevTurnId) { $prevRecords += $rec } else { $records += $rec }
  }
  if (-not $turnId -or $records.Count -eq 0) { return $null }

  # 本轮：优先用 Codex 自己算好的 turn_token_usage；拿不到才退回"逐条求和"
  $srcKind = 'turn_token_usage'
  $cur = Convert-TokenAgg $turnAggRaw
  if (-not $cur) {
    $srcKind = 'sum(usage)'
    $h = 0.0; $m = 0.0; $o = 0.0
    foreach ($r in $records) { $h += $r.agg.cached; $m += $r.agg.miss; $o += $r.agg.out + $r.agg.reason }
    if (($h + $m) -gt 0) {
      $cur = [pscustomobject]@{ input = $h + $m; cached = $h; miss = $m; out = $o; reason = 0.0; rate = 100.0 * $h / ($h + $m) }
    }
  } else {
    $cur = [pscustomobject]@{ input = $cur.input; cached = $cur.cached; miss = $cur.miss; out = $cur.out; reason = $cur.reason; rate = $cur.rate }
  }

  $ts = $records[0].ts
  $when = Get-Date
  try { $when = [datetime]::Parse($ts).ToLocalTime() } catch { }
  $amount = 0.0
  if ($cur) { $amount = Get-Cost -Model $model -Hit $cur.cached -Miss $cur.miss -Out ($cur.out + $cur.reason) -When $when }

  # 上一轮的完整合计（用于"上一轮对话消耗"气泡）
  $prevAgg = $null
  $prevCur = Convert-TokenAgg $prevAggRaw
  if (-not $prevCur -and $prevRecords.Count -gt 0) {
    $ph = 0.0; $pm = 0.0; $po = 0.0
    foreach ($r in $prevRecords) { $ph += $r.agg.cached; $pm += $r.agg.miss; $po += $r.agg.out + $r.agg.reason }
    if (($ph + $pm) -gt 0) {
      $prevCur = [pscustomobject]@{ input = $ph + $pm; cached = $ph; miss = $pm; out = $po; reason = 0.0; rate = 100.0 * $ph / ($ph + $pm) }
    }
  }
  if ($prevCur) {
    $pts = if ($prevRecords.Count -gt 0) { $prevRecords[0].ts } else { $ts }
    $pwhen = Get-Date
    try { $pwhen = [datetime]::Parse($pts).ToLocalTime() } catch { }
    $prevAgg = [pscustomobject]@{
      turn   = $prevTurnId
      amount = Get-Cost -Model $model -Hit $prevCur.cached -Miss $prevCur.miss -Out ($prevCur.out + $prevCur.reason) -When $pwhen
      model  = $model
      hit    = $prevCur.cached; miss = $prevCur.miss; out = $prevCur.out + $prevCur.reason
      rate   = $prevCur.rate
      ts     = $pts
    }
  }

  $threadCur = Convert-TokenAgg $threadAggRaw

  $script:turnCache = [pscustomobject]@{
    turn      = $turnId
    thread    = $src.Thread
    isActive  = $src.IsActive
    source    = $srcKind
    model     = $model
    hit       = if ($cur) { $cur.cached } else { 0.0 }
    miss      = if ($cur) { $cur.miss } else { 0.0 }
    out       = if ($cur) { $cur.out + $cur.reason } else { 0.0 }
    rate      = if ($cur) { $cur.rate } else { $null }
    threadRate = if ($threadCur) { $threadCur.rate } else { $null }
    amount    = $amount
    ts        = $ts
    prev      = $prevAgg
  }
  return $script:turnCache
}

# 每轮统计：不论是否弹"每轮消耗"气泡，都刷新缓存命中率，因为气泡一直要显示它。
# 命中率缺失时置 $null（显示 "—"），不会退化成 0%。
function Update-TurnStats {
  $turn = Get-LastTurn
  if (-not $turn) { return $null }
  $script:cacheRate = $turn.rate
  $script:threadRate = $turn.threadRate
  # 轮次变化、或本轮命中率发生变化时记一条，方便核对"数值确实在跟着刷新"
  $tid = [string]$turn.turn
  $rateTxt = if ($null -eq $turn.rate) { '—' } else { [Math]::Round([double]$turn.rate, 1).ToString() }
  $threadTxt = if ($null -eq $turn.threadRate) { '—' } else { [Math]::Round([double]$turn.threadRate, 1).ToString() }
  $sig = "$tid|$rateTxt|$threadTxt|$($turn.source)|$($turn.isActive)"
  if ($tid -and $sig -ne $script:loggedTurn) {
    $script:loggedTurn = $sig
    $scope = if ($turn.isActive) { '当前会话' } else { '回退(无写入锁)' }
    Write-Log ("轮到 " + $tid.Substring(0, [Math]::Min(8, $tid.Length)) + "：本轮命中 " + $rateTxt +
               "%（本会话 " + $threadTxt + "%；cached=" + [long]$turn.hit + " miss=" + [long]$turn.miss +
               "；来源 " + $turn.source + "；" + $scope + "）")
  }
  return $turn
}

function Poll-TurnCost {
  $turn = Update-TurnStats
  if (-not $turn) { return }
  if (-not $script:cfg.turnCostOn) { return }
  $prev = $null
  if (Test-Path -LiteralPath $costFile) {
    try { $prev = Get-Content -LiteralPath $costFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  }
  if (-not $script:lastTurnSeen) {
    # 首次只对齐，不弹旧轮次
    $script:lastTurnSeen = $true
    $script:lastTurnSeq = if ($prev) { [int]$prev.seq } else { 0 }
    return
  }
  # 弹"上一轮对话消耗"要的是那一轮跑完之后的完整合计，而不是它刚开头那一次请求：
  # 一轮里往往还有几十次工具调用，只取第一条会把消耗和缓存命中率都算小。
  # 新的一轮开始了 ⇒ 上一轮已经结束，这时 $turn.prev 才是它的完整数据。
  $show = $turn.prev
  if (-not $show) { return }                                     # 还没有可报的上一轮
  if ($prev -and [string]$prev.turn -eq [string]$show.turn) { return }   # 这一轮已经报过

  $seq = $script:lastTurnSeq + 1
  $script:lastTurnSeq = $seq
  $payload = [pscustomobject]@{
    ok = $true; seq = $seq; turn = $show.turn
    amount = [Math]::Round($show.amount, 6); model = $show.model
    hit = $show.hit; miss = $show.miss; out = $show.out; ts = $show.ts
  }
  try {
    [System.IO.File]::WriteAllText($costFile, ($payload | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
  } catch { }

  if ($script:cfg.turnCostOn) {
    $script:costBubble = $true
    $script:costAmount = $show.amount
    # 直接用那一轮聚合出来的命中率（口径与主显示一致，不再各自算一遍）
    $script:costRate = $show.rate
    $script:costShownAt = Get-Date
  }
}

# ---------------------------------------------------------------------------
# 台词（沿用上游分组与权重）
# ---------------------------------------------------------------------------
function Get-RandomLines {
  $peak = Test-Peak
  $offText = '空闲时段'; $peakText = '高峰时段'
  if ($script:cfg.peakMode -eq 'liangwen') { $offText = '梁文谷'; $peakText = '梁文峰' }
  elseif ($script:cfg.peakMode -eq 'qiangqiang') { $offText = '!?谷谷?!'; $peakText = '!?峰峰?!' }

  $groups = @(
    @{ w = 45; f = {
        @(
          @{ t = '当前时间段为:'; s = 'A'; c = '' }
          @{ t = $(if ($peak) { $peakText } else { $offText }); s = 'P'; c = $(if ($peak) { $C_PEAK } else { $C_OFF }) }
          @{ t = '今日已用 ' + (Format-Money ($(if ($null -eq $script:todayUsage) { 0 } else { $script:todayUsage })) $script:currency); s = 'C'; c = '' }
        ) } }
    @{ w = 7;  f = { $t = (Get-Random -InputObject @('好模型... ↓', '好女孩...↓')); @($null, @{ t = $t; s = 'B'; c = '' }, $null) } }
    @{ w = 7;  f = { $t = (Get-Random -InputObject @('不知道用户有什么用，先赶走吧~', '我...我...我也要挣钱吗？', '我去吃饭啦，测完叫我', '压力一只蓝色大肥鱼？！', 'DeepSleep...', '坏了...用户彻底怒了！')); @($null, @{ t = $t; s = 'A'; c = ''; wrap = $true }, $null) } }
    @{ w = 10; f = { @{ gif = $true } } }
    @{ w = 3;  f = { $t = (Get-Random -InputObject @('你目录里的dsh是什么...大烧货吗...?', '恭喜你实现token自由！token全跑了！', '真当我是便宜货啊...')); @($null, @{ t = $t; s = 'A'; c = ''; wrap = $true }, $null) } }
    @{ w = 1;  f = { @($null, @{ t = '哦鲸鲸... '; s = 'B'; c = '' }, $null) } }
  )
  $total = 0; foreach ($g in $groups) { $total += $g.w }
  $r = (Get-Random -Minimum 0 -Maximum 100000) / 100000.0 * $total
  foreach ($g in $groups) {
    $r -= $g.w
    if ($r -lt 0) { return & $g.f }
  }
  return & $groups[$groups.Count - 1].f
}

# 缓存命中率文案。命中率 = 命中输入 token /（命中 + 未命中）输入 token，
# 取自最近一轮对话的真实 usage；还没读到会话记录时显示破折号。
function Get-CacheText {
  param([switch]$ForCost)
  $raw = if ($ForCost) { $script:costRate } else { $script:cacheRate }
  # 缺数据就显示 "—"，不要退化成 0%：0% 是"一条都没命中"的真实结果，两者不能混
  if ($null -eq $raw) {
    if ($ForCost) { return '命中 —' }
    return '本轮命中 —'
  }
  $r = [double]$raw
  # 长会话的缓存命中率天然会贴着 100%（整段上下文几乎都在前缀缓存里），
  # 四舍五入成 "100%" 会让人以为这个数字没在统计，所以 99% 以上保留一位小数。
  $txt = if ($r -ge 99) { '{0:N1}%' -f $r } else { '{0:N0}%' -f $r }
  if ($ForCost) { return ('命中 ' + $txt) }   # 这颗气泡讲的是"上一轮"，不再冠以"本轮"
  return ('本轮命中 ' + $txt)
}

function Get-NormalLines {
  if ($script:status -eq 'error') {
    $amt = if ($null -ne $script:shown) { Format-Money $script:shown $script:currency } else { '--' }
    $hint = if ($script:message) { $script:message } else { '获取失败 · 点击重试' }
  } elseif ($null -eq $script:balance) {
    $amt = if ($null -ne $script:shown) { Format-Money $script:shown $script:currency } else { '…' }
    $hint = '加载中…'
  } else {
    $amt = Format-Money $script:shown $script:currency
    $hint = '今日已用 ' + (Format-Money ($(if ($null -eq $script:todayUsage) { 0 } else { $script:todayUsage })) $script:currency)
  }
  return @(
    @{ t = 'DeepSeek 余额'; s = 'A'; c = '' }
    @{ t = $amt; s = 'B'; c = '' }
    @{ t = $hint; s = 'C'; c = '' }
    @{ t = (Get-CacheText); s = 'D'; c = '' }
  )
}

# ---------------------------------------------------------------------------
# 窗口：分层窗口 + 逐像素 alpha（圆形/透明立绘边缘才平滑）
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# 必须在创建任何控件之前设置，否则会抛 "cannot be changed once any Controls are created"
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

if (-not ('WhaleDpi' -as [type])) {
  Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public class WhaleDpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
'@
}
try { [void][WhaleDpi]::SetProcessDPIAware() } catch { }

$script:dpiScale = 1.0
try {
  $probe = [System.Drawing.Graphics]::FromHwnd([System.IntPtr]::Zero)
  if ($probe.DpiX -gt 0) { $script:dpiScale = $probe.DpiX / 96.0 }
  $probe.Dispose()
} catch { }
$script:dpiScale = 1.0   # 分层窗口按物理像素渲染，缩放交给 scale 设置自己控制

if (-not ('WhaleForm' -as [type])) {
  Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class WhaleForm : Form
{
    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)] private struct SIZE { public int cx; public int cy; }
    [StructLayout(LayoutKind.Sequential, Pack = 1)] private struct BLENDFUNCTION
    { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst,
        ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr hdc, IntPtr hObj);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr hObj);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const int ULW_ALPHA = 0x02;
    private const byte AC_SRC_OVER = 0x00;
    private const byte AC_SRC_ALPHA = 0x01;

    // 退出快捷键 Ctrl+Shift+Z
    private const int WM_HOTKEY = 0x0312;
    private const uint MOD_CONTROL = 0x0002;
    private const uint MOD_SHIFT = 0x0004;
    private const uint MOD_NOREPEAT = 0x4000;   // 按住不放也只触发一次
    private const uint VK_Z = 0x5A;
    private const int QUIT_HOTKEY_ID = 0x5A17;

    private bool _hotkeyOn = false;

    public bool QuitHotkeyRegistered { get { return _hotkeyOn; } }
    public event EventHandler QuitHotkeyPressed;

    // 注册成全局热键：挂件平时没有焦点，靠窗体 KeyDown 是收不到按键的。
    // 返回 false 代表这个组合已被别的程序占用，此时挂件照常运行，只是没有快捷键。
    public bool RegisterQuitHotkey(uint modifiers, uint vk)
    {
        if (_hotkeyOn) return true;
        _hotkeyOn = RegisterHotKey(Handle, QUIT_HOTKEY_ID,
            modifiers | MOD_NOREPEAT, vk);
        return _hotkeyOn;
    }

    public void UnregisterQuitHotkey()
    {
        if (!_hotkeyOn) return;
        UnregisterHotKey(Handle, QUIT_HOTKEY_ID);
        _hotkeyOn = false;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == QUIT_HOTKEY_ID)
        {
            EventHandler handler = QuitHotkeyPressed;
            if (handler != null) handler(this, EventArgs.Empty);
        }
        base.WndProc(ref m);
    }

    public WhaleForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        SetStyle(ControlStyles.Opaque | ControlStyles.UserPaint, true);
    }

    protected override CreateParams CreateParams
    {
        get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x00080000; return cp; }
    }

    // 透明区域不参与绘制；命中测试由分层窗口按 alpha 处理
    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e) { }

    private IntPtr _hBitmap = IntPtr.Zero;
    private int _w = 0;
    private int _h = 0;

    // 位图只在内容变化时转成 GDI 句柄缓存一次。Push 每帧都会调用，若每帧都
    // GetHbitmap（新建一块 w*h*4 的 DIB 再整块拷贝）动画就会明显发顿。
    public void SetSurface(Bitmap surface)
    {
        ReleaseSurface();
        if (surface == null) return;
        _hBitmap = surface.GetHbitmap(Color.FromArgb(0));
        _w = surface.Width;
        _h = surface.Height;
    }

    public void ReleaseSurface()
    {
        if (_hBitmap != IntPtr.Zero) { DeleteObject(_hBitmap); _hBitmap = IntPtr.Zero; }
        _w = 0;
        _h = 0;
    }

    public void Push(int opacity)
    {
        if (_hBitmap == IntPtr.Zero) return;
        IntPtr screenDc = GetDC(IntPtr.Zero);
        IntPtr memDc = CreateCompatibleDC(screenDc);
        IntPtr oldBitmap = IntPtr.Zero;
        try
        {
            oldBitmap = SelectObject(memDc, _hBitmap);
            SIZE size = new SIZE();
            size.cx = _w;
            size.cy = _h;
            POINT src = new POINT();
            POINT dst = new POINT();
            dst.x = Left;
            dst.y = Top;
            BLENDFUNCTION blend = new BLENDFUNCTION();
            blend.BlendOp = AC_SRC_OVER;
            blend.BlendFlags = 0;
            if (opacity < 0) opacity = 0;
            if (opacity > 255) opacity = 255;
            blend.SourceConstantAlpha = (byte)opacity;
            blend.AlphaFormat = AC_SRC_ALPHA;
            UpdateLayeredWindow(Handle, screenDc, ref dst, ref size, memDc, ref src, 0, ref blend, ULW_ALPHA);
        }
        finally
        {
            if (oldBitmap != IntPtr.Zero) SelectObject(memDc, oldBitmap);
            DeleteDC(memDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }
}
'@
}

$form = New-Object WhaleForm
$form.TopMost = $true
$form.Text = 'DeepSeek 余额小鲸鱼'
# 关键：默认的 AutoScaleMode.Font 会按 DPI 比例自动缩放窗口的 Size/Location，
# 在 150% 缩放下会把 375x375 变成 250x250、位置也一起除 1.5。这里必须关掉，
# 由我们自己的 scale 设置控制大小。
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None

# ---------------------------------------------------------------------------
# 素材
# ---------------------------------------------------------------------------
$whalePath = Join-Path $AssetDir 'DSniang1.png'
$gifPath = Join-Path $AssetDir 'rua.gif'
$soundSets = @{ duck = @{ press = 'Ya1.mp3'; release = 'Ya2.mp3' }; fx1 = @{ press = 'D1.mp3'; release = 'D2.mp3' } }

$script:whaleImg = $null
if (Test-Path -LiteralPath $whalePath) {
  try { $script:whaleImg = [System.Drawing.Image]::FromFile($whalePath) } catch { Write-Log "立绘加载失败: $($_.Exception.Message)" }
}
$script:gifImg = $null
if (Test-Path -LiteralPath $gifPath) {
  try {
    $script:gifImg = [System.Drawing.Image]::FromFile($gifPath)
    $script:gifFrame = 0
    # 不要用 ImageAnimator.Animate：它会在后台线程回调 PowerShell 脚本块，
    # 跨线程调用脚本块会让进程直接崩掉（0xe0434352）。改成在 UI 线程按帧号切换。
    $script:gifDim = New-Object System.Drawing.Imaging.FrameDimension ([System.Drawing.Imaging.FrameDimension]::Time.Guid)
  } catch { $script:gifImg = $null }
}

# 音效：MediaPlayer 支持 mp3
$script:players = @{}
try {
  Add-Type -AssemblyName PresentationCore
  foreach ($set in $soundSets.Keys) {
    foreach ($kind in @('press', 'release')) {
      $file = Join-Path $AssetDir $soundSets[$set][$kind]
      if (Test-Path -LiteralPath $file) {
        $player = New-Object System.Windows.Media.MediaPlayer
        $player.Open([System.Uri]$file)
        $player.Volume = [double]$script:cfg.vol
        $script:players["$set/$kind"] = $player
      }
    }
  }
} catch { Write-Log "音效不可用: $($_.Exception.Message)" }

function Play-Sound {
  param([string]$Kind)
  if (-not $script:cfg.sound) { return }
  if ([double]$script:cfg.vol -le 0) { return }
  $key = "$($script:cfg.soundSet)/$Kind"
  $p = $script:players[$key]
  if (-not $p) { return }
  try { $p.Stop(); $p.Position = [TimeSpan]::Zero; $p.Volume = [double]$script:cfg.vol; $p.Play() } catch { }
}

# ---------------------------------------------------------------------------
# 视觉状态
# ---------------------------------------------------------------------------
$script:bounceX = 1.0
$script:bounceY = 1.0
$script:flip = 1          # -1 表示左吸附镜像
$script:flipAnim = 1.0
$script:alpha = 255
$script:bubbleOpen = $false
$script:bubbleRandom = $null
$script:bubbleAt = $null
$script:baseSize = 375
$script:animating = $false
$script:animStart = $null
$script:animFrom = 0.0
$script:animTo = 0.0
$script:snapFrom = $null
$script:snapTo = $null
$script:pressed = $false

function Get-BaseSize {
  $vp = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $short = [Math]::Min($vp.Width, $vp.Height)
  $raw = [Math]::Min(250, $short * 0.28) * [double]$script:cfg.scale
  return [int][Math]::Max(122, [Math]::Min(625, $raw))
}

function Get-TextLines {
  if ($script:costBubble) {
    return @(
      @{ t = '上一轮对话消耗:'; s = 'A'; c = '' }
      @{ t = (Format-Money $script:costAmount $script:currency); s = 'B'; c = $C_PEAK }
      @{ t = (Get-CacheText -ForCost); s = 'D'; c = '' }
    )
  }
  if ($script:bubbleRandom) {
    if ($script:bubbleRandom.gif) { return @{ gif = $true } }
    return $script:bubbleRandom
  }
  return Get-NormalLines
}

function New-BubblePath {
  param([double]$U)
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.AddEllipse([float](81 * $U), [float](15 * $U), [float](746 * $U), [float](464 * $U))
  $p.StartFigure()
  $p.AddBezier(
    [float](301 * $U), [float](465 * $U),
    [float](322 * $U), [float](507 * $U),
    [float](392 * $U), [float](516 * $U),
    [float](413 * $U), [float](484 * $U))
  $p.CloseFigure()
  $p.AddEllipse([float](314.5 * $U), [float](535 * $U), [float](75 * $U), [float](52 * $U))
  $p.AddEllipse([float](417.5 * $U), [float](628 * $U), [float](49 * $U), [float](36 * $U))
  return $p
}

function New-LineFont {
  param([string]$Style, [double]$U)
  $size = switch ($Style) { 'B' { 128 } 'P' { 104 } 'A' { 66 } 'D' { 48 } default { 56 } }
  $px = [float]([Math]::Max(7.0, $size * $U))
  $style2 = if ($Style -eq 'C' -or $Style -eq 'D') { [System.Drawing.FontStyle]::Regular } else { [System.Drawing.FontStyle]::Bold }
  return New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei UI', $px, $style2, ([System.Drawing.GraphicsUnit]::Pixel)
}

# ---------------------------------------------------------------------------
# 渲染缓存
#   动画期间每 16ms 就要重画一帧。真正贵的几件事改成"参数变了才做一次"：
#     · 立绘缩放（1026px 的 PNG 双三次缩到目标尺寸）
#     · 气泡 GraphicsPath、字体对象、MeasureString
#     · 立绘 + 气泡这一层（翻转 / Q 弹 / 数字滚动时它都不变）
#   这样每帧只剩：清空复用缓冲 → 贴一层仿射变换后的内容 → 画三行字 → 推送。
# ---------------------------------------------------------------------------
$script:rc = @{
  whaleSize = -1          # 立绘缓存对应的挂件尺寸
  whale     = $null       # 预缩放好的立绘
  layer     = $null       # 立绘 + 气泡（未翻转态）
  layerKey  = $null
  surface   = $null       # 复用的输出缓冲，避免每帧新建位图
  surfaceB  = -1
  path      = $null       # 气泡路径（只跟 u 有关）
  pathKey   = $null
  fonts     = @{}         # 字体按 "风格|u" 复用
  measures  = @{}         # MeasureString 结果按 "风格|文本|u|wrap" 复用
}

function Get-WhaleScaled {
  param([int]$B)
  if ($script:rc.whale -and $script:rc.whaleSize -eq $B) { return $script:rc.whale }
  if (-not $script:whaleImg) { return $null }
  $side = [int][Math]::Max(1, [Math]::Round($B * $WHALE_RATIO))
  $bmp = New-Object System.Drawing.Bitmap($side, $side, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  $g.DrawImage($script:whaleImg, 0, 0, $side, $side)
  $g.Dispose()
  if ($script:rc.whale) { $script:rc.whale.Dispose() }
  $script:rc.whale = $bmp
  $script:rc.whaleSize = $B
  return $bmp
}

function Get-BubblePathCached {
  param([double]$U)
  $key = [string][Math]::Round($U, 6)
  if ($script:rc.path -and $script:rc.pathKey -eq $key) { return $script:rc.path }
  if ($script:rc.path) { $script:rc.path.Dispose() }
  $script:rc.path = New-BubblePath -U $U
  $script:rc.pathKey = $key
  return $script:rc.path
}

function Get-LineFontCached {
  param([string]$Style, [double]$U)
  $key = "$Style|$([Math]::Round($U, 6))"
  if (-not $script:rc.fonts.ContainsKey($key)) {
    $script:rc.fonts[$key] = New-LineFont -Style $Style -U $U
  }
  return $script:rc.fonts[$key]
}

# 立绘 + 气泡合成一层（未翻转、未 Q 弹）。翻转与弹跳都只是对这一层做仿射变换，
# 不需要重画内容；余额数字滚动期间这一层同样完全不变 —— 这是流畅度的关键。
function Get-ContentLayer {
  param([int]$B, [double]$U)
  $key = "$B|$($script:bubbleOpen)|$([Math]::Round($U, 6))"
  if ($script:rc.layer -and $script:rc.layerKey -eq $key) { return $script:rc.layer }
  $bmp = New-Object System.Drawing.Bitmap($B, $B, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)

  $whale = Get-WhaleScaled -B $B
  if ($whale) {
    $side = [float]$whale.Width
    $g.DrawImage($whale, [float]($B - $side), [float]($B - $side), $side, $side)
  }

  if ($script:bubbleOpen) {
    $path = Get-BubblePathCached -U $U
    $pen = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.ColorTranslator]::FromHtml($C_STROKE)), ([float](18 * $U))
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $g.DrawPath($pen, $path)      # 先描边
    $g.FillPath($white, $path)    # 再填充 → 只留下并集外侧的轮廓线
    $white.Dispose(); $pen.Dispose()
  }

  $g.Dispose()

  if ($script:rc.layer) { $script:rc.layer.Dispose() }
  $script:rc.layer = $bmp
  $script:rc.layerKey = $key
  return $bmp
}

function New-Surface {
  $b = [int]$script:baseSize
  $u = $b / 1026.0

  # 复用输出缓冲：每帧新建一块 375×375 Format32bppPArgb 会产生持续的 GC 压力
  if (-not $script:rc.surface -or $script:rc.surfaceB -ne $b) {
    if ($script:rc.surface) { $script:rc.surface.Dispose() }
    $script:rc.surface = New-Object System.Drawing.Bitmap($b, $b, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $script:rc.surfaceB = $b
  }
  $bmp = $script:rc.surface
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $g.Clear([System.Drawing.Color]::Transparent)

  # 按压 Q 弹：绕底边中心缩放
  $g.TranslateTransform([float]($b / 2.0), [float]$b)
  $g.ScaleTransform([float]$script:bounceX, [float]$script:bounceY)
  $g.TranslateTransform([float](-$b / 2.0), [float](-$b))

  # ---- 立绘 + 气泡：整层仿射变换，不重画内容 ----
  $layer = Get-ContentLayer -B $b -U $u
  $state = $g.Save()
  if ([Math]::Abs($script:flipAnim - 1.0) -gt 0.001) {
    $g.TranslateTransform([float]($b / 2.0), 0)
    $g.ScaleTransform([float]$script:flipAnim, 1)
    $g.TranslateTransform([float](-$b / 2.0), 0)
  }
  $g.DrawImage($layer, 0, 0, $b, $b)
  $g.Restore($state)

  # ---- 文字：不翻转，位置按镜像后的坐标放 ----
  if ($script:bubbleOpen) {
    $lines = Get-TextLines
    # 注意：原版里 .dshwv-text / .dshwv-gif 是绝对定位在 .dshwv-bubble 内的，
    # 所以 left/top 的百分比是相对气泡元素——气泡宽 = 挂件宽，高 = 宽 × 700/1026。
    # 纵向百分比要用气泡高度算，用挂件高度会把文字压低约 1.46 倍。
    $bubbleH = $b * $WIDGET_H / $WIDGET_W
    $cx = if ($script:flipAnim -lt 0) { (1 - $TEXT_X) * $b } else { $TEXT_X * $b }
    $cy = $TEXT_Y * $bubbleH

    if ($lines -and -not $lines.gif) {
      $fmt = New-Object System.Drawing.StringFormat
      $fmt.Alignment = [System.Drawing.StringAlignment]::Center
      $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
      $fmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoClip

      $measured = @()
      $total = 0.0
      foreach ($ln in $lines) {
        if (-not $ln) { $measured += $null; continue }
        $font = Get-LineFontCached -Style $ln.s -U $u
        $maxW = if ($ln.wrap) { [float](560 * $u) } else { [float](1200 * $u) }
        # 测量结果按"风格|文本|u|wrap"缓存：数字滚动时每帧都要量，缓存后几乎免费
        $mKey = "$($ln.s)|$($ln.t)|$([Math]::Round($u, 6))|$($ln.wrap)"
        if ($script:rc.measures.ContainsKey($mKey)) {
          $sz = $script:rc.measures[$mKey]
        } else {
          if ($script:rc.measures.Count -gt 600) { $script:rc.measures.Clear() }
          $sz = $g.MeasureString($ln.t, $font, [int]$maxW)
          $script:rc.measures[$mKey] = $sz
        }
        # 行高按原版 CSS 的 line-height 取，而不是 MeasureString 的宽松高度，
        # 否则三行之间会多出一截空白，和原设计不一致。
        $lineH = switch ($ln.s) {
          'B' { 128 * $u * 1.05 }
          'P' { 104 * $u * 1.05 }
          'A' { 66 * $u * 1.15 }
          'D' { 48 * $u * 1.15 + 9 * $u }
          default { 56 * $u * 1.15 + 9 * $u }
        }
        if ($ln.wrap) { $lineH = [double]$sz.Height }
        $measured += [pscustomobject]@{ font = $font; text = $ln.t; size = $sz; height = $lineH; color = $ln.c; wrap = $ln.wrap }
        $total += $lineH
      }

      $y = $cy - $total / 2
      foreach ($m in $measured) {
        if (-not $m) { continue }
        $col = if ($m.color) { $m.color } elseif ($m.font.Size -le 60 * $u) { $C_HINT } else { $C_TEXT }
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($col))
        $w = if ($m.wrap) { [float](560 * $u) } else { [float]$m.size.Width }
        $rect = New-Object System.Drawing.RectangleF ([float]($cx - $w / 2)), ([float]$y), $w, ([float]$m.height)
        if ($m.wrap) { $g.DrawString($m.text, $m.font, $brush, $rect, $fmt) }
        else { $g.DrawString($m.text, $m.font, $brush, [float]$cx, [float]($y + $m.height / 2), $fmt) }
        $brush.Dispose()     # 字体是缓存对象，这里不能 Dispose
        $y += $m.height      # 关键：推进到下一行，否则三行会叠在一起
      }
      $fmt.Dispose()
    }

    # gif 台词：居中绘制动图
    if ($lines -and $lines.gif -and $script:gifImg) {
      $maxW = [float](560 * $u)
      $maxH = [float](400 * $u)
      $iw = [double]$script:gifImg.Width
      $ih = [double]$script:gifImg.Height
      $ratio = [Math]::Min($maxW / $iw, $maxH / $ih)
      $dw = [float]($iw * $ratio); $dh = [float]($ih * $ratio)
      $dest = New-Object System.Drawing.Rectangle ([int]($cx - $dw / 2)), ([int]($cy - $dh / 2)), ([int]$dw), ([int]$dh)
      try {
        $dim = $script:gifDim
        if ($dim) {
          $count = $script:gifImg.GetFrameCount($dim)
          if ($count -gt 1) { $script:gifImg.SelectActiveFrame($dim, ($script:gifFrame % $count)) | Out-Null }
        }
        $g.DrawImage($script:gifImg, $dest, 0, 0, [int]$iw, [int]$ih, [System.Drawing.GraphicsUnit]::Pixel)
      } catch { }
    }
  }

  $g.Dispose()
  return $bmp
}

function Update-Surface {
  try {
    $bmp = New-Surface               # 复用内部缓冲，这里不要 Dispose
    $form.SetSurface($bmp)           # 转成缓存的 GDI 句柄，Push 时不再重建
    $form.Push([int]$script:alpha)
  } catch {
    Write-Log ("渲染失败: " + $_.Exception.Message + " @ " + $_.InvocationInfo.ScriptLineNumber)
  }
}

# ---------------------------------------------------------------------------
# 位置 / 吸附 / 翻转 / 动画
# ---------------------------------------------------------------------------
$script:dragging = $false
$script:dragOrigin = $null
$script:snapStart = $null
$script:snapFrom = $null
$script:snapTo = $null
$script:bounceStart = $null
$script:bounceTargetX = 1.0
$script:bounceTargetY = 1.0
$script:flipStart = $null
$script:flipTarget = 1.0

function Start-Bounce {
  param([double]$X, [double]$Y)
  $script:bounceTargetX = $X; $script:bounceTargetY = $Y
  $script:bounceStart = Get-Date
  $script:animTimer.Start()
}

function Start-Snap {
  param([int]$X, [int]$Y)
  $script:snapFrom = [pscustomobject]@{ x = $form.Left; y = $form.Top }
  $script:snapTo = [pscustomobject]@{ x = $X; y = $Y }
  $script:snapStart = Get-Date
  $script:animTimer.Start()
}

function Set-Flip {
  param([bool]$Flipped)
  $target = if ($Flipped) { -1.0 } else { 1.0 }
  if ([Math]::Abs($script:flipTarget - $target) -lt 0.001) { return }
  $script:flipTarget = $target
  $script:flipStart = Get-Date
  $script:animTimer.Start()
}

function Set-Anim {
  param([double]$From, [double]$To)
  $script:animFrom = $From; $script:animTo = $To; $script:animStart = Get-Date
  $script:animTimer.Start()
}

function Settle {
  $vp = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $b = $script:baseSize
  $cx = $form.Left + $b / 2
  $cy = $form.Top + $b / 2
  $h = ''; $v = ''
  if ($cx -lt $vp.Width / 4) { $h = 'left' } elseif ($cx -gt $vp.Width * 3 / 4) { $h = 'right' }
  if ($cy -lt $vp.Height / 4) { $v = 'top' } elseif ($cy -gt $vp.Height * 3 / 4) { $v = 'bottom' }

  $x = [Math]::Max($vp.X, [Math]::Min($vp.Right - $b, $form.Left))
  $y = [Math]::Max($vp.Y, [Math]::Min($vp.Bottom - $b, $form.Top))
  if ($h -eq 'left') { $x = $vp.X } elseif ($h -eq 'right') { $x = $vp.Right - $b }
  if ($v -eq 'top') { $y = $vp.Y } elseif ($v -eq 'bottom') { $y = $vp.Bottom - $b }

  Set-Flip ($h -eq 'left')
  Start-Snap $x $y
  $script:cfg.x = $x; $script:cfg.y = $y
  Save-Config
}

function Move-Default {
  $vp = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $b = $script:baseSize
  $script:cfg.x = $vp.Right - $b
  $script:cfg.y = $vp.Bottom - $b
  Save-Config
}

# ---------------------------------------------------------------------------
# 气泡
# ---------------------------------------------------------------------------
function Show-Bubble {
  if (-not $script:cfg.bubbleOn) { return }
  if ($script:costBubble) { return }
  if ($script:bubbleOpen) { return }
  $script:bubbleOpen = $true
  $script:bubbleAt = Get-Date
  $script:bubbleRandom = $null
  Update-Surface
}

function Hide-Bubble {
  $script:bubbleOpen = $false
  $script:bubbleRandom = $null
  $script:costBubble = $false
  $script:bubbleAt = $null
  $script:costShownAt = $null
  if ($script:gifTimer) { $script:gifTimer.Stop() }
  Update-Surface
}

function On-WhaleClick {
  Write-Log "点击: bubbleOpen=$($script:bubbleOpen) random=$([bool]$script:bubbleRandom) cost=$($script:costBubble)"
  if ($script:costBubble) { Hide-Bubble; return }
  if ($script:bubbleOpen -and $script:bubbleRandom) { Hide-Bubble; return }
  if ($script:bubbleOpen) {
    $script:bubbleRandom = Get-RandomLines
    # gif 台词才需要按帧重绘；其余台词让 gifTimer 停着，省掉每秒 8 次空转
    if ($script:bubbleRandom -and $script:bubbleRandom.gif) { if ($script:gifTimer) { $script:gifTimer.Start() } }
    Update-Surface
    return
  }
  Show-Bubble
  Refresh-Balance -Manual | Out-Null
}


# ---------------------------------------------------------------------------
# 鼠标交互
# ---------------------------------------------------------------------------
# 右键打开 DeepSeek 用量监控面板。
# 这里只负责“面板服务本身”，不碰悬浮球那条链 —— 球和鲸鱼是两套独立的东西，
# 想看网页不该顺带把球放出来。
$usageUri = $null
try { $usageUri = [System.Uri]$UsagePanelUrl } catch { }
$script:usageHost = if ($usageUri) { $usageUri.Host } else { '127.0.0.1' }
$script:usagePort = if ($usageUri -and $usageUri.Port -gt 0) { $usageUri.Port } else { 8788 }
$usagePluginDir = Join-Path $env:USERPROFILE 'plugins\deepseek-usage-monitor'
$usageDashboard = Join-Path $usagePluginDir 'scripts\dashboard.mjs'
$usageVbs = Join-Path $DataDir 'start-usage-panel.vbs'
$script:pendingOpenAt = $null
$script:pendingOpenDeadline = $null

function Resolve-NodePath {
  $c = (Get-Command node -ErrorAction SilentlyContinue).Source
  if ($c) { return $c }
  foreach ($p in @("$env:ProgramFiles\nodejs\node.exe",
                   "${env:ProgramFiles(x86)}\nodejs\node.exe",
                   "$env:LOCALAPPDATA\Programs\nodejs\node.exe")) {
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}

function Test-UsagePanelUp {
  param([int]$TimeoutMs = 250)
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect($script:usageHost, $script:usagePort, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
    $client.EndConnect($iar)
    return $true
  } catch {
    return $false
  } finally {
    try { $client.Close() } catch { }
  }
}

# 启动面板服务本身（只启动面板，不动悬浮球）。
# node 是控制台程序，用 Win32_Process.Create 直接创建会在桌面上留下一个标题为
# node.exe 路径的黑窗口；所以改用 wscript + VBS 的 window style 0 启动，
# 控制台窗口从创建起就是隐藏的，浏览面板时桌面上不会多出这个窗口。
function Start-UsagePanelService {
  $node = Resolve-NodePath
  if (-not $node) { Write-Log '找不到 node.exe，无法启动面板服务'; return $false }
  if (-not (Test-Path -LiteralPath $usageDashboard)) { Write-Log "找不到面板脚本 $usageDashboard"; return $false }
  $cmdline = '"{0}" "{1}" --port {2} --no-open' -f $node, $usageDashboard, $script:usagePort
  $line = 'CreateObject("WScript.Shell").Run "' + ($cmdline -replace '"', '""') + '", 0, False'
  try {
    [System.IO.File]::WriteAllText($usageVbs, $line, (New-Object System.Text.UTF8Encoding($false)))
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "wscript.exe //nologo `"$usageVbs`"" }
    if ($r.ReturnValue -ne 0) { Write-Log "启动面板服务失败：wscript 返回 $($r.ReturnValue)"; return $false }
    return $true
  } catch {
    Write-Log ('启动面板服务异常: ' + $_.Exception.Message)
    return $false
  }
}

function Open-UsagePanel {
  try {
    # 面板已经在跑：直接开浏览器，什么都不启动
    if (Test-UsagePanelUp) { Start-Process $UsagePanelUrl | Out-Null; return }
    if ($script:pendingOpenAt) { return }          # 已经在等面板起来，别重复触发
    if (-not (Start-UsagePanelService)) { Start-Process $UsagePanelUrl | Out-Null; return }
    # 面板起得来要一两秒，先在定时器里等它就绪再开浏览器，
    # 免得先弹出一个打不开的页面；这段时间界面不阻塞。
    $script:pendingOpenAt = Get-Date
    $script:pendingOpenDeadline = (Get-Date).AddSeconds(8)
    Write-Log '面板未运行，已在后台启动面板服务（不涉及悬浮球）'
  } catch {
    Write-Log ("打开用量面板失败: " + $_.Exception.Message)
    try { Start-Process $UsagePanelUrl | Out-Null } catch { }
  }
}

$form.Add_MouseDown({
  param($sender, $e)
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { Open-UsagePanel; return }
  if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
  $script:dragging = $false
  $script:dragOrigin = $e.Location
  Start-Bounce -X 1.05 -Y 0.88
  Play-Sound 'press'
})

$form.Add_MouseMove({
  param($sender, $e)
  if ($null -eq $script:dragOrigin) { return }
  if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
  $dx = $e.X - $script:dragOrigin.X
  $dy = $e.Y - $script:dragOrigin.Y
  if (($dx * $dx + $dy * $dy) -ge $CLICK_SQ) { $script:dragging = $true }
  if ($script:dragging) {
    $form.Location = New-Object System.Drawing.Point(($form.Left + $dx), ($form.Top + $dy))
  }
})

$form.Add_MouseUp({
  param($sender, $e)
  if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
  if ($null -eq $script:dragOrigin) { return }
  $wasDragging = $script:dragging
  $script:dragOrigin = $null
  Start-Bounce -X 1.0 -Y 1.0
  Play-Sound 'release'
  if ($wasDragging) { Settle } else { On-WhaleClick }
})

$form.Add_MouseWheel({ if ($script:bubbleOpen) { Hide-Bubble } })

# ---------------------------------------------------------------------------
# 定时器
# ---------------------------------------------------------------------------
function Start-Animation {
  param([System.Windows.Forms.Timer]$Timer)
  if (-not $Timer.Enabled) { $Timer.Start() }
}

$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 16
$animTimer.add_Tick({
  $now = Get-Date
  $busy = $false
  $redraw = $false

  if ($script:animStart) {
    $t = ($now - $script:animStart).TotalMilliseconds / $ANIM_MS
    if ($t -ge 1) { $script:shown = $script:animTo; $script:animStart = $null; $redraw = $true }
    else {
      $e = 1 - [Math]::Pow(1 - $t, 3)
      $script:shown = $script:animFrom + ($script:animTo - $script:animFrom) * $e
      $busy = $true; $redraw = $true
    }
  }

  if ($script:bounceStart) {
    $t = ($now - $script:bounceStart).TotalMilliseconds / 220
    if ($t -ge 1) { $script:bounceX = $script:bounceTargetX; $script:bounceY = $script:bounceTargetY; $script:bounceStart = $null }
    else {
      # 0.22s cubic-bezier(.34,1.56,.64,1) 近似
      $e = if ($t -lt 0.5) { 2 * $t * $t * (3 - 2 * $t) * 1.06 } else { 1 - [Math]::Pow(2 - 2 * $t, 3) / 2 }
      if ($e -gt 1.12) { $e = 1.12 }
      $fromX = if ($script:bounceTargetX -gt 1) { 1.0 } else { 1.05 }
      $fromY = if ($script:bounceTargetY -lt 1) { 1.0 } else { 0.88 }
      $script:bounceX = $fromX + ($script:bounceTargetX - $fromX) * $e
      $script:bounceY = $fromY + ($script:bounceTargetY - $fromY) * $e
      $busy = $true
    }
    $redraw = $true
  }

  if ($script:flipStart) {
    $t = ($now - $script:flipStart).TotalMilliseconds / 300
    if ($t -ge 1) { $script:flipAnim = $script:flipTarget; $script:flipStart = $null }
    else {
      $from = if ($script:flipTarget -lt 0) { 1.0 } else { -1.0 }
      $script:flipAnim = $from + ($script:flipTarget - $from) * $t
      $busy = $true
    }
    $redraw = $true
  }

  if ($script:snapStart) {
    $t = ($now - $script:snapStart).TotalMilliseconds / 160
    if ($t -ge 1) { $form.Location = New-Object System.Drawing.Point($script:snapTo.x, $script:snapTo.y); $script:snapStart = $null }
    else {
      $e = 1 - [Math]::Pow(1 - $t, 3)
      $x = [int]($script:snapFrom.x + ($script:snapTo.x - $script:snapFrom.x) * $e)
      $y = [int]($script:snapFrom.y + ($script:snapTo.y - $script:snapFrom.y) * $e)
      $form.Location = New-Object System.Drawing.Point($x, $y)
      $busy = $true
    }
  }

  if ($redraw) { Update-Surface }
  if (-not $busy) { $animTimer.Stop() }   # 收尾帧上面已经画过了，不必再来一次
})

$mainTimer = New-Object System.Windows.Forms.Timer
$mainTimer.Interval = 500
$mainTimer.add_Tick({
  $now = Get-Date
  [void](Complete-BalanceFetch)      # 后台取数回来了，在这里落到界面上
  # 右键点开面板时，如果服务是刚拉起来的，等它就绪再开浏览器（不阻塞界面）
  if ($script:pendingOpenAt) {
    if ((Test-UsagePanelUp -TimeoutMs 60) -or ($now -gt $script:pendingOpenDeadline)) {
      $script:pendingOpenAt = $null
      $script:pendingOpenDeadline = $null
      try { Start-Process $UsagePanelUrl | Out-Null } catch { }
    }
  }
  if ($script:bubbleOpen -and $script:bubbleAt) {
    if (($now - $script:bubbleAt).TotalMilliseconds -ge $BUBBLE_MS) { Hide-Bubble }
  }
  if ($script:costBubble -and $script:costShownAt) {
    $sec = [double]$script:cfg.turnCostCloseSec
    if ($sec -gt 0 -and ($now - $script:costShownAt).TotalMilliseconds -ge $sec * 1000) { Hide-Bubble }
  }
  # 按"上次发起请求的时间"节流：即使失败也等满一轮再重试，不会退化成刷接口
  if ($script:lastBalanceRequestAt -ne [datetime]::MinValue -and
      ($now - $script:lastBalanceRequestAt).TotalMilliseconds -ge $REFRESH_MS) {
    Refresh-Balance | Out-Null
  }
})

$turnTimer = New-Object System.Windows.Forms.Timer
$turnTimer.Interval = $TURN_POLL_MS
$turnTimer.add_Tick({
  try { Poll-TurnCost } catch { }
  if ($script:costBubble) { Update-Surface }
})

# gif 帧推进：只在 gif 台词显示期间才启动，平时完全停着（不再每 120ms 空转一次）
$gifTimer = New-Object System.Windows.Forms.Timer
$gifTimer.Interval = 120
$gifTimer.add_Tick({
  if (-not $script:gifImg -or -not $script:bubbleOpen) { return }
  if (-not ($script:bubbleRandom -and $script:bubbleRandom.gif)) { $gifTimer.Stop(); return }
  $script:gifFrame = $script:gifFrame + 1
  Update-Surface
})

# 停止信号：跟随脚本写 <DataDir>\whale-stop，这里 300ms 检查一次。
# 走 $form.Close() 而不是被强杀，位置/配置才会被正常保存。
$stopTimer = New-Object System.Windows.Forms.Timer
$stopTimer.Interval = 300
$stopTimer.add_Tick({
  if ($script:closing) { return }
  if (Test-Path -LiteralPath $stopFile) { $script:closing = $true; $form.Close() }
})
$stopTimer.Start()

# 跟随 Codex 启停：始终盯着 Codex 进程（不再依赖启动参数，否则从快捷方式启动的挂件
# 永远收不掉）。判定规则只用进程存在性，和"有没有请求"无关，所以 Codex 空闲时不会被误判：
#   · 见过 Codex 运行 → 之后连续 3 次（约 12 秒）找不到就优雅收起
#   · 从没见过 Codex（用户在 Codex 没开时手动放出）→ 保持运行，不误杀
# 不需要注册任何开机自启：开机时 Codex 没开，挂件也就不会出现；
# Codex 打开时会由插件的 MCP 服务把它放出来。
$CODEX_POLL_MS = 4000
$CODEX_MISS_LIMIT = 3      # 连续 3 次（约 12 秒）都找不到 Codex 才收，避免误判
$script:codexMiss = 0
$script:codexSeen = $false # 是否见过 Codex 在跑（区分"手动独立启动"与"Codex 退出"）

function Get-CodexStartTime {
  $procs = Get-Process -Name $CodexProcessName -ErrorAction SilentlyContinue
  if (-not $procs) { return $null }
  $earliest = $null
  foreach ($p in $procs) {
    try {
      if ($p.Path -like $CodexPathFilter) {
        $t = $p.StartTime
        if ($null -eq $earliest -or $t -lt $earliest) { $earliest = $t }
      }
    } catch { }
  }
  return $earliest
}

function Test-CodexRunning {
  return ($null -ne (Get-CodexStartTime))
}

$codexTimer = New-Object System.Windows.Forms.Timer
$codexTimer.Interval = $CODEX_POLL_MS
$codexTimer.add_Tick({
  if ($script:closing) { return }
  if (Test-CodexRunning) { $script:codexSeen = $true; $script:codexMiss = 0; return }
  if (-not $script:codexSeen) { return }   # 从来没见 Codex 跑过：独立启动，别收
  $script:codexMiss++
  if ($script:codexMiss -ge $CODEX_MISS_LIMIT) {
    Write-Log "Codex 已退出（连续 $($script:codexMiss) 次检测不到），自动收起挂件"
    $script:closing = $true
    $form.Close()
  }
})
# followCodex=false = 完全手动模式：既不随 Codex 自动放出，也不会在 Codex 退出时被收掉
if ($script:cfg.followCodex) { $codexTimer.Start() }
else { Write-Log 'followCodex=false：不跟随 Codex 启停（手动模式）' }

# ---------------------------------------------------------------------------
# 启动
# ---------------------------------------------------------------------------
# 清掉上次残留的停止信号（否则一起来就自己关掉）
try { if (Test-Path -LiteralPath $stopFile) { [System.IO.File]::Delete($stopFile) } } catch { }
$script:closing = $false

$script:baseSize = Get-BaseSize
$form.Size = New-Object System.Drawing.Size($script:baseSize, $script:baseSize)

$vp = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$startX = if ($null -ne $script:cfg.x) { [int]$script:cfg.x } else { $vp.Right - $script:baseSize }
$startY = if ($null -ne $script:cfg.y) { [int]$script:cfg.y } else { $vp.Bottom - $script:baseSize }
$startX = [Math]::Max($vp.X, [Math]::Min($vp.Right - $script:baseSize, $startX))
$startY = [Math]::Max($vp.Y, [Math]::Min($vp.Bottom - $script:baseSize, $startY))
$form.Location = New-Object System.Drawing.Point($startX, $startY)
if ($startX -le $vp.X + 2) { $script:flip = -1; $script:flipAnim = -1.0; $script:flipTarget = -1.0 }

$form.Add_Shown({
  Write-Log "挂件启动 size=$($script:baseSize) scale=$($script:cfg.scale) pos=$startX,$startY"
  Write-Log "实际窗口: $($form.Left),$($form.Top) $($form.Width)x$($form.Height) dpi=$($script:dpiScale)"
  $script:shown = $null
  Update-Surface
  Refresh-Balance | Out-Null
  if ($null -ne $script:balance) {
    $script:shown = $script:balance
    Update-Surface
  }
  $mainTimer.Start()
  $turnTimer.Start()
  # 每轮消耗的首次对齐（轮询本身已经很便宜，不必再阻塞 UI 等待）
  try { Poll-TurnCost } catch { }
  # 退出快捷键放在 Shown 里注册：这时窗口句柄一定已经建好
  $hkText = $script:quitHotkey
  $hk = Parse-QuitHotkey $hkText
  if (-not $hkText) {
    Write-Log '退出快捷键已禁用（quitHotkey 为空）'
  } elseif (-not $hk) {
    Write-Log "退出快捷键写法无法识别：$hkText（支持 Ctrl/Shift/Alt/Win + 一个字母或数字）"
  } elseif ($form.RegisterQuitHotkey([uint32]$hk.Mods, [uint32]$hk.Vk)) {
    Write-Log "已注册退出快捷键 $hkText"
  } else {
    Write-Log "注册退出快捷键 $hkText 失败（可能已被其它程序占用），挂件继续运行"
  }
})

# Ctrl+Shift+Z：走的就是"停止信号"那条关闭流程（置 closing 后 form.Close()，
# 由 FormClosing 保存位置、清理 pid），不另外造一套退出逻辑。
$form.add_QuitHotkeyPressed({
  param($sender, $e)
  if ($script:closing) { return }        # 已经在退出了，避免重复执行
  Write-Log '收到 Ctrl+Shift+Z，退出挂件'
  # 记下"这是用户主动关的"：这样即使马上又有一个 Codex 会话拉起 MCP 服务，也不会立刻把挂件弹回来。
  # 等 Codex 下次重新启动（进程启动时间变了）才恢复自动放出。
  try {
    $cx = Get-CodexStartTime
    $payload = [pscustomobject]@{
      at         = (Get-Date).ToString('o')
      codexStart = if ($cx) { $cx.ToString('o') } else { $null }
    }
    [System.IO.File]::WriteAllText($userStopFile, ($payload | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
  $script:closing = $true
  $form.Close()
})

$form.Add_FormClosing({
  param($sender, $e)
  try { $mainTimer.Stop(); $turnTimer.Stop(); $animTimer.Stop(); $gifTimer.Stop(); $stopTimer.Stop(); $codexTimer.Stop() } catch { }
  try { $form.UnregisterQuitHotkey() } catch { }
  $script:cfg.x = $form.Left; $script:cfg.y = $form.Top
  Save-Config
  foreach ($p in $script:players.Values) { try { $p.Close() } catch { } }
  if ($script:whaleImg) { try { $script:whaleImg.Dispose() } catch { } }
  if ($script:gifImg) { try { [System.Drawing.ImageAnimator]::StopAnimate($script:gifImg); $script:gifImg.Dispose() } catch { } }
  # 渲染缓存 / HTTP 客户端
  foreach ($key in @('whale', 'layer', 'surface', 'path')) {
    if ($script:rc[$key]) { try { $script:rc[$key].Dispose() } catch { } ; $script:rc[$key] = $null }
  }
  foreach ($fnt in $script:rc.fonts.Values) { try { $fnt.Dispose() } catch { } }
  $script:rc.fonts.Clear()
  if ($script:http) { try { $script:http.Dispose() } catch { } }
  # pid 与停止信号都要清掉，否则跟随脚本会以为挂件还在跑
  try { if (Test-Path -LiteralPath $pidFile) { [System.IO.File]::Delete($pidFile) } } catch { }
  try { if (Test-Path -LiteralPath $stopFile) { [System.IO.File]::Delete($stopFile) } } catch { }
})

Write-Log "whale.ps1 就绪（资产目录 $AssetDir）"

# 调试：只渲染一帧存盘，便于逐像素核对外观
if ($RenderOnly) {
  $vp = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $short = [Math]::Min($vp.Width, $vp.Height)
  $script:baseSize = [int][Math]::Max(122, [Math]::Min(625, [Math]::Min(250, $short * 0.28) * [double]$script:cfg.scale))
  $script:balance = 1288.5
  $script:shown = 1288.5
  $script:todayUsage = 12.34
  $script:status = 'ok'
  $script:cacheRate = 99.904
  if ($RenderBubble) { $script:bubbleOpen = $true }
  if ($RenderFlip) { $script:flip = -1; $script:flipAnim = -1.0; $script:flipTarget = -1.0 }
  $bmp = $null
  # 连渲 3 帧：第 1 帧含 JIT/字体首次加载，看第 2、3 帧才是真实的每帧成本
  for ($i = 1; $i -le 3; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $bmp = New-Surface
    $sw.Stop()
    Write-Output ("render #{0}: {1} ms" -f $i, $sw.ElapsedMilliseconds)
  }
  $bmp.Save($RenderOnly, [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Output "rendered -> $RenderOnly (size $($script:baseSize), bubble=$($script:bubbleOpen), flip=$($script:flipAnim))"
  exit 0
}

# 调试：只跑一次"右键打开面板"里的服务启动逻辑。用来验证启动面板时不会弹出
# node 控制台窗口，也不会顺带把悬浮球拉起来。
if ($TestOpenPanel) {
  $up = Test-UsagePanelUp -TimeoutMs 250
  $ok = $false
  if (-not $up) { $ok = Start-UsagePanelService }
  Write-Output ("panelAlreadyUp=" + $up + " panelServiceStarted=" + $ok)
  exit 0
}

# 写下自己的 pid：跟随脚本 / CLI 都靠 widget.pid 判断挂件是否在运行。
# （放在 RenderOnly 之后，这样 -RenderOnly 调试不会覆盖正在运行的挂件的 pid）
# 启动前先看"用户主动停止"记号：如果这次 Codex 运行期间你已经用 Ctrl+Shift+Z 关掉过，
# 就不要因为新会话拉起 MCP 又把它弹回来；等 Codex 下次重启（启动时间变了）再恢复。
if ($script:cfg.followCodex) {
  try {
    if (Test-Path -LiteralPath $userStopFile) {
      $marker = Get-Content -LiteralPath $userStopFile -Raw -Encoding UTF8 | ConvertFrom-Json
      $cx = Get-CodexStartTime
      if ($cx -and $marker.codexStart) {
        $mx = $null
        try { $mx = [datetime]::Parse([string]$marker.codexStart) } catch { }
        if ($mx -and $mx -eq $cx) {
          Write-Log '本次 Codex 运行中你已用 Ctrl+Shift+Z 关掉挂件，跳过自动启动（Codex 重启后恢复）'
          exit 0
        }
      }
    }
  } catch { }
}
try { [System.IO.File]::WriteAllText($pidFile, "$PID", (New-Object System.Text.UTF8Encoding($false))) } catch { }

# 捕获未处理异常并写进日志，避免只留一个 Windows 崩溃对话框
[System.Windows.Forms.Application]::add_ThreadException({
  param($sender, $e)
  Write-Log ("UI 线程异常: " + $e.Exception.GetType().FullName + " | " + $e.Exception.Message + " | " + $e.Exception.StackTrace)
})
[System.AppDomain]::CurrentDomain.add_UnhandledException({
  param($sender, $e)
  Write-Log ("未处理异常: " + $e.ExceptionObject)
})

[System.Windows.Forms.Application]::Run($form)
