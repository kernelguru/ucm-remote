#!/usr/bin/env python3
"""Rendert die Server-Vorlagen der App wie ServerSetup.swift, für die CI-Tests der Skripte.

render.py linux|windows <mock-ucm-script> <url> <pin> <out>
"""
import base64
import pathlib
import sys

res = pathlib.Path(__file__).resolve().parents[2] / "UCMRemote" / "Resources"
platform, mock, url, pin, out = sys.argv[1:6]
ucm = pathlib.Path(mock).read_text()
principals = "alice: alice, ops\nroot: root\nbad/user: x"


def shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def psq(s):
    return "'" + s.replace("'", "''") + "'"


common = {"__CA_NAME__": "CI Test CA", "__CA_TYPE__": "user", "__PRINCIPALS_MODE__": "username",
          "__KRL_ENABLED__": "1", "__KRL_INTERVAL__": "15", "__CA_ID__": "3"}
if platform == "linux":
    t = (res / "server-setup-linux.sh").read_text()
    vals = dict(common, __PRINCIPALS_Q__=shq(principals), __UCM_URL_Q__=shq(url), __PIN_Q__=shq(pin),
                __API_KEY_Q__=shq("ucm_ak_TESTKEY"))
    for k, v in vals.items():
        t = t.replace(k, v)
    t = t.replace("__UCM_SCRIPT__", ucm.rstrip("\n"))
    cmd = (" sh -c 'f=$(mktemp) || exit 1; cat >\"$f\"; sh \"$f\" </dev/null; r=$?; rm -f \"$f\"; exit $r' "
           "<<'UCM_REMOTE_EOF'\n" + t + "UCM_REMOTE_EOF\n")
    removal = (" sh -c 'f=$(mktemp) || exit 1; cat >\"$f\"; sh \"$f\" </dev/null; r=$?; rm -f \"$f\"; exit $r' "
               "<<'UCM_REMOTE_EOF'\n" + (res / "krl-remove-linux.sh").read_text() + "UCM_REMOTE_EOF\n")
else:
    t = (res / "server-setup-windows.ps1").read_text()
    upd = (res / "krl-update-windows.ps1").read_text()
    vals = dict(common, __PRINCIPALS_PSQ__=psq(principals), __UCM_URL_PSQ__=psq(url), __PIN_PSQ__=psq(pin),
                __API_KEY_PSQ__=psq("ucm_ak_TESTKEY"),
                __UCM_SCRIPT_B64__=base64.b64encode(ucm.encode()).decode(),
                __UPDATER_B64__=base64.b64encode(upd.encode()).decode())
    for k, v in vals.items():
        t = t.replace(k, v)
    assert t.isascii()

    def wrap(body):
        return ("$ucmSetup = @'\n" + body.rstrip("\n") + "\n'@\n"
                "$ucmFile = Join-Path $env:TEMP ('ucm-remote-' + [guid]::NewGuid().ToString() + '.ps1'); "
                "[IO.File]::WriteAllText($ucmFile, $ucmSetup, (New-Object System.Text.UTF8Encoding $true)); "
                "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ucmFile; "
                "Remove-Item -Force $ucmFile; Remove-Variable ucmSetup, ucmFile\n")
    cmd = wrap(t)
    removal = wrap((res / "krl-remove-windows.ps1").read_text())

for marker in ("__CA_", "__KRL_", "__PIN_", "__API_", "__UCM_", "__PRINCIPALS_", "__UPDATER_"):
    assert marker not in cmd, marker
pathlib.Path(out).write_text(cmd)
pathlib.Path(out + ".remove").write_text(removal)
print("rendered", out, len(cmd), "bytes")
