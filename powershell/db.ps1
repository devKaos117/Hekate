# ============================================================================
# USAGE
# ============================================================================
# ./http.ps1
# $proxy = Initialize-ProxyConnection "HTTP" "proxy:8080/" "kaos"
# $res = Send-HttpReq "GET" "www.google.com" -ProxyConfig $proxy

# ============================================================================
# INITIALIZATIONS
# ============================================================================

$ErrorActionPreference = "Stop"

# ============ Importing
./logger.ps1

# ============ Variables
Set-Variable DefaultConnectionTimeout -Scope Script -Visibility Private -Value 30
Set-Variable DefaultCommandTimeout -Scope Script -Visibility Private -Value 30

# ============================================================================
# PRIVATE FUNCTIONS
# ============================================================================
# ============ Obtain PostgreSQL credentials
function Get-PostgreSQLCredential {
	[CmdletBinding()]
	[OutputType([PSCredential])]
	param(
		[string]$Username
	)

	process {
		Write-Log "Debug" "Requesting PostgreSQL credentials"

		try {
			if ($Username) {
				$securePassword = Read-Host -Prompt "Enter password for user '$Username'" -AsSecureString
				return New-Object System.Management.Automation.PSCredential($Username, $securePassword)
			}
			else {
				return Get-Credential -Message "Enter PostgreSQL credentials"
			}
		}
		catch {
			Write-Log "Error" "Failed to create credentials: $($_.Exception.Message)"
			throw
		}
	}
}

# ============ Obtain PostgreSQL Conn String
function New-PostgreSQLConnectionString {
	[CmdletBinding()]
	[OutputType([string])]
	param(
		[Parameter(Mandatory, Position = 0)]
		[PSCredential]$Credential,

		[Parameter(Mandatory, Position = 1)]
		[string]$Server,

		[Parameter(Mandatory, Position = 2)]
		[int]$Port,

		[Parameter(Mandatory, Position = 3)]
		[string]$Database,

		[Parameter()]
		[int]$ConnectionTimeout = $script:DefaultConnectionTimeout,

		[Parameter()]
		[switch]$UseSSL = $false,

		[Parameter()]
		[switch]$TrustServerCertificate = $false,

		[Parameter()]
		[hashtable]$AdditionalParameters = @{}
	)

	process {
		Write-Log "Debug" "Building PostgreSQL connection query"

		$builder = New-Object System.Text.StringBuilder
		[void]$builder.Append("Host=$Server;")
		[void]$builder.Append("Port=$Port;")
		[void]$builder.Append("Database=$Database;")
		[void]$builder.Append("Timeout=$ConnectionTimeout;")
		[void]$builder.Append("Username=$($Credential.UserName);")

		# Securely extract password
		$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
		try {
			$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
			[void]$builder.Append("Password=$plainPassword;")
		}
		finally {
			[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
		}

		# SSL settings
		if ($UseSSL) {
			[void]$builder.Append("SSL Mode=Require;")
		}
		if ($TrustServerCertificate) {
			[void]$builder.Append("Trust Server Certificate=true;")
		}

		# Additional parameters
		if ($AdditionalParameters) {
			foreach ($key in $AdditionalParameters.Keys) {
				[void]$builder.Append("$key=$($AdditionalParameters[$key]);")
			}
		}

		return $builder.ToString()
	}
}

# ============================================================================
# PUBLIC API
# ============================================================================
# ============ Make a new PostgreSQL connection
function New-PostgreSQLConnection {
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param(
		[Parameter(Mandatory, Position = 0)]
		[string]$Username,

		[Parameter(Mandatory, Position = 1)]
		[string]$Server,

		[Parameter(Mandatory, Position = 2)]
		[int]$Port,

		[Parameter(Mandatory, Position = 3)]
		[string]$Database,

		[Parameter()]
		[int]$ConnectionTimeout = $script:DefaultConnectionTimeout,

		[Parameter()]
		[switch]$UseSSL = $false,

		[Parameter()]
		[switch]$TrustServerCertificate = $false,

		[Parameter()]
		[hashtable]$AdditionalParameters = @{}
	)

	process {
		try {
			Write-Log "Debug" "Connecting to PostgreeSQL"

			$credentials = Get-PostgreSQLCredential -Username $Username

			$connStringParams = @{
				Server = $Server
				Port = $Port
				Database = $Database
				Credential = $credentials
				ConnectionTimeout = $ConnectionTimeout
				UseSSL = $UseSSL
				TrustServerCertificate = $TrustServerCertificate
				AdditionalParameters = $AdditionalParameters
			}

			$connectionString = New-PostgreSQLConnectionString @connStringParams
			$connection = New-Object Npgsql.NpgsqlConnection($connectionString)
			$connection.Open()

			Write-Log "Info" "Successfully connected to PostgreSQL ${Server}:${Port}/${Database}"

			return [PSCustomObject]@{
				Connection = $connection
				Server = $Server
				Database = $Database
				IsOpen = $connection.State -eq 'Open'
				ConnectionId = [guid]::NewGuid()
			}
		}
		catch {
			Write-Log "Error" "Failed to connect to PostgreSQL: $($_.Exception.Message)"
			throw
		}
	}
}

# ============ Close a PostgreSQL connection
function Close-PostgreSQLConnection {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory, ValueFromPipeline)]
		[PSCustomObject]$Connection
	)

	process {
		if (-not $Connection.Connection -or $Connection.Connection.State -ne 'Open') {
			Write-Log "Warning" "Tried to close an unavailable PostgreSQL connection"
			return
		}

		try {
			$Connection.Connection.Close()
			$Connection.Connection.Dispose()
			Write-Log "Debug" "PostgreSQL connection closed"
		}
		catch {
			Write-Log "Error" "Error closing connection: $($_.Exception.Message)"
		}
	}
}

