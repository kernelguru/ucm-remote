# CI-Test (Windows-Runner): OpenSSH-Server installieren, Einfüge-Befehl ausführen, Ergebnis prüfen.
param([Parameter(Mandatory)] [string]$Work)
$ErrorActionPreference = 'Stop'
function Assert($cond, $msg) { if (-not $cond) { throw "FEHLER: $msg" } ; Write-Host "OK: $msg" }

if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    Write-Host 'Installiere OpenSSH-Server ...'
    try {
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    } catch {
        Write-Host "Add-WindowsCapability fehlgeschlagen ($_), versuche Chocolatey"
        choco install openssh -y --no-progress --params '"/SSHServerFeature"' | Out-Null
    }
}
Start-Service sshd
$cfg = Join-Path $env:ProgramData 'ssh\sshd_config'
for ($i = 0; $i -lt 20 -and -not (Test-Path $cfg); $i++) { Start-Sleep 1 }
Assert (Test-Path $cfg) 'sshd_config vorhanden'
if (-not (Select-String -Path $cfg -Pattern '^Match' -Quiet)) {
    Add-Content -Path $cfg -Value "`r`nMatch Group administrators`r`n       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys"
}

Write-Host '=== Einfuege-Befehl ==='
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Work 'paste-windows.ps1')

Write-Host '=== Pruefung ==='
$lines = [IO.File]::ReadAllLines($cfg)
$lines | Select-String -Pattern 'TrustedUserCAKeys|RevokedKeys|AuthorizedPrincipalsFile|^Match' | ForEach-Object { Write-Host $_ }
$match = ($lines | Select-String -Pattern '^Match' | Select-Object -First 1).LineNumber
$trusted = ($lines | Select-String -Pattern '^TrustedUserCAKeys' | Select-Object -First 1).LineNumber
$revoked = ($lines | Select-String -Pattern '^RevokedKeys' | Select-Object -First 1).LineNumber
Assert ($trusted -and $trusted -lt $match) 'TrustedUserCAKeys steht vor Match'
Assert ($revoked -and $revoked -lt $match) 'RevokedKeys steht vor Match'
Assert (-not ($lines | Select-String -Pattern '^\s*AuthorizedPrincipalsFile')) 'AuthorizedPrincipalsFile entfernt'
$krl = Join-Path $env:ProgramData 'ssh\ucm_revoked_keys.krl'
$bytes = [IO.File]::ReadAllBytes($krl)
Assert ([Text.Encoding]::ASCII.GetString($bytes, 0, 6) -eq 'SSHKRL') 'KRL geladen'
Assert (Get-ScheduledTask -TaskName 'UCM Remote KRL Update' -ErrorAction SilentlyContinue) 'Geplante Aufgabe vorhanden'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $env:ProgramData 'ssh\ucm-krl\update.ps1')
Assert ($LASTEXITCODE -eq 0) 'Updater laeuft mit Pinning'
$acl = (Get-Acl (Join-Path $env:ProgramData 'ssh\ucm-krl')).Access | ForEach-Object { $_.IdentityReference.Value }
Assert (-not ($acl | Where-Object { $_ -match 'Users|Benutzer|Everyone' })) 'Nur SYSTEM/Administratoren duerfen den Schluessel lesen'
$svc = Get-CimInstance Win32_Service -Filter "Name='sshd'"
& ($svc.PathName.Trim('"')) -t
Assert ($LASTEXITCODE -eq 0) 'sshd -t'
Assert ((Get-Service sshd).Status -eq 'Running') 'sshd laeuft'

Write-Host '=== Zweiter Lauf ==='
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Work 'paste-windows.ps1')
Assert (@([IO.File]::ReadAllLines($cfg) | Select-String -Pattern '^RevokedKeys').Count -eq 1) 'RevokedKeys genau einmal'

Write-Host '=== Entfernen ==='
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Work 'paste-windows-remove.ps1')
Assert (-not ([IO.File]::ReadAllLines($cfg) | Select-String -Pattern '^RevokedKeys')) 'RevokedKeys entfernt'
Assert (-not (Get-ScheduledTask -TaskName 'UCM Remote KRL Update' -ErrorAction SilentlyContinue)) 'Aufgabe entfernt'
Write-Host 'ALLES OK'
