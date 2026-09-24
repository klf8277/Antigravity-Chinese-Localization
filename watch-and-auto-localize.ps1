# Antigravity 官方更新后自动汉化守护脚本 (Auto-Localize Watcher)
# 监听 resources\app.asar 变动，在官方静默更新后自动重新应用汉化

param (
    [switch]$RunOnce,
    [switch]$NoKill = $true
)

$ErrorActionPreference = "Continue"

# 实例互斥：已有守护在跑则本实例退出，避免双开重复触发
$existing = Get-CimInstance Win32_Process -Filter "name='powershell.exe'" | Where-Object { $_.CommandLine -like "*watch-and-auto-localize.ps1*" -and $_.ProcessId -ne $PID }
if ($existing) {
    Write-Log "检测到守护进程已在运行 (PID $($existing.ProcessId -join ', '))，本实例退出以避免重复。"
    exit 0
}

$ResourcesDir = "$env:LOCALAPPDATA\Programs\antigravity\resources"
$AsarPath = Join-Path $ResourcesDir "app.asar"
$LocalizationDir = $PSScriptRoot
$LocalizeScript = Join-Path $LocalizationDir "localize.js"
$LogFile = Join-Path $LocalizationDir "auto-localize.log"

function Write-Log {
    param ([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line
    try {
        Add-Content -Path $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

function Test-IsChineseLocalized {
    param ([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $buffer = New-Object char[] 65536
        $found = $false
        $marker1 = "Chinese Localization Engine"
        $marker2 = "menuTranslationMap"
        
        while (-not $reader.EndOfStream -and -not $found) {
            $readCount = $reader.Read($buffer, 0, $buffer.Length)
            if ($readCount -le 0) { break }
            $chunk = New-Object string ($buffer, 0, $readCount)
            if ($chunk.Contains($marker1) -or $chunk.Contains($marker2)) {
                $found = $true
                break
            }
        }
        $reader.Close()
        $stream.Close()
        return $found
    } catch {
        Write-Log "检测汉化标记时读取失败: $_"
        return $false
    }
}

function Wait-ForFileStabilization {
    param (
        [string]$Path,
        [int]$TimeoutSeconds = 30
    )
    Write-Log "等待 app.asar 文件写入完成并稳定..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastSize = -1
    $stableCount = 0

    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path $Path) {
            try {
                $fileItem = Get-Item -LiteralPath $Path -ErrorAction Stop
                $currentSize = $fileItem.Length
                if ($currentSize -gt 1048576 -and $currentSize -eq $lastSize) {
                    $stableCount++
                    if ($stableCount -ge 3) {
                        Write-Log "app.asar 文件大小稳定 (当前大小: $currentSize 字节)。"
                        return $true
                    }
                } else {
                    $stableCount = 0
                }
                $lastSize = $currentSize
            } catch {
                $stableCount = 0
            }
        } else {
            $stableCount = 0
        }
        Start-Sleep -Milliseconds 1000
    }
    Write-Log "警告: 等待 app.asar 文件稳定超时 ($TimeoutSeconds 秒)。"
    return $false
}

function Invoke-LocalizationWithBackoff {
    $maxRetries = 3
    $backoffDelays = @(5, 15, 30)

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        Write-Log "--------------------------------------------------"
        Write-Log "开始汉化检查 (第 $attempt/$maxRetries 次尝试)..."

        if (-not (Test-Path $AsarPath)) {
            Write-Log "未检测到 app.asar 文件，跳过本次处理。"
            return $false
        }

        # 1. 检查是否已被汉化
        $isLocalized = Test-IsChineseLocalized -Path $AsarPath
        if ($isLocalized) {
            Write-Log "检测确认当前 app.asar 已包含中文汉化标记，无需重复处理。"
            return $true
        }

        Write-Log "检测到当前 app.asar 为未汉化版本（可能刚发生官方更新）。"

        # 2. 等待文件大小稳定
        $stable = Wait-ForFileStabilization -Path $AsarPath -TimeoutSeconds 30
        if (-not $stable) {
            Write-Log "app.asar 大小尚未完全稳定，继续尝试执行..."
        }

        # 3. 执行汉化命令
        $nodeArgs = @("$LocalizeScript", "--now")
        if ($NoKill) {
            $nodeArgs += "--no-kill"
        }

        Write-Log "正在执行: node $($nodeArgs -join ' ')"
        $process = Start-Process -FilePath "node" -ArgumentList $nodeArgs -WorkingDirectory $LocalizationDir -NoNewWindow -Wait -PassThru

        if ($process.ExitCode -eq 0) {
            Write-Log "🎉 [成功] 自动汉化流程执行成功！"
            Write-Log "标准提示: 恢复以完整重启为标准流程，请完全退出 Antigravity（完整重启）以载入完整中文界面与原生菜单。"
            return $true
        } else {
            Write-Log "⚠️ [执行失败] 汉化进程退出码: $($process.ExitCode)"
            if ($attempt -lt $maxRetries) {
                $delay = $backoffDelays[$attempt - 1]
                Write-Log "进入失败退避策略，等待 $delay 秒后重试第 $($attempt + 1) 次..."
                Start-Sleep -Seconds $delay
            }
        }
    }

    Write-Log "❌ [退避终止] 已达到最大重试次数 ($maxRetries 次)。"
    Write-Log "保护说明: 已保留官方原版文件，禁止非原子覆盖。可能 Antigravity 正在运行中独占文件，请退出软件后手动重试或等待下次重启触发。"
    return $false
}

Write-Log "=================================================="
Write-Log "Antigravity 自动汉化守护程序已启动"
Write-Log "监控资源目录: $ResourcesDir"
Write-Log "汉化执行脚本: $LocalizeScript"
Write-Log "=================================================="

# 启动时先执行一次自检
Invoke-LocalizationWithBackoff

if ($RunOnce) {
    Write-Log "运行参数指定了 -RunOnce，守护脚本单次执行结束。"
    exit 0
}

# 建立文件系统实时变动监控
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $ResourcesDir
$watcher.Filter = "*.*"
$watcher.IncludeSubdirectories = $false
$watcher.EnableRaisingEvents = $true

$script:lastTriggerTime = [DateTime]::MinValue

$action = {
    $path = $Event.SourceEventArgs.FullPath
    $changeType = $Event.SourceEventArgs.ChangeType
    $name = [System.IO.Path]::GetFileName($path).ToLower()

    if ($name -eq "app.asar" -or $name -eq "app.asar.unpacked") {
        $now = [DateTime]::Now
        if (($now - $script:lastTriggerTime).TotalSeconds -ge 5) {
            $script:lastTriggerTime = $now
            Write-Log "检测到文件变动 [$changeType]: $path"
            # 延时 2 秒等待写入初始化
            Start-Sleep -Seconds 2
            Invoke-LocalizationWithBackoff
        }
    }
}

Register-ObjectEvent -InputObject $watcher -EventName "Changed" -Action $action | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $action | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName "Renamed" -Action $action | Out-Null

Write-Log "实时变动监听已就绪，正在后台持续守护..."

# 2026-09-24 修复：原主循环 Start-Sleep 1800 会占住引擎，FileSystemWatcher 的注册事件动作
# 要等引擎空闲才执行，导致"实时监听"最长延迟 30 分钟（2.17.0 升级 21:34 覆盖 asar，实时层全程哑火）。
# 现改为短轮询：每 10 秒比对 app.asar 的 mtime 触发汉化检查（不依赖事件机制），30 分钟巡检另行计时。
$pollIntervalSeconds = 10
$patrolIntervalSeconds = 1800
$lastPatrolTime = [DateTime]::Now
$lastKnownMTime = if (Test-Path $AsarPath) { (Get-Item -LiteralPath $AsarPath).LastWriteTime } else { [DateTime]::MinValue }

try {
    while ($true) {
        Start-Sleep -Seconds $pollIntervalSeconds
        try {
            # mtime 轮询：兜住 FileSystemWatcher 哑火的场景
            if (Test-Path $AsarPath) {
                $asarItem = Get-Item -LiteralPath $AsarPath
                if ($asarItem.Length -gt 1048576 -and $asarItem.LastWriteTime -ne $lastKnownMTime) {
                    Write-Log "[mtime 轮询] 检测到 app.asar 变动 (LastWriteTime=$($asarItem.LastWriteTime))。"
                    Invoke-LocalizationWithBackoff | Out-Null
                    if (Test-Path $AsarPath) {
                        $lastKnownMTime = (Get-Item -LiteralPath $AsarPath).LastWriteTime
                    }
                }
            }
            # 周期巡检：覆盖"重试耗尽后才退出 Antigravity"的场景（无文件变动触发，靠巡检补刀）
            if (((Get-Date) - $lastPatrolTime).TotalSeconds -ge $patrolIntervalSeconds) {
                $lastPatrolTime = Get-Date
                if (Test-Path $AsarPath) {
                    $sizeOk = (Get-Item -LiteralPath $AsarPath).Length -gt 1048576
                    if ($sizeOk -and -not (Test-IsChineseLocalized -Path $AsarPath)) {
                        Write-Log "[周期巡检] 检测到 app.asar 为未汉化版本，自动重新汉化。"
                        Invoke-LocalizationWithBackoff | Out-Null
                    }
                }
            }
        } catch {
            Write-Log "[轮询/巡检] 异常（不影响继续守护）: $_"
        }
    }
} finally {
    $watcher.EnableRaisingEvents = $false
    $watcher.Dispose()
    Write-Log "自动汉化守护程序已退出。"
}
