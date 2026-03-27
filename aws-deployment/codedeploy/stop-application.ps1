# stop-application.ps1
# CodeDeploy ApplicationStop lifecycle hook

# Force 64-bit PowerShell (WebAdministration requires it)
if ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64") {
    $scriptPath = $MyInvocation.MyCommand.Path
    & "$env:SystemRoot\SysNative\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy Bypass -File $scriptPath
    exit $LASTEXITCODE
}

$ErrorActionPreference = "Continue"

function Write-DeploymentLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

try {
    Write-DeploymentLog "Starting ApplicationStop lifecycle hook"
    Import-Module WebAdministration -ErrorAction Stop

    $siteName = "LoanProcessing"
    $appPoolName = "LoanProcessingAppPool"

    # Stop website
    if (Test-Path "IIS:\Sites\$siteName") {
        $website = Get-Website -Name $siteName
        if ($website.State -eq "Started") {
            Stop-Website -Name $siteName -ErrorAction Stop
            Write-DeploymentLog "Website stopped"
        } else {
            Write-DeploymentLog "Website already stopped"
        }
    } else {
        Write-DeploymentLog "Website does not exist, skipping"
    }

    # Stop app pool
    if (Test-Path "IIS:\AppPools\$appPoolName") {
        $appPool = Get-Item "IIS:\AppPools\$appPoolName"
        if ($appPool.State -eq "Started") {
            Stop-WebAppPool -Name $appPoolName -ErrorAction Stop
            $waited = 0
            while ((Get-WebAppPoolState -Name $appPoolName).Value -ne "Stopped" -and $waited -lt 30) {
                Start-Sleep -Seconds 2
                $waited += 2
            }
            Write-DeploymentLog "App pool stopped"
        } else {
            Write-DeploymentLog "App pool already stopped"
        }
    } else {
        Write-DeploymentLog "App pool does not exist, skipping"
    }

    Write-DeploymentLog "ApplicationStop completed"
    exit 0

} catch {
    $errMsg = $_.Exception.Message
    Write-DeploymentLog "Error in ApplicationStop - $errMsg" "WARN"
    Write-DeploymentLog "Continuing deployment (first-time scenario)" "WARN"
    exit 0
}
