<#
.SYNOPSIS
    Self-check for a Codex CLI custom model provider (config.toml, [model_providers.<id>],
    base_url, env_key, wire_api). PowerShell port of scripts/codex-doctor.sh.

.DESCRIPTION
    Prints a PASS / WARN / FAIL table. Nothing is sent over the network unless -Live is given.
    The API key is read only from the environment variable named by env_key; only its length
    is printed, and every line printed from a response is scrubbed of the key.
    Exit code = number of FAIL rows (0 = nothing failed). 64 = bad usage.

    Works in Windows PowerShell 5.1 and PowerShell 7+ (Windows, macOS, Linux).
    TOML is read with a built-in line parser (no Python needed).

.PARAMETER Config
    Check this file instead of $env:CODEX_HOME\config.toml or %USERPROFILE%\.codex\config.toml.

.PARAMETER ProfileName
    Also load <config dir>\<ProfileName>.config.toml on top (like `codex --profile <name>`).

.PARAMETER Project
    Directory to start the search for project-level .codex\config.toml files (default: current).

.PARAMETER Live
    Send GET <base_url>/models and one small streamed POST <base_url>/responses (billed).

.PARAMETER Model
    Model ID for -Live (default: `model` from the config).

.PARAMETER NoColor
    Plain output. NO_COLOR=1 and redirected output also disable colors.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\codex-doctor.ps1

.EXAMPLE
    pwsh -File scripts/codex-doctor.ps1 -ProfileName work -Live

.NOTES
    Part of codex-custom-provider. MIT License.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive CLI output with optional colors')]
[CmdletBinding()]
param(
    [string]$Config = '',
    [string]$ProfileName = '',
    [string]$Project = '',
    [switch]$Live,
    [string]$Model = '',
    [switch]$NoColor,
    [switch]$Help
)

$DoctorVersion = '2.0.0'
$script:ReservedIds = @('openai', 'ollama', 'lmstudio')
$script:BuiltinIds = @('openai', 'ollama', 'lmstudio', 'amazon-bedrock', 'amazon-bedrock-runtime')
$script:TopLevelKeys = @('model', 'model_provider', 'model_reasoning_effort', 'model_reasoning_summary', 'model_verbosity',
    'model_context_window', 'approval_policy', 'sandbox_mode', 'openai_base_url', 'profile')
$script:ProviderKeys = @('name', 'base_url', 'model_catalog_url', 'env_key', 'env_key_instructions', 'experimental_bearer_token',
    'auth', 'gateway_oauth', 'aws', 'wire_api', 'query_params', 'http_headers', 'env_http_headers', 'request_max_retries',
    'stream_max_retries', 'stream_idle_timeout_ms', 'websocket_connect_timeout_ms', 'requires_openai_auth',
    'supports_websockets', 'supports_standalone_web_search')
$script:ProjectIgnored = @('model_provider', 'model_providers', 'openai_base_url', 'chatgpt_base_url', 'profile', 'profiles')
$script:SafeTop = @('model', 'model_provider', 'profile', 'openai_base_url', 'chatgpt_base_url', 'model_reasoning_effort')
$script:SafeProv = @('name', 'base_url', 'wire_api', 'env_key', 'requires_openai_auth', 'stream_idle_timeout_ms',
    'stream_max_retries', 'request_max_retries', 'supports_websockets')

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    exit 0
}
if ($ProfileName -ne '' -and $ProfileName -cnotmatch '^[A-Za-z0-9_-]+$') {
    Write-Host 'codex-doctor: profile names may only contain letters, digits, - and _'
    exit 64
}

$script:TimeoutSec = 60
if ($env:CODEX_DOCTOR_TIMEOUT -match '^\d+$') { $script:TimeoutSec = [int]$env:CODEX_DOCTOR_TIMEOUT }
$codexBin = 'codex'
if ($env:CODEX_DOCTOR_CODEX_BIN) { $codexBin = $env:CODEX_DOCTOR_CODEX_BIN }

$script:UseColor = $true
if ($NoColor -or $env:NO_COLOR -or [Console]::IsOutputRedirected) { $script:UseColor = $false }

$script:Secret = ''
$script:NPass = 0
$script:NWarn = 0
$script:NFail = 0
$script:NSkip = 0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Get-Redacted {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    if ($script:Secret -ne '') { $Text = $Text.Replace($script:Secret, '[REDACTED]') }
    return $Text
}

function Get-OneLine {
    param([string]$Text, [int]$Max = 220)
    if ($null -eq $Text) { return '' }
    $t = ($Text -replace "[`r`n`t]", ' ')
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
    return $t
}

function Add-Result {
    param([string]$Id, [string]$Status, [string]$Check, [string]$Detail, [string]$Hint = '')
    switch ($Status) {
        'PASS' { $script:NPass++; $color = 'Green' }
        'WARN' { $script:NWarn++; $color = 'Yellow' }
        'FAIL' { $script:NFail++; $color = 'Red' }
        default { $script:NSkip++; $color = 'DarkGray' }
    }
    $Detail = Get-Redacted -Text $Detail
    $Hint = Get-Redacted -Text $Hint
    Write-Host (' {0,-4} ' -f $Id) -NoNewline
    if ($script:UseColor) { Write-Host $Status -NoNewline -ForegroundColor $color } else { Write-Host $Status -NoNewline }
    Write-Host ('  {0,-16} {1}' -f $Check, $Detail)
    if ($Hint -ne '') { Write-Host ('                             fix: ' + $Hint) }
}

# ---------------------------------------------------------------------------
# TOML line scanner (same rules as scan_toml in codex-doctor.sh)
# ---------------------------------------------------------------------------

function Get-NormalizedKey {
    param([string]$Key)
    $segments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($part in $Key.Split('.')) {
        $seg = $part.Trim()
        if ($seg.Length -ge 2 -and (($seg.StartsWith('"') -and $seg.EndsWith('"')) -or ($seg.StartsWith("'") -and $seg.EndsWith("'")))) {
            $seg = $seg.Substring(1, $seg.Length - 2)
        }
        $segments.Add($seg)
    }
    return ($segments -join '.')
}

function Get-EqualsIndex {
    param([string]$Text)
    $quote = ''
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = [string]$Text[$i]
        if ($quote -ne '') {
            if ($c -eq $quote) { $quote = '' }
            continue
        }
        if ($c -eq '"' -or $c -eq "'") { $quote = $c; continue }
        if ($c -eq '=') { return $i }
    }
    return -1
}

