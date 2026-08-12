<#
.SYNOPSIS
    FS25_SoilFertilizer Mod Validator (PowerShell version)
    Static analysis tool to catch common errors before loading in-game.

.DESCRIPTION
    Performs the following checks:
    - Lua pitfall detection (goto, os.time, etc.)
    - XML well-formedness
    - Callback cross-reference (XML onClick -> Lua function)
    - Translation key validation
    - modDesc.xml source file validation
    - Debug code detection

.EXAMPLE
    .\validate_mod.ps1

.EXAMPLE
    .\validate_mod.ps1 -Verbose
#>

param(
    [switch]$Verbose
)

# Get mod path (script is in tools/ subdirectory)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ModPath = Split-Path -Parent $ScriptDir

# Validation results
$Errors = @()
$Warnings = @()

function Add-Error {
    param([string]$File, [string]$Category, [int]$Line, [string]$Message)
    $script:Errors += [PSCustomObject]@{
        File = $File
        Category = $Category
        Line = $Line
        Message = $Message
    }
}

function Add-Warning {
    param([string]$File, [string]$Category, [int]$Line, [string]$Message)
    $script:Warnings += [PSCustomObject]@{
        File = $File
        Category = $Category
        Line = $Line
        Message = $Message
    }
}

function Write-Header {
    param([string]$Text)
    Write-Host "`n$('=' * 50)" -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host "$('=' * 50)" -ForegroundColor Cyan
}

function Write-Check {
    param([string]$Text)
    Write-Host "  Checking: $Text..." -ForegroundColor Blue
}

# Verify mod path
if (-not (Test-Path (Join-Path $ModPath "modDesc.xml"))) {
    Write-Host "Error: modDesc.xml not found at $ModPath" -ForegroundColor Red
    exit 1
}

Write-Header "FS25_SoilFertilizer Mod Validator"
Write-Host "Mod Path: $ModPath" -ForegroundColor Gray
Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Gray

# ============================================================
# Phase 1: Collect Lua function names
# ============================================================
Write-Host "`nPhase 1: Collecting data..." -ForegroundColor Blue

$LuaFunctions = @{}
$LuaFiles = Get-ChildItem -Path $ModPath -Filter "*.lua" -Recurse

Write-Host "  Found $($LuaFiles.Count) Lua files" -ForegroundColor Gray

