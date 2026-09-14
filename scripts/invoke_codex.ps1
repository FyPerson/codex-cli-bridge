[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Prompt,

    [Parameter(Mandatory = $false)]
    [string]$PromptFile,

    [Parameter(Mandatory = $false)]
    [ValidateSet("spec-critique", "code-review", "sql-review", "general-assist")]
    [string]$TaskType = "spec-critique",

    [Parameter(Mandatory = $false)]
    [ValidateSet("advice-only", "draft-only")]
    [string]$Mode = "advice-only",

    [Parameter(Mandatory = $false)]
    [ValidateSet("zh-CN", "en-US")]
    [string]$OutputLanguage = "zh-CN",

    [Parameter(Mandatory = $false)]
    [string]$Model,

    [Parameter(Mandatory = $false)]
    [string]$WorkingDirectory = (Get-Location).Path,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [string[]]$ContextFiles,

    [Parameter(Mandatory = $false)]
    [int]$MaxContextChars = 60000,

    [Parameter(Mandatory = $false)]
    [ValidateRange(30, 1800)]
    [int]$TimeoutSeconds = 300,

    [switch]$IncludeProject,
    [switch]$RawPrompt,
    [switch]$PassThru,

    # API 中转模式：走中转 API（按量付费，端点/key 读 .env 的 CODEX_API_*）而非 codex 订阅登录态。
    # 仅当用户显式说明"走 API"时传；未显式说明一律默认本机订阅（2026-09-09 用户拍板，见 SKILL「审查路径（三轨）」节）。
    [switch]$Api,
    [Parameter(Mandatory = $false)]
    [string]$ApiEnvFile = (Join-Path $PSScriptRoot '..\.env'),

    # 远端订阅模式：把 codex 调用发到另一台机器执行，用那台机器上的第二个 ChatGPT 登录态。
    # 凭据永远不离开远端（本机不存 auth.json）。与 -Api 互斥——两者都在决定认证路径。
    # 链路依赖 Tailscale + OpenSSH 密钥认证，实测记录见 SKILL「远端订阅模式」节。
    [switch]$Remote,
    [Parameter(Mandatory = $false)]
    [string]$RemoteTarget = $env:CODEX_BRIDGE_REMOTE_TARGET,
    # 只验链路（连通性 / codex 版本 / 登录态），不跑审核、不消耗额度
    [switch]$RemotePreflight
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (($Remote -or $RemotePreflight) -and [string]::IsNullOrWhiteSpace($RemoteTarget)) {
    throw '远端模式需要 -RemoteTarget user@remote-host 或 CODEX_BRIDGE_REMOTE_TARGET 环境变量。'
}

function Get-SafeFileToken {
    param([Parameter(Mandatory = $true)][string]$Value)
    return (($Value -replace "[^A-Za-z0-9_-]", "-").Trim("-"))
}

# ---------- 远端订阅模式辅助函数（-Remote） ----------
# 2026-09-09 端到端实测踩出的六个坑，解药固化在此，改动前先读：
#   1. SSH 非交互会话里 codex 不在 PATH（PATH 里那个 OpenAI\Codex\bin 是空目录）→ 必须用绝对路径
#   2. packages\standalone\current 是符号链接，SSH 会话下遍历报"无法访问重解析点"→ 只能走 releases\<版本>\
#   3. codex exec 会读 stdin，不给 EOF 会挂住 → ssh 一律带 -n
#   4. 远端工作目录不是 git 仓库，exec 直接拒绝 → --skip-git-repo-check（本机路径 :315 早已有）
#   5. 远端中文输出是 GBK，本地按 UTF-8 读会乱码 → 命令前 chcp 65001
#   6. ssh→cmd→powershell 多层引号解析，"|" 会被 cmd 当管道符 → 命令一律 Base64 -EncodedCommand
# 滤掉 ssh/scp 的固定噪音行，保留真正的错误。
# 2026-09-09 实测教训：原先用 `-o LogLevel=ERROR` 压噪音，结果把连接错误一起吞了——
# "Connection closed by ... port 22" 这类信息全部消失，故障时诊断输出一片空白。
# （中途我曾用一次 ConnectTimeout=4 的观测断定"LogLevel 不是原因"，那是另一种失败模式下的巧合，
#  换成 ConnectTimeout=20 复现即被推翻。单次观测不足以支撑因果结论。）
# 正解是保留完整日志级别，只在读到之后按行滤掉已知无害的告警。
function Remove-SshNoise {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $kept = ($Text -split "`r?`n") | Where-Object {
        $t = $_.Trim()
        $t -and ($t -notmatch '^Warning: Permanently added ')
    }
    return ($kept -join "`n")
}

# 读取被 Start-Process 重定向过的输出文件。
# 必须用 FileShare.ReadWrite 打开并允许重试：子进程刚退出时句柄可能还没释放，
# 直接 ReadAllText 会抛 IOException，把 ssh/scp 的错误信息静默吞掉。
function Read-RedirectedText {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $lastErr = ''
    for ($i = 0; $i -lt 5; $i++) {
        try {
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
            } finally { $fs.Dispose() }
        } catch {
            $lastErr = $_.Exception.Message
            Start-Sleep -Milliseconds 80
        }
    }
    # 复审意见：五次都失败时不能再表现为"诊断为空"，把读取异常本身留在输出里
    return "[read-error] $lastErr"
}