function Read-BasicString {
    param([string]$Text)
    $sb = New-Object -TypeName System.Text.StringBuilder
    for ($i = 1; $i -lt $Text.Length; $i++) {
        $c = [string]$Text[$i]
        if ($c -eq '\') {
            $i++
            if ($i -lt $Text.Length) {
                $e = [string]$Text[$i]
                if ($e -ceq 't' -or $e -ceq 'n') { [void]$sb.Append(' ') } else { [void]$sb.Append($e) }
            }
            continue
        }
        if ($c -eq '"') { return [pscustomobject]@{ Value = $sb.ToString(); Closed = $true } }
        [void]$sb.Append($c)
    }
    return [pscustomobject]@{ Value = $sb.ToString(); Closed = $false }
}

function Get-BracketDelta {
    param([string]$Text)
    $quote = ''
    $d = 0
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = [string]$Text[$i]
        if ($quote -ne '') {
            if ($c -eq '\' -and $quote -eq '"') { $i++; continue }
            if ($c -eq $quote) { $quote = '' }
            continue
        }
        if ($c -eq '#') { break }
        if ($c -eq '"' -or $c -eq "'") { $quote = $c; continue }
        if ($c -eq '[') { $d++ } elseif ($c -eq ']') { $d-- }
    }
    return $d
}

function Add-TomlFact {
    param($Scan, [string]$Path, [string]$Value, [string]$Raw)
    $parts = $Path.Split('.')
    $n = $parts.Length
    $isMarker = ($Value -ceq '<array>' -or $Value -ceq '<table>' -or $Value -ceq '<multiline>')
    if ($parts[0] -ceq 'model_providers') {
        $Scan.Facts['model_providers'] = '<table>'
        if ($n -ge 2) { $Scan.Facts['model_providers.' + $parts[1]] = '<table>' }
        if ($n -eq 3) {
            $provId = $parts[1]
            $pk = $parts[2]
            if (($script:SafeProv -ccontains $pk) -and -not $isMarker) {
                $v = $Value
                if ($pk -ceq 'env_key' -and $v -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') { $v = '<invalid-name:' + $v.Length + '>' }
                $Scan.Facts[$Path] = $v
            } elseif ($pk -ceq 'http_headers') {
                $Scan.Facts[$Path] = '<table>'
                if ($Raw.ToLowerInvariant().Contains('authorization')) {
                    $Scan.Facts['model_providers.' + $provId + '.http_headers.authorization'] = '<set>'
                }
            } elseif ($Value -ceq '<table>') {
                $Scan.Facts[$Path] = '<table>'
            } else {
                $Scan.Facts[$Path] = '<set>'
            }
        } elseif ($n -eq 4 -and $parts[2] -ceq 'http_headers') {
            $Scan.Facts['model_providers.' + $parts[1] + '.http_headers.' + $parts[3].ToLowerInvariant()] = '<set>'
        } elseif ($n -gt 3) {
            $Scan.Facts['model_providers.' + $parts[1] + '.' + $parts[2]] = '<table>'
        }
        return
    }
    if ($parts[0] -ceq 'profiles') {
        $Scan.Facts['profiles'] = '<table>'
        if ($n -ge 2) { $Scan.Facts['profiles.' + $parts[1]] = '<table>' }
        return
    }
    if ($n -eq 1) {
        if (($script:SafeTop -ccontains $Path) -and -not $isMarker) { $Scan.Facts[$Path] = $Value }
        elseif ($Value -ceq '<table>') { $Scan.Facts[$Path] = '<table>' }
        else { $Scan.Facts[$Path] = '<set>' }
    } else {
        $Scan.Facts[$parts[0]] = '<table>'
    }
}

function Read-TomlScan {
    param([string]$Path)
    $scan = [pscustomobject]@{
        Facts          = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        Keys           = New-Object 'System.Collections.Generic.List[object]'
        Errors         = New-Object 'System.Collections.Generic.List[string]'
        FirstTableLine = 0
    }
    $seenTables = New-Object 'System.Collections.Generic.HashSet[string]'
    $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    $table = ''
    $ktable = ''
    $ml = ''
    $depth = 0
    $lines = [System.IO.File]::ReadAllLines($Path)
    for ($idx = 0; $idx -lt $lines.Length; $idx++) {
        $lineNo = $idx + 1
        $line = $lines[$idx]
        if ($lineNo -eq 1 -and $line.Length -gt 0 -and $line[0] -eq [char]0xFEFF) { $line = $line.Substring(1) }
        if ($ml -ne '') {
            if ($line.Contains($ml)) { $ml = '' }
            continue
        }
        if ($depth -gt 0) {
            $depth += (Get-BracketDelta -Text $line)
            if ($depth -lt 0) { $depth = 0 }
            continue
        }
        $s = $line.Trim()
        if ($s -eq '' -or $s.StartsWith('#')) { continue }

        if ($s.StartsWith('[')) {
            if ($s -notmatch '\]\s*(#.*)?$') { $scan.Errors.Add(('line {0}: unterminated table header' -f $lineNo)); continue }
            $aot = $s.StartsWith('[[')
            $h = ($s -replace '^\[\[?', '') -replace '\]\]?\s*(#.*)?$', ''
            $table = Get-NormalizedKey -Key $h
            if ($scan.FirstTableLine -eq 0) { $scan.FirstTableLine = $lineNo }
            if ($aot) {
                $ktable = $table + '#' + $lineNo
            } else {
                if (-not $seenTables.Add($table)) { $scan.Errors.Add(('line {0}: duplicate table [{1}]' -f $lineNo, $table)) }
                $ktable = $table
                Add-TomlFact -Scan $scan -Path $table -Value '<table>' -Raw ''
            }
            continue
        }

        $p = Get-EqualsIndex -Text $s
        if ($p -lt 0) { $scan.Errors.Add(('line {0}: expected key = value' -f $lineNo)); continue }
        $key = Get-NormalizedKey -Key ($s.Substring(0, $p))
        $v = $s.Substring($p + 1).Trim()
        if (-not $seenKeys.Add($ktable + [char]1 + $key)) {
            $where = ''
            if ($table -ne '') { $where = ' in [' + $table + ']' }
            $scan.Errors.Add(('line {0}: duplicate key {1}{2}' -f $lineNo, $key, $where))
        }
        $scan.Keys.Add([pscustomobject]@{ Line = $lineNo; Table = $table; Key = $key })

        $val = ''
        if ($v.StartsWith('"""') -or $v.StartsWith("'''")) {
            $delim = $v.Substring(0, 3)
            $rest = $v.Substring(3)
            $end = $rest.IndexOf($delim)
            if ($end -ge 0) { $val = $rest.Substring(0, $end) } else { $ml = $delim; $val = '<multiline>' }
        } elseif ($v.StartsWith('"')) {
            $bs = Read-BasicString -Text $v
            $val = $bs.Value
            if (-not $bs.Closed) { $scan.Errors.Add(('line {0}: unterminated string' -f $lineNo)) }
        } elseif ($v.StartsWith("'")) {
            $rest = $v.Substring(1)
            $end = $rest.IndexOf("'")
            if ($end -ge 0) { $val = $rest.Substring(0, $end) } else { $val = $rest; $scan.Errors.Add(('line {0}: unterminated string' -f $lineNo)) }
        } elseif ($v.StartsWith('[')) {
            $depth = Get-BracketDelta -Text $v
            if ($depth -lt 0) { $depth = 0 }
            $val = '<array>'
        } elseif ($v.StartsWith('{')) {
            $val = '<table>'
        } else {
            $val = ($v -replace '\s*#.*$', '').Trim()
        }
        $path = $key
        if ($table -ne '') { $path = $table + '.' + $key }
        Add-TomlFact -Scan $scan -Path $path -Value $val -Raw $v
    }
    return $scan
}

function Get-Fact {
    param([string]$Key)
    if ($script:Facts.ContainsKey($Key)) { return $script:Facts[$Key] }
    return $null
}

function Test-Fact {
    param([string]$Key)
    return $script:Facts.ContainsKey($Key)
}

function Get-MisplacedKey {
    param($Scan, [string]$Label)
    $found = New-Object 'System.Collections.Generic.List[string]'
    foreach ($r in $Scan.Keys) {
        $t = $r.Table
        if ($t -eq '' -or $t -cmatch '^profiles(\.|$)') { continue }
        if ($r.Key -ceq 'model_provider' -or ($t -cmatch '^model_providers\.[^.]+$' -and ($script:TopLevelKeys -ccontains $r.Key))) {
            $found.Add(('{0}:{1} {2} is inside [{3}]' -f $Label, $r.Line, $r.Key, $t))
        }
    }
    return $found
}

function Get-UnknownProviderKey {
    param($Scan, [string]$ProviderId)
    $found = New-Object 'System.Collections.Generic.List[string]'
    foreach ($r in $Scan.Keys) {
        if ($r.Table -cne ('model_providers.' + $ProviderId)) { continue }
        $k = $r.Key.Split('.')[0]
        if (($script:ProviderKeys -ccontains $k) -or ($script:TopLevelKeys -ccontains $k)) { continue }
        if (-not $found.Contains($k)) { $found.Add($k) }
    }
    return $found
}

function Get-ProjectProviderKey {
    param([string]$Path)
    $scan = Read-TomlScan -Path $Path
    $found = New-Object 'System.Collections.Generic.List[string]'
    foreach ($r in $scan.Keys) {
        $name = $r.Key
        if ($r.Table -ne '') { $name = $r.Table }
        $root = $name.Split('.')[0]
        if ($r.Table -eq '' -and ($script:ProjectIgnored -ccontains $r.Key)) { $root = $r.Key }
        if (($script:ProjectIgnored -ccontains $root) -and -not $found.Contains($root)) { $found.Add($root) }
    }
    return $found
}

function Get-FullPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path -Path (Get-Location).ProviderPath -ChildPath $Path))
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
Write-Host ('codex-doctor {0} (PowerShell {1})' -f $DoctorVersion, $PSVersionTable.PSVersion.ToString())

