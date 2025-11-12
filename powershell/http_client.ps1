#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# ============================================================================
# HTTP CLIENT
# ============================================================================

# ===================== Variables
$script:ProxyCredentials = $null
$retryableStatusCodes = @(
	408,	# Request Timeout
	429,	# Too Many Requests
	500,	# Internal Server Error
	502,	# Bad Gateway
	503,	# Service Unavailable
	504		# Gateway Timeout
)

# ===================== Functions
# ======= Logger
function script:Log-Host {
	[CmdletBinding()]
	param (
		# Log level
		[Parameter(Mandatory=$true, Position=0)]
		[ValidateSet('Error', 'Warning', 'Info')]
		[string] $Level,

		# Log message
		[Parameter(Mandatory=$true, Position=1)]
		[string] $Message
	)

	process {
		$Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

		switch ($Level) {
			'Error' {
				$Bullet = '[-]'
				$Color = 'Red'
			}
			'Warning' {
				$Bullet = '[*]'
				$Color = 'Yellow'
			}
			'Info' {
				$Bullet = '[+]'
				$Color = 'Green'
			}
		}

		Write-Host -ForegroundColor $Color "$Bullet $Timestamp - $Message"
	}
}

# ======= Proxy connection
function Initialize-ProxyConnection {
	param(
		# URI
		[Parameter(Mandatory = $true)]
		[System.Uri] $ProxyUri,

		# Protocol
		[Parameter(Mandatory = $false)]
		[ValidateSet('HTTP', 'HTTPS', 'SOCKS4', 'SOCKS5')]
		[string] $ProxyProtocol = 'HTTP',

		# Username
		[Parameter(Mandatory = $false)]
		[string] $Username
	)

	if ($ProxyProtocol -ne 'HTTP') {
		throw "Proxy protocol '$ProxyProtocol' is not yet implemented."
	}

	# Configure credentials if username provided
	if ($Username) {
		Write-Host "Enter proxy password for user $Username:" -ForegroundColor White
		$securePassword = Read-Host -AsSecureString

		# Store credentials securely
		$script:ProxyCredentials = New-Object System.Management.Automation.PSCredential($Username, $securePassword)
	}

	# Return proxy configuration object
	$proxyConfig = @{
		Uri = $proxyObj
		Protocol = $ProxyProtocol
		Credentials = $script:ProxyCredentials
	}

	Log-Host 'Info' "$ProxyProtocol proxy configured: $ProxyUri"

	return $proxyConfig
}

# HTTP request
function Send-HttpReq {
	[CmdletBinding()]
	param (
		# Method
		[Parameter(Mandatory = $true, Position=0)]
		[ValidateSet('GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS')]
		[string] $Method,

		# URL
		[Parameter(Mandatory = $true, Position=1)]
		[System.Uri] $Uri

		# Headers
		[Parameter(Mandatory = $false)]
		[hashtable] $Headers = @{},

		# Request Body
		[Parameter(Mandatory = $false)]
		[string] $Body,

		# Timeout in seconds
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 3600)]
		[int] $Timeout = 30,

		# Expected HTTP response code
		[Parameter(Mandatory = $false)]
		[ValidateRange(100, 599)]
		[int] $ExpectedResponseCode = 200,

		# Max request attempts
		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 100)]
		[int] $MaxAttempts = 3,

		# Proxy configuration object
		[Parameter(Mandatory = $false)]
		[object] $ProxyConfig = $null

		# Session name
		[Parameter(Mandatory = $false)]
		[string] $SessionName = 'session'

	)
	process {
		$attemptCount = 0
		$lastError = $null

		while ($attemptCount -lt $MaxAttempts) {
			$attemptCount++

			try {
				# Prepare Invoke-WebRequest parameters
				$requestParams = @{
					Uri = $Url
					Method = $Method
					Headers = $Headers.Clone()
					TimeoutSec = $Timeout
					UseBasicParsing = $true
				}

				# Add body if provided
				if ($Body) {
					$requestParams['Body'] = $Body
				}

				# Add proxy if configured
				if ($ProxyConfig) {
					$requestParams['Proxy'] = $ProxyConfig.Uri.AbsoluteUri

					if ($ProxyConfig.Credentials) {
						$requestParams['ProxyCredential'] = $ProxyConfig.Credentials
					}
				}

				# Managing web session
				$session = Get-Variable -Name $SessionName -Scope Script -ErrorAction SilentlyContinue

				if ($session -and $session.Value -is [Microsoft.PowerShell.Commands.WebRequestSession]) {
					$requestParams['WebSession'] = $session.Value
				} else {
					$requestParams['SessionVariable'] = $SessionName
				}

				# Send the request
				$response = Invoke-WebRequest @requestParams

				# Check the response code
				if ($response.StatusCode -eq $ExpectedResponseCode) {
					return $response.Content
				}
				else {
					throw "Unexpected status code ($($response.StatusCode))"
				}
			}
			catch {
				$statusCode = $null

				# Extract status code from error if available
				if ($_.Exception.Response) {
					$statusCode = [int]$_.Exception.Response.StatusCode
				}

				# Check if this is a retryable attempt
				if ($statusCode -and $statusCode -in $retryableStatusCodes -and $attemptCount -lt $MaxAttempts) {
					# Calculate backoff delay (exponential backoff)
					$delaySeconds = [Math]::Min(2, [Math]::Pow(2, $attemptCount - 1))
					Log-Host 'Info' "Waiting $delaySeconds seconds before retry..."
					Start-Sleep -Seconds $delaySeconds
					continue
				}

				# Non-retryable error - give up immediately
				Log-Host 'Error' "HTTP request error: $($_.Exception.Message)"
				throw "Failed to perform HTTP request after $attemptCount attempts"
			}
		}

		exit 1
	}
}

# ============================================================================
# EXPORT FUNCTIONS
# ============================================================================

# Export-ModuleMember -Function @(
# 	'Send-HttpReq',
# )