foreach ($file in $LuaFiles) {
    $RelPath = $file.FullName.Substring($ModPath.Length + 1)
    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }

    $lines = $content -split "`n"
    $LuaFunctions[$RelPath] = @()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineNum = $i + 1

        # Find function definitions
        if ($line -match 'function\s+(?:\w+[:.])?([\w]+)\s*\(') {
            $LuaFunctions[$RelPath] += $matches[1]
        }

        # Skip comment lines and comment blocks
        $trimmedLine = $line.Trim()
        $isComment = $trimmedLine.StartsWith('--') -or $trimmedLine.StartsWith('Note:')

        # Check for Lua pitfalls (only in actual code, not comments)
        # Only check patterns that indicate actual code issues
        $pitfalls = @(
            @{Pattern = '^\s*goto\s+\w'; Message = "Lua 5.1 does not support 'goto' (FS25 uses Lua 5.1)"},
            @{Pattern = '::\w+::'; Message = "Lua 5.1 does not support labels '::label::'"},
            @{Pattern = '=\s*os\.time\s*\('; Message = "os.time() not available - use g_currentMission.time"},
            @{Pattern = '=\s*os\.date\s*\('; Message = "os.date() not available - use g_currentMission.environment"},
            @{Pattern = 'setTextColorByName\s*\('; Message = "setTextColorByName() doesn't exist - use setTextColor(r,g,b,a)"},
            # Only flag DialogElement class extension, not constant usage like DialogElement.TYPE_INFO
            @{Pattern = 'DialogElement\s*[.:]new\s*\(|extends.*DialogElement'; Message = "DialogElement is deprecated - use MessageDialog pattern"}
        )

        if (-not $isComment) {
            foreach ($pitfall in $pitfalls) {
                if ($line -match $pitfall.Pattern) {
                    Add-Error -File $RelPath -Category "LUA_PITFALL" -Line $lineNum -Message $pitfall.Message
                }
            }
        }

        # Check for debug code (skip comments, logger, dev tools, and console-command files where print() is intentional)
        if (-not $isComment -and $line -match '\bprint\s*\(' `
            -and $RelPath -notmatch 'Logger\.lua' `
            -and $RelPath -notmatch '^tools\\' `
            -and $RelPath -notmatch 'src\\main\.lua' `
            -and $RelPath -notmatch 'PrecisionFarmingBridge\.lua' `
            -and $RelPath -notmatch 'SoilSettingsGUI\.lua') {
            Add-Warning -File $RelPath -Category "DEBUG_CODE" -Line $lineNum -Message "Raw print() - use the mod logger instead"
        }
    }
}

# Build flat list of all function names
$AllFunctions = @()
foreach ($funcs in $LuaFunctions.Values) {
    $AllFunctions += $funcs
}
$AllFunctions = $AllFunctions | Select-Object -Unique
Write-Host "  Found $($AllFunctions.Count) Lua functions" -ForegroundColor Gray

# ============================================================
# Phase 2: Collect XML callbacks and validate
# ============================================================
$XmlFiles = Get-ChildItem -Path $ModPath -Filter "*.xml" -Recurse | Where-Object { $_.Name -notmatch 'modDesc|translation' }

Write-Host "  Found $($XmlFiles.Count) GUI XML files" -ForegroundColor Gray

$CallbackAttrs = @('onClick', 'onOpen', 'onClose', 'onCreate', 'onHighlight', 'onHighlightRemove',
                   'onFocus', 'onFocusLeave', 'onChange', 'onCheckedChanged', 'onSelectionChanged')

foreach ($file in $XmlFiles) {
    $RelPath = $file.FullName.Substring($ModPath.Length + 1)

    try {
        $content = Get-Content $file.FullName -Raw -ErrorAction Stop
        $lines = $content -split "`n"

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $lineNum = $i + 1

            foreach ($attr in $CallbackAttrs) {
                if ($line -match "$attr=`"(\w+)`"") {
                    $callback = $matches[1]
                    # Skip base class callbacks
                    if ($callback -in @('onOpen', 'onClose', 'onCreate', 'superClass')) {
                        continue
                    }
                    if ($callback -notin $AllFunctions) {
                        Add-Error -File $RelPath -Category "MISSING_CALLBACK" -Line $lineNum -Message "$attr=`"$callback`" - function not found in Lua"
                    }
                }
            }
        }

        # Validate XML syntax
        try {
            [xml]$xml = $content
        } catch {
            Add-Error -File $RelPath -Category "XML_PARSE" -Line 0 -Message "XML parse error: $($_.Exception.Message)"
        }

    } catch {
        Add-Error -File $RelPath -Category "FILE_READ" -Line 0 -Message "Could not read file: $($_.Exception.Message)"
    }
}

# ============================================================
# Phase 3: Translation key validation
# ============================================================
Write-Host "`nPhase 2: Cross-reference validation..." -ForegroundColor Blue

$TransDir = Join-Path $ModPath "translations"
$TransKeys = @()

$EnFile = Join-Path $TransDir "translation_en.xml"
if (Test-Path $EnFile) {
    $enContent = Get-Content $EnFile -Raw
    # Match both <e k="key" and <text name="key" formats
    $keyMatches = [regex]::Matches($enContent, '<e\s+k="(\w+)"')
    foreach ($match in $keyMatches) {
        $TransKeys += $match.Groups[1].Value
    }
    $textMatches = [regex]::Matches($enContent, '<text\s+name="(\w+)"')
    foreach ($match in $textMatches) {
        $TransKeys += $match.Groups[1].Value
    }
    Write-Host "  Found $($TransKeys.Count) translation keys" -ForegroundColor Gray
}

