# ============================================================================
# UCM Remote: SSH-CA auf einem Windows-Server (OpenSSH) einrichten
# CA: __CA_NAME__
#
#   1. Einrichtungsskript von Ultimate CA Manager ausfuehren
#   2. Direktiven, die im Block "Match Group administrators" gelandet sind, nach oben holen
#   3. Principals einrichten
#   4. Optional: Sperrliste (KRL) per geplanter Aufgabe von UCM holen (RevokedKeys)
# ============================================================================
$ErrorActionPreference = 'Stop'

$CaType         = '__CA_TYPE__'
$PrincipalsMode = '__PRINCIPALS_MODE__'
$Principals     = __PRINCIPALS_PSQ__
$KrlEnabled     = '__KRL_ENABLED__' -eq '1'
$KrlInterval    = [int]'__KRL_INTERVAL__'
$UcmScriptB64   = '__UCM_SCRIPT_B64__'
$UpdaterB64     = '__UPDATER_B64__'

$SshDir        = Join-Path $env:ProgramData 'ssh'
$SshdConfig    = Join-Path $SshDir 'sshd_config'
$PrincipalsDir = Join-Path $SshDir 'auth_principals'
$KrlDir        = Join-Path $SshDir 'ucm-krl'
$KrlFile       = Join-Path $SshDir 'ucm_revoked_keys.krl'
$KrlDirective  = 'RevokedKeys __PROGRAMDATA__/ssh/ucm_revoked_keys.krl'
$TaskName      = 'UCM Remote KRL Update'
$Utf8Bom       = New-Object System.Text.UTF8Encoding $true
$Utf8NoBom     = New-Object System.Text.UTF8Encoding $false

function Info($m) { Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[OK]    $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

function Keyword([string]$line) {
    $t = $line.TrimStart()
    if ($t -match '^([^\s=]+)') { return $Matches[1].ToLowerInvariant() }
    return ''
}
function Read-Config { return [string[]][IO.File]::ReadAllLines($SshdConfig) }
function Write-Config([string[]]$lines) { [IO.File]::WriteAllLines($SshdConfig, $lines, $Utf8NoBom) }
function First-Match([string[]]$lines) {
    for ($i = 0; $i -lt $lines.Count; $i++) { if ((Keyword $lines[$i]) -eq 'match') { return $i } }
    return -1
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail 'Bitte in einer PowerShell als Administrator ausfuehren.'
}

$sshdExe = $null
$svc = Get-CimInstance Win32_Service -Filter "Name='sshd'" -ErrorAction SilentlyContinue
if ($svc -and $svc.PathName) { $sshdExe = $svc.PathName.Trim('"') }
if (-not $sshdExe -or -not (Test-Path $sshdExe)) { $sshdExe = (Get-Command sshd.exe -ErrorAction SilentlyContinue).Source }

# --- Schritt 1: Skript von UCM ----------------------------------------------
Info 'Schritt 1/4: Einrichtungsskript von UCM'
$ucmFile = Join-Path $env:TEMP ('ucm-ca-setup-' + [guid]::NewGuid().ToString() + '.ps1')
[IO.File]::WriteAllText($ucmFile, $Utf8NoBom.GetString([Convert]::FromBase64String($UcmScriptB64)), $Utf8Bom)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ucmFile -NonInteractive -NoPause
$ucmExit = $LASTEXITCODE
Remove-Item -Force $ucmFile -ErrorAction SilentlyContinue
if ($ucmExit -ne 0) { Fail 'Das UCM-Skript ist fehlgeschlagen (siehe oben).' }
Write-Host ''

if (-not (Test-Path $SshdConfig)) { Fail "$SshdConfig nicht gefunden." }
$backup = "$SshdConfig.ucm-remote." + (Get-Date -Format 'yyyyMMddHHmmss')
Copy-Item -Path $SshdConfig -Destination $backup -Force
Info "Sicherung: $backup"
$original = [IO.File]::ReadAllText($SshdConfig)

# --- Schritt 2: Direktiven aus Match-Bloecken holen ---------------------------
Info 'Schritt 2/4: Lage der Direktiven in sshd_config pruefen'
$keys = @('trustedusercakeys', 'authorizedprincipalsfile', 'hostcertificate', 'revokedkeys')
$lines = Read-Config
$m = First-Match $lines
if ($m -ge 0) {
    $seen = @{}
    for ($i = 0; $i -lt $m; $i++) { $k = Keyword $lines[$i]; if ($keys -contains $k) { $seen[$k] = $true } }
    $move = @{}
    for ($i = $m + 1; $i -lt $lines.Count; $i++) {
        $k = Keyword $lines[$i]
        if (($keys -contains $k) -and -not $seen.ContainsKey($k)) {
            $move[$i] = $true; $seen[$k] = $true
            if ($i - 1 -gt $m -and $lines[$i - 1] -match '^#.*UCM') { $move[$i - 1] = $true }
        }
    }
    if ($move.Count -gt 0) {
        $out = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $m; $i++) { $out.Add($lines[$i]) }
        for ($i = $m + 1; $i -lt $lines.Count; $i++) { if ($move.ContainsKey($i)) { $out.Add($lines[$i]) } }
        $out.Add('')
        for ($i = $m; $i -lt $lines.Count; $i++) { if (-not $move.ContainsKey($i)) { $out.Add($lines[$i]) } }
        Write-Config $out.ToArray()
        Ok 'Direktiven vor den ersten Match-Block verschoben'
    } else { Ok 'Nichts zu verschieben' }
} else { Ok 'Kein Match-Block vorhanden' }

