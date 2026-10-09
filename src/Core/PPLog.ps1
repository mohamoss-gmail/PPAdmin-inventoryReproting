# PPLog.ps1 - structured logging: console + NDJSON transcript.
# Windows PowerShell 5.1 compatible.

$script:PPLogPath   = $null
$script:PPLogStart  = Get-Date

function Initialize-PPLog {
    param([Parameter(Mandatory)][string]$Path)
    $script:PPLogPath  = $Path
    $script:PPLogStart = Get-Date
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -Path $Path -Value '' -Encoding utf8
}

function Write-PPLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','STEP','DEBUG')][string]$Level = 'INFO',
        $Data
    )

    $elapsed = [int]((Get-Date) - $script:PPLogStart).TotalSeconds
    $stamp   = '{0,5}s' -f $elapsed

    switch ($Level) {
        'OK'    { $color = 'Green';      $tag = ' OK  ' }
        'WARN'  { $color = 'Yellow';     $tag = 'WARN ' }
        'ERROR' { $color = 'Red';        $tag = 'FAIL ' }
        'STEP'  { $color = 'Cyan';       $tag = '==== ' }
        'DEBUG' { $color = 'DarkGray';   $tag = 'dbg  ' }
        default { $color = 'Gray';       $tag = '     ' }
    }

    Write-Host ("[{0}] {1}{2}" -f $stamp, $tag, $Message) -ForegroundColor $color

    if ($script:PPLogPath) {
        $entry = [ordered]@{
            ts      = (Get-Date).ToUniversalTime().ToString('o')
            elapsed = $elapsed
            level   = $Level
            message = $Message
        }
        if ($null -ne $Data) { $entry['data'] = $Data }
        try {
            $json = ($entry | ConvertTo-Json -Depth 6 -Compress)
            Add-Content -Path $script:PPLogPath -Value $json -Encoding utf8
        } catch {
            # Logging must never break collection.
        }
    }
}

function Write-PPBanner {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host ('  ' + $Text) -ForegroundColor White
    Write-Host ('  ' + ('-' * $Text.Length)) -ForegroundColor DarkGray
}
