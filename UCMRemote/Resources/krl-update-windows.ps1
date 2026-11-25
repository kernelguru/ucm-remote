# UCM Remote: holt die SSH-Sperrliste (KRL) von Ultimate CA Manager.
# Läuft als geplante Aufgabe unter SYSTEM. Bei Fehlern bleibt die bisherige Liste aktiv.
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -Raw -Path (Join-Path $PSScriptRoot 'config.json') | ConvertFrom-Json
$log = Join-Path $PSScriptRoot 'update.log'
function Log($m) {
    $line = (Get-Date -Format 's') + ' ' + $m
    Add-Content -Path $log -Value $line
    Write-Host $line
}
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if ($cfg.pin) {
        $global:UcmPin = ([string]$cfg.pin).ToUpperInvariant()
        [Net.ServicePointManager]::ServerCertificateValidationCallback = {
            param($sender, $cert, $chain, $errors)
            $sha = [Security.Cryptography.SHA256]::Create()
            $fp = [BitConverter]::ToString($sha.ComputeHash($cert.GetRawCertData())).Replace('-', ':')
            return $fp -eq $global:UcmPin
        }
    }
    $tmp = $cfg.krlFile + '.download'
    $url = $cfg.url + '/api/v2/ssh/cas/' + $cfg.caId + '/krl'
    Invoke-WebRequest -Uri $url -Headers @{ 'X-API-Key' = $cfg.apiKey } -OutFile $tmp -UseBasicParsing -TimeoutSec 60
    $bytes = [IO.File]::ReadAllBytes($tmp)
    if ($bytes.Length -lt 6 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 6) -ne 'SSHKRL') {
        Remove-Item -Force $tmp
        throw 'Antwort ist keine KRL'
    }
    Move-Item -Force -Path $tmp -Destination $cfg.krlFile
    if ((Get-Item $log -ErrorAction SilentlyContinue).Length -gt 1MB) { Remove-Item -Force $log }
    exit 0
} catch {
    Log ("Fehler, bisherige Sperrliste bleibt aktiv: " + $_)
    exit 1
}
