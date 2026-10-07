# ============================================================================
#  Kingdom Rush 1 模组 · 一键安装 (v1.0)
#
#  怎么用（推荐）：双击 "一键安装.bat"
#  命令行：powershell -ExecutionPolicy Bypass -File install.ps1
#          powershell -ExecutionPolicy Bypass -File install.ps1 -Status
#          powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#
#  它做什么：
#    1) 把 mods\*.lua 复制到存档目录 %APPDATA%\kingdom_rush\
#    2) 在存档目录的 args.lua 里写一行 "-custom_script", "kr_mods"
#       （游戏启动时会读 args.lua，按这个参数加载插件宿主）
#    3) 备份原来的 args.lua 到 args.lua.bak
#
#  注意：args.lua 必须是 **token 列表**（游戏用 table.append 只搬数组部分），
#        所以本脚本会把旧写法（["custom_script"] = "xxx"）整行换成新写法。
# ============================================================================
param(
  [switch]$Uninstall,
  [switch]$Status,
  [string]$SaveDir
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Info($m) { Write-Host "       $m" }
function Warn($m) { Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "  [X]  $m" -ForegroundColor Red; exit 1 }
function ReadT($p) { if (-not (Test-Path -LiteralPath $p)) { return $null } return [System.IO.File]::ReadAllText($p, $utf8) }
function WriteT($p, $t) { [System.IO.File]::WriteAllText($p, $t, $utf8) }

$Name    = 'kr_mods'
$Plugins = @('kr_spec_unlimited', 'kr_gold_55555')
$Bundle  = @("$Name.lua") + ($Plugins | ForEach-Object { "$_.lua" })
$Token   = '"-custom_script", "' + $Name + '",'

if (-not $SaveDir) { $SaveDir = Join-Path $env:APPDATA 'kingdom_rush' }
$ArgsFile = Join-Path $SaveDir 'args.lua'
$ModsSrc  = Join-Path $PSScriptRoot 'mods'

Write-Host ''
Write-Host '============================================' -ForegroundColor Cyan
Write-Host ' Kingdom Rush 1 模组 · 一键安装' -ForegroundColor Cyan
Write-Host '============================================' -ForegroundColor Cyan
Write-Host "存档目录：$SaveDir"
Write-Host ''

if (-not (Test-Path -LiteralPath $SaveDir)) {
  Die "找不到存档目录。请先启动一次游戏（进到标题界面即可），退出后再运行本安装。"
}

function Show-Status {
  Write-Host '当前状态：' -ForegroundColor Cyan
  foreach ($f in $Bundle) {
    $p = Join-Path $SaveDir $f
    if (Test-Path -LiteralPath $p) { Ok ("已安装：" + $f) } else { Warn ("缺少：" + $f) }
  }
  $t = ReadT $ArgsFile
  if ($null -eq $t) { Warn 'args.lua 不存在（游戏启动时不会加载模组）' }
  elseif ($t -match [regex]::Escape($Token)) { Ok ("args.lua 已指向 $Name（游戏会自动加载）") }
  elseif ($t -match '-custom_script') { Warn 'args.lua 里的 custom_script 不是本模组（可能是老版本安装）' }
  else { Warn 'args.lua 里没有 custom_script（模组不会加载）' }
  foreach ($log in 'kr_mods_log.txt', 'kr_spec_unlimited_log.txt') {
    $p = Join-Path $SaveDir $log
    if (Test-Path -LiteralPath $p) {
      Write-Host ""
      Write-Host "最近日志 $log：" -ForegroundColor Cyan
      Get-Content -LiteralPath $p -Encoding UTF8 -Tail 6 | ForEach-Object { "       $_" }
    }
  }
  if (Get-Process 'Kingdom Rush' -ErrorAction SilentlyContinue) {
    Write-Host ''
    Warn '游戏正在运行：改动要重启游戏才生效'
  }
}

if ($Status) { Show-Status; exit 0 }

if ($Uninstall) {
  $t = ReadT $ArgsFile
  if ($null -ne $t) {
    $bak = "$ArgsFile.bak"
    if ((Test-Path -LiteralPath $bak) -and ((ReadT $bak) -notmatch '-custom_script')) {
      WriteT $ArgsFile (ReadT $bak)                      # 有干净备份就直接还原
      Ok 'args.lua 已还原成安装前的样子'
    } elseif ($t -match '-custom_script') {
      WriteT $ArgsFile (($t -split "`n" | Where-Object { $_ -notmatch '-custom_script' }) -join "`n")
      Ok 'args.lua 里的加载行已删除'
    }
  }
  foreach ($f in $Bundle) { Remove-Item -LiteralPath (Join-Path $SaveDir $f) -ErrorAction SilentlyContinue }
  Ok '模组文件已删除（日志保留，方便排查）'
  Warn '如果游戏正在运行，请重启游戏；已经开着的关卡里模组仍在生效'
  exit 0
}

# ------------------------------------------------------------------ 安装
$missing = @()
foreach ($f in $Bundle) { if (-not (Test-Path -LiteralPath (Join-Path $ModsSrc $f))) { $missing += $f } }
if ($missing.Count -gt 0) { Die ("压缩包不完整，缺少：" + ($missing -join ', ') + "（请重新下载并完整解压）") }

foreach ($f in $Bundle) {
  Copy-Item -LiteralPath (Join-Path $ModsSrc $f) -Destination (Join-Path $SaveDir $f) -Force
  Ok "已放置 $f"
}

$t = ReadT $ArgsFile
if ($null -eq $t -or $t.Trim() -eq '') {
  WriteT $ArgsFile ("return {`r`n`t$Token`r`n}`r`n")
  Ok '已新建 args.lua 并写入加载参数'
} elseif ($t -match [regex]::Escape($Token)) {
  Ok 'args.lua 里已经是本模组，无需改动'
} else {
  $bak = "$ArgsFile.bak"
  if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $ArgsFile -Destination $bak -Force; Info "已备份原 args.lua -> $bak" }
  if ($t -match '-custom_script') {
    # 老版本安装留下的行（可能是 kr_spec_unlimited）：整行替换
    $out, $replaced = @(), $false
    foreach ($ln in ($t -split "`n")) {
      if (-not $replaced -and $ln -match '-custom_script') { $out += ("`t" + $Token); $replaced = $true }
      elseif ($ln -notmatch '-custom_script') { $out += $ln }
    }
    WriteT $ArgsFile ($out -join "`n")
    Ok 'args.lua 里的加载参数已更新为本模组'
  } else {
    $i = $t.IndexOf('{')
    if ($i -lt 0) { Die "args.lua 格式不认识（里面没有 '{'）。可以把它改名成 args.lua.old 后重跑本安装。" }
    WriteT $ArgsFile ($t.Substring(0, $i + 1) + "`r`n`t$Token" + $t.Substring($i + 1))
    Ok '已把加载参数写进 args.lua'
  }
}

# 写入后自检
if ((ReadT $ArgsFile) -notmatch [regex]::Escape($Token)) { Die 'args.lua 写入后校验失败，请把 args.lua 发给我看看。' }

Write-Host ''
Write-Host '装好了！接下来：' -ForegroundColor Green
Info '1) 启动游戏（Steam / 桌面图标 / KRAUTO 启动器都行）'
Info '2) 进关卡后：金币会变成 55555；四级防御塔的技能可以一直点'
Info '3) 游戏里按 F9 开关金币模组、按 F8 开关专精模组'
Info "4) 日志：$SaveDir\kr_mods_log.txt（插件加载 + 金币跳动都记在里面）"
Write-Host ''
Info '想卸载：双击 卸载.bat   看状态：双击 检查状态.bat'
if (Get-Process 'Kingdom Rush' -ErrorAction SilentlyContinue) {
  Write-Host ''
  Warn '检测到游戏正在运行：请重启游戏，模组才会生效'
}
Write-Host ''
