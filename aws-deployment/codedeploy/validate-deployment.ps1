# validate-deployment.ps1
# CodeDeploy ValidateService lifecycle hook

# Force 64-bit PowerShell (WebAdministration requires it)
if ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64") {
    $scriptPath = $MyInvocation.MyCommand.Path
    & "$env:SystemRoot\SysNative\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy Bypass -File $scriptPath
    exit $LASTEXITCODE
}

$ErrorActionPreference = "Stop"

function Write-DeploymentLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

try {
    Write-DeploymentLog "Starting ValidateService lifecycle hook"

    # Check IIS service
    Write-DeploymentLog "Checking IIS service (W3SVC)"
    $iisService = Get-Service -Name W3SVC -ErrorAction Stop
    if ($iisService.Status -ne "Running") {
        throw "IIS service is not running"
    }
    Write-DeploymentLog "IIS service check passed"

    # Check website state
    Write-DeploymentLog "Checking LoanProcessing website state"
    Import-Module WebAdministration -ErrorAction Stop
    $website = Get-Website -Name "LoanProcessing" -ErrorAction Stop
    if ($website.State -ne "Started") {
        throw "Website is not started"
    }
    Write-DeploymentLog "Website state check passed"

    # HTTP health check with retry
    Write-DeploymentLog "Testing HTTP connectivity"
    $maxAttempts = 10
    $httpSuccess = $false

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Write-DeploymentLog "HTTP check attempt $attempt of $maxAttempts"
            $response = Invoke-WebRequest -Uri "http://localhost/" -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                Write-DeploymentLog "HTTP health check passed - 200 OK"
                $httpSuccess = $true
                break
            }
        } catch {
            $errMsg = $_.Exception.Message
            Write-DeploymentLog "Attempt $attempt failed - $errMsg" "WARN"
            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Seconds 5
            }
        }
    }

    if (-not $httpSuccess) {
        throw "HTTP health check failed after $maxAttempts attempts"
    }

    # Database connectivity (warning only)
    Write-DeploymentLog "Testing database connectivity"
    try {
        $webConfigPath = "C:\inetpub\wwwroot\LoanProcessing\Web.config"
        if (Test-Path $webConfigPath) {
            [xml]$webConfig = Get-Content $webConfigPath
            $connNode = $webConfig.configuration.connectionStrings.add | Where-Object { $_.name -eq "LoanProcessingConnection" }
            if ($null -ne $connNode) {
                $csBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($connNode.connectionString)
                $result = sqlcmd -S $csBuilder.DataSource -U $csBuilder.UserID -P $csBuilder.Password -d $csBuilder.InitialCatalog -Q "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES" -h -1 -W
                if ($LASTEXITCODE -eq 0) {
                    Write-DeploymentLog "Database connectivity verified"
                } else {
                    Write-DeploymentLog "Database check returned non-zero exit code" "WARN"
                }
            } else {
                Write-DeploymentLog "Connection string not found in Web.config" "WARN"
            }
        } else {
            Write-DeploymentLog "Web.config not found" "WARN"
        }
    } catch {
        $dbErr = $_.Exception.Message
        Write-DeploymentLog "Database check failed (non-critical) - $dbErr" "WARN"
    }

    # Summary
    Write-DeploymentLog "Validation passed - IIS running, website started, HTTP 200 OK"
    exit 0

} catch {
    $fatalErr = $_.Exception.Message
    $stack = $_.ScriptStackTrace
    Write-DeploymentLog "Fatal error - $fatalErr" "ERROR"
    Write-DeploymentLog "Stack - $stack" "ERROR"
    exit 1
}