# ---------------------------------------------------------------------------
# 1. codex CLI
# ---------------------------------------------------------------------------
$installHint = 'install: npm install -g @openai/codex, or irm https://chatgpt.com/codex/install.ps1 | iex'
$cmd = Get-Command -Name $codexBin -ErrorAction SilentlyContinue
if ($null -eq $cmd) {
    Add-Result -Id '1' -Status 'WARN' -Check 'codex CLI' -Detail ("'" + $codexBin + "' not found in PATH; the config can still be checked") -Hint $installHint
} else {
    $verLine = ''
    try { $verLine = [string](& $codexBin --version 2>$null | Select-Object -First 1) } catch { $verLine = '' }
    $m = [regex]::Match($verLine, '(\d+)\.(\d+)\.(\d+)')
    if (-not $m.Success) {
        Add-Result -Id '1' -Status 'WARN' -Check 'codex CLI' -Detail ('found ' + $cmd.Source + ' but could not read a version from: ' + (Get-OneLine -Text $verLine -Max 80))
    } elseif ([version]$m.Value -ge [version]'0.134.0') {
        Add-Result -Id '1' -Status 'PASS' -Check 'codex CLI' -Detail (Get-OneLine -Text $verLine -Max 80)
    } else {
        Add-Result -Id '1' -Status 'WARN' -Check 'codex CLI' -Detail ($m.Value + ' is older than 0.134.0: profile files (<name>.config.toml) and some checks here assume a newer Codex') -Hint 'update Codex (npm install -g @openai/codex@latest)'
    }
}

# ---------------------------------------------------------------------------
# 2. config file
# ---------------------------------------------------------------------------
$configOk = $false
$configPath = ''
$profilePath = ''
$configFrom = 'default'
$codexHomeBad = $false
if ($Config -ne '') {
    $configPath = Get-FullPath -Path $Config
    $configFrom = '-Config'
} elseif ($env:CODEX_HOME) {
    $configFrom = '$env:CODEX_HOME'
    if (Test-Path -LiteralPath $env:CODEX_HOME -PathType Container) {
        $configPath = Join-Path -Path (Get-FullPath -Path $env:CODEX_HOME) -ChildPath 'config.toml'
    } else {
        $codexHomeBad = $true
    }
} else {
    $homeDir = [Environment]::GetFolderPath('UserProfile')
    if (-not $homeDir) { $homeDir = $env:HOME }
    $configPath = Join-Path -Path (Join-Path -Path $homeDir -ChildPath '.codex') -ChildPath 'config.toml'
}

