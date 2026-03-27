# start-application.ps1
# CodeDeploy ApplicationStart lifecycle hook
# Configures and starts IIS website and application pool after deployment

# Force 64-bit PowerShell (WebAdministration requires it)
if ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64") {
    # Running in 32-bit process on 64-bit OS - relaunch as 64-bit
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

try {
    Write-DeploymentLog "Starting ApplicationStart lifecycle hook"
    
    # Import WebAdministration module
    Write-DeploymentLog "Importing WebAdministration module"
    Import-Module WebAdministration -ErrorAction Stop
    
    $appPoolName = "LoanProcessingAppPool"
    $siteName = "LoanProcessing"
    $appPath = "C:\inetpub\wwwroot\LoanProcessing"
    $port = 80
    
    # ============================================================================
    # STEP 1: Create or Configure Application Pool
    # ============================================================================
    
    Write-DeploymentLog "Configuring application pool: $appPoolName"
    
    if (-not (Test-Path "IIS:\AppPools\$appPoolName")) {
        Write-DeploymentLog "Application pool does not exist, creating: $appPoolName"
        try {
            New-WebAppPool -Name $appPoolName -ErrorAction Stop
            Write-DeploymentLog "Application pool created successfully"
        } catch {
            Write-DeploymentLog "Failed to create application pool: ${_}" "ERROR"
            throw "Application pool creation failed: ${_}"
        }
    } else {
        Write-DeploymentLog "Application pool already exists: $appPoolName"
    }
    
    # Configure application pool settings
    Write-DeploymentLog "Configuring application pool settings"
    try {
        # Set .NET Framework version to v4.0 (compatible with .NET Framework 4.7.2)
        Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name managedRuntimeVersion -Value "v4.0"
        Write-DeploymentLog "Set managedRuntimeVersion to v4.0"
        
        # Set 64-bit mode
        Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name enable32BitAppOnWin64 -Value $false
        Write-DeploymentLog "Set enable32BitAppOnWin64 to false (64-bit mode)"
        
        # Set identity to ApplicationPoolIdentity
        Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name processModel.identityType -Value 2
        Write-DeploymentLog "Set identity to ApplicationPoolIdentity"
        
        Write-DeploymentLog "Application pool configured successfully"
        
    } catch {
        Write-DeploymentLog "Failed to configure application pool: ${_}" "ERROR"
        throw "Application pool configuration failed: ${_}"
    }
    
    # ============================================================================
    # STEP 2: Create or Configure Website
    # ============================================================================
    
    Write-DeploymentLog "Configuring website: $siteName"
    
    # Remove Default Web Site if it exists (frees port 80)
    if (Test-Path "IIS:\Sites\Default Web Site") {
        Write-DeploymentLog "Removing Default Web Site to free port 80"
        Remove-Website -Name "Default Web Site" -ErrorAction SilentlyContinue
    }
    
    # Verify application path exists
    if (-not (Test-Path $appPath)) {
        Write-DeploymentLog "Application path does not exist: $appPath" "ERROR"
        throw "Application path not found - deployment files may not have been copied correctly"
    }
    
    if (-not (Test-Path "IIS:\Sites\$siteName")) {
        Write-DeploymentLog "Website does not exist, creating: $siteName"
        try {
            New-Website -Name $siteName `
                -PhysicalPath $appPath `
                -ApplicationPool $appPoolName `
                -Port $port `
                -ErrorAction Stop
            
            Write-DeploymentLog "Website created successfully (port: $port, path: $appPath, app pool: $appPoolName)"
            
        } catch {
            Write-DeploymentLog "Failed to create website: ${_}" "ERROR"
            throw "Website creation failed: ${_}"
        }
    } else {
        Write-DeploymentLog "Website already exists: $siteName"
        
        # Update website configuration
        Write-DeploymentLog "Updating website configuration"
        try {
            Set-ItemProperty "IIS:\Sites\$siteName" -Name physicalPath -Value $appPath
            Set-ItemProperty "IIS:\Sites\$siteName" -Name applicationPool -Value $appPoolName
            Write-DeploymentLog "Website configuration updated (path: $appPath, app pool: $appPoolName)"
            
        } catch {
            Write-DeploymentLog "Failed to update website configuration: ${_}" "ERROR"
            throw "Website configuration update failed: ${_}"
        }
    }
    
    # ============================================================================
    # STEP 3: Start Application Pool
    # ============================================================================
    
    Write-DeploymentLog "Starting application pool: $appPoolName"
    
    try {
        $appPool = Get-Item "IIS:\AppPools\$appPoolName"
        
        if ($appPool.State -eq "Started") {
            Write-DeploymentLog "Application pool is already started"
        } else {
            Write-DeploymentLog "Application pool state: $($appPool.State), starting..."
            Start-WebAppPool -Name $appPoolName -ErrorAction Stop
            
            # Wait for app pool to start (max 30 seconds)
            $maxWaitSeconds = 30
            $waitSeconds = 0
            while ((Get-WebAppPoolState -Name $appPoolName).Value -ne "Started" -and $waitSeconds -lt $maxWaitSeconds) {
                Start-Sleep -Seconds 2
                $waitSeconds += 2
                Write-DeploymentLog "Waiting for application pool to start... ($waitSeconds seconds)"
            }
            
            if ((Get-WebAppPoolState -Name $appPoolName).Value -eq "Started") {
                Write-DeploymentLog "Application pool started successfully"
            } else {
                throw "Application pool did not start within $maxWaitSeconds seconds"
            }
        }
        
    } catch {
        Write-DeploymentLog "Failed to start application pool: ${_}" "ERROR"
        throw "Application pool start failed: ${_}"
    }
    
    # ============================================================================
    # STEP 4: Start Website with Retry Logic
    # ============================================================================
    
    Write-DeploymentLog "Starting website: $siteName"
    
    $maxAttempts = 3
    $retryDelaySeconds = 10
    $websiteStarted = $false
    
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Write-DeploymentLog "Website start attempt $attempt of $maxAttempts"
            
            $website = Get-Website -Name $siteName
            
            if ($website.State -eq "Started") {
                Write-DeploymentLog "Website is already started"
                $websiteStarted = $true
                break
            } else {
                Write-DeploymentLog "Website state: $($website.State), starting..."
                Start-Website -Name $siteName -ErrorAction Stop
                
                # Wait for website to start (max 10 seconds per attempt)
                $maxWaitSeconds = 10
                $waitSeconds = 0
                while ((Get-Website -Name $siteName).State -ne "Started" -and $waitSeconds -lt $maxWaitSeconds) {
                    Start-Sleep -Seconds 1
                    $waitSeconds += 1
                }
                
                $website = Get-Website -Name $siteName
                if ($website.State -eq "Started") {
                    Write-DeploymentLog "Website started successfully on attempt $attempt"
                    $websiteStarted = $true
                    break
                } else {
                    throw "Website state is $($website.State) after start command"
                }
            }
            
        } catch {
            Write-DeploymentLog "Website start attempt $attempt failed: ${_}" "WARN"
            
            if ($attempt -lt $maxAttempts) {
                Write-DeploymentLog "Retrying in $retryDelaySeconds seconds..." "WARN"
                Start-Sleep -Seconds $retryDelaySeconds
            } else {
                Write-DeploymentLog "All website start attempts failed" "ERROR"
                throw "Failed to start website after $maxAttempts attempts: ${_}"
            }
        }
    }
    
    if (-not $websiteStarted) {
        throw "Website failed to start after $maxAttempts attempts"
    }
    
    # ============================================================================
    # STEP 5: Verify Configuration
    # ============================================================================
    
    Write-DeploymentLog "Verifying IIS configuration"
    
    try {
        # Verify application pool is running
        $appPoolState = (Get-WebAppPoolState -Name $appPoolName).Value
        Write-DeploymentLog "Application pool state: $appPoolState"
        
        if ($appPoolState -ne "Started") {
            throw "Application pool is not in Started state: $appPoolState"
        }
        
        # Verify website is running
        $websiteState = (Get-Website -Name $siteName).State
        Write-DeploymentLog "Website state: $websiteState"
        
        if ($websiteState -ne "Started") {
            throw "Website is not in Started state: $websiteState"
        }
        
        # Verify website binding
        $binding = Get-WebBinding -Name $siteName -Port $port
        if ($null -ne $binding) {
            Write-DeploymentLog "Website binding verified: port $port"
        } else {
            Write-DeploymentLog "Website binding not found for port $port" "WARN"
        }
        
        Write-DeploymentLog "IIS configuration verification passed"
        
    } catch {
        Write-DeploymentLog "IIS configuration verification failed: ${_}" "ERROR"
        throw "Configuration verification failed: ${_}"
    }
    
    Write-DeploymentLog "ApplicationStart lifecycle hook completed successfully"
    Write-DeploymentLog "IIS is running and ready to serve requests"
    exit 0
    
} catch {
    Write-DeploymentLog "Fatal error in ApplicationStart hook: ${_}" "ERROR"
    Write-DeploymentLog "Stack trace: $(${_}.ScriptStackTrace)" "ERROR"
    
    # Exit with error code to fail deployment
    # Application start failures should trigger rollback
    exit 1
}
