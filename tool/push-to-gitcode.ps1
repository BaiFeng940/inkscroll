# 把当前仓库推送到 GitCode 镜像。
#
# 用法：
#   $env:GITCODE_TOKEN = '你的 GitCode 访问令牌'
#   pwsh -File tool/push-to-gitcode.ps1 [-Owner BaiFeng940] [-Repo inkscroll]
#
# 前提：仓库已经在 GitCode 上创建好（见 docs/GITCODE.md 第一节）。
# 为什么要脚本而不是写死在 .git/config 里：token 不能进仓库，
# 每次从环境变量读，避免泄露。

param(
  [string]$Owner = 'BaiFeng940',
  [string]$Repo = 'inkscroll'
)

$ErrorActionPreference = 'Stop'

$token = $env:GITCODE_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) {
  Write-Host '缺少环境变量 GITCODE_TOKEN。' -ForegroundColor Red
  Write-Host '在 GitCode：头像 → 设置 → 访问令牌 → 新建，勾选仓库读写。' -ForegroundColor Yellow
  exit 1
}

$git = 'C:\Program Files\Git\cmd\git.exe'
if (-not (Test-Path $git)) { $git = 'git' }

# 确认在仓库根目录（有 pubspec.yaml）
if (-not (Test-Path 'pubspec.yaml')) {
  Write-Host '请在仓库根目录运行本脚本。' -ForegroundColor Red
  exit 1
}

$url = "https://oauth2:$token@gitcode.com/$Owner/$Repo.git"

# 添加或更新 remote
$existing = & $git remote 2>$null
if ($existing -contains 'gitcode') {
  & $git remote set-url gitcode $url
  Write-Host '→ 已更新 remote: gitcode'
} else {
  & $git remote add gitcode $url
  Write-Host '→ 已添加 remote: gitcode'
}

Write-Host '→ 推送 main …'
& $git -c credential.helper= push gitcode main:main
if ($LASTEXITCODE -ne 0) {
  Write-Host '推送 main 失败。检查：仓库是否已创建、token 是否有写权限。' -ForegroundColor Red
  exit 1
}

Write-Host '→ 推送 tags …'
& $git -c credential.helper= push gitcode --tags
if ($LASTEXITCODE -ne 0) {
  Write-Host '推送 tags 失败（不致命，可以稍后手动推）。' -ForegroundColor Yellow
}

# 推完立刻把带 token 的 URL 复原，避免明文 token 留在 .git/config
& $git remote set-url gitcode "https://gitcode.com/$Owner/$Repo.git"
Write-Host ''
Write-Host "✓ 完成：https://gitcode.com/$Owner/$Repo" -ForegroundColor Green
Write-Host '  别忘了在 GitCode 上创建同名 tag 的 release 并上传 APK（见 docs/GITCODE.md 第四节）。'