if ($codexHomeBad) {
    Add-Result -Id '2' -Status 'FAIL' -Check 'config file' -Detail ('CODEX_HOME points to "' + $env:CODEX_HOME + '", but that path does not exist or is not a directory') -Hint 'create the directory or remove CODEX_HOME (Codex refuses to start in this state)'
} elseif (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    if (Test-Path -LiteralPath ($configPath + '.txt') -PathType Leaf) {
        Add-Result -Id '2' -Status 'FAIL' -Check 'config file' -Detail ($configPath + ' not found, but ' + $configPath + '.txt exists') -Hint 'rename it to config.toml (Windows Explorer hides the .txt extension)'
    } else {
        Add-Result -Id '2' -Status 'FAIL' -Check 'config file' -Detail ($configPath + ' not found (' + $configFrom + ')') -Hint 'create it from config/config.toml.example; provider settings only work in the user-level file'
    }
} else {
    $configOk = $true
    if ($ProfileName -ne '') {
        $profilePath = Join-Path -Path (Split-Path -Parent $configPath) -ChildPath ($ProfileName + '.config.toml')
        if (Test-Path -LiteralPath $profilePath -PathType Leaf) {
            Add-Result -Id '2' -Status 'PASS' -Check 'config file' -Detail ($configPath + ' + profile ' + $profilePath)
        } else {
            Add-Result -Id '2' -Status 'FAIL' -Check 'config file' -Detail ('profile file ' + $profilePath + ' not found (needed for -ProfileName ' + $ProfileName + ')') -Hint 'Codex 0.134+ reads profiles from <CODEX_HOME>/<name>.config.toml, not from [profiles.<name>]'
            $profilePath = ''
            $configOk = $false
        }
    } else {
        Add-Result -Id '2' -Status 'PASS' -Check 'config file' -Detail ($configPath + ' (' + $configFrom + ')')
    }
}

# ---------------------------------------------------------------------------
# 3. TOML parse
# ---------------------------------------------------------------------------
$parseOk = $false
$scanBase = $null
$scanProfile = $null
$script:Facts = New-Object 'System.Collections.Generic.Dictionary[string,string]'
if (-not $configOk) {
    Add-Result -Id '3' -Status 'SKIP' -Check 'TOML parse' -Detail 'no config file to parse'
} else {
    $readError = ''
    try {
        $scanBase = Read-TomlScan -Path $configPath
        if ($profilePath -ne '') { $scanProfile = Read-TomlScan -Path $profilePath }
    } catch {
        $readError = $_.Exception.Message
    }
    $syntax = ''
    if ($readError -eq '') {
        if ($scanBase.Errors.Count -gt 0) { $syntax = $configPath + ': ' + $scanBase.Errors[0] }
        elseif ($null -ne $scanProfile -and $scanProfile.Errors.Count -gt 0) { $syntax = $profilePath + ': ' + $scanProfile.Errors[0] }
    }
    if ($readError -ne '') {
        Add-Result -Id '3' -Status 'FAIL' -Check 'TOML parse' -Detail ('cannot read the file: ' + (Get-OneLine -Text $readError))
    } elseif ($syntax -ne '') {
        Add-Result -Id '3' -Status 'FAIL' -Check 'TOML parse' -Detail (Get-OneLine -Text $syntax -Max 240) -Hint 'fix the TOML syntax at the reported line (Codex will not start)'
    } else {
        foreach ($kv in $scanBase.Facts.GetEnumerator()) { $script:Facts[$kv.Key] = $kv.Value }
        if ($null -ne $scanProfile) { foreach ($kv in $scanProfile.Facts.GetEnumerator()) { $script:Facts[$kv.Key] = $kv.Value } }
        $parseOk = $true
        Add-Result -Id '3' -Status 'PASS' -Check 'TOML parse' -Detail 'read with the built-in line parser (basic syntax checks only)'
    }
}

# ---------------------------------------------------------------------------
# 4. key order
# ---------------------------------------------------------------------------
if (-not $parseOk) {
    Add-Result -Id '4' -Status 'SKIP' -Check 'key order' -Detail 'config was not parsed'
} else {
    $mis = @(Get-MisplacedKey -Scan $scanBase -Label (Split-Path -Leaf $configPath))
    if ($null -ne $scanProfile) { $mis += @(Get-MisplacedKey -Scan $scanProfile -Label (Split-Path -Leaf $profilePath)) }
    if ($mis.Count -gt 0) {
        Add-Result -Id '4' -Status 'FAIL' -Check 'key order' -Detail (Get-OneLine -Text ($mis -join '; ') -Max 240) -Hint 'move model / model_provider above the first [table]; in TOML every key after [x] belongs to x'
    } else {
        $where = ''
        if ($scanBase.FirstTableLine -gt 0) { $where = ' (line ' + $scanBase.FirstTableLine + ')' }
        Add-Result -Id '4' -Status 'PASS' -Check 'key order' -Detail ('top-level keys come before the first table' + $where)
    }
}

# ---------------------------------------------------------------------------
# 5. model + model_provider
# ---------------------------------------------------------------------------
$provId = ''
$custom = $false
$modelId = ''
if (-not $parseOk) {
    Add-Result -Id '5' -Status 'SKIP' -Check 'model_provider' -Detail 'config was not parsed'
} else {
    $reservedTables = @()
    foreach ($rid in $script:ReservedIds) {
        if (Test-Fact -Key ('model_providers.' + $rid)) { $reservedTables += ('`' + $rid + '`') }
    }
    $provId = [string](Get-Fact -Key 'model_provider')
    $modelId = [string](Get-Fact -Key 'model')
    if ($reservedTables.Count -gt 0) {
        Add-Result -Id '5' -Status 'FAIL' -Check 'model_provider' -Detail ('model_providers contains reserved built-in provider IDs: ' + ($reservedTables -join ', ') + '. Built-in providers cannot be overridden.') -Hint 'rename the table and model_provider to your own ID, e.g. [model_providers.my-gateway]'
    } elseif ($provId -eq '') {
        $obu = [string](Get-Fact -Key 'openai_base_url')
        if ($obu -ne '') {
            Add-Result -Id '5' -Status 'WARN' -Check 'model_provider' -Detail ('not set; using the built-in openai provider with openai_base_url = ' + $obu + ' (checks 6-9 cover custom providers only)')
        } else {
            Add-Result -Id '5' -Status 'FAIL' -Check 'model_provider' -Detail 'not set at the top level, so Codex uses the built-in `openai` provider' -Hint 'add model_provider = "<id>" above the first [table]'
        }
    } elseif ($provId -ceq 'ollama-chat') {
        Add-Result -Id '5' -Status 'FAIL' -Check 'model_provider' -Detail '`ollama-chat` is no longer supported' -Hint 'replace `ollama-chat` with `ollama`'
    } elseif ($script:BuiltinIds -ccontains $provId) {
        Add-Result -Id '5' -Status 'WARN' -Check 'model_provider' -Detail ('`' + $provId + '` is a built-in provider, not a custom one (checks 6-9 cover custom providers only)')
    } elseif ($modelId -eq '' -and $Model -eq '') {
        $custom = $true
        Add-Result -Id '5' -Status 'WARN' -Check 'model_provider' -Detail ('model_provider = ' + $provId + ', but `model` is not set: Codex will ask the gateway for its own default model ID') -Hint 'set model = "<an ID from GET <base_url>/models>"'
    } else {
        $custom = $true
        $shown = $modelId
        if ($shown -eq '') { $shown = $Model }
        Add-Result -Id '5' -Status 'PASS' -Check 'model_provider' -Detail ('model_provider = ' + $provId + ', model = ' + $shown)
    }
}

