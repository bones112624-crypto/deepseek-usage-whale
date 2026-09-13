<#
.SYNOPSIS
  DeepSeek 小鲸鱼挂件的生命周期守护：完全跟着 Codex 一起开、一起关。

.DESCRIPTION
  一个脚本承担四种角色：

    -Action watch    守护进程（默认）。每 2 秒检查一次 Codex 是否在运行：
                     Codex 起来 → 放出小鲸鱼挂件；Codex 退出 → 一起收掉。
                     被 -Action stop 停过之后保持停止，直到下一次启动 Codex 才恢复。
    -Action start    立刻放出挂件（桌面快捷方式用），并切到"独立模式"：
                     不依赖 Codex，也不会因为 Codex 退出而被收掉。
    -Action stop     收起挂件，并标记为用户主动停止。
    -Action status   打印当前状态，便于排查。

  Codex 桌面版的主进程是 ChatGPT.exe，路径里带 OpenAI.Codex_，所以这里按
  "进程名 + 路径"双重匹配，不会把浏览器里的 ChatGPT 网页算成 Codex。

  状态文件：<DataDir>\follow-state.json
  日志：    <DataDir>\follow.log
#>
[CmdletBinding()]
param(
  [ValidateSet('watch', 'start', 'stop', 'status')][string]$Action = 'watch',
  [double]$IntervalSeconds = 2,
  [string]$CodexProcessName = 'ChatGPT',
  [string]$CodexPathFilter = '*OpenAI.Codex_*',
  [string]$PluginDir = (Join-Path $env:USERPROFILE 'plugins\deepseek-whale-widget'),
  [string]$DataDir = (Join-Path $env:USERPROFILE '.deepseek-whale'),
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
try {
  [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

if (-not (Test-Path -LiteralPath $DataDir)) {
  New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
}

$stateFile = Join-Path $DataDir 'follow-state.json'
$logFile = Join-Path $DataDir 'follow.log'
$pidFile = Join-Path $DataDir 'widget.pid'
$stopFile = Join-Path $DataDir 'whale-stop'
$whaleScript = Join-Path $PluginDir 'widget\whale.ps1'

function Write-Log {
  param([string]$Message)
  if ($Quiet) { return }
  try {
    if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 512KB) {
      $kept = Get-Content -LiteralPath $logFile -Tail 200 -ErrorAction SilentlyContinue
      [System.IO.File]::WriteAllLines($logFile, $kept, (New-Object System.Text.UTF8Encoding($false)))
    }
    Add-Content -LiteralPath $logFile -Value ("[{0}] {1}" -f (Get-Date).ToString('MM-dd HH:mm:ss'), $Message) -Encoding UTF8
  } catch { }
}

# ---- 状态 -----------------------------------------------------------------

function Read-State {
  $default = [ordered]@{ mode = 'follow'; stopped = $false; stoppedAt = $null; updatedAt = $null }
  if (-not (Test-Path -LiteralPath $stateFile)) { return $default }
  try {
    $raw = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $default.mode = if ($raw.mode -in @('follow', 'standalone')) { $raw.mode } else { 'follow' }
    $default.stopped = [bool]$raw.stopped
    $default.stoppedAt = $raw.stoppedAt
    $default.updatedAt = $raw.updatedAt
  } catch { }
  return $default
}

function Save-State {
  param($State)
  try {
    $State.updatedAt = (Get-Date).ToString('o')
    [System.IO.File]::WriteAllText($stateFile, ($State | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
  } catch { }
}

# ---- Codex 检测 -----------------------------------------------------------

# 返回 Codex 主程序里最早那个进程的启动时间；没在跑就返回 $null。
# 用启动时间而不是布尔值，才能区分"停止之后又重新开了一轮 Codex"——
# 否则一次瞬时的检测失败就会把用户的手动停止给误解除。
function Get-CodexStartTime {
  $procs = Get-Process -Name $CodexProcessName -ErrorAction SilentlyContinue
  if (-not $procs) { return $null }
  $earliest = $null
  foreach ($p in $procs) {
    try {
      if ($p.Path -notlike $CodexPathFilter) { continue }
      $t = $p.StartTime
      if ($null -eq $earliest -or $t -lt $earliest) { $earliest = $t }
    } catch { }
  }
  return $earliest
}

function Test-CodexRunning {
  return ($null -ne (Get-CodexStartTime))
}

# ---- 挂件检测 / 启停 -------------------------------------------------------

function Get-WhalePid {
  if (-not (Test-Path -LiteralPath $pidFile)) { return 0 }
  try {
    $id = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim())
    if ($id -le 0) { return 0 }
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'powershell') { return $id }
  } catch { }
  return 0
}

function Test-WhaleRunning {
  return ((Get-WhalePid) -gt 0)
}

$script:startTimes = New-Object System.Collections.ArrayList

function Start-Whale {
  if (Test-WhaleRunning) { return $false }
  if (-not (Test-Path -LiteralPath $whaleScript)) { Write-Log "找不到挂件脚本 $whaleScript"; return $false }

  # 秒退保护：60 秒内已经启动过 3 次还是没起来，说明挂件本身有问题，
  # 再拉下去就是死循环刷进程。停手并记一笔，等下一轮 Codex 启动再说。
  $now = Get-Date
  $recent = @($script:startTimes | Where-Object { ($now - $_).TotalSeconds -lt 60 })
  if ($recent.Count -ge 3) {
    Write-Log '挂件连续启动失败，暂停自动拉起（等下次 Codex 启动）'
    $s = Read-State
    $s.stopped = $true
    $s.stoppedAt = $now.ToString('o')
    Save-State $s
    return $false
  }
  [void]$script:startTimes.Add($now)

  # 清掉可能残留的停止信号，否则新挂件一起来就自己关掉
  try { if (Test-Path -LiteralPath $stopFile) { [System.IO.File]::Delete($stopFile) } } catch { }
  try { if (Test-Path -LiteralPath $pidFile) { [System.IO.File]::Delete($pidFile) } } catch { }

  # 用 WMI 创建进程：完全独立于调用者，快捷方式/计划任务退出也不会把它带走
  $cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$whaleScript`" -DataDir `"$DataDir`""
  try {
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
    if ($r.ReturnValue -ne 0) { Write-Log "启动挂件失败：Win32_Process.Create 返回 $($r.ReturnValue)"; return $false }
    Write-Log "已启动挂件 pid=$($r.ProcessId)"
  } catch {
    Write-Log "启动挂件异常：$($_.Exception.Message)"
    return $false
  }

  # 等它把 widget.pid 写出来，避免下一轮 watchdog 又拉一个
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 300
    if (Test-WhaleRunning) { break }
  }
  return $true
}

function Stop-Whale {
  $id = Get-WhalePid
  if ($id -le 0) {
    try { if (Test-Path -LiteralPath $pidFile) { [System.IO.File]::Delete($pidFile) } } catch { }
    return $false
  }
  # 优先优雅关闭：写停止信号，挂件每 300ms 检查一次，收到就正常走关闭流程
  # （这样它会保存位置与配置，而不是被强杀丢状态）
  try { [System.IO.File]::WriteAllText($stopFile, 'stop', (New-Object System.Text.UTF8Encoding($false))) } catch { }
  for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Milliseconds 80
    if (-not (Get-Process -Id $id -ErrorAction SilentlyContinue)) { Write-Log '挂件已优雅退出'; break }
  }
  # 兜底：没响应就强杀
  $p = Get-Process -Id $id -ErrorAction SilentlyContinue
  if ($p -and $p.ProcessName -eq 'powershell') {
    try { Stop-Process -Id $p.Id -Force; Write-Log "挂件未响应关闭，已强制结束 pid=$($p.Id)" } catch { }
  }
  try { if (Test-Path -LiteralPath $stopFile) { [System.IO.File]::Delete($stopFile) } } catch { }
  try { if (Test-Path -LiteralPath $pidFile) { [System.IO.File]::Delete($pidFile) } } catch { }
  return $true
}