# 统一的外部进程调用层：带真实总时限 + 进程树回收。
# codex 审 Commit2/issue 1 的直接产物——此前用 `& ssh` 只有 ConnectTimeout，
# 连上之后远端卡住本机会无限等待，而注释却宣称"有 60 秒余量的等待上限"（声明大于实作）。
# 这里落实成真的：Start-Process + WaitForExit(ms)，到点杀进程树并明确回报 TimedOut。
# 预算口径（复审二 issue 4 校准）：-TimeoutSeconds 是"主等待预算"；超时分支另有最多约 10 秒清理开销
# （taskkill 5s + 直接进程 5s）加读取重试零点几秒。本函数不承诺在 TimeoutSeconds 内返回，调用方按此留余量。
function Invoke-ExternalWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    $tmpOut = [System.IO.Path]::GetTempFileName()
    $tmpErr = [System.IO.Path]::GetTempFileName()
    $code = -1; $timedOut = $false; $localFailure = $null
    try {
        try {
            $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments `
                -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr `
                -NoNewWindow -PassThru
        } catch {
            return [pscustomobject]@{
                ExitCode = -1; ExitCodeKnown = $false; TimedOut = $false; KillConfirmed = $false; Output = ''; ErrorOutput = ''
                LocalFailure = "启动 $FilePath 失败: $($_.Exception.Message)"
            }
        }

        # 2026-09-09 实测：PS 5.1 的 Start-Process -PassThru 返回的 Process 对象读不到 ExitCode
        # （HasExited=True 但 ExitCode 为空），对 `powershell -Command "exit 42"` 与失败的 ssh 都复现。
        # 所以这里绝不把"读不到"粉饰成 0——那正是 codex 审 issue 5 批评的"把未知压成成功"。
        # 未知就标成 -1 且 ExitCodeKnown=$false，由调用方改用更直接的判据（输出标记、文件大小）定成败。
        $exitCodeKnown = $false
        $killConfirmed = $false
        if ($p.WaitForExit($TimeoutSeconds * 1000)) {
            # 复审意见：收尾等待也要有预算，函数才真正具备"总返回时限"
            $null = $p.WaitForExit(5000)
            try {
                $raw = $p.ExitCode
                if ($null -ne $raw) { $code = [int]$raw; $exitCodeKnown = $true }
            } catch { }
            if (-not $exitCodeKnown) { $code = -1 }
        } else {
            $timedOut = $true
            # PS 5.1 跑在 .NET Framework 上，Process.Kill(bool) 是 .NET Core 3.0+ 才有的 API，
            # 无参 Kill() 只终止直接进程，留下的 ssh/scp 子进程会继续持有连接。
            # 所以先用 taskkill /T /F 整树端掉，再兜底 Kill()。taskkill 自身也给 5 秒预算，不用 -Wait 无限等。
            try {
                $tk = Start-Process -FilePath 'taskkill' -ArgumentList '/PID', $p.Id, '/T', '/F' -NoNewWindow -PassThru -ErrorAction SilentlyContinue
                if ($tk) {
                    # 复审二 issue 3：辅助进程自己也有生命周期——taskkill 超时就终止它并有界等待，不留孤儿，最后释放对象
                    if (-not $tk.WaitForExit(5000)) {
                        try { $tk.Kill() } catch { }
                        try { $null = $tk.WaitForExit(2000) } catch { }
                    }
                    try { $tk.Dispose() } catch { }
                }
            } catch { }
            try { if (-not $p.HasExited) { $p.Kill() } } catch { }
            try { $null = $p.WaitForExit(5000) } catch { }
            # 只能确认直接进程是否退出；进程树是否全部终止本函数无法逐一核实，调用方措辞须是"已尝试终止"
            try { $killConfirmed = $p.HasExited } catch { }
            $code = -1
        }

        # 2026-09-09 实测踩坑：进程刚退出时重定向文件的句柄可能尚未释放，
        # [System.IO.File]::ReadAllText 会抛 IOException 被 catch 吞掉，stderr 静默丢失——
        # 表现为连接失败时诊断输出一片空白，等于没有排障能力。
        # 改用共享读 + 短重试，确保拿得到 ssh/scp 的真实错误信息。
        $outText = Read-RedirectedText -Path $tmpOut
        $errText = Read-RedirectedText -Path $tmpErr

        return [pscustomobject]@{
            ExitCode = $code; ExitCodeKnown = $exitCodeKnown; TimedOut = $timedOut; KillConfirmed = $killConfirmed
            Output = $outText; ErrorOutput = $errText
            LocalFailure = $localFailure
        }
    } finally {
        Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-RemotePowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$ScriptText,
        [int]$ConnectTimeoutSeconds = 20,
        # 整条命令的总时限（不是建连时限）。默认 120 秒够探测/建目录/清理这类轻量操作用；
        # 真正跑 codex 的那次由调用方按 -TimeoutSeconds 显式放大。
        [int]$OverallTimeoutSeconds = 120
    )
    # codex 审 issue 3：ssh 不存在时 `& ssh` 抛的是 CommandNotFound，并不会更新 $LASTEXITCODE，
    # 于是会读到上一条命令留下的陈旧退出码（很可能是 0），把"本机没装 ssh"误报成"SSH 可达"。
    # 因此先显式解析 ssh.exe，并把"本机依赖缺失"与"远端问题"分成两类返回。
    $sshCmd = Get-Command ssh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $sshCmd) {
        return [pscustomobject]@{
            ExitCode     = -1; ExitCodeKnown = $false; TimedOut = $false
            Output       = ''
            LocalFailure = '本机未找到 ssh 命令（Windows 10/11 可在「设置 → 系统 → 可选功能」里启用 OpenSSH 客户端）'
        }
    }

    # 坑 6：UTF-16LE + Base64，彻底绕开多层引号解析。
    # 坑 11（2026-09-09 复审后实测）：整段脚本编码后塞进一行命令，膨胀约 2.7 倍；Windows 命令行上限 8191 字符，
    # 超过时 sshd 那头的 cmd 只回一句 GBK 的"命令行太长"，本机按 UTF-8 读成一行乱码，极难诊断。
    # 对策：注释行不上传（它们是给本文件读者看的，远端不需要），并在超限之前就明确报错。
    # 模板约束（复审二确认）：下面这个 "^\s*#" 按行剔除不是通用的 PowerShell 注释解析器——
    # 远端模板里不得出现 here-string / 多行字符串内以 # 开头的行，否则会被静默删掉。新增模板内容时必须重查。
    $slim = ((($ScriptText -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n")
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($slim))
    $remoteCmd = "powershell -NoProfile -NonInteractive -EncodedCommand $encoded"
    if ($remoteCmd.Length -gt 7500) {
        return [pscustomobject]@{
            ExitCode = -1; ExitCodeKnown = $false; TimedOut = $false; Output = ''
            LocalFailure = "远端命令行 $($remoteCmd.Length) 字符，超过安全线 7500（针对当前 sshd→cmd 启动链路，为 8191 上限预留约 700 字符外围命令；换 shell 需重估）；需精简远端脚本模板或改为上传脚本文件执行"
        }
    }
    $sshArgs = @(
        '-n'                                          # 坑 3：不让远端进程继承 stdin
        '-o', 'StrictHostKeyChecking=accept-new'
        '-o', 'BatchMode=yes'                         # 密钥认证失败直接报错，不卡在密码提示上
        '-o', "ConnectTimeout=$ConnectTimeoutSeconds"
        # 这里不再用 LogLevel=ERROR 压噪音——它会连真实连接错误一起吞掉（实测见 Remove-SshNoise 注释）。
        # known_hosts 那类告警改由 Remove-SshNoise 按行过滤。
        # codex 审 issue 5（部分采纳）：ConnectTimeout 只管建连，管不住"连上之后对端失联"。
        # 15 秒无响应即断，成本一行。至于"连接正常但远端命令卡死"，交给主流程的 -TimeoutSeconds 兜，
        # 不为此把这里改造成 Start-Process + 三路重定向（代码量翻倍，收益不成比例）。
        '-o', 'ServerAliveInterval=5'
        '-o', 'ServerAliveCountMax=3'
        $Target
        $remoteCmd
    )

    # 坑 7 已由 Invoke-ExternalWithTimeout 从根上解决：stdout/stderr 直接重定向到文件，
    # 不再经过 PowerShell 的 2>&1 管道，也就不会被包成 NativeCommandError 触发 EAP=Stop。
    $r = Invoke-ExternalWithTimeout -FilePath $sshCmd.Source -Arguments $sshArgs -TimeoutSeconds $OverallTimeoutSeconds
    if ($r.LocalFailure) {
        return [pscustomobject]@{ ExitCode = -1; ExitCodeKnown = $false; TimedOut = $false; Output = ''; LocalFailure = $r.LocalFailure }
    }
    # ssh 的诊断信息（连不上/认证失败）走 stderr，与远端脚本的 stdout 合并供上层解析与展示；
    # 只滤掉 known_hosts 这类固定告警，真实错误必须留着，否则故障时无从排查。
    $merged = $r.Output
    $cleanErr = Remove-SshNoise -Text $r.ErrorOutput
    if (-not [string]::IsNullOrWhiteSpace($cleanErr)) { $merged = $merged + "`n" + $cleanErr }
    $localFailure = if ($r.TimedOut) { "ssh 超过 $OverallTimeoutSeconds 秒未返回，已尝试终止本机子进程树（直接进程退出确认: $($r.KillConfirmed)）" } else { $null }
    return [pscustomobject]@{
        ExitCode      = $r.ExitCode
        ExitCodeKnown = $r.ExitCodeKnown
        TimedOut      = $r.TimedOut
        Output        = $merged
        LocalFailure  = $localFailure
    }
}

function Get-RemoteCodexInfo {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [int]$ConnectTimeoutSeconds = 20
    )
    # 坑 2（2026-09-09 订正）：最初以为 packages\standalone\current 这个 Junction 在 SSH 会话下
    # 完全不可用——实测证明只有"执行穿过它的路径"会报重解析点错误，读取元数据
    # （Test-Path / Get-Item -Force 的 .Target）完全正常。当初拿一次执行失败推出了过宽的结论，
    # 结果选了按目录时间猜版本这个次优方案，被 codex 审 issue 2 咬中。
    # 现在首选读 Junction 指向：那是安装器维护的"当前启用版本"权威指针，codex 升级会自动更新；
    # 目录修改时间既不代表版本大小、也不代表当前启用，只在 current 缺失或损坏时兜底。
    $probe = @'
$ProgressPreference = 'SilentlyContinue'
'PROBE_STARTED=1'
function Flatten-Output($items) {
    # 坑 7 的远端镜像：codex 把 "Logged in using ChatGPT" 写在 stderr，
    # 远端 PowerShell 会包成 ErrorRecord，直接 ToString() 会得到 "codex.exe : xxx" 带命令名前缀。
    # 取 Exception.Message 才是干净正文。
    return ((@($items) | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
    }) -join ' ').Trim()
}
$base = Join-Path $env:USERPROFILE '.codex\packages\standalone'
$exe = $null
$how = ''
$cur = Join-Path $base 'current'
if (Test-Path $cur) {
    try {
        $t = @((Get-Item $cur -Force -ErrorAction Stop).Target)
        if ($t.Count -gt 0 -and $t[0]) {
            $cand = Join-Path $t[0] 'bin\codex.exe'
            if (Test-Path $cand) { $exe = $cand; $how = 'junction-target' }
        }
    } catch { }
}
if (-not $exe) {
    $root = Join-Path $base 'releases'
    if (Test-Path $root) {
        $exe = Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object { Join-Path $_.FullName 'bin\codex.exe' } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
        if ($exe) { $how = 'mtime-fallback' }
    }
}
'CODEX_EXE=' + $exe
'CODEX_RESOLVED_BY=' + $how
'AUTH_EXISTS=' + (Test-Path (Join-Path $env:USERPROFILE '.codex\auth.json'))
if ($exe) {
    $vRaw = & $exe --version 2>&1
    'VERSION_RC=' + $LASTEXITCODE
    'CODEX_VERSION=' + (Flatten-Output $vRaw)
    $lRaw = & $exe login status 2>&1
    'LOGIN_RC=' + $LASTEXITCODE
    'LOGIN_STATUS=' + (Flatten-Output $lRaw)
}
'PROBE_DONE=1'
'@
    $r = Invoke-RemotePowerShell -Target $Target -ScriptText $probe -ConnectTimeoutSeconds $ConnectTimeoutSeconds

    # 远端可能夹带 CLIXML / progress 噪音，只挑认识的 KEY=VALUE 行，其余忽略。
    # 预填空值，后续可以直接索引，不用到处 ContainsKey。
    $knownKeys = @('PROBE_STARTED', 'PROBE_DONE', 'CODEX_EXE', 'CODEX_RESOLVED_BY',
                   'AUTH_EXISTS', 'CODEX_VERSION', 'VERSION_RC', 'LOGIN_STATUS', 'LOGIN_RC')
    $fields = @{}
    foreach ($k in $knownKeys) { $fields[$k] = '' }
    foreach ($line in ($r.Output -split "`r?`n")) {
        $t = $line.Trim()
        foreach ($key in $knownKeys) {
            if ($t.StartsWith("$key=")) { $fields[$key] = $t.Substring($key.Length + 1).Trim() }
        }
    }

    $loginText = $fields['LOGIN_STATUS']
    return [pscustomobject]@{
        LocalFailure    = $r.LocalFailure
        ExitCode        = $r.ExitCode
        # codex 审 issue 4：拿整条 ssh 命令的退出码判"SSH 是否可达"会把连接失败和远端脚本失败
        # 混为一谈。远端脚本一进门就打 PROBE_STARTED，以此把两者切开。
        ProbeStarted    = ($fields['PROBE_STARTED'] -eq '1')
        ProbeDone       = ($fields['PROBE_DONE'] -eq '1')
        CodexPath       = $fields['CODEX_EXE']
        ResolvedBy      = $fields['CODEX_RESOLVED_BY']
        CodexVersion    = $fields['CODEX_VERSION']
        # issue 4：路径存在 ≠ 跑得起来，必须看 --version 的真实退出码
        VersionOk       = ($fields['VERSION_RC'] -eq '0')
        AuthExists      = ($fields['AUTH_EXISTS'] -eq 'True')
        LoginStatus     = $loginText
        # codex 审 issue 1：只匹配 "Logged in" 会把 API key 登录也放行，导致静默走成按量付费，
        # 与"借第二份订阅额度"的初衷相悖。必须锁死 ChatGPT 订阅，且登录命令本身退出码为 0。
        LoggedInChatGPT = (($fields['LOGIN_RC'] -eq '0') -and ($loginText -match 'Logged in using ChatGPT'))
        RawOutput       = $r.Output
    }
}