$hasTable = $custom -and (Test-Fact -Key ('model_providers.' + $provId))
$pfx = 'model_providers.' + $provId

# ---------------------------------------------------------------------------
# 6. provider table
# ---------------------------------------------------------------------------
if (-not $custom) {
    Add-Result -Id '6' -Status 'SKIP' -Check 'provider table' -Detail 'no custom model_provider selected'
} elseif (-not $hasTable) {
    Add-Result -Id '6' -Status 'FAIL' -Check 'provider table' -Detail ('Model provider `' + $provId + '` not found: there is no [model_providers.' + $provId + '] table') -Hint ('model_provider must match the table name exactly: model_provider = "' + $provId + '" <-> [model_providers.' + $provId + ']')
} else {
    $pname = [string](Get-Fact -Key ($pfx + '.name'))
    $unk = @(Get-UnknownProviderKey -Scan $scanBase -ProviderId $provId)
    if ($null -ne $scanProfile) { $unk += @(Get-UnknownProviderKey -Scan $scanProfile -ProviderId $provId) }
    $unk = @($unk | Select-Object -Unique)
    if ($pname.Trim() -eq '') {
        Add-Result -Id '6' -Status 'FAIL' -Check 'provider table' -Detail ('model_providers.' + $provId + ': provider name must not be empty') -Hint 'add name = "<display name>"'
    } elseif ($unk.Count -gt 0) {
        $hint = 'Codex ignores unknown provider keys'
        if (($unk -ccontains 'api_key') -or ($unk -ccontains 'key') -or ($unk -ccontains 'token') -or ($unk -ccontains 'api-key')) {
            $hint = 'Codex has no api_key field: delete it (it is a plaintext secret) and use env_key = "<ENV_VAR_NAME>"'
        }
        Add-Result -Id '6' -Status 'WARN' -Check 'provider table' -Detail ('[model_providers.' + $provId + '] has keys Codex does not know: ' + ($unk -join ' ')) -Hint $hint
    } else {
        Add-Result -Id '6' -Status 'PASS' -Check 'provider table' -Detail ('[model_providers.' + $provId + '] name = "' + $pname + '"')
    }
}

# ---------------------------------------------------------------------------
# 7. base_url
# ---------------------------------------------------------------------------
$baseUrl = ''
$gwHost = ''
if (-not $hasTable) {
    Add-Result -Id '7' -Status 'SKIP' -Check 'base_url' -Detail 'no custom provider table to check'
} else {
    $baseUrl = [string](Get-Fact -Key ($pfx + '.base_url'))
    $b = $baseUrl.TrimEnd('/')
    $lb = $b.ToLowerInvariant()
    $hm = [regex]::Match($lb, '^[a-z]+://([^/:?]*)')
    if ($hm.Success) { $gwHost = $hm.Groups[1].Value }
    if ($baseUrl -eq '') {
        Add-Result -Id '7' -Status 'FAIL' -Check 'base_url' -Detail "missing: Codex would send this provider's requests to https://api.openai.com/v1" -Hint 'base_url = "https://<your-gateway>/v1"'
    } elseif ($lb -match '\s') {
        Add-Result -Id '7' -Status 'FAIL' -Check 'base_url' -Detail ('"' + $baseUrl + '" contains whitespace')
    } elseif (-not ($lb.StartsWith('http://') -or $lb.StartsWith('https://'))) {
        Add-Result -Id '7' -Status 'FAIL' -Check 'base_url' -Detail ('"' + $baseUrl + '" must start with http:// or https://')
    } elseif ($lb.Contains('?')) {
        Add-Result -Id '7' -Status 'FAIL' -Check 'base_url' -Detail ('"' + $baseUrl + '" contains a query string; Codex appends /responses after it') -Hint 'move query parameters to query_params = { key = "value" }'
    } elseif ($lb.EndsWith('/v1/v1') -or $lb.Contains('/v1/v1/')) {
        Add-Result -Id '7' -Status 'FAIL' -Check 'base_url' -Detail ('"' + $baseUrl + '" repeats /v1; requests would go to ' + $b + '/responses') -Hint 'keep exactly one /v1 at the end'
    } elseif ($lb.EndsWith('/responses') -or $lb.EndsWith('/chat/completions') -or $lb.EndsWith('/completions')) {
        Add-Result -Id '7' -Status 'FAIL' -Check 'base_url' -Detail ('"' + $baseUrl + '" already ends with an endpoint; Codex appends /responses itself -> ' + $b + '/responses') -Hint 'cut base_url back to the API root, usually .../v1'
    } elseif ($lb.EndsWith('/v1')) {
        if ($lb.StartsWith('http://') -and -not (@('localhost', '127.0.0.1', '[', '::1') -contains $gwHost)) {
            Add-Result -Id '7' -Status 'WARN' -Check 'base_url' -Detail ('plain http to ' + $gwHost + ': the API key travels unencrypted (requests go to ' + $b + '/responses)') -Hint 'use https:// unless this is a trusted local network'
        } else {
            Add-Result -Id '7' -Status 'PASS' -Check 'base_url' -Detail ('requests go to ' + $b + '/responses')
        }
    } else {
        Add-Result -Id '7' -Status 'WARN' -Check 'base_url' -Detail ('does not end with /v1; Codex will call ' + $b + '/responses') -Hint "most OpenAI-compatible gateways expect https://<host>/v1 - check your gateway's docs"
    }
}

# ---------------------------------------------------------------------------
# 8. wire_api
# ---------------------------------------------------------------------------
if (-not $hasTable) {
    Add-Result -Id '8' -Status 'SKIP' -Check 'wire_api' -Detail 'no custom provider table to check'
} elseif (-not (Test-Fact -Key ($pfx + '.wire_api'))) {
    Add-Result -Id '8' -Status 'PASS' -Check 'wire_api' -Detail 'not set (defaults to "responses")'
} else {
    $wa = [string](Get-Fact -Key ($pfx + '.wire_api'))
    if ($wa -ceq 'responses') {
        Add-Result -Id '8' -Status 'PASS' -Check 'wire_api' -Detail '"responses" (the gateway must implement POST /v1/responses)'
    } elseif ($wa -ceq 'chat') {
        Add-Result -Id '8' -Status 'FAIL' -Check 'wire_api' -Detail '`wire_api = "chat"` is no longer supported' -Hint 'set wire_api = "responses"; a gateway that only has /chat/completions cannot serve Codex'
    } else {
        Add-Result -Id '8' -Status 'FAIL' -Check 'wire_api' -Detail ('unknown variant `' + $wa + '`, expected `responses`') -Hint 'set wire_api = "responses"'
    }
}

