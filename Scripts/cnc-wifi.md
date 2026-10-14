# Raptorex Wi-Fi mode switching

The Raptorex's FluidNC controller runs in one of two Wi-Fi modes. Flipping between them
is one setting (`$WiFi/Mode`) plus a restart; the station SSID/password stay stored in
the controller either way.

| Mode | `$WiFi/Mode` | Reach it at | Tablet pendant |
|---|---|---|---|
| **office** — joins the KorayBirand network | `STA>AP` | http://raptorex-012.local/ (was 192.168.1.39) | offline |
| **tablet** — its own access point (factory state) | `AP` | SSID **Raptorex_012**, controller at **192.168.4.1** | works |

Two scripts do this, same behaviour:

- **On this Mac**: [`Scripts/cnc-wifi.py`](cnc-wifi.py) (no dependencies, Python 3).
- **On the Windows Candle PC**: `C:\Users\info\Documents\RaptorEx-backup\cnc-wifi.ps1`
  (original; copied verbatim below in case the PC is unreachable).

## Using it on this Mac

Over USB (preferred — it watches the boot log and confirms the result):

```bash
python3 Scripts/cnc-wifi.py tablet    # back to its own access point
python3 Scripts/cnc-wifi.py office    # join the office network
python3 Scripts/cnc-wifi.py status    # current mode + [ESP420] report, no restart
```

The serial device is auto-detected (`/dev/cu.usbserial*` etc.); pass `--port` if several
are present. Without USB, over Wi-Fi:

```bash
python3 Scripts/cnc-wifi.py tablet --telnet                  # host raptorex-012.local
python3 Scripts/cnc-wifi.py office --telnet 192.168.4.1      # from inside the Raptorex_012 AP
```

Over telnet the restart drops the connection, so the script cannot confirm the final
state — it tells you where to look instead.

### Cautions

- **Disconnect anything holding the connection first**: the app's Machine panel, Candle,
  an open telnet session.
- **office/tablet restart the controller.** With `off_on_alarm:false` in raptorex.yaml the
  spindle can twitch on restart — remove the bit or cut spindle power.
- After the restart the controller is unhomed (the usual power-on alarm): home before use.

## Doing it by hand

From any terminal connected to the controller (USB at 115200, or `nc raptorex-012.local 23`):

```
$WiFi/Mode            query the current mode
$WiFi/Mode=AP         tablet / access-point mode
$WiFi/Mode=STA>AP     office mode (station, falling back to AP if it can't join)
$Bye                  restart so the new mode takes effect
```

## Original Windows script (verbatim copy, 2026-10-13)

From `C:\Users\info\Documents\RaptorEx-backup\cnc-wifi.ps1` on the Candle PC
(`info@192.168.1.171`). The 2026-10-05 FluidNC backup (raptorex.yaml, nvs.bin,
full-flash-4MB.bin) sits in the same folder.

```powershell
<#
.SYNOPSIS
  Switch the RaptorEx CNC (FluidNC) between the office network and its own access point.

.USAGE
  .\cnc-wifi.ps1 office   # join KorayBirand -> http://raptorex-012.local/  (tablet pendant offline)
  .\cnc-wifi.ps1 tablet   # be access point Raptorex_012 / 192.168.4.1       (tablet pendant works)
  .\cnc-wifi.ps1 status   # show current mode, no restart

.NOTES
  - Close Candle first; it holds COM3.
  - office/tablet restart the controller. With off_on_alarm:false in raptorex.yaml
    the spindle can twitch on restart - remove the bit or cut spindle power.
  - Station SSID/password stay stored in the controller; this only flips $WiFi/Mode.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('office', 'tablet', 'status')]
    [string]$Mode,
    [string]$Port = 'COM3'
)

$sp = New-Object System.IO.Ports.SerialPort $Port, 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 500
$sp.DtrEnable = $false   # keep DTR/RTS low: toggling them resets the ESP32
$sp.RtsEnable = $false

function Send([string]$cmd, [int]$ms) {
    $sp.Write($cmd + "`n")
    $end = (Get-Date).AddMilliseconds($ms)
    $buf = New-Object System.Text.StringBuilder
    while ((Get-Date) -lt $end) {
        try { $c = $sp.ReadExisting(); if ($c) { [void]$buf.Append($c) } } catch {}
        Start-Sleep -Milliseconds 80
    }
    return $buf.ToString()
}

try {
    $sp.Open()
} catch {
    Write-Host "Cannot open $Port - is Candle (or another sender) still connected?" -ForegroundColor Red
    exit 1
}
Start-Sleep -Milliseconds 400
$sp.DiscardInBuffer()

try {
    if ($Mode -eq 'status') {
        Write-Host (Send '$WiFi/Mode' 1200).Trim()
        Write-Host (Send '[ESP420]' 2500).Trim()
        exit 0
    }

    $target = if ($Mode -eq 'office') { 'STA>AP' } else { 'AP' }
    Write-Host "Setting `$WiFi/Mode=$target ..."
    $r = Send "`$WiFi/Mode=$target" 1500
    if ($r -notmatch 'ok') { Write-Host "Unexpected reply: $r" -ForegroundColor Red; exit 1 }

    Write-Host "Restarting controller (spindle may twitch) - watching boot log for 25 s ..."
    $boot = Send '$Bye' 25000

    $ip = [regex]::Match($boot, 'IP is (\d+\.\d+\.\d+\.\d+)')
    $ap = [regex]::Match($boot, 'AP SSID (\S+) IP (\d+\.\d+\.\d+\.\d+)')
    if ($ip.Success) {
        Write-Host ("Joined office network. IP {0}  -  http://raptorex-012.local/" -f $ip.Groups[1].Value) -ForegroundColor Green
    } elseif ($ap.Success) {
        Write-Host ("Access point {0} up at {1}. Tablet pendant can connect." -f $ap.Groups[1].Value, $ap.Groups[2].Value) -ForegroundColor Green
    } else {
        Write-Host "Could not confirm WiFi state from boot log:" -ForegroundColor Yellow
        Write-Host $boot
    }
}
finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}
```