# Check for missing translation keys in Lua files
# Only flag sf_* keys as missing (base game keys are expected to be in game's i18n)
foreach ($file in $LuaFiles) {
    $RelPath = $file.FullName.Substring($ModPath.Length + 1)
    $content = Get-Content $file.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }

    $lines = $content -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineNum = $i + 1

        # Skip comment lines
        $trimmedLine = $line.Trim()
        if ($trimmedLine.StartsWith('--')) { continue }

        $keyMatches = [regex]::Matches($line, 'getText\s*\(\s*["''](\w+)["'']')
        foreach ($match in $keyMatches) {
            $key = $match.Groups[1].Value
            # Only flag sf_* keys as errors (base game keys are assumed to exist)
            # Skip keys ending with _ (dynamic key construction like "sf_fluid_" .. fluidType)
            if ($key.StartsWith('sf_') -and -not $key.EndsWith('_') -and $key -notin $TransKeys) {
                Add-Error -File $RelPath -Category "MISSING_TRANSLATION" -Line $lineNum -Message "Translation key $key not found in translation_en.xml"
            }
        }
    }
}

# ============================================================
# Phase 4: modDesc validation
# ============================================================
Write-Host "`nPhase 3: modDesc validation..." -ForegroundColor Blue

$ModDescPath = Join-Path $ModPath "modDesc.xml"
$modDescContent = Get-Content $ModDescPath -Raw

# Check source files exist
$sourceMatches = [regex]::Matches($modDescContent, '<sourceFile\s+filename="([^"]+)"')
foreach ($match in $sourceMatches) {
    $srcFile = $match.Groups[1].Value
    if (-not (Test-Path (Join-Path $ModPath $srcFile))) {
        Add-Error -File "modDesc.xml" -Category "MISSING_SOURCE" -Line 0 -Message "sourceFile '$srcFile' does not exist"
    }
}

# ============================================================
# Print Results
# ============================================================
Write-Header "Validation Results"

# Group errors by category
$ErrorsByCategory = $Errors | Group-Object -Property Category

if ($Errors.Count -gt 0) {
    Write-Host "`nERRORS: $($Errors.Count)" -ForegroundColor Red -BackgroundColor Black

    foreach ($group in $ErrorsByCategory) {
        Write-Host "`n  [$($group.Name)] ($($group.Count) issues)" -ForegroundColor Red
        $group.Group | Select-Object -First 10 | ForEach-Object {
            $lineStr = if ($_.Line -gt 0) { ":$($_.Line)" } else { "" }
            Write-Host "    $($_.File)$lineStr : $($_.Message)" -ForegroundColor Red
        }
        if ($group.Count -gt 10) {
            Write-Host "    ... and $($group.Count - 10) more" -ForegroundColor Red
        }
    }
} else {
    Write-Host "`nERRORS: 0" -ForegroundColor Green
}

$WarningsByCategory = $Warnings | Group-Object -Property Category

if ($Warnings.Count -gt 0) {
    Write-Host "`nWARNINGS: $($Warnings.Count)" -ForegroundColor Yellow

    foreach ($group in $WarningsByCategory) {
        Write-Host "`n  [$($group.Name)] ($($group.Count) issues)" -ForegroundColor Yellow
        $group.Group | Select-Object -First 10 | ForEach-Object {
            $lineStr = if ($_.Line -gt 0) { ":$($_.Line)" } else { "" }
            Write-Host "    $($_.File)$lineStr : $($_.Message)" -ForegroundColor Yellow
        }
        if ($group.Count -gt 10) {
            Write-Host "    ... and $($group.Count - 10) more" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "`nWARNINGS: 0" -ForegroundColor Green
}

# Summary
Write-Host "`n$('=' * 50)" -ForegroundColor Cyan
if ($Errors.Count -eq 0 -and $Warnings.Count -eq 0) {
    Write-Host "All checks passed!" -ForegroundColor Green
} else {
    Write-Host "Total: $($Errors.Count) errors, $($Warnings.Count) warnings" -ForegroundColor White
    if ($Errors.Count -gt 0) {
        Write-Host "Fix errors before loading in-game!" -ForegroundColor Red
    }
}
Write-Host "$('=' * 50)`n" -ForegroundColor Cyan

# Exit code
if ($Errors.Count -gt 0) {
    exit 1
} else {
    exit 0
}
