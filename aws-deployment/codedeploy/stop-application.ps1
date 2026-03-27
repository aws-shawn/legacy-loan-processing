# stop-application.ps1
# CodeDeploy ApplicationStop lifecycle hook
# Stops IIS website and application pool before deployment

# Force 64-bit PowerShell (WebAdministration requires it)
if ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64") {
    $scriptPath = $MyInvocation.MyCommand.Path
    & "$env:SystemRoot\SysNative\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy Bypass -File $scriptPath
    exit $LASTEXITCODE
}

$ErrorActionPreference = "Continue"

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

try {
    Write-DeploymentLog "Starting ApplicationStop lifecycle hook"
    
    # Import WebAdministration module
    Write-DeploymentLog "Importing WebAdministration module"
    Import-Module WebAdministration -ErrorAction Stop
    
    $siteName = "LoanProcessing"
    $appPoolName = "LoanProcessingAppPool"
    
    # Stop website if it exists
    if (Test-Path "IIS:\Sites\$siteName") {
        Write-DeploymentLog "Stopping website: $siteName"
        try {
            $website = Get-Website -Name $siteName
            if ($website.State -eq "Started") {
                Stop-Website -Name $siteName -ErrorAction Stop
                Write-DeploymentLog "Website $siteName stopped successfully"
            } else {
                Write-DeploymentLog "Website $siteName is already stopped (state: $($website.State))"
            }
        } catch {
            Write-DeploymentLog "Error stopping website ${siteName}: ${_}" "ERROR"
            # Continue to try stopping app pool even if website stop fails
        }
    } else {
        Write-DeploymentLog "Website $siteName does not exist, skipping" "WARN"
    }
    
    # Stop application pool if it exists
    if (Test-Path "IIS:\AppPools\$appPoolName") {
        Write-DeploymentLog "Stopping application pool: $appPoolName"
        try {
            $appPool = Get-Item "IIS:\AppPools\$appPoolName"
            if ($appPool.State -eq "Started") {
                Stop-WebAppPool -Name $appPoolName -ErrorAction Stop
                
                # Wait for app pool to fully stop (max 30 seconds)
                $maxWaitSeconds = 30
                $waitSeconds = 0
                while ((Get-WebAppPoolState -Name $appPoolName).Value -ne "Stopped" -and $waitSeconds -lt $maxWaitSeconds) {
                    Start-Sleep -Seconds 2
                    $waitSeconds += 2
                    Write-DeploymentLog "Waiting for application pool to stop... ($waitSeconds seconds)"
                }
                
                if ((Get-WebAppPoolState -Name $appPoolName).Value -eq "Stopped") {
                    Write-DeploymentLog "Application pool $appPoolName stopped successfully"
                } else {
                    Write-DeploymentLog "Application pool $appPoolName did not stop within $maxWaitSeconds seconds" "WARN"
                }
            } else {
                Write-DeploymentLog "Application pool $appPoolName is already stopped (state: $($appPool.State))"
            }
        } catch {
            Write-DeploymentLog "Error stopping application pool ${appPoolName}: ${_}" "ERROR"
            # Don't fail deployment if app pool stop fails - it might not exist yet
        }
    } else {
        Write-DeploymentLog "Application pool $appPoolName does not exist, skipping" "WARN"
    }
    
    Write-DeploymentLog "ApplicationStop lifecycle hook completed successfully"
    exit 0
    
} catch {
    Write-DeploymentLog "Fatal error in ApplicationStop hook: ${_}" "ERROR"
    Write-DeploymentLog "Stack trace: $(${_}.ScriptStackTrace)" "ERROR"
    
    # Exit with 0 to allow deployment to continue even if stop fails
    # This handles first-time deployments where IIS components don't exist yet
    Write-DeploymentLog "Continuing deployment despite errors (first-time deployment scenario)" "WARN"
    exit 0
}
