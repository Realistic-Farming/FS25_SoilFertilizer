<#
.SYNOPSIS
    Extracts SoilFertilizer-related errors and warnings from FS25 game log.

.DESCRIPTION
    Parses the Farming Simulator 25 log.txt file and extracts all entries
    related to the SoilFertilizer mod, categorizing them by severity and type.

.PARAMETER LogPath
    Path to the log.txt file. Defaults to the standard FS25 location.

.PARAMETER OutputFile
    Optional path to save the report. If not specified, outputs to console.

.PARAMETER LastNLines
    Only analyze the last N lines of the log (useful for large logs).

.EXAMPLE
    .\extract_log_errors.ps1

.EXAMPLE
    .\extract_log_errors.ps1 -OutputFile "error_report.txt"

.EXAMPLE
    .\extract_log_errors.ps1 -LastNLines 5000
#>

param(
    [string]$LogPath = "$env:USERPROFILE\Documents\My Games\FarmingSimulator2025\log.txt",
    [string]$OutputFile = "",
    [int]$LastNLines = 0
)

# Colors for console output
function Write-ColorOutput {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

function Write-Header {
    param([string]$Text)
    Write-ColorOutput "`n$('=' * 60)" "Cyan"
    Write-ColorOutput $Text "Cyan"
    Write-ColorOutput "$('=' * 60)" "Cyan"
}

function Write-SubHeader {
    param([string]$Text)
    Write-ColorOutput "`n$Text" "Yellow"
    Write-ColorOutput ("-" * $Text.Length) "Yellow"
}

# Check if log file exists
if (-not (Test-Path $LogPath)) {
    Write-ColorOutput "Error: Log file not found at: $LogPath" "Red"
    Write-ColorOutput "Make sure you've run the game at least once." "Yellow"
    exit 1
}

Write-Header "SoilFertilizer Log Analyzer"
Write-ColorOutput "Analyzing: $LogPath" "Gray"
Write-ColorOutput "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "Gray"

# Read log file
$logContent = Get-Content $LogPath -Raw
$lines = $logContent -split "`n"

if ($LastNLines -gt 0 -and $lines.Count -gt $LastNLines) {
    Write-ColorOutput "Analyzing last $LastNLines lines of $($lines.Count) total" "Gray"
    $lines = $lines | Select-Object -Last $LastNLines
}

# Initialize counters and collections
$stats = @{
    TotalLines = $lines.Count
    SoilFertilizerLines = 0
    Errors = @()
    Warnings = @()
    LuaErrors = @()
    NilAccess = @()
    XmlErrors = @()
    LoadSuccess = $false
    ModVersion = "Unknown"
}

# Patterns to match
$patterns = @{
    # SoilFertilizer specific patterns
    SoilFertilizerLine = 'SoilFertilizer|FS25_SoilFertilizer'
    ModLoaded = 'v(\d+\.\d+\.\d+)'

    # Error patterns
    LuaError = 'Error: .+\.lua:\d+'
    LuaRuntime = 'attempt to (call|index|compare|concatenate|perform arithmetic)'
    NilValue = "attempt to \w+ (?:a )?nil value"
    XmlParse = 'XML parse error|Could not load XML'
    Warning = 'Warning:'

    # Specific SoilFertilizer patterns
    ManagerInit = '(FinanceManager|UsedVehicleManager|VehicleSaleManager)\s+(initialized|loaded)'
    DialogError = 'Dialog.*(?:nil|error|failed)'
    EventError = 'Event.*(?:nil|error|failed)'
}

# Track context for multi-line errors
$inStackTrace = $false
$currentError = @()

foreach ($i in 0..($lines.Count - 1)) {
    $line = $lines[$i]

    # Check if line is SoilFertilizer related
    if ($line -match $patterns.SoilFertilizerLine) {
        $stats.SoilFertilizerLines++

        # Check for mod version
        if ($line -match $patterns.ModLoaded) {
            $stats.ModVersion = $matches[1]
            $stats.LoadSuccess = $true
        }

        # Check for Lua errors
        if ($line -match $patterns.LuaError -or $line -match $patterns.LuaRuntime) {
            $errorEntry = @{
                Line = $i + 1
                Text = $line.Trim()
                Type = "LuaError"
            }

            # Capture stack trace if present
            $stackTrace = @($line)
            $j = $i + 1
            while ($j -lt $lines.Count -and $lines[$j] -match '^\s+(at|in|\.lua:\d+)') {
                $stackTrace += $lines[$j]
                $j++
            }
            $errorEntry.StackTrace = $stackTrace -join "`n"
            $stats.LuaErrors += $errorEntry
            $stats.Errors += $errorEntry
        }

        # Check for nil access
        if ($line -match $patterns.NilValue) {
            $errorEntry = @{
                Line = $i + 1
                Text = $line.Trim()
                Type = "NilAccess"
            }
            $stats.NilAccess += $errorEntry
            $stats.Errors += $errorEntry
        }

        # Check for warnings
        if ($line -match $patterns.Warning) {
            $stats.Warnings += @{
                Line = $i + 1
                Text = $line.Trim()
                Type = "Warning"
            }
        }
    }

    # Also check for XML errors that might reference our mod
    if ($line -match $patterns.XmlParse -and $line -match 'SoilFertilizer') {
        $stats.XmlErrors += @{
            Line = $i + 1
            Text = $line.Trim()
            Type = "XmlError"
        }
        $stats.Errors += $stats.XmlErrors[-1]
    }
}

# Generate report
$report = @()
$report += "=" * 60
$report += "SoilFertilizer Error Report"
$report += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$report += "=" * 60

$report += "`nSUMMARY"
$report += "-" * 40
$report += "Mod Version: $($stats.ModVersion)"
$report += "Mod Loaded Successfully: $($stats.LoadSuccess)"
$report += "Total Log Lines: $($stats.TotalLines)"
$report += "SoilFertilizer-Related Lines: $($stats.SoilFertilizerLines)"
$report += "Errors Found: $($stats.Errors.Count)"
$report += "Warnings Found: $($stats.Warnings.Count)"

if ($stats.Errors.Count -eq 0 -and $stats.Warnings.Count -eq 0) {
    $report += "`nNo errors or warnings found - log is clean!"
    Write-ColorOutput "`nNo errors or warnings found - log is clean!" "Green"
}

# Detailed error breakdown
if ($stats.LuaErrors.Count -gt 0) {
    $report += "`nLUA ERRORS ($($stats.LuaErrors.Count))"
    $report += "-" * 40
    foreach ($err in $stats.LuaErrors) {
        $report += "Line $($err.Line): $($err.Text)"
        if ($err.StackTrace) {
            $report += $err.StackTrace
        }
        $report += ""
    }

    Write-SubHeader "LUA ERRORS ($($stats.LuaErrors.Count))"
    foreach ($err in $stats.LuaErrors | Select-Object -First 5) {
        Write-ColorOutput "  Line $($err.Line): $($err.Text)" "Red"
    }
    if ($stats.LuaErrors.Count -gt 5) {
        Write-ColorOutput "  ... and $($stats.LuaErrors.Count - 5) more" "Red"
    }
}

if ($stats.NilAccess.Count -gt 0) {
    $report += "`nNIL ACCESS ERRORS ($($stats.NilAccess.Count))"
    $report += "-" * 40
    foreach ($err in $stats.NilAccess) {
        $report += "Line $($err.Line): $($err.Text)"
    }

    Write-SubHeader "NIL ACCESS ERRORS ($($stats.NilAccess.Count))"
    foreach ($err in $stats.NilAccess | Select-Object -First 5) {
        Write-ColorOutput "  Line $($err.Line): $($err.Text)" "Red"
    }
    if ($stats.NilAccess.Count -gt 5) {
        Write-ColorOutput "  ... and $($stats.NilAccess.Count - 5) more" "Red"
    }
}

if ($stats.XmlErrors.Count -gt 0) {
    $report += "`nXML ERRORS ($($stats.XmlErrors.Count))"
    $report += "-" * 40
    foreach ($err in $stats.XmlErrors) {
        $report += "Line $($err.Line): $($err.Text)"
    }

    Write-SubHeader "XML ERRORS ($($stats.XmlErrors.Count))"
    foreach ($err in $stats.XmlErrors) {
        Write-ColorOutput "  Line $($err.Line): $($err.Text)" "Red"
    }
}

if ($stats.Warnings.Count -gt 0) {
    $report += "`nWARNINGS ($($stats.Warnings.Count))"
    $report += "-" * 40
    foreach ($warn in $stats.Warnings) {
        $report += "Line $($warn.Line): $($warn.Text)"
    }

    Write-SubHeader "WARNINGS ($($stats.Warnings.Count))"
    foreach ($warn in $stats.Warnings | Select-Object -First 10) {
        Write-ColorOutput "  Line $($warn.Line): $($warn.Text)" "Yellow"
    }
    if ($stats.Warnings.Count -gt 10) {
        Write-ColorOutput "  ... and $($stats.Warnings.Count - 10) more" "Yellow"
    }
}

# Output report
if ($OutputFile) {
    $report | Out-File -FilePath $OutputFile -Encoding utf8
    Write-ColorOutput "`nReport saved to: $OutputFile" "Green"
} else {
    Write-Header "END OF REPORT"
}

# Exit with appropriate code
if ($stats.Errors.Count -gt 0) {
    exit 1
} else {
    exit 0
}