# ---------------------------------------------------------------------------
# 9. credentials
# ---------------------------------------------------------------------------
if (-not $hasTable) {
    Add-Result -Id '9' -Status 'SKIP' -Check 'credentials' -Detail 'no custom provider table to check'
} else {
    $hasEnvKey = Test-Fact -Key ($pfx + '.env_key')
    $hasAuth = Test-Fact -Key ($pfx + '.auth')
    $ek = [string](Get-Fact -Key ($pfx + '.env_key'))
    if ($hasEnvKey -and $hasAuth) {
        Add-Result -Id '9' -Status 'FAIL' -Check 'credentials' -Detail 'provider auth cannot be combined with env_key' -Hint ('keep either env_key or [model_providers.' + $provId + '.auth]')
    } elseif ($hasEnvKey) {
        if ($ek.StartsWith('<invalid-name:')) {
            $len = $ek.Substring(14).TrimEnd('>')
            Add-Result -Id '9' -Status 'FAIL' -Check 'credentials' -Detail ('env_key is not a valid environment variable name (value hidden, length ' + $len + ') - is the key itself pasted there?') -Hint 'env_key must be the NAME of a variable, e.g. env_key = "MY_GATEWAY_API_KEY"; put the key in that variable'
        } else {
            $val = [Environment]::GetEnvironmentVariable($ek)
            if ($null -eq $val -or $val.Trim() -eq '') {
                $userVal = $null
                try { $userVal = [Environment]::GetEnvironmentVariable($ek, 'User') } catch { $userVal = $null }
                if ($null -ne $userVal -and $userVal.Trim() -ne '') {
                    Add-Result -Id '9' -Status 'FAIL' -Check 'credentials' -Detail ('Missing environment variable: `' + $ek + '`. (It is saved for your Windows user, but this session does not see it.)') -Hint 'open a new terminal, and fully restart VS Code, after setting user variables'
                } else {
                    Add-Result -Id '9' -Status 'FAIL' -Check 'credentials' -Detail ('Missing environment variable: `' + $ek + '`.') -Hint ('set it: $env:' + $ek + ' = ''...'' (this session) or [Environment]::SetEnvironmentVariable(''' + $ek + ''', ''...'', ''User''); see docs/windows.md')
                }
            } else {
                $script:Secret = $val
                $klen = $val.Length
                if ($val.StartsWith('"') -or $val.EndsWith('"') -or $val.StartsWith("'") -or $val.EndsWith("'")) {
                    Add-Result -Id '9' -Status 'WARN' -Check 'credentials' -Detail ('$' + $ek + ' is set (length ' + $klen + ') but starts or ends with a quote character') -Hint 'remove the extra quotes around the key'
                } elseif ($val -match '\s') {
                    Add-Result -Id '9' -Status 'WARN' -Check 'credentials' -Detail ('$' + $ek + ' is set (length ' + $klen + ') but contains whitespace') -Hint 're-copy the key without spaces or line breaks'
                } else {
                    Add-Result -Id '9' -Status 'PASS' -Check 'credentials' -Detail ('$' + $ek + ' is set (length ' + $klen + ')')
                }
            }
        }
    } elseif ($hasAuth) {
        Add-Result -Id '9' -Status 'PASS' -Check 'credentials' -Detail ('command-backed token ([model_providers.' + $provId + '.auth])')
    } elseif (Test-Fact -Key ($pfx + '.experimental_bearer_token')) {
        Add-Result -Id '9' -Status 'WARN' -Check 'credentials' -Detail 'experimental_bearer_token stores the key in the config file' -Hint 'prefer env_key = "<ENV_VAR_NAME>" (the official docs discourage experimental_bearer_token)'
    } elseif ([string](Get-Fact -Key ($pfx + '.requires_openai_auth')) -ceq 'true') {
        Add-Result -Id '9' -Status 'WARN' -Check 'credentials' -Detail 'requires_openai_auth = true: the key comes from Codex login (auth.json / keyring), not from env_key' -Hint 'for a third-party gateway prefer env_key; see docs/errors.md#401'
    } elseif (Test-Fact -Key ($pfx + '.http_headers.authorization')) {
        Add-Result -Id '9' -Status 'WARN' -Check 'credentials' -Detail 'an Authorization header is hard-coded in http_headers (plaintext key in the config)' -Hint 'use env_key, or env_http_headers to read the header from a variable'
    } elseif (@('localhost', '127.0.0.1', '::1', '[') -contains $gwHost) {
        Add-Result -Id '9' -Status 'WARN' -Check 'credentials' -Detail 'no env_key / auth configured (fine for an unauthenticated local server)'
    } else {
        Add-Result -Id '9' -Status 'FAIL' -Check 'credentials' -Detail ('no API key configured for [model_providers.' + $provId + ']') -Hint 'add env_key = "<ENV_VAR_NAME>" and set that variable'
    }
}

# ---------------------------------------------------------------------------
# 10. keys Codex ignores or rejects
# ---------------------------------------------------------------------------
$tenStatus = 'PASS'
$tenDetail = New-Object 'System.Collections.Generic.List[string]'
$tenHint = New-Object 'System.Collections.Generic.List[string]'
function Add-TenNote {
    param([string]$Status, [string]$Text, [string]$Hint)
    if ($Status -eq 'FAIL' -or ($Status -eq 'WARN' -and $script:tenStatus -eq 'PASS')) { $script:tenStatus = $Status }
    $script:tenDetail.Add($Text)
    if ($Hint -ne '') { $script:tenHint.Add($Hint) }
}
if ($parseOk) {
    if ($scanBase.Facts.ContainsKey('profile')) {
        $lp = $scanBase.Facts['profile']
        Add-TenNote -Status 'FAIL' -Text ('legacy `profile = "' + $lp + '"` config is no longer supported') -Hint ('delete it and run codex --profile ' + $lp + ' with ' + $lp + '.config.toml')
    }
    $legacy = @()
    foreach ($k in $scanBase.Facts.Keys) {
        if ($k.StartsWith('profiles.')) { $legacy += $k.Substring(9) }
    }
    if ($legacy.Count -gt 0) {
        if ($ProfileName -ne '' -and ($legacy -ccontains $ProfileName)) {
            Add-TenNote -Status 'FAIL' -Text ('--profile ' + $ProfileName + ' cannot be used while config.toml contains [profiles.' + $ProfileName + ']') -Hint ('move that table''s keys into ' + $ProfileName + '.config.toml as top-level keys and delete [profiles.' + $ProfileName + ']')
        } else {
            Add-TenNote -Status 'WARN' -Text ('legacy [profiles.*] tables are ignored by Codex 0.134+: ' + ($legacy -join ' ')) -Hint 'move each into <CODEX_HOME>/<name>.config.toml (see config/profiles/)'
        }
    }
}
$startDir = $Project
if ($startDir -eq '') { $startDir = (Get-Location).ProviderPath }
$cfgFull = ''
if ($configPath -ne '' -and (Test-Path -LiteralPath $configPath -PathType Leaf)) { $cfgFull = (Resolve-Path -LiteralPath $configPath).ProviderPath }
$profFull = ''
if ($profilePath -ne '') { $profFull = (Resolve-Path -LiteralPath $profilePath).ProviderPath }
$d = $null
if (Test-Path -LiteralPath $startDir -PathType Container) { $d = (Resolve-Path -LiteralPath $startDir).ProviderPath }
while ($d) {
    $pf = Join-Path -Path (Join-Path -Path $d -ChildPath '.codex') -ChildPath 'config.toml'
    if (Test-Path -LiteralPath $pf -PathType Leaf) {
        $pfFull = (Resolve-Path -LiteralPath $pf).ProviderPath
        if ($pfFull -ne $cfgFull -and $pfFull -ne $profFull) {
            $pk = @(Get-ProjectProviderKey -Path $pf)
            if ($pk.Count -gt 0) {
                Add-TenNote -Status 'WARN' -Text ('project config ' + $pf + ' sets ' + ($pk -join ' ') + ' - Codex ignores these there') -Hint ('move provider settings to the user-level config (' + $configPath + ')')
            }
        }
    }
    if (Test-Path -LiteralPath (Join-Path -Path $d -ChildPath '.git')) { break }
    $parent = Split-Path -Parent $d
    if (-not $parent -or $parent -eq $d) { break }
    $d = $parent
}
if ($tenDetail.Count -eq 0) {
    Add-Result -Id '10' -Status 'PASS' -Check 'ignored keys' -Detail ('no project-level provider keys, no legacy profiles (searched from ' + $startDir + ')')
} else {
    Add-Result -Id '10' -Status $tenStatus -Check 'ignored keys' -Detail ($tenDetail -join '; ') -Hint ($tenHint -join '; ')
}

# ---------------------------------------------------------------------------
# 11. live checks (only with -Live)
# ---------------------------------------------------------------------------
function Invoke-GatewayRequest {
    param([string]$Method, [string]$Url, [string]$Body)
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { $null = $_ }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { $null = $_ }
    $client = New-Object -TypeName System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($script:TimeoutSec)
    try {
        $req = New-Object -TypeName System.Net.Http.HttpRequestMessage -ArgumentList (New-Object -TypeName System.Net.Http.HttpMethod -ArgumentList $Method), $Url
        [void]$req.Headers.TryAddWithoutValidation('Authorization', 'Bearer ' + $script:Secret)
        if ($Body -ne '') {
            [void]$req.Headers.TryAddWithoutValidation('Accept', 'text/event-stream')
            $req.Content = New-Object -TypeName System.Net.Http.StringContent -ArgumentList $Body, ([System.Text.Encoding]::UTF8), 'application/json'
        }
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $text; Error = '' }
    } catch {
        return [pscustomobject]@{ Status = 0; Body = ''; Error = $_.Exception.GetBaseException().Message }
    } finally {
        $client.Dispose()
    }
}

$liveModel = $Model
if ($liveModel -eq '') { $liveModel = $modelId }
$liveReady = $true
if (-not $Live) {
    Add-Result -Id '11a' -Status 'SKIP' -Check 'live /models' -Detail 'not run (add -Live)'
    Add-Result -Id '11b' -Status 'SKIP' -Check 'live /responses' -Detail 'not run (add -Live; sends one small billed request)'
    $liveReady = $false
} elseif (-not $custom -or $baseUrl -eq '') {
    Add-Result -Id '11a' -Status 'SKIP' -Check 'live /models' -Detail 'no custom provider with a base_url'
    Add-Result -Id '11b' -Status 'SKIP' -Check 'live /responses' -Detail 'no custom provider with a base_url'
    $liveReady = $false
}

if ($liveReady) {
    $api = $baseUrl.TrimEnd('/')

    # 11a GET /models
    $r = Invoke-GatewayRequest -Method 'GET' -Url ($api + '/models') -Body ''
    if ($r.Status -eq 200) {
        $ids = @()
        $okJson = $true
        try {
            $obj = $r.Body | ConvertFrom-Json
            $ids = @($obj.data | ForEach-Object { $_.id })
        } catch { $okJson = $false }
        $sample = Get-OneLine -Text ((@($ids | Select-Object -First 12)) -join ', ') -Max 160
        if (-not $okJson -or $null -eq $obj.data) {
            Add-Result -Id '11a' -Status 'FAIL' -Check 'live /models' -Detail 'HTTP 200 but the body is not an OpenAI-style model list' -Hint ('check base_url: ' + $api + '/models')
        } elseif ($liveModel -eq '') {
            Add-Result -Id '11a' -Status 'PASS' -Check 'live /models' -Detail ('HTTP 200, ' + $ids.Count + ' models: ' + $sample)
        } elseif ($ids -ccontains $liveModel) {
            Add-Result -Id '11a' -Status 'PASS' -Check 'live /models' -Detail ('HTTP 200, ' + $ids.Count + ' models, ' + $liveModel + ' is listed')
        } else {
            Add-Result -Id '11a' -Status 'WARN' -Check 'live /models' -Detail ('HTTP 200, ' + $ids.Count + ' models, but ' + $liveModel + ' is not listed: ' + $sample) -Hint 'set model to one of the listed IDs (IDs differ between gateways and key groups)'
        }
    } else {
        $bodyText = Get-OneLine -Text ($r.Body + $r.Error) -Max 200
        switch ($r.Status) {
            { $_ -eq 401 -or $_ -eq 403 } { Add-Result -Id '11a' -Status 'FAIL' -Check 'live /models' -Detail ('HTTP ' + $r.Status + ': key rejected: ' + $bodyText) -Hint 'check the key value and that it belongs to this gateway (docs/errors.md#401)'; break }
            404 { Add-Result -Id '11a' -Status 'FAIL' -Check 'live /models' -Detail ('HTTP 404 for ' + $api + '/models: ' + $bodyText) -Hint 'base_url is probably wrong (docs/errors.md#404-v1-v1)'; break }
            0 { Add-Result -Id '11a' -Status 'FAIL' -Check 'live /models' -Detail ('no HTTP response: ' + $bodyText) -Hint ('check DNS / proxy / firewall for ' + $gwHost); break }
            default { Add-Result -Id '11a' -Status 'FAIL' -Check 'live /models' -Detail ('HTTP ' + $r.Status + ': ' + $bodyText) }
        }
    }

    # 11b POST /responses (stream: true, like Codex)
    if ($liveModel -eq '') {
        Add-Result -Id '11b' -Status 'FAIL' -Check 'live /responses' -Detail 'no model to test: set model in the config or pass -Model ID'
    } else {
        $payload = (@{ model = $liveModel; input = 'Reply with the single word: pong'; stream = $true } | ConvertTo-Json -Compress)
        $r = Invoke-GatewayRequest -Method 'POST' -Url ($api + '/responses') -Body $payload
        if ($r.Status -eq 200) {
            $events = 0
            $last = $null
            foreach ($ln in ($r.Body -split "`r?`n")) {
                $t = $ln.Trim()
                if (-not $t.StartsWith('data:')) { continue }
                $json = $t.Substring(5).Trim()
                try { $ev = $json | ConvertFrom-Json } catch { continue }
                if ($null -eq $ev -or $null -eq $ev.PSObject.Properties['type']) { continue }
                $events++
                if (@('response.completed', 'response.incomplete', 'response.failed', 'error') -contains $ev.type) { $last = $ev }
            }
            if ($events -eq 0) {
                $why = 'no data: events in the body'
                if ($r.Body.TrimStart().StartsWith('{')) { $why = 'body is plain JSON, not an SSE stream' }
                Add-Result -Id '11b' -Status 'FAIL' -Check 'live /responses' -Detail ('HTTP 200 but ' + $why) -Hint 'Codex needs an SSE stream for stream=true (docs/check-responses-support.md)'
            } elseif ($null -eq $last) {
                Add-Result -Id '11b' -Status 'FAIL' -Check 'live /responses' -Detail ('stream ended without response.completed after ' + $events + ' events - Codex reports: stream disconnected before completion: stream closed before response.completed') -Hint 'the gateway (or a proxy in front of it) must forward the final response.completed event'
            } elseif ($last.type -ceq 'response.completed') {
                $resp = $last.response
                $usage = $null
                if ($null -ne $resp) { $usage = $resp.usage }
                $usageOk = $true
                if ($null -ne $usage) {
                    foreach ($f in @('input_tokens', 'output_tokens', 'total_tokens')) {
                        if (-not ($usage.$f -is [ValueType])) { $usageOk = $false }
                    }
                }
                if ($null -eq $resp -or -not ($resp.id -is [string])) {
                    Add-Result -Id '11b' -Status 'FAIL' -Check 'live /responses' -Detail 'response.completed has no response.id' -Hint 'Codex cannot parse this response.completed event'
                } elseif (-not $usageOk) {
                    Add-Result -Id '11b' -Status 'FAIL' -Check 'live /responses' -Detail 'usage lacks integer input_tokens/output_tokens/total_tokens' -Hint 'Codex cannot parse this response.completed event'
                } else {
                    $u = 'usage -'
                    if ($null -ne $usage) { $u = 'usage in=' + $usage.input_tokens + ' out=' + $usage.output_tokens + ' total=' + $usage.total_tokens }
                    Add-Result -Id '11b' -Status 'PASS' -Check 'live /responses' -Detail ('HTTP 200, ' + $events + ' SSE events, ends with response.completed, ' + $u)
                }
            } elseif ($last.type -ceq 'response.incomplete') {
                $reason = 'unknown'
                if ($null -ne $last.response -and $null -ne $last.response.incomplete_details -and $last.response.incomplete_details.reason) { $reason = $last.response.incomplete_details.reason }
                Add-Result -Id '11b' -Status 'FAIL' -Check 'live /responses' -Detail ('Incomplete response returned, reason: ' + $reason)
            } else {
                $err = $last
                if ($null -ne $last.response -and $null -ne $last.response.error) { $err = $last.response.error }
                Add-Result -Id '11b' -Status 'FAIL' -Check 'live /responses' -Detail ('response.failed / error event: ' + (Get-OneLine -Text ($err | ConvertTo-Json -Compress -Depth 5) -Max 160))
            }
        } else {
            $bodyText = Get-OneLine -Text ($r.Body + $r.Error) -Max 200
            switch ($r.Status) {
                { $_ -eq 401 -or $_ -eq 403 } { Add-Result -Id '11b' -Status 'FAIL' -Check 'live /responses' -Detail ('HTTP ' + $r.Status + ': key rejected: ' + $bodyText) -Hint 'docs/errors.md#401'; break }
                { $_ -eq 404 -or $_ -eq 405 } { Add-Result -Id '11b' -Status 'FAIL' -Check 'live /responses' -Detail ('HTTP ' + $r.Status + ' for ' + $api + '/responses: ' + $bodyText) -Hint 'this gateway does not serve the Responses API at this path; Codex cannot use it (docs/errors.md#responses-404)'; break }
                { $_ -eq 400 -or $_ -eq 422 } { Add-Result -Id '11b' -Status 'FAIL' -Check 'live /responses' -Detail ('HTTP ' + $r.Status + ': ' + $bodyText) -Hint 'often an unknown model ID - compare with GET /models (docs/errors.md#model-not-found)'; break }
                0 { Add-Result -Id '11b' -Status 'FAIL' -Check 'live /responses' -Detail ('no HTTP response: ' + $bodyText) -Hint 'check network / proxy; raise CODEX_DOCTOR_TIMEOUT for slow models'; break }
                default { Add-Result -Id '11b' -Status 'FAIL' -Check 'live /responses' -Detail ('HTTP ' + $r.Status + ': ' + $bodyText) }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('Summary: {0} PASS, {1} WARN, {2} FAIL, {3} SKIP' -f $script:NPass, $script:NWarn, $script:NFail, $script:NSkip)
if ($script:NFail -gt 0) {
    Write-Host 'Each check number is explained in docs/errors.md. Exit code = number of FAIL rows.'
} elseif (-not $Live) {
    Write-Host 'Offline checks passed. Next: -Live (one small billed request), then: codex exec "Reply with the single word: ready"'
} else {
    Write-Host 'All checks passed. Next: codex exec "Reply with the single word: ready"'
}
exit $script:NFail
