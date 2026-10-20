# 把本机源码（含前端 build 产物）传到 Linux 服务器，可选地顺手执行安装脚本。
#
#   powershell -ExecutionPolicy Bypass -File deploy\upload-source.ps1 -Server 192.168.1.10 -Install
#
# 服务器不需要装 Node：前端在本地 build，传上去的是静态产物。
# 依赖 Windows 自带的 tar.exe 与 OpenSSH 客户端（ssh / scp）。

param(
    [Parameter(Mandatory = $true)][string]$Server,
    [string]$User = 'root',
    [string]$RemoteDir = '/data/spug',
    [switch]$SkipBuild,
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot
$Web = Join-Path $Repo 'spug_web'
$TarDir = Join-Path $env:TEMP 'spug-deploy'
$TarName = 'spug-src.tar.gz'

function step($msg) { Write-Host "==> $msg" }
function assertLastExit($what) {
    if ($LASTEXITCODE -ne 0) { throw "$what 失败（退出码 $LASTEXITCODE）" }
}

if (-not $SkipBuild) {
    step '构建前端（react-scripts 3.x 需要 openssl-legacy-provider）'
    Push-Location $Web
    try {
        $env:NODE_OPTIONS = '--openssl-legacy-provider'
        $env:GENERATE_SOURCEMAP = 'false'
        npx react-app-rewired build
        assertLastExit '前端构建'
    }
    finally {
        Remove-Item Env:NODE_OPTIONS, Env:GENERATE_SOURCEMAP -ErrorAction SilentlyContinue
        Pop-Location
    }
}
if (-not (Test-Path (Join-Path $Web 'build\index.html'))) {
    throw "缺少 $Web\build\index.html，先去掉 -SkipBuild 构建一次"
}

step '打包源码（排除虚拟环境、依赖、本地数据库与运行期数据）'
# 用 Windows 自带的 bsdtar，并把目标写成相对路径：GNU tar 与 scp 都会把
# C:\Users\... 里的冒号解析成 host:path，从而报 "Cannot connect to C: resolve failed"。
New-Item -ItemType Directory -Force -Path $TarDir | Out-Null
$SystemTar = Join-Path $env:SystemRoot 'System32\tar.exe'
Push-Location $TarDir
try {
    if (Test-Path $TarName) { Remove-Item $TarName }
    & $SystemTar -czf $TarName -C $Repo `
        --exclude='*__pycache__*' `
        --exclude='./spug_api/venv' `
        --exclude='./spug_api/logs' `
        --exclude='./spug_api/storage' `
        --exclude='./spug_api/repos' `
        --exclude='./spug_api/db.sqlite3' `
        --exclude='./spug_api/spug/overrides.py' `
        --exclude='./spug_web/node_modules' `
        --exclude='./.qoder-credits' `
        --exclude='./.git' `
        --exclude='./.github' `
        .
    assertLastExit '打包'
    if (Test-Path $TarName) {
        $size = [math]::Round((Get-Item $TarName).Length / 1MB, 1)
        step "打包完成：$(Join-Path $TarDir $TarName)（$size MB）"
    }
}
finally { Pop-Location }

step "上传到 $User@${Server}:$RemoteDir"
ssh "$User@$Server" "mkdir -p $RemoteDir"
assertLastExit 'ssh 连接'
Push-Location $TarDir
try {
    scp $TarName "$User@${Server}:/tmp/$TarName"
    assertLastExit '上传'
}
finally { Pop-Location }
# tar 包内路径以 ./ 开头，--strip-components=1 正好落到 $RemoteDir 下
ssh "$User@$Server" "tar -xzf /tmp/$TarName -C $RemoteDir --strip-components=1 && rm -f /tmp/$TarName"
assertLastExit '解包'

if ($Install) {
    step '在服务器上执行安装脚本'
    # ALLOWED_HOSTS 必须含访问用的地址，否则 Django 对每个 /api 请求返回 DisallowedHost
    ssh -t "$User@$Server" "SPUG_DIR=$RemoteDir ALLOWED_HOSTS=$Server bash $RemoteDir/deploy/install-spug.sh"
    assertLastExit '安装'
}

Write-Host ''
step '源码已就位。后续步骤见 deploy/README.md'
