# validate-deployment.ps1
# CodeDeploy ValidateService lifecycle hook
# Validates that the deployment was successful by checking IIS, website, HTTP response, and database connectivity

# Force 64-bit PowerShell (WebAdministration requires it)
if ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64") {
    $scriptPath = $MyInvocation.MyCommand.Path
    & "$env:SystemRoot\SysNative\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy Bypass -File $scriptPath
    exit $LASTEXITCODE
}

$ErrorActionPreference = "Stop"

# Function to write logs to CloudWatch
function Write-DeploymentLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage
    
    # Write to CloudWatch Logs via stdout (CodeDeploy agent captures this)
    # Format: [timestamp] [level] message
    # CloudWatch log group: /aws/codedeploy/loan-processing-{environment}
}

# Function to redact sensitive information from logs
function Write-SafeLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    # Redact password patterns
    $safeMessage = $Message -replace "Password=[^;]+", "Password=***REDACTED***"
    $safeMessage = $safeMessage -replace "password['""]?\s*[:=]\s*['""]?[^'"";\s]+", "password=***REDACTED***"
    
    Write-DeploymentLog $safeMessage $Level
}

try {
    Write-DeploymentLog "Starting ValidateService lifecycle hook - Deployment Validation"
    
    # ============================================================================
    # STEP 1: Check IIS Service (W3SVC) is Running
    # ============================================================================
    
    Write-DeploymentLog "Checking IIS service (W3SVC) status"
    
    try {
        $iisService = Get-Service -Name W3SVC -ErrorAction Stop
        
        Write-DeploymentLog "IIS service status: $($iisService.Status)"
        
        if ($iisService.Status -ne "Running") {
            Write-DeploymentLog "IIS service is not running (status: $($iisService.Status))" "ERROR"
            throw "IIS service (W3SVC) is not running - deployment validation failed"
        }
        
        Write-DeploymentLog "IIS service check passed - W3SVC is running"
        
    } catch {
        Write-DeploymentLog "Failed to check IIS service: ${_}" "ERROR"
        throw "IIS service check failed: ${_}"
    }
    
    # ============================================================================
    # STEP 2: Check LoanProcessing Website State is "Started"
    # ============================================================================
    
    Write-DeploymentLog "Checking LoanProcessing website state"
    
    try {
        Import-Module WebAdministration -ErrorAction Stop
        
        $siteName = "LoanProcessing"
        $website = Get-Website -Name $siteName -ErrorAction Stop
        
        Write-DeploymentLog "Website '$siteName' state: $($website.State)"
        
        if ($website.State -ne "Started") {
            Write-DeploymentLog "Website is not in Started state (state: $($website.State))" "ERROR"
            throw "Website '$siteName' is not started - deployment validation failed"
        }
        
        Write-DeploymentLog "Website state check passed - '$siteName' is started"
        
    } catch {
        Write-DeploymentLog "Failed to check website state: ${_}" "ERROR"
        throw "Website state check failed: ${_}"
    }
    
    # ============================================================================
    # STEP 3: Make HTTP Request to http://localhost/ with Retry Logic
    # ============================================================================
    
    Write-DeploymentLog "Testing HTTP connectivity to application"
    
    $maxAttempts = 10
    $retryDelaySeconds = 5
    $httpSuccess = $false
    $url = "http://localhost/"
    
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Write-DeploymentLog "HTTP health check attempt $attempt of $maxAttempts (URL: $url)"
            
            $response = Invoke-WebRequest -Uri $url -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
            
            Write-DeploymentLog "HTTP response received - Status Code: $($response.StatusCode)"
            
            # ============================================================================
            # STEP 4: Verify HTTP Response Status Code is 200
            # ============================================================================
            
            if ($response.StatusCode -eq 200) {
                Write-DeploymentLog "HTTP health check passed - received 200 OK response"
                $httpSuccess = $true
                break
            } else {
                Write-DeploymentLog "HTTP response status code is not 200 (received: $($response.StatusCode))" "WARN"
                throw "Unexpected status code: $($response.StatusCode)"
            }
            
        } catch {
            Write-DeploymentLog "HTTP health check attempt $attempt failed: ${_}" "WARN"
            
            if ($attempt -lt $maxAttempts) {
                Write-DeploymentLog "Retrying in $retryDelaySeconds seconds..." "WARN"
                Start-Sleep -Seconds $retryDelaySeconds
            } else {
                Write-DeploymentLog "All HTTP health check attempts failed" "ERROR"
                throw "Application health check failed after $maxAttempts attempts - deployment validation failed"
            }
        }
    }
    
    if (-not $httpSuccess) {
        throw "HTTP health check failed after $maxAttempts attempts"
    }
    
    # ============================================================================
    # STEP 5: Test Database Connectivity (Warning Only)
    # ============================================================================
    
    Write-DeploymentLog "Testing database connectivity"
    
    try {
        $webConfigPath = "C:\inetpub\wwwroot\LoanProcessing\Web.config"
        
        if (-not (Test-Path $webConfigPath)) {
            Write-DeploymentLog "Web.config not found at $webConfigPath" "WARN"
            Write-DeploymentLog "Skipping database connectivity check" "WARN"
        } else {
            # Load Web.config and parse connection string
            Write-DeploymentLog "Loading Web.config to extract connection string"
            [xml]$webConfig = Get-Content $webConfigPath
            
            $connectionNode = $webConfig.configuration.connectionStrings.add | 
                Where-Object { $_.name -eq "LoanProcessingConnection" }
            
            if ($null -eq $connectionNode) {
                Write-DeploymentLog "LoanProcessingConnection not found in Web.config" "WARN"
                Write-DeploymentLog "Skipping database connectivity check" "WARN"
            } else {
                $connectionString = $connectionNode.connectionString
                Write-SafeLog "Connection string found in Web.config: $connectionString"
                
                # Parse connection string
                $csBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder($connectionString)
                
                $dbServer = $csBuilder.DataSource
                $dbName = $csBuilder.InitialCatalog
                $dbUsername = $csBuilder.UserID
                $dbPassword = $csBuilder.Password
                
                Write-DeploymentLog "Parsed connection string - Server: $dbServer, Database: $dbName, Username: $dbUsername"
                
                # Execute test query
                Write-DeploymentLog "Executing test query to verify database connectivity"
                $testQuery = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES"
                
                $result = sqlcmd -S $dbServer -U $dbUsername -P $dbPassword -d $dbName -Q $testQuery -h -1 -W
                
                if ($LASTEXITCODE -eq 0) {
                    $tableCount = [int]$result.Trim()
                    Write-DeploymentLog "Database connectivity verified successfully - found $tableCount tables"
                } else {
                    throw "sqlcmd returned exit code $LASTEXITCODE"
                }
            }
        }
        
    } catch {
        # Database connectivity failures are logged as warnings, not errors
        # Per requirements 8.7: Log warning (not failure) if database connectivity check fails
        Write-DeploymentLog "Database connectivity check failed: ${_}" "WARN"
        Write-DeploymentLog "This is a non-critical warning - deployment validation will continue" "WARN"
        Write-DeploymentLog "Database may not be accessible, but application deployment is considered successful" "WARN"
    }
    
    # ============================================================================
    # STEP 6: Final Validation Summary
    # ============================================================================
    
    Write-DeploymentLog "Deployment validation summary:"
    Write-DeploymentLog "  - IIS service (W3SVC): Running ✓"
    Write-DeploymentLog "  - LoanProcessing website: Started ✓"
    Write-DeploymentLog "  - HTTP health check (http://localhost/): 200 OK ✓"
    Write-DeploymentLog "  - Database connectivity: Checked (warning only)"
    
    Write-DeploymentLog "ValidateService lifecycle hook completed successfully"
    Write-DeploymentLog "Deployment validation passed - application is ready to serve requests"
    exit 0
    
} catch {
    Write-DeploymentLog "Fatal error in ValidateService hook: ${_}" "ERROR"
    Write-DeploymentLog "Stack trace: $(${_}.ScriptStackTrace)" "ERROR"
    Write-DeploymentLog "Deployment validation failed - this will trigger automatic rollback"
    
    # Exit with error code to fail deployment
    # Validation failures should trigger rollback to previous version
    exit 1
}
