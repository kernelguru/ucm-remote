# UCM Remote: automatische Sperrliste (KRL) wieder entfernen
$ErrorActionPreference = 'Stop'
$SshDir = Join-Path $env:ProgramData 'ssh'
$SshdConfig = Join-Path $SshDir 'sshd_config'
Unregister-ScheduledTask -TaskName 'UCM Remote KRL Update' -Confirm:$false -ErrorAction SilentlyContinue
Copy-Item -Path $SshdConfig -Destination ("$SshdConfig.ucm-remote." + (Get-Date -Format 'yyyyMMddHHmmss')) -Force
$lines = [IO.File]::ReadAllLines($SshdConfig) | Where-Object {
    $_ -ne '# SSH revocation list: added by UCM Remote' -and -not ($_.TrimStart() -match '^(?i)RevokedKeys\b.*ucm_revoked_keys\.krl')
}
[IO.File]::WriteAllLines($SshdConfig, [string[]]$lines, (New-Object System.Text.UTF8Encoding $false))
Restart-Service -Name sshd -Force
Remove-Item -Recurse -Force (Join-Path $SshDir 'ucm-krl') -ErrorAction SilentlyContinue
Remove-Item -Force (Join-Path $SshDir 'ucm_revoked_keys.krl') -ErrorAction SilentlyContinue
Write-Host '[OK]    Automatische Sperrliste entfernt. Der API-Schluessel kann jetzt in UCM widerrufen werden.' -ForegroundColor Green
