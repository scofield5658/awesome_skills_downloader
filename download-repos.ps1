# Windows PowerShell：在 git 被管控、无法 git clone 的内网里，用 curl.exe 或
# Invoke-WebRequest 走 HTTP 一次性下载 GitHub 默认分支 zip（等同网页
# Code -> Download ZIP），再解压整理成工作区目录。全程不调用 git，也不创建 .git。
# 优先使用系统自带的 curl.exe，否则回退到 Invoke-WebRequest。
#
# 结果：<项目根>\output\{groupName}-{repoName}\
# 例如 vercel-labs/skills -> output\vercel-labs-skills
# 代理：curl.exe / Invoke-WebRequest 会读取 HTTP_PROXY / HTTPS_PROXY / NO_PROXY。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\download-repos.ps1
#   $env:OUTPUT_DIR = "D:\output"; .\download-repos.ps1
#   $env:DRY_RUN = "1"; .\download-repos.ps1
#   $env:GITHUB_TOKEN = "ghp_xxx"; .\download-repos.ps1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ListFile = if ($env:REPOS_FILE) { $env:REPOS_FILE } else { Join-Path $ScriptDir "repos.txt" }
$OutDir = if ($env:OUTPUT_DIR) { $env:OUTPUT_DIR } else { Join-Path $ScriptDir "output" }
$UserAgent = if ($env:USER_AGENT) { $env:USER_AGENT } else { "awesome-skills-downloader" }
$DryRun = $env:DRY_RUN -and $env:DRY_RUN -ne "0"

if (-not (Test-Path -LiteralPath $ListFile)) {
    Write-Error "找不到仓库列表：$ListFile"
    exit 1
}

function ConvertTo-OwnerRepo {
    param([string]$Raw)

    $value = $Raw.Trim().TrimEnd("/")
    if ($value.EndsWith(".git", [System.StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(0, $value.Length - 4)
    }

    if ($value -match "^git@github\.com:(.+)$") {
        $value = $Matches[1]
    }
    elseif ($value -match "^ssh://git@github\.com/(.+)$") {
        $value = $Matches[1]
    }
    elseif ($value -match "github\.com/(.+)$") {
        $value = $Matches[1]
    }

    $parts = $value.Split("/", [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Length -lt 2) {
        return $null
    }

    $repo = $parts[1]
    if ($repo.EndsWith(".git", [System.StringComparison]::OrdinalIgnoreCase)) {
        $repo = $repo.Substring(0, $repo.Length - 4)
    }
    return @{ Owner = $parts[0]; Repo = $repo }
}

function Test-ZipFile {
    param([string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $b0 = $stream.ReadByte()
        $b1 = $stream.ReadByte()
        return ($b0 -eq 0x50 -and $b1 -eq 0x4B)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-RemoteFile {
    param(
        [string]$Url,
        [string]$OutFile,
        [string[]]$Headers
    )

    $curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue
    if ($curl) {
        $curlArgs = @("-fL", "--retry", "3", "--retry-delay", "2", "-A", $UserAgent, "-o", $OutFile)
        foreach ($header in $Headers) {
            $curlArgs += @("-H", $header)
        }
        $curlArgs += @("--", $Url)
        & $curl.Source @curlArgs
        if ($LASTEXITCODE -ne 0) {
            throw "curl.exe 退出码 $LASTEXITCODE"
        }
        return
    }

    $headerMap = @{ "User-Agent" = $UserAgent }
    foreach ($header in $Headers) {
        $kv = $header.Split(":", 2)
        if ($kv.Length -eq 2) {
            $headerMap[$kv[0].Trim()] = $kv[1].Trim()
        }
    }
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -Headers $headerMap
}

function ConvertTo-RepoTree {
    param(
        [string]$ZipPath,
        [string]$Dest
    )

    $work = Join-Path ([IO.Path]::GetTempPath()) ("skills-dl-" + [guid]::NewGuid().ToString("N"))
    $extract = Join-Path $work "extract"
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    try {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $extract -Force
        $entries = @(Get-ChildItem -LiteralPath $extract -Force)
        $src = $extract
        if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) {
            $src = $entries[0].FullName
        }
        if (Test-Path -LiteralPath $Dest) {
            Remove-Item -LiteralPath $Dest -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $Dest | Out-Null
        Get-ChildItem -LiteralPath $src -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $Dest -Recurse -Force
        }
    }
    finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force
        }
    }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$okCount = 0
$failCount = 0

Get-Content -LiteralPath $ListFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -eq "" -or $line.StartsWith("#")) {
        return
    }

    $parsed = ConvertTo-OwnerRepo $line
    if (-not $parsed) {
        Write-Host "[FAIL] 无法解析：$line"
        $script:failCount++
        return
    }

    $owner = $parsed.Owner
    $repo = $parsed.Repo
    $dest = Join-Path $OutDir ("{0}-{1}" -f $owner, $repo)
    $headers = @()

    if ($env:GITHUB_TOKEN) {
        $url = "https://api.github.com/repos/$owner/$repo/zipball"
        $headers += "Authorization: Bearer $($env:GITHUB_TOKEN)"
        $headers += "Accept: application/vnd.github+json"
        $authNote = "API zipball"
    }
    else {
        $url = "https://github.com/$owner/$repo/archive/HEAD.zip"
        $authNote = "archive/HEAD.zip"
    }

    Write-Host "[INFO] $owner/$repo  ->  $dest  ($authNote)"
    if ($DryRun) {
        Write-Host "       $url"
        $script:okCount++
        return
    }

    $zipPath = Join-Path ([IO.Path]::GetTempPath()) ("skills-dl-" + [guid]::NewGuid().ToString("N") + ".zip")
    try {
        Get-RemoteFile -Url $url -OutFile $zipPath -Headers $headers
        if (-not (Test-ZipFile $zipPath)) {
            throw "下载结果不是 zip"
        }
        ConvertTo-RepoTree -ZipPath $zipPath -Dest $dest
        Write-Host "[OK]   $dest"
        $script:okCount++
    }
    catch {
        Write-Host "[FAIL] $owner/$repo : $($_.Exception.Message)"
        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Recurse -Force
        }
        $script:failCount++
    }
    finally {
        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force
        }
    }
}

Write-Host ""
Write-Host "完成：成功 $okCount，失败 $failCount"
if ($failCount -ne 0) {
    exit 1
}