function Invoke-ScpTransfer {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [int]$ConnectTimeoutSeconds = 20,
        # 传输也必须有总时限：issue 1 指出上传卡住时，已经传过去的代码会一直留在远端
        [int]$OverallTimeoutSeconds = 180
    )
    $scpCmd = Get-Command scp -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $scpCmd) {
        return [pscustomobject]@{ Ok = $false; ExitCode = -1; ExitCodeKnown = $false; TimedOut = $false; Output = ''; LocalFailure = '本机未找到 scp 命令（随 OpenSSH 客户端一起安装）' }
    }
    $scpArgs = @(
        '-o', 'StrictHostKeyChecking=accept-new'
        '-o', 'BatchMode=yes'
        '-o', "ConnectTimeout=$ConnectTimeoutSeconds"
        # 同 Invoke-RemotePowerShell：不用 LogLevel=ERROR，噪音交给 Remove-SshNoise 过滤
        '-o', 'ServerAliveInterval=5'
        '-o', 'ServerAliveCountMax=3'
        $Source
        $Destination
    )
    $r = Invoke-ExternalWithTimeout -FilePath $scpCmd.Source -Arguments $scpArgs -TimeoutSeconds $OverallTimeoutSeconds
    if ($r.LocalFailure) {
        return [pscustomobject]@{ Ok = $false; ExitCode = -1; ExitCodeKnown = $false; TimedOut = $false; Output = ''; LocalFailure = $r.LocalFailure }
    }
    $merged = $r.Output
    $cleanErr = Remove-SshNoise -Text $r.ErrorOutput
    if (-not [string]::IsNullOrWhiteSpace($cleanErr)) { $merged = $merged + "`n" + $cleanErr }
    # 退出码在 PS 5.1 下可能压根读不到，所以不可读时不据此判失败（否则每次传输都会误判为失败）；
    # 真正的判据交给调用方——文件有没有落地、大小对不对，那比退出码更贴近"传输是否成功"本身。
    return [pscustomobject]@{
        Ok           = ((-not $r.TimedOut) -and ((-not $r.ExitCodeKnown) -or ($r.ExitCode -eq 0)))
        ExitCode     = $r.ExitCode
        ExitCodeKnown = $r.ExitCodeKnown
        TimedOut     = $r.TimedOut
        Output       = $merged
        LocalFailure = $(if ($r.TimedOut) { "scp 超过 $OverallTimeoutSeconds 秒未完成，已尝试终止本机子进程树（直接进程退出确认: $($r.KillConfirmed)）" } else { $null })
    }
}

# 远端执行：上传 → 执行 → 拉回 → 清理。
# 设计取舍（2026-09-09 实测后定）：远端完整复刻本机的 Start-Process 三路重定向，
# 产物（raw.jsonl / stderr.txt / final.txt）先落在远端再 scp 拉回，而不是让 ssh 转发 stdout。
# 理由是 scp 传的是字节流，不受 ssh 通道编码与缓冲影响；raw.jsonl 的纯 JSONL 约定得以原样保持。
# 代价是多两次网络往返（约 0.5 秒），相对 codex 几十秒的思考时间可以忽略。
function Invoke-RemoteCodexExec {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$CodexPath,
        [Parameter(Mandatory = $true)][string]$PromptPath,
        [Parameter(Mandatory = $true)][string]$SchemaPath,
        [Parameter(Mandatory = $true)][string]$RawOutputPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [Parameter(Mandatory = $true)][string]$FinalPath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [AllowEmptyString()][string]$Model = ''
    )

    $diag = New-Object System.Collections.Generic.List[string]
    $runId = 'run-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
    # scp 的 host:path 语法会跟 Windows 盘符里的冒号打架，所以远端一律走"相对家目录 + 正斜杠"，
    # 只有远端 PowerShell 内部才用绝对路径。
    $remoteRel = ".codex-bridge-runs/$runId"
    $remoteDir = ''

    # codex 审 issue 3（部分采纳）：-Model 是会被拼进远端脚本的外部输入，限定字符集。
    # 路径含空格的 argv quoting 问题不在此处理——本机路径同样存在，SKILL.md「已知限制」已记录并接受，
    # 要修应单开 commit 同时修两侧，不借远端改造之名做本机重构。
    if (-not [string]::IsNullOrWhiteSpace($Model) -and ($Model -notmatch '^[A-Za-z0-9._\-\[\]]+$')) {
        return [pscustomobject]@{
            ExitCode = -1; ExitCodeKnown = $false; TimedOut = $false; PromptPurged = $null
            Failure = "[param] -Model 含非法字符（仅允许字母数字与 . _ - [ ]）：$Model"
            RemoteDir = ''; RunId = $runId; Diagnostics = ''
        }
    }
    # codex 审 issue 6：连续 Replace 会让先插入的值里的 "<<...>>" 被后续替换二次解释。
    # 插入值一律不得含占位符起始符，从源头堵死。
    foreach ($v in @($CodexPath, $Model)) {
        if ($v -and $v.Contains('<<')) {
            return [pscustomobject]@{
                ExitCode = -1; ExitCodeKnown = $false; TimedOut = $false; PromptPurged = $null
                Failure = "[param] 注入远端脚本的值不得包含 '<<'：$v"
                RemoteDir = ''; RunId = $runId; Diagnostics = ''
            }
        }
    }

    # 复审意见：失败结果必须保留已知状态（超时 / 退出码 / 输入清理），未知就留 null，
    # 不把"不知道"表示成"确定未超时"。这些变量随流程推进被赋值，$fail 经 & 调用时读取当前值（PS 动态作用域）。
    # 复审二 issue 2：ExitCode 与 ExitCodeKnown 必须描述同一事实——拿到远端退出码就原样返回，没拿到才 -1 + false。
    $knownTimedOut = $null; $knownExitCode = $null; $knownExitCodeKnown = $false; $knownPromptPurged = $null
    $fail = {
        param($stage, $msg)
        return [pscustomobject]@{
            ExitCode = $(if ($null -ne $knownExitCode) { $knownExitCode } else { -1 })
            ExitCodeKnown = $knownExitCodeKnown; TimedOut = $knownTimedOut; PromptPurged = $knownPromptPurged
            Failure = "[$stage] $msg"
            RemoteDir = $remoteDir; RunId = $runId; Diagnostics = ($diag -join "`n")
        }
    }

    # ---- 1) 远端建目录 ----
    # 建目录时顺带做陈旧目录 GC（codex 审 issue 2）：
    # 本机断线、宿主进程被杀等场景下，本机的 finally 根本执行不到，遗留目录里躺着被审代码原文。
    # 这里给它一个兜底的过期回收，6 小时远超任何一次正常审核的时长。
    $mkTemplate = @'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:USERPROFILE '.codex-bridge-runs'
if (Test-Path $root) {
    $cut = (Get-Date).AddHours(-6)
    Get-ChildItem $root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cut } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}
