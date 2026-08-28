#requires -Version 5.1
<#
.SYNOPSIS
    Automated cppcheck analysis runner abstracted from IDE.
    Designed for integration into larger CI/CD pipelines.

.DESCRIPTION
    This script wraps cppcheck 2.13.0+ to run static analysis using a project
    configuration file. It supports multiple output formats, result caching,
    and pipeline-friendly exit codes.

.PARAMETER ConfigFile
    Path to the .cppcheck configuration file (e.g., project_files.cppcheck)

.PARAMETER OutputDir
    Directory for analysis results and reports. Defaults to ./cppcheck-results

.PARAMETER OutputFormat
    Result format: 'json', 'xml', 'text', or 'html'. Defaults to 'json'

.PARAMETER SeverityThreshold
    Fail if issues of this severity or higher are found: 'error', 'warning', 'style', 'performance', 'portability', 'information'

.PARAMETER EnableStandards
    Comma-separated list of coding standards to check: 'posix', 'c99', 'c11', etc.

.PARAMETER Jobs
    Number of parallel jobs for analysis. Defaults to auto-detect (logical CPU count)

.PARAMETER AdditionalArgs
    Additional cppcheck command-line arguments as a string

.PARAMETER NoCache
    Skip using cached results; force full analysis

.PARAMETER Verbose
    Enable verbose output

.EXAMPLE
    .\Run-CppcheckAnalysis.ps1 -ConfigFile project_files.cppcheck -OutputFormat json -SeverityThreshold warning

.EXAMPLE
    .\Run-CppcheckAnalysis.ps1 -ConfigFile project_files.cppcheck -OutputDir ./build/analysis -Jobs 4 -Verbose

.NOTES
    Requires: cppcheck >= 2.13.0
    Exit Codes:
        0 - Success (no issues above threshold)
        1 - Analysis issues found above severity threshold
        2 - Script execution error (missing cppcheck, bad config, etc.)
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = "./cppcheck-results",

    [Parameter(Mandatory = $false)]
    [ValidateSet('json', 'xml', 'text', 'html')]
    [string]$OutputFormat = 'json',

    [Parameter(Mandatory = $false)]
    [ValidateSet('error', 'warning', 'style', 'performance', 'portability', 'information')]
    [string]$SeverityThreshold = 'warning',

    [Parameter(Mandatory = $false)]
    [string]$EnableStandards,

    [Parameter(Mandatory = $false)]
    [int]$Jobs = 0,  # 0 = auto

    [Parameter(Mandatory = $false)]
    [string]$AdditionalArgs,

    [Parameter(Mandatory = $false)]
    [switch]$NoCache,

    [Parameter(Mandatory = $false)]
    [switch]$Verbose
)

# ==============================================================================
# Configuration & Initialization
# ==============================================================================

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# Resolve absolute paths
$ConfigFile = Resolve-Path $ConfigFile
$OutputDir = Join-Path (Resolve-Path (Split-Path $OutputDir -Parent)) (Split-Path $OutputDir -Leaf)
$CacheDir = Join-Path $OutputDir ".cache"

# Ensure output directory exists
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Write-Information "Created output directory: $OutputDir"
}

if (-not $NoCache -and -not (Test-Path $CacheDir)) {
    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
}

$LogFile = Join-Path $OutputDir "cppcheck-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$ReportFile = Join-Path $OutputDir "report.$OutputFormat"

# ==============================================================================
# Helper Functions
# ==============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $logMessage
    if ($Verbose) {
        Write-Host $logMessage
    }
}

function Test-CppcheckInstalled {
    try {
        $version = cppcheck --version 2>&1
        Write-Log "Found cppcheck: $version"
        return $true
    }
    catch {
        Write-Error "cppcheck not found in PATH. Please install cppcheck >= 2.13.0"
        return $false
    }
}

function Get-CppcheckVersion {
    $output = cppcheck --version 2>&1
    # Output format: "Cppcheck 2.13.0"
    if ($output -match 'Cppcheck (\d+\.\d+\.\d+)') {
        return [version]$Matches[1]
    }
    return $null
}

function Build-CppcheckCommand {
    $cmd = @('cppcheck')

    # Core arguments
    $cmd += '--project=' + $ConfigFile
    
    if ($Jobs -gt 0) {
        $cmd += '-j', $Jobs
    }

    # Output configuration
    switch ($OutputFormat) {
        'xml' {
            $cmd += '--xml'
            $cmd += '--output-file=' + $ReportFile
        }
        'json' {
            $cmd += '--output-file=' + $ReportFile
            $cmd += '--json'
        }
        'html' {
            $cmd += '--output-file=' + $ReportFile
            # Note: HTML requires special handling in cppcheck
        }
        'text' {
            $cmd += '--output-file=' + $ReportFile
        }
    }

    # Cache configuration
    if (-not $NoCache) {
        $cmd += '--cppcheck-build-dir=' + $CacheDir
    }

    # Standards
    if ($EnableStandards) {
        $cmd += '--std=' + $EnableStandards
    }

    # Severity & suppression
    $cmd += '--enable=all'
    
    # Add any additional arguments
    if ($AdditionalArgs) {
        $cmd += $AdditionalArgs -split '\s+'
    }

    return $cmd
}