# ============ Test a PostgreSQL connection
function Test-PostgreSQLConnection {
	[CmdletBinding()]
	[OutputType([bool])]
	param(
		[Parameter(Mandatory, ValueFromPipeline)]
		[PSCustomObject]$Connection
	)

	process {
		if ($Connection.Connection.State -ne 'Open') {
			return $false
		}

		try {
			$cmd = $Connection.Connection.CreateCommand()
			$cmd.CommandText = "SELECT 1"
			$cmd.CommandTimeout = 5
			$result = $cmd.ExecuteScalar()
			$cmd.Dispose()

			return $result -eq 1
		}
		catch {
			return $false
		}
	}
}

# ============ Invoke a PostgreSQL query
function Invoke-PostgreSQLQuery {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory, Position = 0)]
		[PSCustomObject]$Connection,

		[Parameter(Mandatory, Position = 1)]
		[string]$Query,

		[Parameter()]
		[hashtable]$Parameters,

		[Parameter()]
		[int]$CommandTimeout = $script:DefaultCommandTimeout,

		[Parameter()]
		[switch]$AsDataTable = $false
	)

	$cmd = $null
	$reader = $null

	try {
		$cmd = $Connection.Connection.CreateCommand()
		$cmd.CommandText = $Query
		$cmd.CommandTimeout = $CommandTimeout

		# Add parameters securely
		if ($Parameters) {
			foreach ($key in $Parameters.Keys) {
				$param = $cmd.CreateParameter()
				$param.ParameterName = $key
				$param.Value = if ($null -eq $Parameters[$key]) { [DBNull]::Value } else { $Parameters[$key] }
				[void]$cmd.Parameters.Add($param)
			}
		}

		Write-Log "Debug" "Executing query: $Query"

		if ($AsDataTable) {
			$dataTable = New-Object System.Data.DataTable
			$reader = $cmd.ExecuteReader()
			$dataTable.Load($reader)
			Write-Log "Debug" "Data table query returned $($dataTable.Rows.Count) rows"
			return $dataTable
		}
		else {
			$reader = $cmd.ExecuteReader()
			$results = @()

			while ($reader.Read()) {
				$row = @{}
				for ($i = 0; $i -lt $reader.FieldCount; $i++) {
					$columnName = $reader.GetName($i)
					$row[$columnName] = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
				}
				$results += [PSCustomObject]$row
			}

			Write-Log "Debug" "Query returned $($results.Count) rows"
			return $results
		}
	}
	catch {
		Write-Log "Error" "Query execution failed: $($_.Exception.Message)"
		throw
	}
	finally {
		if ($reader) { $reader.Close(); $reader.Dispose() }
		if ($cmd) { $cmd.Dispose() }
	}
}