$d = Join-Path $root '<<RUNID>>'
New-Item -ItemType Directory -Path $d -Force | Out-Null
'REMOTE_DIR=' + $d
'@
    $mk = Invoke-RemotePowerShell -Target $Target -ScriptText $mkTemplate.Replace('<<RUNID>>', $runId)
    if ($mk.LocalFailure) { return (& $fail 'local' $mk.LocalFailure) }
    foreach ($line in ($mk.Output -split "`r?`n")) {
        $t = $line.Trim()
        if ($t.StartsWith('REMOTE_DIR=')) { $remoteDir = $t.Substring('REMOTE_DIR='.Length).Trim() }
    }
    if ([string]::IsNullOrWhiteSpace($remoteDir)) {
        return (& $fail 'mkdir' "远端临时目录创建失败。ssh exit=$($mk.ExitCode)`n$($mk.Output)")
    }
    $diag.Add("remoteDir = $remoteDir")

    try {
        # ---- 2) 上传 prompt + schema ----
        foreach ($pair in @(@($PromptPath, 'prompt.txt'), @($SchemaPath, 'schema.json'))) {
            $up = Invoke-ScpTransfer -Source $pair[0] -Destination ("{0}:{1}/{2}" -f $Target, $remoteRel, $pair[1])
            if (-not $up.Ok) {
                $why = if ($up.LocalFailure) { $up.LocalFailure } else { "scp exit=$($up.ExitCode)`n$($up.Output)" }
                return (& $fail 'upload' "上传 $($pair[1]) 失败：$why")
            }
        }
        $diag.Add('uploaded: prompt.txt, schema.json')

        # ---- 3) 远端执行 ----
        # 参数与本机路径逐项对齐（见本文件 Build codex arguments 段）。
        # -IncludeProject 与 -Remote 互斥，所以远端恒为 --ignore-rules。
        $modelLine = if ([string]::IsNullOrWhiteSpace($Model)) { '' } else { "`$argList += @('-m','" + $Model.Replace("'", "''") + "')" }
        $execTemplate = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
'REMOTE_EXEC_STARTED=1'
$d      = '<<REMOTE_DIR>>'
$exe    = '<<CODEX_EXE>>'
$timeoutMs = <<TIMEOUT_MS>>
$in     = Join-Path $d 'prompt.txt'
$out    = Join-Path $d 'raw.jsonl'
$err    = Join-Path $d 'stderr.txt'
$final  = Join-Path $d 'final.txt'
$schema = Join-Path $d 'schema.json'
# 复审 issue 1：启动 codex 之前先按本机记录的字节数校验两份输入。scp 退出码在 PS 5.1 下读不到，
# 截断的 prompt 照样能让 codex 产出一份"合法"结论，下游无从察觉——这是审核可信度问题，不是传输问题。
$expPrompt = <<PROMPT_SIZE>>
$expSchema = <<SCHEMA_SIZE>>
$actPrompt = $(if (Test-Path $in)     { (Get-Item $in).Length }     else { -1 })
$actSchema = $(if (Test-Path $schema) { (Get-Item $schema).Length } else { -1 })
if (($actPrompt -ne $expPrompt) -or ($actSchema -ne $expSchema)) {
    'UPLOAD_MISMATCH=prompt ' + $actPrompt + '/' + $expPrompt + ' bytes, schema ' + $actSchema + '/' + $expSchema + ' bytes'
    Remove-Item -LiteralPath $in -Force -ErrorAction SilentlyContinue
    'PROMPT_PURGED=' + $(if (Test-Path $in) { '0' } else { '1' })
    'REMOTE_EXEC_DONE=1'
    exit 0
}
try {
    $argList = @('exec','--sandbox','read-only','--color','never','--json',
                 '-o',$final,'--output-schema',$schema,'--skip-git-repo-check','-C',$d,'--ignore-rules')
<<MODEL_LINE>>
    $p = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $d `
         -RedirectStandardInput $in -RedirectStandardOutput $out -RedirectStandardError $err `
         -NoNewWindow -PassThru
    if ($p.WaitForExit($timeoutMs)) {
        # 与本机路径同源的坑：WaitForExit(ms) 刚返回时 ExitCode 可能还没 ready，甚至取到 $null。
        # 这里沿用本机的 null -> 0 语义以保持两条路径一致，但额外打一个 UNKNOWN 标记，
        # 让上层知道这个 0 是推断值而非真实退出码（真正的成败判据仍是 final.txt 非空）。
        $p.WaitForExit()
        $code = $null
        try { $code = $p.ExitCode } catch { }
        if ($null -eq $code) { 'CODEX_EXIT_UNKNOWN=1'; $code = 0 }
        'CODEX_EXIT=' + $code
        'CODEX_TIMEDOUT=0'
    } else {
        # PS 5.1 跑在 .NET Framework 上，没有 Kill(bool)，无参 Kill() 只终止直接进程。
        # 先 taskkill 整树端掉，再兜底 Kill()，最后确认终止真的完成，并回报终止结果。
        try { Start-Process -FilePath 'taskkill' -ArgumentList '/PID',$p.Id,'/T','/F' -NoNewWindow -Wait -ErrorAction SilentlyContinue } catch { }
        try { if (-not $p.HasExited) { $p.Kill() } } catch { }
        try { $null = $p.WaitForExit(5000) } catch { }
        'CODEX_KILLED=' + $(if ($p.HasExited) { '1' } else { '0' })
        'CODEX_EXIT=-1'
        'CODEX_TIMEDOUT=1'
    }
    # 三个产物的大小都回报，本机据此校验 scp 是否完整传回（比退出码可靠，见 Invoke-ScpTransfer 注释）
    'FINAL_SIZE=' + $(if (Test-Path $final) { (Get-Item $final).Length } else { -1 })
    'RAW_SIZE='   + $(if (Test-Path $out)   { (Get-Item $out).Length }   else { -1 })
    'ERR_SIZE='   + $(if (Test-Path $err)   { (Get-Item $err).Length }   else { -1 })
} finally {
    # codex 审 issue 2 最要紧的一条：prompt.txt 里是被审代码的原文。
    # 本机断线、宿主进程被杀时，本机的 finally 根本执行不到——所以远端脚本自己
    # 第一时间销毁输入，不把安全性托付在"对端还活着"这个假设上。
    Remove-Item -LiteralPath $in -Force -ErrorAction SilentlyContinue
    'PROMPT_PURGED=' + $(if (Test-Path $in) { '0' } else { '1' })
}
'REMOTE_EXEC_DONE=1'
'@
        $promptSize = (Get-Item -LiteralPath $PromptPath).Length
        $schemaSize = (Get-Item -LiteralPath $SchemaPath).Length
        $execScript = $execTemplate.
            Replace('<<REMOTE_DIR>>', $remoteDir.Replace("'", "''")).
            Replace('<<CODEX_EXE>>', $CodexPath.Replace("'", "''")).
            Replace('<<TIMEOUT_MS>>', [string]($TimeoutSeconds * 1000)).
            Replace('<<PROMPT_SIZE>>', [string]$promptSize).
            Replace('<<SCHEMA_SIZE>>', [string]$schemaSize).
            Replace('<<MODEL_LINE>>', $modelLine)

        # 本机等待上限 = 远端预算 + 90 秒余量。这一次是真的实现了（见 Invoke-ExternalWithTimeout），
        # 不再是注释里的空头承诺：远端到点会自己 Kill 并正常返回，本机这层只兜"远端连 Kill 都没做成"。
        $ex = Invoke-RemotePowerShell -Target $Target -ScriptText $execScript `
            -ConnectTimeoutSeconds 20 -OverallTimeoutSeconds ($TimeoutSeconds + 90)
        # 复审二 issue 1：先解析、先记状态，再做任何判断或返回。
        # ssh 超时 / DONE 缺失 / 字段不全时，远端可能已经把 CODEX_TIMEDOUT、PROMPT_PURGED 传回来了，
        # 若先返回再解析，这些到手的事实就会被丢掉。
        $ef = @{}
        foreach ($line in ($ex.Output -split "`r?`n")) {
            $t = $line.Trim()
            foreach ($k in @('REMOTE_EXEC_STARTED', 'REMOTE_EXEC_DONE', 'UPLOAD_MISMATCH', 'CODEX_EXIT', 'CODEX_TIMEDOUT',
                             'CODEX_EXIT_UNKNOWN', 'CODEX_KILLED', 'FINAL_SIZE', 'RAW_SIZE', 'ERR_SIZE', 'PROMPT_PURGED')) {
                if ($t.StartsWith("$k=")) { $ef[$k] = $t.Substring($k.Length + 1).Trim() }
            }
        }
        if ($ef.ContainsKey('CODEX_TIMEDOUT')) { $knownTimedOut = ($ef['CODEX_TIMEDOUT'] -eq '1') }
        if ($ef.ContainsKey('CODEX_EXIT')) {
            $parsedExit = 0
            if ([int]::TryParse($ef['CODEX_EXIT'], [ref]$parsedExit)) { $knownExitCode = $parsedExit }
        }
        $knownExitCodeKnown = ($ef.ContainsKey('CODEX_EXIT') -and (-not $ef.ContainsKey('CODEX_EXIT_UNKNOWN')))
        if ($ef.ContainsKey('PROMPT_PURGED')) { $knownPromptPurged = ($ef['PROMPT_PURGED'] -eq '1') }

        if ($ex.LocalFailure) {
            # 本机 ssh 明确超时：即便远端没回报，也是已知超时；远端已回报 1 时不被覆盖
            if ($ex.TimedOut) { $knownTimedOut = $true }
            return (& $fail 'exec' $ex.LocalFailure)
        }

        # codex 审 issue 5：不能把"执行状态未知"压成"确定未超时"。
        # 启动标记 / 完成标记 / 状态字段任一缺失，都必须回报明确失败，而不是 Failure=null。
        if (-not $ef.ContainsKey('REMOTE_EXEC_STARTED')) {
            return (& $fail 'exec' "远端执行脚本没能启动。ssh exit=$($ex.ExitCode)`n$($ex.Output)")
        }
        if ($ef.ContainsKey('UPLOAD_MISMATCH')) {
            return (& $fail 'upload' "上传后远端校验大小不一致，未启动 codex：$($ef['UPLOAD_MISMATCH'])")
        }
        if (-not $ef.ContainsKey('REMOTE_EXEC_DONE')) {
            return (& $fail 'exec' "远端执行中断，未跑到结尾（脚本异常或连接断开），执行状态未知。ssh exit=$($ex.ExitCode)`n$($ex.Output)")
        }
        if ((-not $ef.ContainsKey('CODEX_EXIT')) -or (-not $ef.ContainsKey('CODEX_TIMEDOUT'))) {
            return (& $fail 'exec' "远端未回报完整执行状态（缺 CODEX_EXIT / CODEX_TIMEDOUT）。ssh exit=$($ex.ExitCode)")
        }

        # 已知状态在解析后第一时间记过了（见上），这里只记诊断
        $diag.Add("remote exec: exit=$($ef['CODEX_EXIT']) timedOut=$($ef['CODEX_TIMEDOUT']) finalSize=$($ef['FINAL_SIZE']) rawSize=$($ef['RAW_SIZE'])")
        if ($ef.ContainsKey('CODEX_EXIT_UNKNOWN')) {
            $diag.Add('警告：远端取不到真实退出码，exit=0 为推断值，成败以 final.txt 为准')
        }
        if ($ef.ContainsKey('CODEX_KILLED') -and $ef['CODEX_KILLED'] -ne '1') {
            $diag.Add('警告：远端超时后未能确认 codex 进程已终止')
        }
        if ($ef.ContainsKey('PROMPT_PURGED') -and $ef['PROMPT_PURGED'] -ne '1') {
            Write-Warning "远端 prompt.txt（含被审代码原文）未能删除，请手工检查：$remoteDir"
        }

        # ---- 4) 拉回产物 ----
        # codex 审 issue 4：先下到 .part 再原子改名。scp 中途断掉会留下"非空但残缺"的文件，
        # 直接落到正式路径会被上层"存在且非空"的判据误判为成功。
        # final.txt 是核心产物，取不回来直接判失败；raw/stderr 属诊断材料，缺失只记 diag。
        $pullFailures = @()
        $pullPlan = @(
            @{ Name = 'raw.jsonl';  Local = $RawOutputPath; SizeKey = 'RAW_SIZE' }
            @{ Name = 'stderr.txt'; Local = $StderrPath;    SizeKey = 'ERR_SIZE' }
            @{ Name = 'final.txt';  Local = $FinalPath;     SizeKey = 'FINAL_SIZE' }
        )
        foreach ($item in $pullPlan) {
            $expected = -1
            if ($ef.ContainsKey($item.SizeKey)) { [void][int]::TryParse($ef[$item.SizeKey], [ref]$expected) }
            if ($expected -lt 0) {
                # 远端压根没生成这个文件（例如 codex 失败时不会有 final.txt），不必尝试拉取
                $diag.Add("远端无 $($item.Name)（未生成）")
                $pullFailures += $item.Name
                continue
            }

            $tmpDest = $item.Local + '.part'
            Remove-Item -LiteralPath $tmpDest -Force -ErrorAction SilentlyContinue
            $dl = Invoke-ScpTransfer -Source ("{0}:{1}/{2}" -f $Target, $remoteRel, $item.Name) -Destination $tmpDest

            # 判据不是 scp 退出码（PS 5.1 下读不到），而是"文件落地了且大小与远端一致"——
            # 这同时堵住了 issue 4 说的"传输中断留下非空残缺文件被当成成功"。
            $actual = if (Test-Path -LiteralPath $tmpDest) { (Get-Item -LiteralPath $tmpDest).Length } else { -1 }
            if ($dl.Ok -and ($actual -eq $expected)) {
                Move-Item -LiteralPath $tmpDest -Destination $item.Local -Force
            } else {
                Remove-Item -LiteralPath $tmpDest -Force -ErrorAction SilentlyContinue
                $why = if ($dl.LocalFailure) { $dl.LocalFailure } else { "远端 $expected 字节 / 本地收到 $actual 字节；$($dl.Output)" }
                $diag.Add("拉回 $($item.Name) 失败：$why")
                $pullFailures += $item.Name
            }
        }
        # 复审 issue 2：远端已明确超时时，final.txt 缺失是超时的自然结果，不是"下载失败"——
        # 走正常返回让 wrapper 记 timedOut=true，与本机路径的超时表现同语义；只有非超时下取不回才判失败。
        if (($pullFailures -contains 'final.txt') -and (-not $knownTimedOut)) {
            return (& $fail 'download' "核心产物 final.txt 未能取回（远端 FINAL_SIZE=$($ef['FINAL_SIZE'])）。$($diag -join '; ')")
        }

        return [pscustomobject]@{
            ExitCode  = $(if ($ef.ContainsKey('CODEX_EXIT')) { [int]$ef['CODEX_EXIT'] } else { -1 })
            # 远端也是 PS 5.1，Start-Process 同样读不到退出码；UNKNOWN 标记在即表示 exit=0 是推断值
            ExitCodeKnown = (-not $ef.ContainsKey('CODEX_EXIT_UNKNOWN'))
            TimedOut  = ($ef.ContainsKey('CODEX_TIMEDOUT') -and $ef['CODEX_TIMEDOUT'] -eq '1')
            PromptPurged = $(if ($ef.ContainsKey('PROMPT_PURGED')) { $ef['PROMPT_PURGED'] -eq '1' } else { $null })
            Failure   = $null
            RemoteDir = $remoteDir
            RunId     = $runId
            Diagnostics = ($diag -join "`n")
        }
    } finally {
        # ---- 5) 清理远端（务必执行）----
        # prompt.txt 里含被审代码的原文，任何路径下都不能留在那台机器上。
        # codex 审 issue 6：不信任远端回传的 REMOTE_DIR 去做递归删除。
        # 改为在远端按"固定根目录 + 本次 runId"重新拼路径，并校验它确实位于根目录之下、
        # 且末级目录名恰为 runId，通过后才 Remove-Item -Recurse。
        $clTemplate = @'
$root = Join-Path $env:USERPROFILE '.codex-bridge-runs'
$rid  = '<<RUNID>>'
$d    = Join-Path $root $rid
$ok = $false
if (-not (Test-Path $d)) {
    $ok = $true
} else {
    $full     = (Resolve-Path -LiteralPath $d).Path
    $rootFull = (Resolve-Path -LiteralPath $root).Path
    if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -and ((Split-Path $full -Leaf) -eq $rid)) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
        $ok = -not (Test-Path $full)
    }
}
'CLEANED=' + $ok
'@
        if (-not [string]::IsNullOrWhiteSpace($remoteDir)) {
            $cl = Invoke-RemotePowerShell -Target $Target -ScriptText $clTemplate.Replace('<<RUNID>>', $runId) -OverallTimeoutSeconds 60
            if ($cl.Output -notmatch 'CLEANED=True') {
                Write-Warning "远端临时目录可能未清理干净（内含被审代码原文），请手工确认：$remoteDir"
            }
        }
    }
}

