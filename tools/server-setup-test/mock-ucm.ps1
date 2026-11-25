# Nachbildung des UCM-Skripts für Tests (Windows): hängt die Direktiven ans Ende der sshd_config.
param([switch]$NonInteractive, [switch]$NoPause)
$ErrorActionPreference = 'Stop'
$SshDir = Join-Path $env:ProgramData 'ssh'
$KeyDir = Join-Path $SshDir 'ssh_ca_keys'
New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
$CaPubKey = @'
CA_KEY_PLACEHOLDER
'@
Set-Content -Path (Join-Path $KeyDir 'user_ca.pub') -Value $CaPubKey.Trim() -Encoding Ascii
$cfg = Join-Path $SshDir 'sshd_config'
Add-Content -Path $cfg -Value ''
Add-Content -Path $cfg -Value '# SSH User CA Trust - added by UCM setup script'
Add-Content -Path $cfg -Value "TrustedUserCAKeys $KeyDir\user_ca.pub"
Add-Content -Path $cfg -Value "AuthorizedPrincipalsFile $SshDir\auth_principals\%u"
Write-Host 'mock UCM script done'