function Show-Status {
  $s = Read-State
  $codex = Test-CodexRunning
  $whale = Test-WhaleRunning
  [pscustomobject]@{
    mode            = $s.mode
    stoppedByUser   = $s.stopped
    codexRunning    = $codex
    whaleRunning    = $whale
    whalePid        = (Get-WhalePid)
    shouldBeRunning = ((-not $s.stopped) -and ($codex -or $s.mode -eq 'standalone'))
    dataDir         = $DataDir
  }
}

# ---- 入口 -----------------------------------------------------------------

switch ($Action) {
  'status' {
    Show-Status | Format-List
  }

  'stop' {
    $s = Read-State
    $s.stopped = $true
    $s.stoppedAt = (Get-Date).ToString('o')
    $s.mode = 'follow'
    Save-State $s
    Stop-Whale | Out-Null
    # 守护循环可能刚好读到停止之前的状态、在停止之后把挂件又拉了起来，
    # 所以隔一拍再收一次，确保收干净。
    Start-Sleep -Milliseconds 800
    Stop-Whale | Out-Null
    Write-Log '用户主动停止挂件（下次启动 Codex 会自动恢复）'
    if (-not $Quiet) { Write-Output '已收起小鲸鱼挂件。下次启动 Codex 会自动恢复。' }
  }

  'start' {
    $s = Read-State
    $s.mode = 'standalone'
    $s.stopped = $false
    $s.stoppedAt = $null
    Save-State $s
    Start-Whale | Out-Null
    Write-Log '独立模式：放出挂件（不依赖 Codex）'
    if (-not $Quiet) { Write-Output '小鲸鱼挂件已放出（独立模式，不依赖 Codex）。' }
  }

  'watch' {
    Write-Log "守护进程启动（间隔 ${IntervalSeconds}s）"
    while ($true) {
      try {
        $s = Read-State
        $codexStart = Get-CodexStartTime
        $codex = $null -ne $codexStart

        # 只有"停止之后新启动的 Codex"才解除手动停止；
        # 比"没开→开了"的布尔跳变可靠，不会因为一次瞬时检测失败就误解除。
        if ($s.stopped -and $codexStart -and $s.stoppedAt) {
          $stoppedAt = $null
          try { $stoppedAt = [datetime]::Parse($s.stoppedAt) } catch { }
          if ($stoppedAt -and $codexStart -gt $stoppedAt) {
            Write-Log '检测到 Codex 重新启动，恢复跟随'
            # 写之前重新读一遍，避免把这期间别的改动（快捷方式启动的独立模式）覆盖掉
            $fresh = Read-State
            $fresh.stopped = $false
            $fresh.stoppedAt = $null
            $fresh.mode = 'follow'
            Save-State $fresh
            $s = Read-State
          }
        }

        if ((-not $s.stopped) -and ($codex -or $s.mode -eq 'standalone')) {
          if (-not (Read-State).stopped) { Start-Whale | Out-Null }
        } else {
          if (Test-WhaleRunning) {
            Stop-Whale | Out-Null
            if ($s.stopped) { Write-Log '用户已停止，保持关闭' }
            else { Write-Log 'Codex 已退出，收起挂件' }
          }
        }
      } catch {
        Write-Log "守护循环异常：$($_.Exception.Message)"
      }
      Start-Sleep -Milliseconds ([int]([Math]::Max(0.5, $IntervalSeconds) * 1000))
    }
  }
}