function Convert-ToJsonString {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return 'null' }
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return '"' + $escaped + '"'
}

function New-BridgePrompt {
    param(
        [Parameter(Mandatory = $true)][string]$TaskType,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$OutputLanguage,
        [Parameter(Mandatory = $true)][string]$TaskBrief,
        [Parameter(Mandatory = $false)][string]$ContextBlock
    )

    $languageInstruction = if ($OutputLanguage -eq "zh-CN") {
        "All human-readable strings in the JSON must be written in Simplified Chinese."
    } else {
        "All human-readable strings in the JSON must be written in English."
    }

    $contextSection = if ($ContextBlock) {
        "`nProvided context files (read-only reference, do not assume you can modify them):`n$ContextBlock`n"
    } else {
        ""
    }

    @"
You are assisting Claude Code through a local Codex CLI bridge.
You are a SECOND-OPINION reviewer, not the primary executor.
Task type: $TaskType
Execution mode: $Mode
Output language: $OutputLanguage

Rules:
- Stay strictly within the requested review subtask.
- Do NOT claim you changed files, ran tests, or verified behavior.
- Do NOT attempt to write files or execute shell commands.
- Claude Code remains the final decision maker and executor.
- Keep the response concrete, actionable, and implementation-oriented.
- Prioritize concrete issues (ambiguity, contradictions, missing NOT NULL constraints, unhandled edge cases, security risks, inconsistency between sections) over generic best-practice advice.
- If the task brief references files but no file content is provided, review the brief text only and note which files would need to be read for a deeper review.
- $languageInstruction

Mode semantics:
- advice-only: provide analysis and recommendations only.
- draft-only: you may provide draft wording or draft patches, but clearly mark them as NOT APPLIED.

Return your final answer as a single JSON object with this exact top-level shape:
{
  "task_type": "$TaskType",
  "mode": "$Mode",
  "summary": "1-2 sentence high-level verdict",
  "issues": [
    {
      "severity": "critical|high|medium|low",
      "category": "ambiguity|contradiction|missing-constraint|edge-case|security|performance|readability|other",
      "location": "file path or section name, if identifiable",
      "problem": "what is wrong",
      "suggestion": "concrete fix suggestion"
    }
  ],
  "recommendations": ["high-level recommendation 1", "..."],
  "risks": ["risk 1", "..."],
  "confidence": "low|medium|high",
  "notes_for_claude_code": "any meta-notes for Claude Code integrating this review"
}
$contextSection
Task brief:
$TaskBrief
"@
}

