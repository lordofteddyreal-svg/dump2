#Requires -Version 5.1
<#
.SYNOPSIS
  SpaceDLC (spacedlc.ru) launcher dump: API + dynamic file/memory capture.
  Target: https://spacedlc.ru/files/launcher.exe (adl_launcher.exe, packed 18MB)

.DESCRIPTION
  1. Скачивает свежий launcher.exe, считает хэши
  2. Если заданы SPACEDLC_LOGIN / SPACEDLC_PASSWORD (GitHub Secrets) -
     логинится POST {username,password} -> /auth/login, дергает
     /frontend/files/mods, /user/profile и пробует скачать jar-моды
  3. Запускает лаунчер на N секунд, собирает:
     - новые файлы в APPDATA/LOCALAPPDATA/TEMP/.minecraft
     - TCP-соединения, процессы
     - memory dump через ProcDump + strings-выжимку URL/jar/spacedlc
  4. Все складывает в C:\dump\out + SUMMARY.md

.USAGE (GitHub Actions, windows-latest):
  $env:SPACEDLC_LOGIN="user"; $env:SPACEDLC_PASSWORD="pass"
  powershell -ExecutionPolicy Bypass -File .\dump.ps1 -RunSeconds 60 -Beta:$false

.USAGE (local Windows):
  powershell -ExecutionPolicy Bypass -File dump.ps1
