# start-application.ps1
# CodeDeploy ApplicationStart lifecycle hook

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
    Write-DeploymentLog "Starting ApplicationStart lifecycle hook"
    Import-Module WebAdministration -ErrorAction Stop

    $appPoolName = "LoanProcessingAppPool"
    $siteName = "LoanProcessing"
    $appPath = "C:\inetpub\wwwroot\LoanProcessing"
    $port = 80

    # Remove Default Web Site if it exists (frees port 80)
    if (Test-Path "IIS:\Sites\Default Web Site") {
        Write-DeploymentLog "Removing Default Web Site to free port 80"
        Remove-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
    }

    # Create or configure app pool
    if (-not (Test-Path "IIS:\AppPools\$appPoolName")) {
        New-WebAppPool -Name $appPoolName -ErrorAction Stop
        Write-DeploymentLog "App pool created"
    }
    Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name managedRuntimeVersion -Value "v4.0"
    Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name enable32BitAppOnWin64 -Value $false
    Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name processModel.identityType -Value 2
    Write-DeploymentLog "App pool configured"

    # Verify app path exists
    if (-not (Test-Path $appPath)) {
        throw "Application path not found: $appPath"
    }

    # Create or configure website
    if (-not (Test-Path "IIS:\Sites\$siteName")) {
        New-Website -Name $siteName -PhysicalPath $appPath -ApplicationPool $appPoolName -Port $port -ErrorAction Stop
        Write-DeploymentLog "Website created"
    } else {
        Set-ItemProperty "IIS:\Sites\$siteName" -Name physicalPath -Value $appPath
        Set-ItemProperty "IIS:\Sites\$siteName" -Name applicationPool -Value $appPoolName
        Write-DeploymentLog "Website updated"
    }

    # Start app pool
    $poolState = (Get-WebAppPoolState -Name $appPoolName).Value
    if ($poolState -ne "Started") {
        Start-WebAppPool -Name $appPoolName -ErrorAction Stop
        $waited = 0
        while ((Get-WebAppPoolState -Name $appPoolName).Value -ne "Started" -and $waited -lt 30) {
            Start-Sleep -Seconds 2
            $waited += 2
        }
    }
    Write-DeploymentLog "App pool started"

    # Start website with retry
    $started = $false
    for ($i = 1; $i -le 3; $i++) {
        try {
            $ws = Get-Website -Name $siteName
            if ($ws.State -eq "Started") {
                $started = $true
                break
            }
            Start-Website -Name $siteName -ErrorAction Stop
            Start-Sleep -Seconds 3
            if ((Get-Website -Name $siteName).State -eq "Started") {
                $started = $true
                break
            }
        } catch {
            $retryErr = $_.Exception.Message
            Write-DeploymentLog "Start attempt $i failed - $retryErr" "WARN"
            if ($i -lt 3) { Start-Sleep -Seconds 10 }
        }
    }

    if (-not $started) {
        throw "Website failed to start after 3 attempts"
    }
    Write-DeploymentLog "Website started"

    # Verify
    $finalPool = (Get-WebAppPoolState -Name $appPoolName).Value
    $finalSite = (Get-Website -Name $siteName).State
    Write-DeploymentLog "Final state - App pool: $finalPool, Website: $finalSite"

    if ($finalPool -ne "Started" -or $finalSite -ne "Started") {
        throw "Verification failed - pool: $finalPool, site: $finalSite"
    }

    Write-DeploymentLog "ApplicationStart completed successfully"
    exit 0

} catch {
    $fatalErr = $_.Exception.Message
    $stack = $_.ScriptStackTrace
    Write-DeploymentLog "Fatal error - $fatalErr" "ERROR"
    Write-DeploymentLog "Stack - $stack" "ERROR"
    exit 1
}
