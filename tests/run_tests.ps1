# ============================================================================
#  不开游戏的测试：用 fengari（Lua 5.3 沙箱）+ 假游戏跑两个插件的全部逻辑
#
#    cd tests
#    npm install                                  # 只需要一次（只有 fengari 一个依赖）
#    powershell -ExecutionPolicy Bypass -File .\run_tests.ps1
# ============================================================================
param([string]$Node = 'node')

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$bad  = 0

function Step([string]$title, [scriptblock]$body) {
  Write-Host ''
  Write-Host "=== $title ==="
  try { & $body } catch { Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red; $script:bad++ }
}

Step '1/2 专精插件（抬上限 / 数组越界 / 菜单小点表 / 出关复位 / 第二关）' {
  & $Node (Join-Path $here 'krspec_test.js')
  if ($LASTEXITCODE -ne 0) { throw "krspec_test exit=$LASTEXITCODE" }
}

Step '2/2 插件宿主 + 金币插件（加载链 / 金币跳 55555 / 花钱有效 / F9 / 每帧转发）' {
  & $Node (Join-Path $here 'krmods_test.js')
  if ($LASTEXITCODE -ne 0) { throw "krmods_test exit=$LASTEXITCODE" }
}

Write-Host ''
if ($bad -eq 0) { Write-Host 'SELFTEST OK' -ForegroundColor Green } else { Write-Host "SELFTEST FAILED ($bad)" -ForegroundColor Red; exit 1 }