#>
param(
  [string]$LauncherUrl = "https://spacedlc.ru/files/launcher.exe",
  [string]$ApiBase = "https://spacedlc.ru/api",
  [int]$RunSeconds = 60,
  [switch]$Beta,
  [string]$WorkDir = "C:\dump",
  [string]$OutDir = "C:\dump\out"
)

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Log([string]$m) {
  $ts = Get-Date -Format "HH:mm:ss"
  Write-Host "[$ts] $m"
}
function Save-Text([string]$path, [string]$text) {
  $d = Split-Path $path -Parent
  if ($d -and !(Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  [IO.File]::WriteAllText($path, $text)
}
function Snapshot-Files([string[]]$roots) {
  $out = @()
  foreach ($r in $roots) {
    if (!$r -or !(Test-Path $r)) { continue }
    try {
      $out += Get-ChildItem -Path $r -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object @{n="Root";e={$r}}, FullName, Length, LastWriteTime
    } catch {}
  }
  return $out
}

New-Item -ItemType Directory -Force -Path $WorkDir, $OutDir | Out-Null
$summary = New-Object System.Text.StringBuilder
[void]$summary.AppendLine("# SpaceDLC dump $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
[void]$summary.AppendLine("")

# ---------- 0. env ----------
Log "=== ENV ==="
$sysinfo = @"
OS: $([Environment]::OSVersion.VersionString)
User: $env:USERNAME Computer: $env:COMPUTERNAME
PS: $($PSVersionTable.PSVersion)
APPDATA=$env:APPDATA
LOCALAPPDATA=$env:LOCALAPPDATA
TEMP=$env:TEMP
"@
Save-Text "$OutDir\env.txt" $sysinfo
Log $sysinfo
[void]$summary.AppendLine("## Env")
[void]$summary.AppendLine('```')
[void]$summary.AppendLine($sysinfo)
[void]$summary.AppendLine('```')

# ---------- 1. download launcher ----------
Log "=== DOWNLOAD LAUNCHER ==="
$launcher = Join-Path $WorkDir "spacelauncher.exe"
try {
  Invoke-WebRequest -Uri $LauncherUrl -OutFile $launcher -UseBasicParsing -TimeoutSec 120
  Log "downloaded $LauncherUrl"
} catch {
  Log "download FAILED: $($_.Exception.Message)"
}
if (Test-Path $launcher) {
  $h = Get-FileHash $launcher -Algorithm SHA256
  $sz = (Get-Item $launcher).Length
  # first 2 bytes must be MZ
  $br = New-Object IO.BinaryReader([IO.File]::OpenRead($launcher))
  $mz = [Text.Encoding]::ASCII.GetString($br.ReadBytes(2)); $br.Close()
  $info = "file=$launcher`nsize=$sz`nsha256=$($h.Hash)`nMZ=$mz`nurl=$LauncherUrl"
  Save-Text "$OutDir\launcher-info.txt" $info
  Log $info
  Copy-Item $launcher "$OutDir\spacelauncher.exe" -Force
  [void]$summary.AppendLine("## Launcher")
  [void]$summary.AppendLine('```')
  [void]$summary.AppendLine($info)
  [void]$summary.AppendLine('```')
} else {
  Log "no launcher binary, abort dynamic part"
  [void]$summary.AppendLine("## Launcher: DOWNLOAD FAILED")
}

# ---------- 2. API probe (site = SPA, apiUrl=spacedlc.ru) ----------
Log "=== API PROBE ==="
$login = $env:SPACEDLC_LOGIN
$pass = $env:SPACEDLC_PASSWORD
$token = $null
$apiLog = New-Object System.Text.StringBuilder

function Api-Call([string]$method, [string]$path, $body, [string]$tok) {
  $url = "$ApiBase$path"
  $headers = @{ "Accept" = "application/json" }
  if ($tok) { $headers["Authorization"] = "Bearer $tok" }
  try {
    $p = @{ Uri = $url; Method = $method; Headers = $headers; TimeoutSec = 20; UseBasicParsing = $true }
    if ($body -ne $null) {
      $p["ContentType"] = "application/json"
      $p["Body"] = ($body | ConvertTo-Json -Compress)
    }
    $r = Invoke-WebRequest @p
    return @{ ok = $true; status = $r.StatusCode; text = $r.Content }
  } catch {
    $st = $null; $tx = $_.Exception.Message
    try {
      $resp = $_.Exception.Response
      if ($resp) {
        $st = [int]$resp.StatusCode
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        $tx = $sr.ReadToEnd(); $sr.Close()
      }
    } catch {}
    return @{ ok = $false; status = $st; text = $tx }
  }
}

# public probe (expected 403/404 without token)
foreach ($p in @("/frontend/files/mods?beta=false", "/user/profile")) {
  $r = Api-Call "GET" $p $null $null
  [void]$apiLog.AppendLine("$p -> $($r.status) $($r.text.Substring(0, [Math]::Min(300, $r.text.Length)))")
}
Log $apiLog.ToString()
Save-Text "$OutDir\api-public.txt" $apiLog.ToString()

if ($login -and $pass) {
  Log "login as $login ..."
  $lr = Api-Call "POST" "/auth/login" @{ username = $login; password = $pass } $null
  Save-Text "$OutDir\api-login.txt" "status=$($lr.status)`n$($lr.text)"
  Log "login status=$($lr.status)"
  try {
    $lj = $lr.text | ConvertFrom-Json
    # token field name varies (token/accessToken/jwt) - try all
    $token = $lj.token
    if (!$token) { $token = $lj.accessToken }
    if (!$token) { $token = $lj.jwt }
    if (!$token) { $token = $lj.data.token }
    if (!$token -and $lj -is [string]) { $token = $lj }
  } catch { Log "login json parse failed" }
  if ($token) {
    Save-Text "$OutDir\token.txt" $token
    Log "got token len=$($token.Length)"
    $betaStr = if ($Beta) { "true" } else { "false" }
    foreach ($p in @(
      "/frontend/files/mods?beta=$betaStr",
      "/frontend/files/mods?beta=false",
      "/user/profile",
      "/user/getHwid"
    )) {
      $r = Api-Call "GET" $p $null $token
      $fn = ($p -replace "[^a-zA-Z0-9]+", "_") + ".json"
      Save-Text "$OutDir\api-$fn" "status=$($r.status)`n$($r.text)"
      Log "$p -> $($r.status) len=$($r.text.Length)"
    }
    # user/sub needs x-www-form-urlencoded POST, probe it
    try {
      $u = "$ApiBase/user/sub"
      $rr = Invoke-WebRequest -Uri $u -Method POST -Headers @{ Authorization = "Bearer $token" } -ContentType "application/x-www-form-urlencoded" -Body "" -UseBasicParsing -TimeoutSec 20
      Save-Text "$OutDir\api-user-sub.txt" "status=$($rr.StatusCode)`n$($rr.Content)"
    } catch {
      Save-Text "$OutDir\api-user-sub.txt" "FAILED: $($_.Exception.Message)"
    }
    # try to download jars if mods list contains urls
    try {
      $modsRaw = Get-Content "$OutDir\api-_frontend_files_mods_beta_$($betaStr).json" -Raw -ErrorAction Stop
      $urls = [regex]::Matches($modsRaw, 'https?://[^\s"''<>]+?\.jar[^\s"''<>]*') | ForEach-Object { $_.Value } | Sort-Object -Unique
      Save-Text "$OutDir\mod-urls.txt" ($urls -join "`n")
      Log "found $($urls.Count) jar urls in mods list"
      $i = 0
      foreach ($u in $urls) {
        $i++
        try {
          $dst = Join-Path $OutDir ("mod-$i.jar")
          Invoke-WebRequest -Uri $u -OutFile $dst -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing -TimeoutSec 120
          Log "downloaded mod $i : $u"
        } catch { Log "mod download failed $u : $($_.Exception.Message)" }
        if ($i -ge 20) { break }
      }
    } catch { Log "no mods list to parse for jars" }
    [void]$summary.AppendLine("## API: login OK, see api-*.json")
  } else {
    Log "NO TOKEN extracted, check api-login.txt (maybe Turnstile captcha or wrong creds)"
    [void]$summary.AppendLine("## API: login FAILED (no token, see api-login.txt)")
  }
} else {
  Log "SPACEDLC_LOGIN/PASSWORD not set -> anonymous mode only. Set GitHub Secrets to enable authed mod download."
  [void]$summary.AppendLine("## API: anonymous (no creds, see api-public.txt)")
}

# ---------- 3. dynamic run ----------
Log "=== DYNAMIC RUN ($RunSeconds s) ==="
$roots = @($env:APPDATA, $env:LOCALAPPDATA, $env:TEMP, $env:USERPROFILE, (Get-Location).Path, $WorkDir, $OutDir, "C:\ProgramData")
$mc = Join-Path $env:APPDATA ".minecraft"
if (Test-Path $mc) { $roots += $mc }
$before = Snapshot-Files $roots
$before | Export-Csv "$OutDir\files-before.csv" -NoTypeInformation -Encoding UTF8
Log "files before: $($before.Count)"

$tcpBefore = @()
try { $tcpBefore = Get-NetTCPConnection -ErrorAction Stop | Where-Object { $_.State -eq "Established" } } catch {}
$tcpBefore | Out-String | Out-File "$OutDir\tcp-before.txt"

$proc = $null
$runLog = New-Object System.Text.StringBuilder
if (Test-Path $launcher) {
  try {
    # лаунчер GUI + требует логин: запускаем без ключей, GUI может висеть - это ок, нам нужны файлы/память/сеть
    $proc = Start-Process -FilePath $launcher -WorkingDirectory $WorkDir -PassThru -ErrorAction Stop
    [void]$runLog.AppendLine("started pid=$($proc.Id) at $(Get-Date -Format o)")
    Log "started pid=$($proc.Id)"
    # быстрая проверка: жив ли через 5 сек, сразу снимаем процессы/сеть (иначе GUI на headless-раннере дохнет мгновенно)
    Start-Sleep -Seconds 5
    try {
      $p = Get-Process -Id $proc.Id -ErrorAction Stop
      [void]$runLog.AppendLine("alive after 5s: $($p.ProcessName) responding=$($p.Responding)")
      Log "alive after 5s: $($p.ProcessName)"
      Get-Process -Id $proc.Id | Out-String | Out-File "$OutDir\launcher-proc-early.txt"
    } catch {
      [void]$runLog.AppendLine("EXITED within 5s (headless/GUI/login-required?). ExitCode check via WMI:")
      try {
        $w = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" -ErrorAction Stop
        [void]$runLog.AppendLine("still in WMI: $($w.CommandLine)")
      } catch { [void]$runLog.AppendLine("not in WMI either -> процесс сразу завершился") }
      Log "process already exited within 5s"
    }
    Start-Sleep -Seconds ([Math]::Max(0, $RunSeconds - 5))
    try {
      $p = Get-Process -Id $proc.Id -ErrorAction Stop
      Log "still running, capturing memory..."
    } catch { Log "process already exited" }
  } catch {
    [void]$runLog.AppendLine("Start-Process FAILED: $($_.Exception.Message)")
    Log "Start-Process failed: $($_.Exception.Message)"
  }
  Save-Text "$OutDir\run.log" $runLog.ToString()
}

# TCP after
try {
  Get-NetTCPConnection -ErrorAction Stop | Where-Object { $_.State -eq "Established" } |
    Out-String | Out-File "$OutDir\tcp-after.txt"
  Log "tcp snapshot saved"
} catch { Log "tcp capture failed" }
try { Get-Process | Sort-Object ProcessName | Out-String | Out-File "$OutDir\processes.txt" } catch {}
try {
  Get-WinEvent -LogName Application -MaxEvents 50 -ErrorAction Stop |
    Where-Object { $_.Message -match "spacelauncher|adl_launcher|Visual C\+\+|VCRUNTIME|\.NET|SideBySide" } |
    Format-List TimeCreated, ProviderName, Id, Message | Out-String | Out-File "$OutDir\eventlog-app.txt"
  Log "eventlog saved"
} catch { Log "eventlog read failed: $($_.Exception.Message)" }

# screenshots of new files
Start-Sleep -Seconds 2
$after = Snapshot-Files $roots
$after | Export-Csv "$OutDir\files-after.csv" -NoTypeInformation -Encoding UTF8
$beforeSet = @{}
foreach ($b in $before) { $beforeSet[$b.FullName] = $true }
$newFiles = @($after | Where-Object { -not $beforeSet.ContainsKey($_.FullName) })
Log "new files: $($newFiles.Count)"
$newFiles | Format-Table FullName, Length, LastWriteTime -AutoSize | Out-String | Out-File "$OutDir\files-new.txt"
$newFiles | Export-Csv "$OutDir\files-new.csv" -NoTypeInformation -Encoding UTF8

# copy interesting new files (jar/json/log/config)
$collect = Join-Path $OutDir "collected"
New-Item -ItemType Directory -Force -Path $collect | Out-Null
foreach ($f in $newFiles) {
  if ($f.FullName -match '\.(jar|json|log|txt|cfg|properties|toml)$') {
    try {
      $dst = Join-Path $collect ([IO.Path]::GetFileName($f.FullName))
      # dedupe names
      $k = 1
      while (Test-Path $dst) { $dst = Join-Path $collect ("$k-" + [IO.Path]::GetFileName($f.FullName)); $k++ }
      Copy-Item $f.FullName $dst -Force -ErrorAction Stop
    } catch {}
  }
}
# also always grab .minecraft/mods if exists
foreach ($cand in @("$env:APPDATA\.minecraft\mods", "$env:APPDATA\SpaceVisuals", "$WorkDir\mods")) {
  if (Test-Path $cand) {
    try { Copy-Item $cand (Join-Path $collect ([IO.Path]::GetFileName($cand))) -Recurse -Force } catch {}
  }
}
Log "collected interesting files"

# ---------- 4. memory dump via ProcDump ----------
if ($proc) {
  try {
    $pdZip = Join-Path $WorkDir "procdump.zip"
    $pdDir = Join-Path $WorkDir "procdump"
    if (!(Test-Path (Join-Path $pdDir "procdump.exe"))) {
      New-Item -ItemType Directory -Force -Path $pdDir | Out-Null
      Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Procdump.zip" -OutFile $pdZip -UseBasicParsing -TimeoutSec 120
      Expand-Archive -Path $pdZip -DestinationPath $pdDir -Force
    }
    $pd = Join-Path $pdDir "procdump.exe"
    if (Test-Path $pd) {
      $dmp = Join-Path $OutDir "launcher.dmp"
      # -ma full memory, -accepteula silent
      $stillRunning = $false
      try { Get-Process -Id $proc.Id -ErrorAction Stop | Out-Null; $stillRunning = $true } catch {}
      if ($stillRunning) {
        Log "procdump -ma $($proc.Id) ..."
        & $pd -accepteula -ma $proc.Id $dmp | Out-String | Out-File "$OutDir\procdump.log"
        Log "procdump done"
      } else {
        Log "process exited before procdump, skip"
      }
    }
  } catch { Log "procdump failed: $($_.Exception.Message)" }
  try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop; Log "killed pid $($proc.Id)" } catch {}
}

# ---------- 5. strings over binary + dumps ----------
Log "=== STRINGS ==="
function Extract-Strings([string]$file, [string]$outFile) {
  try {
    $bytes = [IO.File]::ReadAllBytes($file)
    $txt = [Text.Encoding]::ASCII.GetString($bytes)
    $urls = [regex]::Matches($txt, 'https?://[A-Za-z0-9\.\-/:_?=&%+#;@~\(\)\[\]\{\}\$,!''\*]+') |
      ForEach-Object { $_.Value.TrimEnd('.', ',', ';', '!', ')', ']', '"', "'") } |
      Where-Object { $_.Length -gt 10 } | Sort-Object -Unique
    $hits = [regex]::Matches($txt, '(?i)(spacedlc|adl_launcher|adl_get_hwid|\.jar\b|minecraft|mojang|fabric|forge|quilt|neoforge|/auth/|/frontend/|bearer|hwid|modrinth|curseforge)[^\x00-\x1F\x7F]{0,160}') |
      ForEach-Object { $_.Value } | Sort-Object -Unique
    $res = "== URLS ($($urls.Count)) ==`n" + ($urls -join "`n") + "`n`n== HITS ($($hits.Count)) ==`n" + ($hits -join "`n")
    Save-Text $outFile $res
    Log "$file -> urls=$($urls.Count) hits=$($hits.Count)"
  } catch { Log "strings failed for $file : $($_.Exception.Message)" }
}
if (Test-Path $launcher) { Extract-Strings $launcher "$OutDir\strings-launcher.txt" }
foreach ($d in @(Get-ChildItem $OutDir -Filter *.dmp -ErrorAction SilentlyContinue)) {
  Extract-Strings $d.FullName "$OutDir\strings-$($d.BaseName).txt"
}
foreach ($j in @(Get-ChildItem $collect -Filter *.jar -ErrorAction SilentlyContinue)) {
  try {
    # jar = zip: list entries without extracting
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($j.FullName)
    ($zip.Entries | Select-Object FullName, Length | Out-String) | Out-File "$OutDir\jar-$($j.BaseName)-entries.txt"
    $zip.Dispose()
  } catch { Log "jar list failed $($j.Name)" }
}

# ---------- summary ----------
[void]$summary.AppendLine("")
[void]$summary.AppendLine("## Dynamic")
[void]$summary.AppendLine("- files before: $($before.Count), new: $($newFiles.Count)")
[void]$summary.AppendLine("- collected: $((Get-ChildItem $collect -ErrorAction SilentlyContinue | Measure-Object).Count) files")
[void]$summary.AppendLine("- memory dumps: $((Get-ChildItem $OutDir -Filter *.dmp -ErrorAction SilentlyContinue | Measure-Object).Count)")
[void]$summary.AppendLine("- jars in collected: $((Get-ChildItem $collect -Filter *.jar -ErrorAction SilentlyContinue | Measure-Object).Count)")
[void]$summary.AppendLine("")
[void]$summary.AppendLine("Смотри: strings-launcher.txt, strings-launcher_*.txt, mod-urls.txt, api-*.json, collected/, files-new.txt")
Save-Text "$OutDir\SUMMARY.md" $summary.ToString()
Log "DONE -> $OutDir"
Get-ChildItem $OutDir | Format-Table Name, Length -AutoSize | Out-String | Write-Host
