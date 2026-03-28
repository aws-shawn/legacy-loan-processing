<powershell>
# EC2 User Data Script for Legacy .NET Loan Processing Application
# This script runs on first boot to configure the Windows Server instance

# Set error handling
$ErrorActionPreference = "Stop"

# Log file
$logFile = "C:\ProgramData\Amazon\EC2-Windows\Launch\Log\UserDataExecution.log"
Start-Transcript -Path $logFile -Append

Write-Host "========================================" 
Write-Host "Starting User Data Execution"
Write-Host "Time: $(Get-Date)"
Write-Host "========================================"

try {
    # Install IIS and required features
    Write-Host "Installing IIS and .NET Framework features..."
    Install-WindowsFeature -Name Web-Server -IncludeManagementTools
    Install-WindowsFeature -Name Web-Asp-Net45
    Install-WindowsFeature -Name Web-Net-Ext45
    Install-WindowsFeature -Name Web-ISAPI-Ext
    Install-WindowsFeature -Name Web-ISAPI-Filter
    Install-WindowsFeature -Name Web-Mgmt-Console
    Install-WindowsFeature -Name Web-Scripting-Tools
    
    Write-Host "IIS installation completed successfully"

    # Install .NET Framework 4.7.2 (if not already installed)
    Write-Host "Checking .NET Framework version..."
    $netVersion = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue
    if ($netVersion.Release -lt 461808) {
        Write-Host "Installing .NET Framework 4.7.2..."
        $netInstallerUrl = "https://download.microsoft.com/download/6/E/4/6E48E8AB-DC00-419E-9704-06DD46E5F81D/NDP472-KB4054530-x86-x64-AllOS-ENU.exe"
        $netInstallerPath = "C:\Windows\Temp\NDP472-KB4054530-x86-x64-AllOS-ENU.exe"
        Invoke-WebRequest -Uri $netInstallerUrl -OutFile $netInstallerPath
        Start-Process -FilePath $netInstallerPath -ArgumentList "/q", "/norestart" -Wait
        Write-Host ".NET Framework 4.7.2 installed"
    } else {
        Write-Host ".NET Framework 4.7.2 or higher already installed"
    }

    # Install NuGet provider (required for Install-Module in non-interactive sessions)
    Write-Host "Installing NuGet provider..."
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    Write-Host "NuGet provider installed"

    # Install SqlServer PowerShell module for database operations
    Write-Host "Installing SqlServer PowerShell module..."
    Install-Module SqlServer -Force -AllowClobber -Scope AllUsers
    Write-Host "SqlServer module installed"

    # Install AWS PowerShell modules for Secrets Manager and SSM Parameter Store
    Write-Host "Installing AWS PowerShell modules..."
    Install-Module AWS.Tools.Common -Force -AllowClobber -Scope AllUsers
    Install-Module AWS.Tools.SecretsManager -Force -AllowClobber -Scope AllUsers
    Install-Module AWS.Tools.SimpleSystemsManagement -Force -AllowClobber -Scope AllUsers
    Write-Host "AWS PowerShell modules installed"

    # Install CloudWatch Agent
    Write-Host "Installing CloudWatch Agent..."
    $cwAgentUrl = "https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi"
    $cwAgentPath = "C:\Windows\Temp\amazon-cloudwatch-agent.msi"
    Invoke-WebRequest -Uri $cwAgentUrl -OutFile $cwAgentPath
    Start-Process msiexec.exe -ArgumentList "/i", $cwAgentPath, "/qn" -Wait
    Write-Host "CloudWatch Agent installed"

    # Configure CloudWatch Agent
    Write-Host "Configuring CloudWatch Agent..."
    $cwConfig = @{
        logs = @{
            logs_collected = @{
                files = @{
                    collect_list = @(
                        @{
                            file_path = "C:\\inetpub\\logs\\LogFiles\\W3SVC1\\*.log"
                            log_group_name = "/aws/ec2/${project_name}"
                            log_stream_name = "{instance_id}/iis"
                            timezone = "UTC"
                        },
                        @{
                            file_path = "C:\\Windows\\System32\\LogFiles\\HTTPERR\\*.log"
                            log_group_name = "/aws/ec2/${project_name}"
                            log_stream_name = "{instance_id}/httperr"
                            timezone = "UTC"
                        }
                    )
                }
                windows_events = @{
                    collect_list = @(
                        @{
                            event_name = "Application"
                            event_levels = @("ERROR", "WARNING", "INFORMATION")
                            log_group_name = "/aws/ec2/${project_name}"
                            log_stream_name = "{instance_id}/application"
                            event_format = "xml"
                        },
                        @{
                            event_name = "System"
                            event_levels = @("ERROR", "WARNING")
                            log_group_name = "/aws/ec2/${project_name}"
                            log_stream_name = "{instance_id}/system"
                            event_format = "xml"
                        }
                    )
                }
            }
        }
        metrics = @{
            namespace = "${project_name}/${environment}"
            metrics_collected = @{
                cpu = @{
                    measurement = @(
                        @{
                            name = "cpu_usage_idle"
                            rename = "CPU_IDLE"
                            unit = "Percent"
                        }
                    )
                    metrics_collection_interval = 60
                    totalcpu = $false
                }
                disk = @{
                    measurement = @(
                        @{
                            name = "used_percent"
                            rename = "DISK_USED"
                            unit = "Percent"
                        }
                    )
                    metrics_collection_interval = 60
                    resources = @("*")
                }
                memory = @{
                    measurement = @(
                        @{
                            name = "mem_used_percent"
                            rename = "MEM_USED"
                            unit = "Percent"
                        }
                    )
                    metrics_collection_interval = 60
                }
            }
        }
    }
    
    $cwConfigPath = "C:\ProgramData\Amazon\AmazonCloudWatchAgent\config.json"
    $cwConfig | ConvertTo-Json -Depth 10 | Out-File -FilePath $cwConfigPath -Encoding UTF8
    
    # Start CloudWatch Agent (non-critical — don't block deployment if this fails)
    try {
        & "C:\Program Files\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent-ctl.ps1" `
            -a fetch-config `
            -m ec2 `
            -s `
            -c file:$cwConfigPath
        Write-Host "CloudWatch Agent configured and started"
    } catch {
        Write-Host "WARNING: CloudWatch Agent configuration failed: $_"
        Write-Host "Continuing with deployment setup..."
    }

    # Install CodeDeploy Agent
    Write-Host "Installing CodeDeploy Agent..."
    $region = "${aws_region}"
    $codeDeployInstallerUrl = "https://aws-codedeploy-$region.s3.$region.amazonaws.com/latest/codedeploy-agent.msi"
    $codeDeployInstallerPath = "C:\Windows\Temp\codedeploy-agent.msi"
    
    Write-Host "Downloading CodeDeploy Agent from $codeDeployInstallerUrl..."
    Invoke-WebRequest -Uri $codeDeployInstallerUrl -OutFile $codeDeployInstallerPath
    
    Write-Host "Installing CodeDeploy Agent..."
    Start-Process msiexec.exe -ArgumentList "/i", $codeDeployInstallerPath, "/qn", "/l*v", "C:\Windows\Temp\codedeploy-agent-install.log" -Wait
    
    # Wait for service to be created
    Start-Sleep -Seconds 10
    
    # Verify CodeDeploy Agent service exists and start it
    $codeDeployService = Get-Service -Name "codedeployagent" -ErrorAction SilentlyContinue
    if ($codeDeployService) {
        Write-Host "CodeDeploy Agent service found, starting..."
        Set-Service -Name "codedeployagent" -StartupType Automatic
        Start-Service -Name "codedeployagent"
        
        # Verify service is running
        $serviceStatus = (Get-Service -Name "codedeployagent").Status
        if ($serviceStatus -eq "Running") {
            Write-Host "CodeDeploy Agent installed and running successfully"
        } else {
            Write-Host "Warning: CodeDeploy Agent service is not running. Status: $serviceStatus"
        }
    } else {
        Write-Host "Warning: CodeDeploy Agent service not found after installation"
    }
    
    # Configure CodeDeploy Agent with region and environment
    Write-Host "Configuring CodeDeploy Agent..."
    $codeDeployConfigPath = "C:\ProgramData\Amazon\CodeDeploy\conf.onpremises.yml"
    $codeDeployConfig = @"
---
region: $region
"@
    
    # Create config directory if it doesn't exist
    $configDir = Split-Path -Path $codeDeployConfigPath -Parent
    if (!(Test-Path $configDir)) {
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
    }
    
    # Write configuration file
    $codeDeployConfig | Out-File -FilePath $codeDeployConfigPath -Encoding UTF8 -Force
    Write-Host "CodeDeploy Agent configured for region: $region, environment: ${environment}"

    # Install Git
    Write-Host "Installing Git..."
    $gitInstallerUrl = "https://github.com/git-for-windows/git/releases/download/v2.43.0.windows.1/Git-2.43.0-64-bit.exe"
    $gitInstallerPath = "C:\Windows\Temp\git-installer.exe"
    Invoke-WebRequest -Uri $gitInstallerUrl -OutFile $gitInstallerPath
    Start-Process -FilePath $gitInstallerPath -ArgumentList "/VERYSILENT", "/NORESTART", "/NOCANCEL", "/SP-", "/CLOSEAPPLICATIONS", "/RESTARTAPPLICATIONS", "/COMPONENTS=`"icons,ext\reg\shellhere,assoc,assoc_sh`"" -Wait
    
    # Add Git to PATH for this session
    $env:Path += ";C:\Program Files\Git\cmd"
    Write-Host "Git installed"

    # Clone repository
    Write-Host "Cloning application from GitHub..."
    $repoPath = "C:\Deploy\legacy-loan-processing"
    $appPath = "C:\inetpub\wwwroot\LoanProcessing"
    
    New-Item -Path "C:\Deploy" -ItemType Directory -Force
    Set-Location "C:\Deploy"
    
    & "C:\Program Files\Git\cmd\git.exe" clone https://github.com/aws-shawn/legacy-loan-processing.git
    Write-Host "Repository cloned"

    # Install NuGet CLI
    Write-Host "Installing NuGet..."
    $nugetUrl = "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe"
    $nugetPath = "C:\Windows\Temp\nuget.exe"
    Invoke-WebRequest -Uri $nugetUrl -OutFile $nugetPath
    Write-Host "NuGet installed"

    # Restore NuGet packages
    Write-Host "Restoring NuGet packages..."
    Set-Location "$repoPath\LoanProcessing"
    & $nugetPath restore packages.config -PackagesDirectory "$repoPath\packages"
    Write-Host "NuGet packages restored"

    # Copy application files to IIS directory
    Write-Host "Deploying application files..."
    New-Item -Path $appPath -ItemType Directory -Force
    
    # Copy web application files
    Copy-Item -Path "$repoPath\LoanProcessing\*" -Destination $appPath -Recurse -Force -Exclude @("*.cs", "*.csproj", "*.csproj.user", "obj", "Properties")
    
    # Copy bin directory with all assemblies
    Copy-Item -Path "$repoPath\LoanProcessing\bin" -Destination "$appPath\bin" -Recurse -Force
    
    Write-Host "Application files deployed"

    # Configure IIS Application Pool
    Write-Host "Configuring IIS Application Pool..."
    Import-Module WebAdministration
    
    # Create application pool
    $appPoolName = "LoanProcessingAppPool"
    if (!(Test-Path "IIS:\AppPools\$appPoolName")) {
        New-WebAppPool -Name $appPoolName
        Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name managedRuntimeVersion -Value "v4.0"
        Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name enable32BitAppOnWin64 -Value $false
        Set-ItemProperty "IIS:\AppPools\$appPoolName" -Name processModel.identityType -Value 2  # NetworkService
        Write-Host "Application pool created: $appPoolName"
    }
    
    # Remove default website
    if (Test-Path "IIS:\Sites\Default Web Site") {
        Remove-Website -Name "Default Web Site"
        Write-Host "Default website removed"
    }
    
    # Create website
    $siteName = "LoanProcessing"
    if (!(Test-Path "IIS:\Sites\$siteName")) {
        New-Website -Name $siteName `
            -PhysicalPath $appPath `
            -ApplicationPool $appPoolName `
            -Port 80
        Write-Host "Website created: $siteName"
    }
    
    # Start website
    Start-Website -Name $siteName
    Write-Host "Website started"

    # Configure Windows Firewall
    Write-Host "Configuring Windows Firewall..."
    New-NetFirewallRule -DisplayName "Allow HTTP" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow
    New-NetFirewallRule -DisplayName "Allow HTTPS" -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow
    Write-Host "Firewall rules configured"

    # Set timezone to UTC
    Write-Host "Setting timezone to UTC..."
    Set-TimeZone -Id "UTC"
    
    # Optimize Windows for web server
    Write-Host "Optimizing Windows settings..."
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "TcpTimedWaitDelay" -Value 30
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "MaxUserPort" -Value 65534
    
    # Note: Not restarting IIS to avoid health check failures during deployment
    Write-Host "IIS configuration complete (no restart needed)"
    
    Write-Host "========================================" 
    Write-Host "User Data Execution Completed Successfully"
    Write-Host "Time: $(Get-Date)"
    Write-Host "========================================"
    
} catch {
    Write-Host "========================================" 
    Write-Host "ERROR: User Data Execution Failed"
    Write-Host "Error: $_"
    Write-Host "Stack Trace: $($_.ScriptStackTrace)"
    Write-Host "========================================"
    throw
} finally {
    Stop-Transcript
}
</powershell>
