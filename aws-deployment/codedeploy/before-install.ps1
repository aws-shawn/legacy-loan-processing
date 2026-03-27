# before-install.ps1
# CodeDeploy BeforeInstall lifecycle hook
# Backs up current application files and Web.config before deployment

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
    Write-DeploymentLog "Starting BeforeInstall lifecycle hook"
    
    $appPath = "C:\inetpub\wwwroot\LoanProcessing"
    $backupRootPath = "C:\Deploy\backups"
    
    # Create backup directory with timestamp
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = Join-Path $backupRootPath $timestamp
    
    Write-DeploymentLog "Creating backup directory: $backupPath"
    try {
        New-Item -Path $backupPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Write-DeploymentLog "Backup directory created successfully"
    } catch {
        Write-DeploymentLog "Error creating backup directory: ${_}" "ERROR"
        throw "Failed to create backup directory: ${_}"
    }
    
    # Check if application directory exists
    if (Test-Path $appPath) {
        Write-DeploymentLog "Application directory exists at $appPath, proceeding with backup"
        
        # Backup Web.config separately (critical for rollback)
        $webConfigPath = Join-Path $appPath "Web.config"
        if (Test-Path $webConfigPath) {
            Write-DeploymentLog "Backing up Web.config"
            try {
                $webConfigBackupPath = Join-Path $backupPath "Web.config"
                Copy-Item -Path $webConfigPath -Destination $webConfigBackupPath -Force -ErrorAction Stop
                Write-DeploymentLog "Web.config backed up successfully to $webConfigBackupPath"
            } catch {
                Write-DeploymentLog "Error backing up Web.config: ${_}" "ERROR"
                throw "Failed to backup Web.config: ${_}"
            }
        } else {
            Write-DeploymentLog "Web.config not found at $webConfigPath, skipping Web.config backup" "WARN"
        }
        
        # Backup all application files
        Write-DeploymentLog "Backing up application files from $appPath"
        try {
            $appBackupPath = Join-Path $backupPath "app"
            New-Item -Path $appBackupPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
            
            # Copy all files and subdirectories
            Copy-Item -Path "$appPath\*" -Destination $appBackupPath -Recurse -Force -ErrorAction Stop
            
            # Count backed up files
            $fileCount = (Get-ChildItem -Path $appBackupPath -Recurse -File).Count
            Write-DeploymentLog "Application files backed up successfully ($fileCount files) to $appBackupPath"
            
        } catch {
            Write-DeploymentLog "Error backing up application files: ${_}" "ERROR"
            throw "Failed to backup application files: ${_}"
        }
        
    } else {
        Write-DeploymentLog "Application directory does not exist at $appPath, skipping backup (first-time deployment)" "WARN"
    }
    
    # Clean up old backups (keep last 5 backups)
    Write-DeploymentLog "Cleaning up old backups"
    try {
        if (Test-Path $backupRootPath) {
            $backups = Get-ChildItem -Path $backupRootPath -Directory | 
                       Sort-Object Name -Descending | 
                       Select-Object -Skip 5
            
            if ($backups) {
                foreach ($backup in $backups) {
                    Write-DeploymentLog "Removing old backup: $($backup.Name)"
                    Remove-Item -Path $backup.FullName -Recurse -Force -ErrorAction Stop
                }
                Write-DeploymentLog "Removed $($backups.Count) old backup(s)"
            } else {
                Write-DeploymentLog "No old backups to remove"
            }
        }
    } catch {
        Write-DeploymentLog "Error cleaning up old backups: ${_}" "WARN"
        # Don't fail deployment if cleanup fails
    }
    
    Write-DeploymentLog "BeforeInstall lifecycle hook completed successfully"
    exit 0
    
} catch {
    Write-DeploymentLog "Fatal error in BeforeInstall hook: ${_}" "ERROR"
    Write-DeploymentLog "Stack trace: $(${_}.ScriptStackTrace)" "ERROR"
    
    # Exit with error code to fail deployment
    # Backup failures should prevent deployment to enable rollback capability
    exit 1
}
