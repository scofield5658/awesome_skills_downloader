@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem Windows CMD：内网禁用 git clone 时，用 curl.exe 走 HTTP 一次性下载默认分支 zip
rem （等同网页 Code -> Download ZIP），再解压到 output\{groupName}-{repoName}\。
rem 全程不调用 git，也不创建 .git。代理读取 HTTP_PROXY / HTTPS_PROXY / NO_PROXY。
rem 用法：
rem   download-repos.cmd
rem   set OUTPUT_DIR=D:\output && download-repos.cmd
rem   set DRY_RUN=1 && download-repos.cmd
rem   set GITHUB_TOKEN=ghp_xxx && download-repos.cmd

cd /d "%~dp0"

where curl.exe >nul 2>&1
if errorlevel 1 (
  echo [ERROR] 未找到 curl.exe。Windows 10 1803+ 自带该命令，或改用 download-repos.ps1。
  exit /b 1
)

set "LIST=%~dp0repos.txt"
if not "%REPOS_FILE%"=="" set "LIST=%REPOS_FILE%"
if not exist "%LIST%" (
  echo [ERROR] 找不到仓库列表：%LIST%
  exit /b 1
)

set "OUTDIR=%~dp0output"
if not "%OUTPUT_DIR%"=="" set "OUTDIR=%OUTPUT_DIR%"
if not exist "%OUTDIR%" mkdir "%OUTDIR%"

set "UA=awesome-skills-downloader"
if not "%USER_AGENT%"=="" set "UA=%USER_AGENT%"

set /a OK=0
set /a FAIL=0

for /f "usebackq eol=# tokens=* delims=" %%L in ("%LIST%") do (
  set "LINE=%%L"
  if not "!LINE!"=="" (
    call :process_line "!LINE!"
  )
)

echo.
echo 完成：成功 !OK!，失败 !FAIL!
if not "!FAIL!"=="0" exit /b 1
exit /b 0

:process_line
set "RAW=%~1"
for /f "tokens=* delims= " %%T in ("!RAW!") do set "RAW=%%T"
if "!RAW!"=="" goto :eof

if /i "!RAW:~-4!"==".git" set "RAW=!RAW:~0,-4!"
if /i "!RAW:~-1!"=="/" set "RAW=!RAW:~0,-1!"

set "OWNER="
set "REPO="
echo !RAW! | findstr /i /c:"github.com/" >nul
if !errorlevel! == 0 (
  set "REST=!RAW:*github.com/=!"
  for /f "tokens=1,2 delims=/" %%A in ("!REST!") do (
    set "OWNER=%%A"
    set "REPO=%%B"
  )
) else (
  echo !RAW! | findstr /c:"/" >nul
  if !errorlevel! == 0 (
    for /f "tokens=1,2 delims=/" %%A in ("!RAW!") do (
      set "OWNER=%%A"
      set "REPO=%%B"
    )
  )
)

if "!OWNER!"=="" goto :fail_parse
if "!REPO!"=="" goto :fail_parse
if /i "!REPO:~-4!"==".git" set "REPO=!REPO:~0,-4!"

set "DEST=%OUTDIR%\!OWNER!-!REPO!"
if not "%GITHUB_TOKEN%"=="" (
  set "URL=https://api.github.com/repos/!OWNER!/!REPO!/zipball"
  set "NOTE=API zipball"
) else (
  set "URL=https://github.com/!OWNER!/!REPO!/archive/HEAD.zip"
  set "NOTE=archive/HEAD.zip"
)

echo [INFO] !OWNER!/!REPO!  -^>  !DEST!  (!NOTE!)
if not "%DRY_RUN%"=="" if not "%DRY_RUN%"=="0" (
  echo        !URL!
  set /a OK+=1
  goto :eof
)

set "ZIP=%TEMP%\skills-dl-!RANDOM!!RANDOM!.zip"
if not "%GITHUB_TOKEN%"=="" (
  curl.exe -fL --retry 3 --retry-delay 2 -A "%UA%" -H "Authorization: Bearer %GITHUB_TOKEN%" -H "Accept: application/vnd.github+json" -o "!ZIP!" -- "!URL!"
) else (
  curl.exe -fL --retry 3 --retry-delay 2 -A "%UA%" -o "!ZIP!" -- "!URL!"
)
if errorlevel 1 (
  echo [FAIL] 下载失败：!OWNER!/!REPO!
  if exist "!ZIP!" del /f /q "!ZIP!" >nul 2>&1
  set /a FAIL+=1
  goto :eof
)

call :materialize "!ZIP!" "!DEST!"
if errorlevel 1 (
  echo [FAIL] 解压整理失败：!OWNER!/!REPO!
  if exist "!ZIP!" del /f /q "!ZIP!" >nul 2>&1
  if exist "!DEST!" rmdir /s /q "!DEST!" >nul 2>&1
  set /a FAIL+=1
  goto :eof
)

if exist "!ZIP!" del /f /q "!ZIP!" >nul 2>&1
echo [OK]   !DEST!
set /a OK+=1
goto :eof

:materialize
set "ZIPFILE=%~1"
set "TARGET=%~2"
set "WORK=%TEMP%\skills-dl-!RANDOM!!RANDOM!"
set "EXTRACT=!WORK!\extract"
mkdir "!EXTRACT!" >nul 2>&1

set "EXTRACTED=0"
where tar.exe >nul 2>&1
if not errorlevel 1 (
  tar.exe -xf "!ZIPFILE!" -C "!EXTRACT!"
  if not errorlevel 1 set "EXTRACTED=1"
)
if "!EXTRACTED!"=="0" (
  powershell -NoProfile -Command "Expand-Archive -LiteralPath '!ZIPFILE!' -DestinationPath '!EXTRACT!' -Force"
  if errorlevel 1 (
    if exist "!WORK!" rmdir /s /q "!WORK!" >nul 2>&1
    exit /b 1
  )
)

set "SRC=!EXTRACT!"
set /a N=0
set "CAND="
for /f "delims=" %%D in ('dir /b /a "!EXTRACT!"') do (
  set /a N+=1
  set "CAND=!EXTRACT!\%%D"
)
if !N! == 1 if exist "!CAND!\" set "SRC=!CAND!"

if exist "!TARGET!" rmdir /s /q "!TARGET!" >nul 2>&1
mkdir "!TARGET!" >nul 2>&1
xcopy /E /I /H /Y /Q "!SRC!\*" "!TARGET!\" >nul
if errorlevel 1 (
  if exist "!WORK!" rmdir /s /q "!WORK!" >nul 2>&1
  exit /b 1
)

if exist "!WORK!" rmdir /s /q "!WORK!" >nul 2>&1
exit /b 0

:fail_parse
echo [FAIL] 无法解析：%~1
set /a FAIL+=1
goto :eof
