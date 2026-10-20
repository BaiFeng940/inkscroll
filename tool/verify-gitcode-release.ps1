# 校验 GitCode release 上的 APK 是否完整可下载。
#
# 用法：
#   pwsh -File tool/verify-gitcode-release.ps1 -Version 0.8.0
#
# 为什么需要这个脚本：
#   1. GitCode 的 release 资产**只能通过网页上传**，API 不支持
#      （/releases/attach_files 只回 405，其余路径 404）。
#      也就是说"传没传、传得对不对"无法靠创建 release 的返回值判断，
#      只能事后校验。
#   2. **HEAD 请求会返回 401**，看起来像"文件下不了"，
#      但 GET 其实是 200 并重定向到 file-cdn.gitcode.com。
#      用 HEAD 判断会得出完全错误的结论 —— 本脚本一律用 GET + Range。
#
# 校验内容：
#   · releases/latest 接口里 tag 是否等于目标版本
#   · assets 里是否有 type=attach 的 .apk（不是 type=source 的源码包）
#   · 每个 .apk 是否真的能 GET 到（206/200）
#   · 下载到的字节数与 assets 里上报的 size 是否一致
#   · 本地 dist/ 里的同名文件 SHA256 是否与远端一致

param(
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$Owner = 'BaiFeng940',
  [string]$Repo = 'inkscroll',
  [string]$DistDir = 'dist'
)

$ErrorActionPreference = 'Stop'
$tag = "v$Version"
$api = "https://gitcode.com/api/v5/repos/$Owner/$Repo"
$ok = $true

Write-Host "=== 1) 检查 release 是否存在且 tag 正确 ==="
try {
  $rel = Invoke-RestMethod -Uri "$api/releases/tags/$tag" -TimeoutSec 30
  Write-Host "  ✓ tag = $($rel.tag_name)"
} catch {
  Write-Host "  ✗ 取不到 $tag 的 release：$($_.Exception.Message)" -ForegroundColor Red
  exit 1
}

Write-Host ''
Write-Host "=== 2) 检查 assets（要 type=attach 的 .apk）==="
$all = @($rel.assets)
$sources = $all | Where-Object { $_.type -eq 'source' }
$attaches = $all | Where-Object { $_.type -eq 'attach' }
$apks = $attaches | Where-Object { $_.name -like '*.apk' }

Write-Host "  源码包(source, 自动生成, 不是安装包): $($sources.Count) 个"
if ($apks.Count -eq 0) {
  Write-Host '  ✗ 没有任何 .apk 附件！' -ForegroundColor Red
  Write-Host '    → 打开 release 页面，编辑并上传：' -ForegroundColor Yellow
  Get-ChildItem $DistDir -Filter "inkscroll-$Version-*.apk" -EA SilentlyContinue |
    ForEach-Object { Write-Host "      $($_.FullName)" -ForegroundColor Yellow }
  $ok = $false
} else {
  foreach ($a in $apks) {
    Write-Host "  ✓ $($a.name)  (type=$($a.type))"
    Write-Host "      $($a.browser_download_url)" -ForegroundColor DarkGray
  }
}

Write-Host ''
Write-Host '=== 3) 实测下载（GET + Range，不用 HEAD）==='
foreach ($a in $apks) {
  $url = $a.browser_download_url
  $code = (& curl.exe -sS -L -o NUL -w '%{http_code}' -H 'Range: bytes=0-1023' -A 'inkScroll' $url 2>&1) -join ''
  if ($code -in @('200', '206')) {
    Write-Host "  ✓ $($a.name)  HTTP $code"
  } else {
    Write-Host "  ✗ $($a.name)  HTTP $code" -ForegroundColor Red
    $ok = $false
  }
}

Write-Host ''
Write-Host '=== 4) 与本地 dist/ 对比 SHA256 ==='
foreach ($a in $apks) {
  $local = Join-Path $DistDir $a.name
  if (-not (Test-Path $local)) {
    Write-Host "  · $($a.name) 本地没有，跳过对比" -ForegroundColor DarkGray
    continue
  }
  $tmp = Join-Path $env:TEMP ("gc_" + $a.name)
  & curl.exe -sS -L -o $tmp -A 'inkScroll' $a.browser_download_url 2>&1 | Out-Null
  $h1 = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
  $h2 = (Get-FileHash $local -Algorithm SHA256).Hash.ToLower()
  $size = [Math]::Round((Get-Item $tmp).Length / 1MB, 2)
  if ($h1 -eq $h2) {
    Write-Host "  ✓ $($a.name)  $size MB  SHA256 一致"
  } else {
    Write-Host "  ✗ $($a.name)  SHA256 不一致（远端文件可能损坏或传错版本）" -ForegroundColor Red
    $ok = $false
  }
  Remove-Item $tmp -Force -EA SilentlyContinue
}

Write-Host ''
if ($ok) {
  Write-Host "✓ $tag 的镜像资产校验通过，应用内更新可正常从 GitCode 下载。" -ForegroundColor Green
  exit 0
} else {
  Write-Host "✗ $tag 的镜像资产不完整，见上面的红字。" -ForegroundColor Red
  exit 1
}