function Invoke-CppcheckAnalysis {
    param([string[]]$Command)
    
    Write-Log "Executing: $($Command -join ' ')"
    Write-Information "Starting cppcheck analysis..."

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    try {
        & $Command[0] @($Command[1..($Command.Length - 1)]) 2>&1 | Tee-Object -FilePath $LogFile -Append
        $exitCode = $LASTEXITCODE
        $stopwatch.Stop()
        
        Write-Log "Analysis completed in $($stopwatch.Elapsed.TotalSeconds) seconds with exit code: $exitCode"
        return $exitCode
    }
    catch {
        Write-Log "Error during analysis execution: $_" -Level 'ERROR'
        throw
    }
}

function Parse-CppcheckResults {
    param([string]$ReportFile, [string]$Format)
    
    if (-not (Test-Path $ReportFile)) {
        Write-Log "Report file not found: $ReportFile" -Level 'WARN'
        return @()
    }

    $issues = @()

    switch ($Format) {
        'json' {
            try {
                $content = Get-Content $ReportFile -Raw | ConvertFrom-Json
                $issues = $content.results
            }
            catch {
                Write-Log "Failed to parse JSON report: $_" -Level 'WARN'
            }
        }
        'xml' {
            try {
                $xml = [xml](Get-Content $ReportFile)
                $issues = $xml.SelectNodes('//error')
            }
            catch {
                Write-Log "Failed to parse XML report: $_" -Level 'WARN'
            }
        }
    }

    return $issues
}

function Filter-IssuesBySeverity {
    param([array]$Issues, [string]$Threshold)
    
    $severityOrder = @{
        'information' = 0
        'portability' = 1
        'performance' = 2
        'style'       = 3
        'warning'     = 4
        'error'       = 5
    }

    $thresholdValue = $severityOrder[$Threshold]
    
    return $Issues | Where-Object {
        $issueLevel = $_.level ?? $_.severity ?? 'information'
        $severityOrder[$issueLevel] -ge $thresholdValue
    }
}

function Generate-Summary {
    param([array]$Issues, [string]$ReportFile)
    
    $summaryFile = $ReportFile -replace '\.[^.]+$', '-summary.txt'
    $summary = @(
        "=== Cppcheck Analysis Summary ==="
        "Report File: $ReportFile"
        "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Total Issues Found: $($Issues.Count)"
        ""
        "By Severity:"
    )

    $severityGroups = $Issues | Group-Object -Property { $_.level ?? $_.severity ?? 'information' }
    foreach ($group in $severityGroups | Sort-Object -Property Name) {
        $summary += "  $($group.Name): $($group.Count)"
    }

    $summary | Out-File -FilePath $summaryFile
    Write-Information "Summary written to: $summaryFile"
}

# ==============================================================================
# Main Execution
# ==============================================================================

Write-Log "===== Cppcheck Analysis Start ====="
Write-Information "Configuration: $ConfigFile"
Write-Information "Output Directory: $OutputDir"

try {
    # Validate cppcheck installation
    if (-not (Test-CppcheckInstalled)) {
        exit 2
    }

    $version = Get-CppcheckVersion
    Write-Log "Cppcheck Version: $version"

    # Build and execute analysis
    $cmd = Build-CppcheckCommand
    Write-Information "Running cppcheck with format: $OutputFormat"
    
    $analysisExitCode = Invoke-CppcheckAnalysis -Command $cmd
    
    # Parse results
    $issues = Parse-CppcheckResults -ReportFile $ReportFile -Format $OutputFormat
    $filteredIssues = Filter-IssuesBySeverity -Issues $issues -Threshold $SeverityThreshold
    
    # Generate summary
    Generate-Summary -Issues $filteredIssues -ReportFile $ReportFile

    # Determine exit code
    if ($filteredIssues.Count -gt 0) {
        Write-Information "Found $($filteredIssues.Count) issue(s) at or above severity '$SeverityThreshold'"
        Write-Log "Issues above threshold detected - failing build" -Level 'WARN'
        $finalExitCode = 1
    }
    else {
        Write-Information "No issues found above severity threshold"
        Write-Log "Analysis passed - no issues above threshold"
        $finalExitCode = 0
    }

    Write-Log "===== Cppcheck Analysis End ====="
    exit $finalExitCode
}
catch {
    Write-Error "Fatal error during analysis: $_"
    Write-Log "Fatal error: $_" -Level 'ERROR'
    Write-Log "===== Cppcheck Analysis Failed ====="
    exit 2
}