function Build-ContextBlock {
    param(
        [Parameter(Mandatory = $true)][string[]]$Files,
        [Parameter(Mandatory = $true)][string]$BaseDir,
        [Parameter(Mandatory = $true)][int]$MaxChars
    )
    $sb = New-Object System.Text.StringBuilder
    $total = 0
    foreach ($f in $Files) {
        $path = if ([System.IO.Path]::IsPathRooted($f)) { $f } else { Join-Path $BaseDir $f }
        if (-not (Test-Path -LiteralPath $path)) {
            $null = $sb.AppendLine("<file path=`"$f`" status=`"missing`"/>")
            continue
        }
        $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        $len = $content.Length
        if (($total + $len) -gt $MaxChars) {
            $remaining = $MaxChars - $total
            if ($remaining -le 200) {
                $null = $sb.AppendLine("<file path=`"$f`" status=`"skipped-context-budget`"/>")
                continue
            }
            $content = $content.Substring(0, $remaining) + "`n...[truncated by MaxContextChars]..."
            $len = $remaining
        }
        $null = $sb.AppendLine("<file path=`"$f`">")
        $null = $sb.AppendLine($content)
        $null = $sb.AppendLine("</file>")
        $total += $len
    }
    return $sb.ToString()
}

# ---------- 远端订阅模式：互斥校验 + 预检早退 ----------
# 放在 Prompt resolution 之前，因为 -RemotePreflight 只验链路，不需要 prompt。
if ($Remote -and $Api) {
    throw "-Remote 与 -Api 互斥：前者用远端机器的 ChatGPT 订阅登录态，后者用中转 API key，两者都在决定认证与计费路径。请只选一种，并先向用户显式确认走哪条。"
}
if ($Remote -and $IncludeProject) {
    throw "-Remote 与 -IncludeProject 互斥：远端机器上没有本项目文件，--add-dir 无从谈起。请改用 -ContextFiles（Claude 在本机读取后拼入 prompt，随 prompt 一起送到远端）。"
}
if ($RemotePreflight -and -not $Remote) {
    throw "-RemotePreflight 需要配合 -Remote 使用。"
}

if ($RemotePreflight) {
    Write-Host "[remote-preflight] target = $RemoteTarget"
    $info = Get-RemoteCodexInfo -Target $RemoteTarget
    $preflightOk = $true

    # codex 审 issue 4 + recommendation：先报清楚"卡在哪一层"，再给排查建议。
    # 四层依次为 local（本机依赖）→ ssh（连接）→ codex（可执行）→ auth（认证类型）。
    # 原来一律提示 Tailscale/sshd/公钥，会把"本机没装 ssh""远端脚本报错"这类问题指错方向。
    if ($info.LocalFailure) {
        Write-Host "  [FAIL] stage=local  $($info.LocalFailure)"
        $preflightOk = $false
    } elseif (-not $info.ProbeStarted) {
        Write-Host "  [FAIL] stage=ssh  远端探测脚本没能启动"
        # 刻意不展示 ssh 退出码：PS 5.1 的 Start-Process 读不到子进程退出码，
        # 打出来只会是误导性的 "exit 0"。ssh 的真实原因在 stderr 里。
        $sshLines = (($info.RawOutput -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 3)
        foreach ($l in $sshLines) { Write-Host "         ssh: $($l.Trim())" }
        Write-Host "         按序排查：两端 Tailscale 是否都在线（tailscale status）"
        Write-Host "                   远端 sshd 是否在跑（Get-Service sshd）"
        Write-Host "                   公钥是否在远端 C:\ProgramData\ssh\administrators_authorized_keys"
        Write-Host "                   远端主机密钥是否变更（本机 known_hosts 冲突）"
        $preflightOk = $false
    } else {
        Write-Host "  [ OK ] stage=ssh  远端探测脚本已启动"
        if (-not $info.ProbeDone) {
            Write-Host "  [WARN] 远端探测未跑到结尾，以下结论可能不完整"
        }

        if ([string]::IsNullOrWhiteSpace($info.CodexPath)) {
            Write-Host "  [FAIL] stage=codex  远端未找到 codex.exe"
            Write-Host "         已查：~\.codex\packages\standalone\current（Junction 指向）与 releases\*\bin\"
            $preflightOk = $false
        } elseif (-not $info.VersionOk) {
            # issue 4：路径存在 ≠ 跑得起来（缺 DLL / 权限不足 / 文件损坏都可能），不能算通过
            Write-Host "  [FAIL] stage=codex  找到了 codex.exe 但执行失败: $($info.CodexVersion)"
            Write-Host "         path = $($info.CodexPath)"
            $preflightOk = $false
        } else {
            Write-Host "  [ OK ] stage=codex  $($info.CodexVersion)"
            Write-Host "         path = $($info.CodexPath)  (resolved by $($info.ResolvedBy))"
            if ($info.ResolvedBy -eq 'mtime-fallback') {
                Write-Host "  [WARN] current 这个 Junction 没读到，退回了按目录时间猜版本；"
                Write-Host "         若远端存在多个 release 残留，有可能选到并非当前启用的版本"
            }
        }

        if (-not $info.AuthExists) {
            Write-Host "  [FAIL] stage=auth  远端 .codex\auth.json 不存在，那台机器没登录过 codex"
            $preflightOk = $false
        } elseif (-not $info.LoggedInChatGPT) {
            Write-Host "  [FAIL] stage=auth  不是 ChatGPT 订阅登录: $($info.LoginStatus)"
            Write-Host "         -Remote 的前提就是借远端那份订阅额度；若远端实为 API key 认证，"
            Write-Host "         继续走下去会静默变成按量付费。需到那台机器前面跑 codex login"
            Write-Host "         （浏览器 OAuth 流程，SSH 里做不了）"
            $preflightOk = $false
        } else {
            Write-Host "  [ OK ] stage=auth  $($info.LoginStatus)"
        }
    }

    # 机器可读摘要：中文说明在某些终端编码下会花，这行保证判定始终可靠
    if ($preflightOk) {
        Write-Host "REMOTE_PREFLIGHT_RESULT=PASS"
        exit 0
    } else {
        Write-Host "REMOTE_PREFLIGHT_RESULT=FAIL"
        Write-Host "---- raw remote output ----"
        Write-Host $info.RawOutput
        exit 1
    }
}

# ---------- Prompt resolution ----------
if ([string]::IsNullOrWhiteSpace($Prompt)) {
    if ([string]::IsNullOrWhiteSpace($PromptFile)) {
        throw "必须提供 -Prompt 或 -PromptFile。"
    }
    if (-not (Test-Path -LiteralPath $PromptFile)) {
        throw "Prompt 文件不存在: $PromptFile"
    }
    $Prompt = Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8
}

# ---------- Sanity checks ----------
# -Remote 时 codex 跑在远端，本机装没装都无所谓；远端可用性由 -RemotePreflight 与执行前探测负责
if (-not $Remote -and -not (Get-Command codex -ErrorAction SilentlyContinue)) {
    throw "当前机器未找到 codex 命令。请先安装 Codex CLI 并 `codex login`。"
}

if (-not (Test-Path -LiteralPath $WorkingDirectory)) {
    throw "WorkingDirectory 不存在: $WorkingDirectory"
}

$resolvedWorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path

# ---------- Incompatibility guard ----------
# -IncludeProject 和 -ContextFiles 互斥
if ($IncludeProject -and $ContextFiles -and $ContextFiles.Count -gt 0) {
    throw "-IncludeProject 和 -ContextFiles 不能同时使用。前者让 Codex 直接读项目文件，后者让 Claude 读取后拼入 prompt。请只选一种。"
}

# ---------- Safe workspace & output paths ----------
# Codex CLI 的 websocket header 无法处理非 ASCII 路径（含中文等），
# 所以 codex 的 -C 参数永远指向一个安全的英文工作区。
$codexSafeWorkspace = Join-Path $env:TEMP "codex-bridge-workspace"
if (-not (Test-Path -LiteralPath $codexSafeWorkspace)) {
    New-Item -ItemType Directory -Path $codexSafeWorkspace -Force | Out-Null
}

$hasNonAscii = $resolvedWorkingDirectory -match '[^\x00-\x7F]'

# 如果用户开了 -IncludeProject 但 WorkingDirectory 含非 ASCII，不能用 --add-dir
# （会触发 Codex websocket header 的 UTF-8 bug）。直接报错并建议改用 -ContextFiles。
if ($IncludeProject -and $hasNonAscii) {
    throw "-IncludeProject 需要 Codex 通过 --add-dir 读取 WorkingDirectory，但当前 WorkingDirectory 含非 ASCII 字符（如中文），会触发 Codex CLI 的 websocket header UTF-8 bug。请改用 -ContextFiles 让 Claude 读取后拼入 prompt。"
}

$outputBaseDir = if ($hasNonAscii) {
    Join-Path $codexSafeWorkspace "runs"
} else {
    Join-Path $resolvedWorkingDirectory "tmp\codex-runs"
}

$outputDirectory = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputBaseDir
} else {
    # PS5.1 中 Split-Path 的 -LiteralPath 与 -Parent 分属不同参数集（PS7 才合并），
    # 同时传会报 "Parameter set cannot be resolved"，故用 .NET 方法。
    [System.IO.Path]::GetDirectoryName($OutputPath)
}

if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

    # 清理 7 天前的旧文件，避免无限累积。
    # 防误删双保险：
    #   1. 只在"默认 outputBaseDir"里清理；用户传入自定义 -OutputPath 的目录不自动清理
    #   2. 即使触发清理，也只删符合 bridge 命名规则的文件（codex_*.{prompt.txt|raw.jsonl|stderr.txt|final.txt|json}）
    $isDefaultOutputDir = [string]::IsNullOrWhiteSpace($OutputPath) -and ($outputDirectory -eq $outputBaseDir)
    if ($isDefaultOutputDir) {
        try {
            $bridgePatterns = @('codex_*.prompt.txt', 'codex_*.raw.jsonl', 'codex_*.stderr.txt', 'codex_*.final.txt', 'codex_*.json')
            foreach ($pat in $bridgePatterns) {
                Get-ChildItem -LiteralPath $outputDirectory -File -Filter $pat -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
                    Remove-Item -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $fileToken = Get-SafeFileToken -Value $TaskType
    if ([string]::IsNullOrWhiteSpace($fileToken)) { $fileToken = "general-assist" }
    $OutputPath = Join-Path $outputDirectory ("codex_{0}_{1}.json" -f $fileToken, $timestamp)
}

$rawOutputPath = [System.IO.Path]::ChangeExtension($OutputPath, ".raw.jsonl")
$stderrOutputPath = [System.IO.Path]::ChangeExtension($OutputPath, ".stderr.txt")
$promptPath = [System.IO.Path]::ChangeExtension($OutputPath, ".prompt.txt")
$finalMessagePath = [System.IO.Path]::ChangeExtension($OutputPath, ".final.txt")

# ---------- Write review schema once (for --output-schema) ----------
$schemaPath = Join-Path $codexSafeWorkspace "review-schema.json"
$reviewSchema = @'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["task_type", "mode", "summary", "issues", "recommendations", "risks", "confidence", "notes_for_claude_code"],
  "properties": {
    "task_type": {"type": "string"},
    "mode": {"type": "string"},
    "summary": {"type": "string"},
    "issues": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["severity", "category", "location", "problem", "suggestion"],
        "properties": {
          "severity": {"type": "string", "enum": ["critical", "high", "medium", "low"]},
          "category": {"type": "string"},
          "location": {"type": "string"},
          "problem": {"type": "string"},
          "suggestion": {"type": "string"}
        }
      }
    },
    "recommendations": {"type": "array", "items": {"type": "string"}},
    "risks": {"type": "array", "items": {"type": "string"}},
    "confidence": {"type": "string", "enum": ["low", "medium", "high"]},
    "notes_for_claude_code": {"type": "string"}
  }
}
'@
# Codex CLI 不接受 UTF-8 BOM 的 schema 文件，必须用无 BOM 的 UTF-8
[System.IO.File]::WriteAllText($schemaPath, $reviewSchema, (New-Object System.Text.UTF8Encoding $false))

# ---------- Build context block from -ContextFiles ----------
$contextBlock = $null
if ($ContextFiles -and $ContextFiles.Count -gt 0) {
    $contextBlock = Build-ContextBlock -Files $ContextFiles -BaseDir $resolvedWorkingDirectory -MaxChars $MaxContextChars
}

# ---------- Build effective prompt ----------
$effectivePrompt = if ($RawPrompt) {
    $Prompt
} else {
    New-BridgePrompt -TaskType $TaskType -Mode $Mode -OutputLanguage $OutputLanguage -TaskBrief $Prompt -ContextBlock $contextBlock
}

Set-Content -LiteralPath $promptPath -Value $effectivePrompt -Encoding UTF8

# ---------- Build codex arguments ----------
$arguments = @(
    "exec",
    "--sandbox", "read-only",
    "--color", "never",
    "--json",
    "-o", $finalMessagePath,
    "--output-schema", $schemaPath,
    "--skip-git-repo-check",
    "-C", $codexSafeWorkspace
)

if ($IncludeProject) {
    # 真实启用项目可见性：让 Codex 通过 --add-dir 读取 WorkingDirectory
    $arguments += "--add-dir"
    $arguments += $resolvedWorkingDirectory
} else {
    # 不读项目规则
    $arguments += "--ignore-rules"
}

if ($Model) {
    $arguments += "-m"
    $arguments += $Model
}

# Pass prompt via file redirection (stdin from file).
# 不用 "-" 参数 + pipe 的姿势，因为 Start-Job 环境里没有 stdin tty。
# 也不用位置参数（过长 prompt + 中文可能触发 CLI 的 argv 编码问题）。
# 最稳妥：让 codex 自己读我们写好的 prompt 文件。

# ---------- 远端订阅模式：执行前探测（早失败优于半路失败） ----------
# 放在真正开跑之前，链路不通就别浪费时间拼 prompt / 传文件。
$remoteInfo = $null
$remoteCodexPath = ''
$remoteExec = $null     # 仅 -Remote 成功执行后非空；wrapper 组装段据此决定 remote 字段内容
if ($Remote) {
    $remoteInfo = Get-RemoteCodexInfo -Target $RemoteTarget
    if ($remoteInfo.LocalFailure) {
        throw "-Remote 预检失败（本机依赖）：$($remoteInfo.LocalFailure)"
    }
    if (-not $remoteInfo.ProbeStarted) {
        # 复审 issue 5：话术要求展示 ssh 原文，throw 里就得带上（过滤后的前几行），不能只给一个不可信的退出码
        $sshLines = ((($remoteInfo.RawOutput -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' / ')
        throw "-Remote 预检失败（SSH）：远端探测脚本没能启动。ssh: $sshLines。可先跑 -RemotePreflight 看分层诊断。"
    }
    if ([string]::IsNullOrWhiteSpace($remoteInfo.CodexPath) -or -not $remoteInfo.VersionOk) {
        throw "-Remote 预检失败（codex）：远端 codex 不可用（path='$($remoteInfo.CodexPath)' version='$($remoteInfo.CodexVersion)'）。可先跑 -RemotePreflight 看分层诊断。"
    }
    if (-not $remoteInfo.LoggedInChatGPT) {
        throw "-Remote 预检失败（认证）：远端不是 ChatGPT 订阅登录（'$($remoteInfo.LoginStatus)'）。-Remote 的前提是借用远端那份订阅额度；若远端实为 API key 认证，继续下去会静默变成按量付费。"
    }
    $remoteCodexPath = $remoteInfo.CodexPath
}

# ---------- Record codex version ----------
# -Remote 时记录的必须是"实际执行者"的版本，即远端那台机器上的 codex。
$codexVersion = ""
if ($Remote) {
    $codexVersion = $remoteInfo.CodexVersion
} else {
    try {
        $codexVersion = (& codex --version 2>&1 | Out-String).Trim()
    } catch {
        $codexVersion = "unknown"
    }
}

# ---------- API 中转模式（可选）：隔离 CODEX_HOME + apikey 认证，不碰订阅登录态 ----------
# 端点/key 读 .env 的 CODEX_API_BASE_URL / CODEX_API_KEY；
# auth.json 只含 key、无 OAuth token（不可能回落订阅计费）。
$apiHome = $null
$prevCodexHome = $env:CODEX_HOME
if ($Api) {
    if (-not (Test-Path -LiteralPath $ApiEnvFile)) {
        throw "-Api 模式需要 relay 配置，但未找到 .env: $ApiEnvFile（可用 -ApiEnvFile 指定）。"
    }
    $envMap = @{}
    foreach ($line in (Get-Content -LiteralPath $ApiEnvFile -Encoding UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('='); if ($i -lt 1) { continue }
        $envMap[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
    }
    $apiKey = $envMap['CODEX_API_KEY']
    $apiBase = $envMap['CODEX_API_BASE_URL']
    if ([string]::IsNullOrWhiteSpace($apiKey) -or [string]::IsNullOrWhiteSpace($apiBase)) {
        throw "-Api 模式：$ApiEnvFile 缺 CODEX_API_KEY 或 CODEX_API_BASE_URL。"
    }
    $apiBase = $apiBase.TrimEnd('/')
    $apiModel = if ($Model) { $Model } else { 'gpt-5.6-sol' }
    $apiHome = Join-Path $codexSafeWorkspace 'api-home'
    if (-not (Test-Path -LiteralPath $apiHome)) { New-Item -ItemType Directory -Path $apiHome -Force | Out-Null }
    $cfgLines = @(
        'model_provider = "OpenAI"'
        "model = `"$apiModel`""
        'model_reasoning_effort = "high"'
        'disable_response_storage = true'
        'network_access = "enabled"'
        'windows_wsl_setup_acknowledged = true'
        ''
        '[model_providers.OpenAI]'
        'name = "OpenAI"'
        "base_url = `"$apiBase`""
        'wire_api = "responses"'
        'requires_openai_auth = true'
    )
    [System.IO.File]::WriteAllText((Join-Path $apiHome 'config.toml'), (($cfgLines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    [System.IO.File]::WriteAllText((Join-Path $apiHome 'auth.json'), ('{"OPENAI_API_KEY":"' + $apiKey + '"}'), (New-Object System.Text.UTF8Encoding $false))
    $env:CODEX_HOME = $apiHome
}

# ---------- Invoke codex with timeout ----------
# Windows PowerShell 5.1 默认 $OutputEncoding 是 ASCII，会把中文 prompt 转成乱码后再喂给 codex stdin。
# 必须强制 UTF-8，否则 codex 收到的是乱码。
$previousConsoleEncoding = [Console]::OutputEncoding
$previousOutputEncoding = $OutputEncoding
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$OutputEncoding = [System.Text.UTF8Encoding]::new()

$timedOut = $false
$rawOutput = ""
$exitCode = -1

# 不再 Push-Location 到用户的 WorkingDirectory——现在 Start-Process 已经固定用
# $codexSafeWorkspace 作为进程工作目录，PowerShell 宿主无需切换到中文路径。
try {
    if ($Remote) {
        # 远端订阅路径：上传 → 远端执行 → 拉回 → 清理。
        # 产物落到与本机路径完全相同的那三个文件（raw.jsonl / stderr.txt / final.txt），
        # 所以下游的 final.txt 解析与 wrapper 组装完全不必区分这次是本机跑的还是远端跑的。
        $remoteExec = Invoke-RemoteCodexExec -Target $RemoteTarget -CodexPath $remoteCodexPath `
            -PromptPath $promptPath -SchemaPath $schemaPath `
            -RawOutputPath $rawOutputPath -StderrPath $stderrOutputPath -FinalPath $finalMessagePath `
            -TimeoutSeconds $TimeoutSeconds -Model $Model
        if ($remoteExec.Failure) {
            # 失败即 throw，与本机路径"codex 不可用即 throw"同体例；wrapper 不会生成，
            # 所以把已知状态与诊断随异常一并带出，不让它们在 throw 里丢掉（复审 issue 2）
            # 三个状态都可能是 null（= 未知），打出来要写明 unknown，不能让 null 变成空白被误读成 false
            $stTimed  = if ($null -eq $remoteExec.TimedOut)     { 'unknown' } else { $remoteExec.TimedOut }
            $stPurged = if ($null -eq $remoteExec.PromptPurged) { 'unknown' } else { $remoteExec.PromptPurged }
            $stExit   = if ($remoteExec.ExitCodeKnown) { "$($remoteExec.ExitCode)" } else { 'unknown' }
            throw "远端执行失败：$($remoteExec.Failure)`n[state] timedOut=$stTimed exitCode=$stExit promptPurged=$stPurged runId=$($remoteExec.RunId)`n[diag] $($remoteExec.Diagnostics)"
        }
        $exitCode = $remoteExec.ExitCode
        $timedOut = $remoteExec.TimedOut
    } else {
    # ↓↓↓ 以下本机路径代码保持原样、未重新缩进——刻意为之：
    # 重排缩进会让 diff 淹没在空白改动里，掩盖真正的逻辑变更。本文件正被其他会话调用，
    # diff 的可审性比缩进美观重要。
    # 用 Start-Process + stdin 重定向文件实现超时。
    # 避免 Start-Job 环境无 stdin tty + pipe 方式无法控超时的问题。
    # 直接让 codex 把 stdout 和 stderr 写到最终文件——
    # stdout 直接是 .raw.jsonl（纯 Codex 事件流，严格 JSONL）
    # stderr 写到 .stderr.txt（含登录/schema/连接等错误，不与 stdout 拼接）
    # 这样 .raw.jsonl 可以被 jq 等工具直接流式消费。
    # 直接找 codex.cmd 全路径（避免 PATH 解析问题）
    $codexCmd = (Get-Command codex.cmd -ErrorAction SilentlyContinue)
    if (-not $codexCmd) {
        $codexCmd = Get-Command codex -ErrorAction Stop
    }
    $codexCmdPath = $codexCmd.Source

    # 关键防护：Start-Process 的 WorkingDirectory 永远用英文安全路径，
    # 避免 PowerShell 宿主因为中文项目目录里的大量文件（node_modules/.git 等）
    # 持续监听/缓存文件系统事件，导致内存膨胀（曾观察到单进程 90% 内存占用）。
    # 用户真实 WorkingDirectory 只用于决定输出目录，不参与进程工作目录。
    $proc = Start-Process -FilePath $codexCmdPath `
        -ArgumentList $arguments `
        -WorkingDirectory $codexSafeWorkspace `
        -RedirectStandardInput $promptPath `
        -RedirectStandardOutput $rawOutputPath `
        -RedirectStandardError $stderrOutputPath `
        -NoNewWindow -PassThru
    if ($proc.WaitForExit($TimeoutSeconds * 1000)) {
        # 有时 WaitForExit 刚返回 ExitCode 还没 ready
        $proc.WaitForExit()
        $exitCode = if ($null -ne $proc.ExitCode) { [int]$proc.ExitCode } else { 0 }
    } else {
        $timedOut = $true
        try { $proc.Kill($true) } catch { try { $proc.Kill() } catch {} }
        $exitCode = -1
    }
    # 保持 stderr 文件纯净：超时标记只通过 wrapper.timedOut 字段暴露，不污染 .stderr.txt
    }
} finally {
    [Console]::OutputEncoding = $previousConsoleEncoding
    $OutputEncoding = $previousOutputEncoding
    # API 模式：还原 CODEX_HOME + 清掉隔离 HOME 里的明文 key（正常/超时/异常都走到）
    if ($Api) {
        $env:CODEX_HOME = $prevCodexHome
        if ($apiHome) {
            $af = Join-Path $apiHome 'auth.json'
            if (Test-Path -LiteralPath $af) {
                try {
                    [System.IO.File]::WriteAllText($af, '{}', (New-Object System.Text.UTF8Encoding $false))
                    [System.IO.File]::Delete($af)
                } catch { }
            }
        }
    }
}

# stdout 和 stderr 已由 Start-Process 直接写入 $rawOutputPath 和 $stderrOutputPath，无需再组装

# ---------- Read final message ----------
$finalMessage = $null
if (Test-Path -LiteralPath $finalMessagePath) {
    $finalMessage = Get-Content -LiteralPath $finalMessagePath -Raw -Encoding UTF8
}

# ---------- Try to parse structured response from final message ----------
# 解析优先级：
#   1. ```json fenced block
#   2. ``` (无 lang) fenced block
#   3. 从第一个 { / [ 截到末尾
$structuredResponseJson = $null
$structuredResponseParsed = $false

if (-not [string]::IsNullOrWhiteSpace($finalMessage)) {
    $candidates = @()

    # 1. ```json ... ``` （优先）
    $m = [regex]::Match($finalMessage, '```json\s*\r?\n(.+?)\r?\n```', 'Singleline')
    if ($m.Success) { $candidates += $m.Groups[1].Value.Trim() }

    # 2. ``` ... ```（无 lang）
    if ($candidates.Count -eq 0) {
        $m = [regex]::Match($finalMessage, '```\s*\r?\n(\{.+?\})\r?\n```', 'Singleline')
        if ($m.Success) { $candidates += $m.Groups[1].Value.Trim() }
    }

    # 3. 从第一个 { 或 [ 截到末尾
    $trimmed = $finalMessage.Trim()
    $objIdx = $trimmed.IndexOf('{')
    $arrIdx = $trimmed.IndexOf('[')
    $startIdx = -1
    if ($objIdx -ge 0 -and $arrIdx -ge 0) {
        $startIdx = [Math]::Min($objIdx, $arrIdx)
    } elseif ($objIdx -ge 0) { $startIdx = $objIdx }
    elseif ($arrIdx -ge 0) { $startIdx = $arrIdx }
    if ($startIdx -ge 0) {
        $candidates += $trimmed.Substring($startIdx)
    }

    foreach ($cand in $candidates) {
        try {
            $null = $cand | ConvertFrom-Json
            $structuredResponseParsed = $true
            $structuredResponseJson = $cand
            break
        } catch {
            # try next candidate
        }
    }
}

# ---------- Build wrapper ----------
# 手工构造 JSON 字符串，避免 ConvertTo-Json 处理深层对象图时卡住
$jsonParts = @()
$jsonParts += '{'
$jsonParts += '  "wrapperVersion": 2,'
$jsonParts += '  "promptScaffoldVersion": ' + $(if ($RawPrompt) { 0 } else { 1 }) + ','
$jsonParts += '  "invokedAt": ' + (Convert-ToJsonString ((Get-Date).ToString("s"))) + ','
$jsonParts += '  "workingDirectory": ' + (Convert-ToJsonString $resolvedWorkingDirectory) + ','
$jsonParts += '  "taskType": ' + (Convert-ToJsonString $TaskType) + ','
$jsonParts += '  "mode": ' + (Convert-ToJsonString $Mode) + ','
$jsonParts += '  "outputLanguage": ' + (Convert-ToJsonString $OutputLanguage) + ','
$jsonParts += '  "modelRequested": ' + (Convert-ToJsonString $Model) + ','
$jsonParts += '  "codexVersion": ' + (Convert-ToJsonString $codexVersion) + ','
$jsonParts += '  "apiMode": ' + $(if ($Api) { 'true' } else { 'false' }) + ','
# 远端订阅模式的元信息，体例照 apiMode：非 -Remote 时恒为 remoteMode=false / remote=null，
# 本机路径的 wrapper 只多这两个字段，消费者是 Claude 自己，多字段无害。
$jsonParts += '  "remoteMode": ' + $(if ($Remote) { 'true' } else { 'false' }) + ','
if ($Remote -and ($null -ne $remoteExec)) {
    $jsonParts += '  "remote": {'
    $jsonParts += '    "target": ' + (Convert-ToJsonString $RemoteTarget) + ','
    $jsonParts += '    "codexPath": ' + (Convert-ToJsonString $remoteCodexPath) + ','
    $jsonParts += '    "codexResolvedBy": ' + (Convert-ToJsonString $remoteInfo.ResolvedBy) + ','
    $jsonParts += '    "runId": ' + (Convert-ToJsonString $remoteExec.RunId) + ','
    $jsonParts += '    "remoteDir": ' + (Convert-ToJsonString $remoteExec.RemoteDir) + ','
    # false 表示 exitCode 是推断值（PS 5.1 读不到子进程退出码），成败请以 finalMessage 为准
    $jsonParts += '    "exitCodeKnown": ' + $(if ($remoteExec.ExitCodeKnown) { 'true' } else { 'false' }) + ','
    $jsonParts += '    "promptPurged": ' + $(if ($null -eq $remoteExec.PromptPurged) { 'null' } elseif ($remoteExec.PromptPurged) { 'true' } else { 'false' }) + ','
    $jsonParts += '    "diagnostics": ' + (Convert-ToJsonString $remoteExec.Diagnostics)
    $jsonParts += '  },'
} else {
    $jsonParts += '  "remote": null,'
}
$jsonParts += '  "includeProject": ' + $(if ($IncludeProject) { 'true' } else { 'false' }) + ','
$jsonParts += '  "contextFilesCount": ' + $(if ($ContextFiles) { $ContextFiles.Count } else { 0 }) + ','
$jsonParts += '  "maxContextChars": ' + $MaxContextChars + ','
$jsonParts += '  "timeoutSeconds": ' + $TimeoutSeconds + ','
$jsonParts += '  "timedOut": ' + $(if ($timedOut) { 'true' } else { 'false' }) + ','
$jsonParts += '  "exitCode": ' + $exitCode + ','
$jsonParts += '  "outputPath": ' + (Convert-ToJsonString $OutputPath) + ','
$jsonParts += '  "rawOutputPath": ' + (Convert-ToJsonString $rawOutputPath) + ','
$jsonParts += '  "stderrPath": ' + (Convert-ToJsonString $stderrOutputPath) + ','
$jsonParts += '  "promptPath": ' + (Convert-ToJsonString $promptPath) + ','
$jsonParts += '  "finalMessagePath": ' + (Convert-ToJsonString $finalMessagePath) + ','
$jsonParts += '  "schemaPath": ' + (Convert-ToJsonString $schemaPath) + ','
$jsonParts += '  "finalMessage": ' + (Convert-ToJsonString $finalMessage) + ','
$jsonParts += '  "structuredResponseParsed": ' + $(if ($structuredResponseParsed) { 'true' } else { 'false' }) + ','
if ($structuredResponseJson) {
    $jsonParts += '  "structuredResponse": ' + $structuredResponseJson
} else {
    $jsonParts += '  "structuredResponse": null'
}
$jsonParts += '}'

($jsonParts -join "`n") | Set-Content -LiteralPath $OutputPath -Encoding UTF8

if ($PassThru) {
    Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8
} else {
    Write-Output $OutputPath
}

# 防内存膨胀：脚本收尾前显式释放大字符串 + 强制 GC。
# 背景：曾观察到 PowerShell 宿主单进程 90% 内存占用，
# 主要嫌疑是 prompt + rawOutput + wrapper JSON 字符串累积、以及进程对象未及时回收。
$Prompt = $null
$effectivePrompt = $null
$contextBlock = $null
$rawOutput = $null
$stdoutContent = $null
$stderrContent = $null
$finalMessage = $null
$structuredResponseJson = $null
$reviewSchema = $null
$jsonParts = $null
$proc = $null
try {
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()
} catch { }
