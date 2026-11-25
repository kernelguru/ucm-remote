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
        # Prüfung in C#: ein PowerShell-Scriptblock als Callback läuft auf einem fremden Thread
        # ohne Runspace und bricht die Verbindung ab.
        if (-not ('UcmRemotePin' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
public static class UcmRemotePin {
    public static string Expected;
    public static bool Check(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
        if (cert == null || string.IsNullOrEmpty(Expected)) return false;
        using (SHA256 sha = SHA256.Create()) {
            string fp = BitConverter.ToString(sha.ComputeHash(cert.GetRawCertData())).Replace("-", ":");
            return string.Equals(fp, Expected, StringComparison.OrdinalIgnoreCase);
        }
    }
}
'@
        }
        [UcmRemotePin]::Expected = [string]$cfg.pin
        [Net.ServicePointManager]::ServerCertificateValidationCallback =
            [Delegate]::CreateDelegate([Net.Security.RemoteCertificateValidationCallback], [UcmRemotePin].GetMethod('Check'))
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
    $detail = $_.Exception
    $msg = $detail.Message
    while ($detail.InnerException) { $detail = $detail.InnerException; $msg += ' / ' + $detail.Message }
    Log ("Fehler, bisherige Sperrliste bleibt aktiv: " + $msg)
    exit 1
}
