# Antigravity 官方更新后自动汉化守护脚本 v2 (2026-10-24 竞态根治升级)
# 原 v1（2026-09-21 起）能力保留：互斥体单实例、文件稳定等待、退避重试、退出补刀、mtime 轮询、周期巡检。
#
# v2 升级点（根治 2026-10-22 / 10-24 两次"官方更新后打不开"）：
# 1. 补丁前置闸：执行汉化前先等 Antigravity 全部退出（最长 90s，超时登记 PendingSwap 等退出补刀），
#    绝不在官方安装器 --force-run 重启窗口期 / 用户使用中写 asar（v1 的补丁可能与自启赛跑，读到半成品秒死）。
# 2. 补丁后闭环：所有路径的汉化成功后统一"拉起应用 + 30 秒活性验证"，失败自动回滚官方 app.asar.bak 再拉起。
#    最坏结局 = 界面回到英文但应用可用，永不再出现"更新后打不开"。
# 3. 拉起一律显式 WorkingDirectory=安装目录（2026-10-22/24 实证：正确 CWD 的控制台裸跑活着，错误 CWD 的
#    wscript 链拉起深秒死）。
# 4. 守护日志维持 auto-localize.log。

param (
    [switch]$RunOnce,
    [switch]$NoKill = $true
)

$ErrorActionPreference = "Continue"

# 实例互斥：命名互斥体，随进程退出自动释放（沿用 v1）
$ResourcesDir = "$env:LOCALAPPDATA\Programs\antigravity\resources"
$AsarPath = Join-Path $ResourcesDir "app.asar"
$AsarBakPath = Join-Path $ResourcesDir "app.asar.bak"
$AppExe = Join-Path (Split-Path $ResourcesDir) "Antigravity.exe"
$AppDir = Split-Path $ResourcesDir
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

$script:AppMutex = New-Object System.Threading.Mutex($false, "AntigravityAutoLocalizeWatchdog")
if (-not $script:AppMutex.WaitOne(0)) {
    Write-Log "已有守护实例持有互斥体，本实例退出以避免重复。"
    exit 0
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

function Test-AppRunning {
    # 主程序判定：存在任意 Antigravity.exe 进程（子进程只在主进程存活时存在）
    try {
        $p = Get-Process -Name "Antigravity" -ErrorAction SilentlyContinue
        return @($p).Count -gt 0
    } catch {
        return $false
    }
}

function Wait-AppExit {
    # v2 新增·补丁前置闸：等 Antigravity 全部退出，绝不与官方安装器自启/用户使用抢写窗口。
    param ([int]$TimeoutSeconds = 90)
    if (-not (Test-AppRunning)) { return $true }
    Write-Log "Antigravity 仍在运行（可能是官方更新自启或用户使用中），等待退出（最多 $TimeoutSeconds 秒）..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 2
        if (-not (Test-AppRunning)) {
            Write-Log "Antigravity 已退出，写入窗口就绪。"
            return $true
        }
    }
    Write-Log "等待超时：应用仍在使用中，本次不打补丁（登记退出补刀，等用户退出后再处理）。"
    return $false
}

function Start-Antigravity {
    # v2 新增：一律显式 WorkingDirectory（spawn 上下文敏感教训）
    try {
        $wd = Split-Path $ResourcesDir
        Start-Process -FilePath $AppExe -WorkingDirectory $wd | Out-Null
        Write-Log "已启动 Antigravity (WorkingDirectory=$wd)。"
        return $true
    } catch {
        Write-Log "启动 Antigravity 失败: $_"
        return $false
    }
}

function Test-BootAlive {
    # v2 新增：拉起后 30 秒活性验证
    param ([int]$Seconds = 30)
    Write-Log "启动活性验证中（等待 $Seconds 秒窗口）..."
    Start-Sleep -Seconds 10
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        if (Test-AppRunning) {
            Write-Log "[OK] 启动验证通过：Antigravity 进程存活。"
            return $true
        }
        Start-Sleep -Seconds 2
    }
    Write-Log "[NG] 启动验证失败：$Seconds 秒内未见 Antigravity 进程。"
    return $false
}