# --- Schritt 3: Principals ----------------------------------------------------
Info 'Schritt 3/4: Principals'
if ($CaType -eq 'user') {
    if ($PrincipalsMode -eq 'username') {
        $lines = Read-Config
        $kept = @($lines | Where-Object { -not ((Keyword $_) -eq 'authorizedprincipalsfile' -and $_ -match 'auth_principals') })
        if ($kept.Count -ne $lines.Count) {
            Write-Config $kept
            Ok 'AuthorizedPrincipalsFile entfernt: Principal = Benutzername'
        } else { Ok 'Principal = Benutzername' }
    } elseif ($PrincipalsMode -eq 'file') {
        New-Item -ItemType Directory -Force -Path $PrincipalsDir | Out-Null
        $count = 0
        foreach ($entry in ($Principals -split "`n")) {
            $entry = $entry.Trim()
            if (-not $entry -or -not $entry.Contains(':')) { continue }
            $user = $entry.Substring(0, $entry.IndexOf(':')).Trim()
            if ($user -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { Warn "Ungueltiger Benutzername uebersprungen: $user"; continue }
            $list = @($entry.Substring($entry.IndexOf(':') + 1) -split '[,\s]+' | Where-Object { $_ })
            [IO.File]::WriteAllLines((Join-Path $PrincipalsDir $user), [string[]]$list, $Utf8NoBom)
            Ok ("Principals fuer ${user}: " + ($list -join ' '))
            $count++
        }
        if ($count -eq 0) { Warn "Keine Eintraege. Ohne $PrincipalsDir\<benutzer> ist keine Anmeldung per Zertifikat moeglich." }
    } else { Ok 'Unveraendert' }
} else { Ok 'Host-CA, nichts zu tun' }

# --- Schritt 4: Sperrliste (KRL) ---------------------------------------------
Info 'Schritt 4/4: Sperrliste (KRL)'
if ($KrlEnabled -and $CaType -eq 'user') {
    New-Item -ItemType Directory -Force -Path $KrlDir | Out-Null
    # Nur SYSTEM und Administratoren duerfen den API-Schluessel lesen
    & icacls.exe $KrlDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    $config = [ordered]@{
        url     = __UCM_URL_PSQ__
        caId    = '__CA_ID__'
        pin     = __PIN_PSQ__
        apiKey  = __API_KEY_PSQ__
        krlFile = $KrlFile
    }
    [IO.File]::WriteAllText((Join-Path $KrlDir 'config.json'), ($config | ConvertTo-Json), $Utf8NoBom)
    $updater = Join-Path $KrlDir 'update.ps1'
    [IO.File]::WriteAllText($updater, $Utf8NoBom.GetString([Convert]::FromBase64String($UpdaterB64)), $Utf8Bom)

    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $updater
    if ($LASTEXITCODE -ne 0) {
        Fail "Die Sperrliste konnte nicht geladen werden, RevokedKeys wird nicht gesetzt. Test: powershell -File `"$updater`""
    }
    Ok "Sperrliste geladen: $KrlFile"

    $lines = Read-Config
    $existing = @($lines | Where-Object { (Keyword $_) -eq 'revokedkeys' })
    if ($existing.Count -gt 0) {
        if ($existing[0] -match 'ucm_revoked_keys\.krl') { Ok 'RevokedKeys ist bereits gesetzt' }
        else { Warn ('RevokedKeys zeigt bereits auf eine andere Datei, bitte pruefen: ' + $existing[0]) }
    } else {
        $m = First-Match $lines
        $out = New-Object System.Collections.Generic.List[string]
        if ($m -ge 0) {
            for ($i = 0; $i -lt $m; $i++) { $out.Add($lines[$i]) }
            $out.Add('# SSH revocation list: added by UCM Remote'); $out.Add($KrlDirective); $out.Add('')
            for ($i = $m; $i -lt $lines.Count; $i++) { $out.Add($lines[$i]) }
        } else {
            foreach ($l in $lines) { $out.Add($l) }
            $out.Add(''); $out.Add('# SSH revocation list: added by UCM Remote'); $out.Add($KrlDirective)
        }
        Write-Config $out.ToArray()
        Ok "$KrlDirective eingetragen"
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$updater`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $KrlInterval)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Ok "Geplante Aufgabe '$TaskName' aktiv: alle $KrlInterval Minuten"
} else { Ok 'Nicht gewuenscht' }

# --- Pruefen und neu starten --------------------------------------------------
if ($sshdExe -and (Test-Path $sshdExe)) {
    & $sshdExe -t
    if ($LASTEXITCODE -ne 0) {
        Copy-Item -Path $backup -Destination $SshdConfig -Force
        Fail "sshd -t meldet einen Fehler, $backup wurde wiederhergestellt."
    }
    Ok 'sshd-Konfiguration ist gueltig'
} else { Warn 'sshd.exe nicht gefunden, Konfiguration ungeprueft' }
if ([IO.File]::ReadAllText($SshdConfig) -ne $original) {
    try { Restart-Service -Name sshd -Force; Ok 'sshd neu gestartet' }
    catch { Warn "sshd konnte nicht neu gestartet werden: $_" }
}
Write-Host ''
Ok 'Fertig.'
