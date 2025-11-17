# ============================================================================
# USAGE
# ============================================================================
# ./logger.ps1
#
# Write-Log Critical 'Testing critical'
# Write-Log Error 'Testing error'
# Write-Log Warning 'Testing warning'
# Write-Log Info 'Testing info'
# Write-Log Debug 'Testing debug'

# ============================================================================
# INITIALIZATIONS
# ============================================================================

$ErrorActionPreference = 'Stop'

# ============ Constants
Set-Variable LOG_NONE -Option ReadOnly -Value 99
Set-Variable LOG_CRITICAL -Option ReadOnly -Value 50
Set-Variable LOG_ERROR -Option ReadOnly -Value 40
Set-Variable LOG_WARNING -Option ReadOnly -Value 30
Set-Variable LOG_INFO -Option ReadOnly -Value 20
Set-Variable LOG_DEBUG -Option ReadOnly -Value 10

Set-Variable LogLevelNames -Option ReadOnly -Value @{
	99 = 'NONE'
	50 = 'CRITICAL'
	40 = 'ERROR'
	30 = 'WARNING'
	20 = 'INFO'
	10 = 'DEBUG'
}

Set-Variable LogColors -Option ReadOnly -Value @{
	99 = 'Gray'		# Reset/None
	50 = 'Magenta'	# Critical
	40 = 'Red'		# Error
	30 = 'Yellow'	# Warning
	20 = 'Green'	# Info
	10 = 'Cyan'		# Debug
	0 = 'White'		# Custom
}

Set-Variable TimestampFormat -Option ReadOnly -Value 'HH:mm:ss.fff'

# ============ Default Configurations
$CurrentLogLevel = $LOG_INFO
$ColorizeMessage = $true

# ============================================================================
# PRIVATE FUNCTIONS
# ============================================================================

# ============ Traceback the calling stack
function Get-CallerInfo {
	[CmdletBinding()]
	param()

	# Get call stack
	$callStack = Get-PSCallStack

	# Skip internal logger functions
	$callerFrame = $null
	foreach ($frame in $callStack) {
		if ($frame.Command -notlike '*Log*' -and
			$frame.Command -ne 'Get-CallerInfo' -and
			$frame.Command -ne '<ScriptBlock>') {
			$callerFrame = $frame
			break
		}
	}

	# Default values if we can't find a caller
	if (-not $callerFrame) {
		$callerFrame = $callStack[-1]
	}

	# Get caller info
	$processId = $PID

	$fileName = if ($callerFrame.ScriptName) {
		Split-Path -Leaf $callerFrame.ScriptName
	} else {
		'Interactive'
	}

	$functionName = if ($callerFrame.Command) {
		$callerFrame.Command
	} else {
		'main'
	}

	return "${processId}:${fileName}:${functionName}"
}

# ============ Write the log to the host
function Write-LogMessage {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[int]$Level,

		[Parameter(Mandatory = $true)]
		[string]$Message
	)

	# Check if we should log this level
	if ($Level -lt $CurrentLogLevel) {
		return
	}

	# Gather metadata
	$timestamp = Get-Date -Format $TimestampFormat
	$levelName = $LogLevelNames[$Level]
	$callerInfo = Get-CallerInfo

	# Format the message
	if ($ColorizeMessage) {
		# Build colored output
		Write-Host '[' -NoNewline -ForegroundColor Gray
		Write-Host $timestamp -NoNewline -ForegroundColor Cyan
		Write-Host '] [' -NoNewline -ForegroundColor Gray
		Write-Host $callerInfo -NoNewline -ForegroundColor Cyan
		Write-Host '] [' -NoNewline -ForegroundColor Gray
		Write-Host $levelName -NoNewline -ForegroundColor $LogColors[$Level]
		Write-Host '] ' -NoNewline -ForegroundColor Gray
		Write-Host $Message -ForegroundColor White
	} else {
		# Plain text output
		Write-Host "[$timestamp] [$callerInfo] [$levelName] $Message"
	}
}

# ============================================================================
# PUBLIC API
# ============================================================================

# ============ Logging API
function Write-Log {
	[CmdletBinding()]
	param (
		# Log level
		[Parameter(Mandatory=$true, Position=0)]
		[ValidateSet('Critical', 'Error', 'Warning', 'Info', 'Debug')]
		[string] $Level,

		# Log message
		[Parameter(Mandatory=$true, Position=1)]
		[string] $Message
	)

	process {
		switch ($Level) {
			'Critical' {
				Write-LogMessage -Level $LOG_CRITICAL -Message $Message
			}
			'Error' {
				Write-LogMessage -Level $LOG_ERROR -Message $Message
			}
			'Warning' {
				Write-LogMessage -Level $LOG_WARNING -Message $Message
			}
			'Info' {
				Write-LogMessage -Level $LOG_INFO -Message $Message
			}
			'Debug' {
				Write-LogMessage -Level $LOG_DEBUG -Message $Message
			}
		}
	}
}