function Invoke-LocalizationWithBackoff {
    param ([switch]$ForceKill)
    $maxRetries = 3
    $backoffDelays = @(5, 15, 30)
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        Write-Log "--------------------------------------------------"
        Write-Log "开始汉化检查 (第 $attempt/$maxRetries 次尝试)..."
        if (-not (Test-Path $AsarPath)) {
            Write-Log "未检测到 app.asar 文件，跳过本次处理。"
            return $false
        }
        $isLocalized = Test-IsChineseLocalized -Path $AsarPath
        if ($isLocalized) {
            Write-Log "检测确认当前 app.asar 已包含中文汉化标记，无需重复处理。"
            return $true
        }
        Write-Log "检测到当前 app.asar 为未汉化版本（可能刚发生官方更新）。"
        $stable = Wait-ForFileStabilization -Path $AsarPath -TimeoutSeconds 30
        if (-not $stable) {
            Write-Log "app.asar 大小尚未完全稳定，继续尝试执行..."
        }
        $nodeArgs = @("$LocalizeScript", "--now")
        if ($NoKill -and -not $ForceKill) {
            $nodeArgs += "--no-kill"
        }
        Write-Log "正在执行: node $($nodeArgs -join ' ')"
        $process = Start-Process -FilePath "node" -ArgumentList $nodeArgs -WorkingDirectory $LocalizationDir -NoNewWindow -Wait -PassThru
        if ($process.ExitCode -eq 0) {
            Write-Log "🎉 [成功] 自动汉化流程执行成功！"
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
    Write-Log "保护说明: 已保留官方原版文件，禁止非原子覆盖。可能 Antigravity 正在运行中独占文件。"
    return $false
}

function Assert-OauthDispatch {
    # v2 新增：NSIS 更新会把 antigravity:// 协议重置回官方 exe（2026-10-24 实证），
    # 这里把它指回 antigravity-tools 的分发器，让分身登录回调在一次更新后依然有效。
    $regPath = "Registry::HKCU\Software\Classes\antigravity\shell\open\command"
    $expected = '"C:\Windows\System32\wscript.exe" //B //Nologo "C:\Users\KLF9518\AppData\Local\antigravity-tools\oauth-dispatch.vbs" "%1"'
    if (-not (Test-Path "C:\Users\KLF9518\AppData\Local\antigravity-tools\oauth-dispatch.vbs")) { return }
    try {
        $cur = (Get-ItemProperty -Path $regPath -ErrorAction Stop).'(default)'
        if ($cur -ne $expected) {
            Set-ItemProperty -Path $regPath -Name "(default)" -Value $expected
            Write-Log "已修复 antigravity:// 协议注册（NSIS 更新会重置它）→ antigravity-tools\oauth-dispatch.vbs"
        }
    } catch {
        Write-Log "antigravity:// 协议注册检查失败: $_"
    }
}

function Invoke-Patch-And-Boot {
    # v2 新增·总闭环：前置闸 → 汉化 → 拉起 → 活性验证 → 失败自动回滚官方 asar → 再拉起
    param ([switch]$ForceKill)
    Assert-OauthDispatch
    if (-not (Wait-AppExit -TimeoutSeconds 90)) {
        $script:PendingSwap = $true
        Write-Log "已登记退出补刀：待 Antigravity 退出后将自动补汉化并重启应用。"
        return $false
    }
    $patched = Invoke-LocalizationWithBackoff -ForceKill:$ForceKill
    if (-not $patched) { return $false }
    if (-not (Start-Antigravity)) { return $false }
    if (Test-BootAlive -Seconds 30) { return $true }
    Write-Log "❌ 汉化补丁疑似与当前官方版本不兼容（应用未能存活），执行自动回滚..."
    if (Test-Path $AsarBakPath) {
        try {
            Copy-Item -LiteralPath $AsarBakPath -Destination $AsarPath -Force
            Write-Log ("已回滚官方 app.asar (大小 " + (Get-Item -LiteralPath $AsarPath).Length + " 字节)。界面回到英文，但应用可用。")
        } catch {
            Write-Log "自动回滚失败: $_ （请手动用 resources\app.asar.bak 覆盖 resources\app.asar）"
        }
    } else {
        Write-Log "未找到 app.asar.bak，无法自动回滚。"
    }
    Write-Log "用可用版本重新拉起 Antigravity..."
    Start-Antigravity | Out-Null
    return $false
}

Write-Log "=================================================="
Write-Log "Antigravity 自动汉化守护程序 v2 已启动 (2026-10-24 竞态根治版)"
Write-Log "监控资源目录: $ResourcesDir"
Write-Log "汉化执行脚本: $LocalizeScript"
Write-Log "=================================================="

# 启动时先执行一次自检（带前置闸与启动验证）
Assert-OauthDispatch
Invoke-Patch-And-Boot | Out-Null

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
            Start-Sleep -Seconds 2
            Invoke-Patch-And-Boot | Out-Null
        }
    }
}

Register-ObjectEvent -InputObject $watcher -EventName "Changed" -Action $action | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $action | Out-Null
Register-ObjectEvent -InputObject $watcher -EventName "Renamed" -Action $action | Out-Null

Write-Log "实时变动监听已就绪，正在后台持续守护..."

# 2026-09-24 修复（沿用 v1）：短轮询 mtime（防事件机制哑火），30 分钟巡检另行计时
$pollIntervalSeconds = 10
$patrolIntervalSeconds = 1800
$lastPatrolTime = [DateTime]::Now
$script:PendingSwap = $false
$lastKnownMTime = if (Test-Path $AsarPath) { (Get-Item -LiteralPath $AsarPath).LastWriteTime } else { [DateTime]::MinValue }

try {
    while ($true) {
        Start-Sleep -Seconds $pollIntervalSeconds
        try {
            # 退出补刀：先前因应用占用登记的补丁，在应用退出后立即执行
            if ($script:PendingSwap -and -not (Test-AppRunning)) {
                Write-Log "[退出补刀] 检测到 Antigravity 已退出，立即执行补汉化。"
                $swapOk = Invoke-Patch-And-Boot -ForceKill
                $script:PendingSwap = $false
            }
            # mtime 轮询
            if (Test-Path $AsarPath) {
                $asarItem = Get-Item -LiteralPath $AsarPath
                if ($asarItem.Length -gt 1048576 -and $asarItem.LastWriteTime -ne $lastKnownMTime) {
                    Write-Log "[mtime 轮询] 检测到 app.asar 变动 (LastWriteTime=$($asarItem.LastWriteTime))。"
                    Invoke-Patch-And-Boot | Out-Null
                    if (Test-Path $AsarPath) {
                        $lastKnownMTime = (Get-Item -LiteralPath $AsarPath).LastWriteTime
                    }
                }
            }
            # 周期巡检
            if (((Get-Date) - $lastPatrolTime).TotalSeconds -ge $patrolIntervalSeconds) {
                $lastPatrolTime = Get-Date
                if (Test-Path $AsarPath) {
                    $sizeOk = (Get-Item -LiteralPath $AsarPath).Length -gt 1048576
                    if ($sizeOk -and -not (Test-IsChineseLocalized -Path $AsarPath)) {
                        Write-Log "[周期巡检] 检测到 app.asar 为未汉化版本，自动重新汉化。"
                        Invoke-Patch-And-Boot | Out-Null
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
