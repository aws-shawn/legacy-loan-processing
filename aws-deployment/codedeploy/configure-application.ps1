# configure-application.ps1
# CodeDeploy AfterInstall lifecycle hook
# Configures database connection and initializes database schema if needed

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

Import-Module SqlServer
Import-Module AWS.Tools.Common
Import-Module AWS.Tools.SecretsManager
Import-Module AWS.Tools.SimpleSystemsManagement

try {
    Write-DeploymentLog "Starting AfterInstall lifecycle hook - Configure Application"
    
    # ============================================================================
    # STEP 0: Load Deployment Config
    # ============================================================================
    
    $configPath = "C:\Deploy\config.json"
    if (Test-Path $configPath) {
        $deployConfig = Get-Content $configPath -Raw | ConvertFrom-Json
        $awsRegion = $deployConfig.Region
        $secretArn = $deployConfig.DbSecretArn
        Write-DeploymentLog "Loaded deployment config: region=$awsRegion, environment=$($deployConfig.Environment)"
    } else {
        Write-DeploymentLog "No deployment config found at $configPath, using defaults" "WARN"
        $awsRegion = "us-east-2"
        $secretArn = $null
        $deployConfig = @{ Environment = "workshop" }
    }
    
    Set-DefaultAWSRegion -Region $awsRegion
    
    # ============================================================================
    # STEP 1: Retrieve Database Credentials from AWS Secrets Manager
    # ============================================================================
    
    Write-DeploymentLog "Retrieving database credentials from AWS Secrets Manager"
    
    if ([string]::IsNullOrEmpty($secretArn) -or $secretArn -like "*error*") {
        Write-DeploymentLog "Secret ARN not in config, trying SSM Parameter Store" "WARN"
        try {
            $ssmParam = Get-SSMParameterValue -Name "/loan-processing/$($deployConfig.Environment)/db-secret-arn" -Region $awsRegion
            $secretArn = $ssmParam.Parameters[0].Value
        } catch {
            throw "Cannot retrieve DB secret ARN: ${_}"
        }
    }
    
    Write-DeploymentLog "Using secret ARN: $secretArn"
    
    # Retrieve secret from Secrets Manager
    try {
        $secretResult = Get-SECSecretValue -SecretId $secretArn -Region $awsRegion
        $secretJson = $secretResult.SecretString
        
        Write-DeploymentLog "Successfully retrieved secret from Secrets Manager"
        
    } catch {
        Write-DeploymentLog "Failed to retrieve secret from Secrets Manager: ${_}" "ERROR"
        throw "Secrets Manager retrieval failed - deployment cannot continue: ${_}"
    }
    
    # Parse secret JSON
    try {
        $secret = $secretJson | ConvertFrom-Json
        
        $dbHost = $secret.host
        $dbUsername = $secret.username
        $dbPassword = $secret.password
        $dbName = $secret.dbname
        
        if ([string]::IsNullOrEmpty($dbHost) -or 
            [string]::IsNullOrEmpty($dbUsername) -or 
            [string]::IsNullOrEmpty($dbPassword) -or 
            [string]::IsNullOrEmpty($dbName)) {
            throw "Secret JSON is missing required fields (host, username, password, dbname)"
        }
        
        Write-DeploymentLog "Successfully parsed database credentials (host: $dbHost, database: $dbName, username: $dbUsername)"
        
    } catch {
        Write-DeploymentLog "Failed to parse secret JSON: ${_}" "ERROR"
        throw "Invalid secret format - deployment cannot continue: ${_}"
    }
    
    # ============================================================================
    # STEP 2: Build SQL Server Connection String
    # ============================================================================
    
    Write-DeploymentLog "Building SQL Server connection string"
    
    # Build connection string with security settings
    $connectionString = "Server=$dbHost;Database=$dbName;User Id=$dbUsername;Password=$dbPassword;Encrypt=True;TrustServerCertificate=True;"
    
    Write-SafeLog "Connection string built: Server=$dbHost;Database=$dbName;User Id=$dbUsername;Password=***;Encrypt=True;TrustServerCertificate=True;"
    
    # ============================================================================
    # STEP 3: Update Web.config with Connection String
    # ============================================================================
    
    Write-DeploymentLog "Updating Web.config with database connection string"
    
    $webConfigPath = "C:\inetpub\wwwroot\LoanProcessing\Web.config"
    
    if (-not (Test-Path $webConfigPath)) {
        Write-DeploymentLog "Web.config not found at $webConfigPath" "ERROR"
        throw "Web.config not found - deployment cannot continue"
    }
    
    try {
        # Load Web.config as XML
        [xml]$webConfig = Get-Content $webConfigPath
        
        Write-DeploymentLog "Loaded Web.config successfully"
        
        # Ensure connectionStrings section exists
        if ($null -eq $webConfig.configuration.connectionStrings) {
            Write-DeploymentLog "Creating connectionStrings section in Web.config"
            $connectionStringsNode = $webConfig.CreateElement("connectionStrings")
            $webConfig.configuration.AppendChild($connectionStringsNode) | Out-Null
        }
        
        # Find or create LoanProcessingConnection
        $connectionNode = $webConfig.configuration.connectionStrings.add | 
            Where-Object { $_.name -eq "LoanProcessingConnection" }
        
        if ($null -eq $connectionNode) {
            Write-DeploymentLog "Creating new LoanProcessingConnection in Web.config"
            $connectionNode = $webConfig.CreateElement("add")
            $connectionNode.SetAttribute("name", "LoanProcessingConnection")
            $connectionNode.SetAttribute("providerName", "System.Data.SqlClient")
            $webConfig.configuration.connectionStrings.AppendChild($connectionNode) | Out-Null
        } else {
            Write-DeploymentLog "Updating existing LoanProcessingConnection in Web.config"
        }
        
        # Update connection string
        $connectionNode.SetAttribute("connectionString", $connectionString)
        
        # Save Web.config (preserve other settings)
        $webConfig.Save($webConfigPath)
        
        Write-DeploymentLog "Web.config updated successfully with database connection string"
        
    } catch {
        Write-DeploymentLog "Failed to update Web.config: ${_}" "ERROR"
        throw "Web.config update failed - deployment cannot continue: ${_}"
    }
    
    # ============================================================================
    # STEP 4: Check if Database Exists
    # ============================================================================
    
    Write-DeploymentLog "Checking if database '$dbName' exists"
    
    $checkDbQuery = "SELECT COUNT(*) FROM sys.databases WHERE name = '$dbName'"
    
    try {
        # Use Invoke-Sqlcmd to check database existence
        $dbExistsResult = Invoke-Sqlcmd -ServerInstance $dbHost -Username $dbUsername -Password $dbPassword -Query $checkDbQuery -TrustServerCertificate
        
        $dbExists = [int]$dbExistsResult[0]
        
        Write-DeploymentLog "Database existence check result: $dbExists (0=does not exist, 1=exists)"
        
    } catch {
        Write-DeploymentLog "Failed to check database existence: ${_}" "ERROR"
        Write-DeploymentLog "Database connectivity check failed - this may indicate network or credential issues" "WARN"
        Write-DeploymentLog "Deployment will continue, but database initialization may be skipped" "WARN"
        
        # Set dbExists to 1 to skip initialization on connectivity failure
        $dbExists = 1
    }
    
    # ============================================================================
    # STEP 5: Initialize Database if Needed
    # ============================================================================
    
    if ($dbExists -eq 0) {
        Write-DeploymentLog "Database does not exist - proceeding with initialization"
        
        $databaseScriptsPath = "C:\Deploy\database"
        $createDatabaseScript = Join-Path $databaseScriptsPath "CreateDatabase.sql"
        $storedProcsScript = Join-Path $databaseScriptsPath "CreateStoredProcedures_Task3.sql"
        $searchAutocompleteScript = Join-Path $databaseScriptsPath "CreateSearchCustomersAutocomplete.sql"
        $initializeSampleDataScript = Join-Path $databaseScriptsPath "InitializeSampleData.sql"
        
        # Verify scripts exist
        if (-not (Test-Path $createDatabaseScript)) {
            Write-DeploymentLog "CreateDatabase.sql not found at $createDatabaseScript" "WARN"
            Write-DeploymentLog "Database initialization will be skipped" "WARN"
        } elseif (-not (Test-Path $initializeSampleDataScript)) {
            Write-DeploymentLog "InitializeSampleData.sql not found at $initializeSampleDataScript" "WARN"
            Write-DeploymentLog "Sample data initialization will be skipped" "WARN"
        } else {
            # Database initialization with error tolerance
            try {
                # Create database
                Write-DeploymentLog "Creating database '$dbName'"
                $createDbQuery = "CREATE DATABASE [$dbName]"
                Invoke-Sqlcmd -ServerInstance $dbHost -Username $dbUsername -Password $dbPassword -Query $createDbQuery -TrustServerCertificate
                
                Write-DeploymentLog "Database '$dbName' created successfully"
                
                # Wait for database to be ready
                Start-Sleep -Seconds 5
                
                # Run CreateDatabase.sql to create schema
                Write-DeploymentLog "Running CreateDatabase.sql to create tables and stored procedures"
                Invoke-Sqlcmd -ServerInstance $dbHost -Username $dbUsername -Password $dbPassword -Database $dbName -InputFile $createDatabaseScript -TrustServerCertificate
                
                Write-DeploymentLog "Database schema created successfully"
                
                # Run CreateStoredProcedures_Task3.sql to create stored procedures
                Write-DeploymentLog "Running CreateStoredProcedures_Task3.sql to create stored procedures"
                Invoke-Sqlcmd -ServerInstance $dbHost -Username $dbUsername -Password $dbPassword -Database $dbName -InputFile $storedProcsScript -TrustServerCertificate
                
                Write-DeploymentLog "Stored procedures created successfully"
                
                # Run CreateSearchCustomersAutocomplete.sql to create autocomplete procedure
                Write-DeploymentLog "Running CreateSearchCustomersAutocomplete.sql to create autocomplete procedure"
                Invoke-Sqlcmd -ServerInstance $dbHost -Username $dbUsername -Password $dbPassword -Database $dbName -InputFile $searchAutocompleteScript -TrustServerCertificate
                
                Write-DeploymentLog "Autocomplete procedure created successfully"
                
                # Run InitializeSampleData.sql to load sample data
                Write-DeploymentLog "Running InitializeSampleData.sql to load sample data"
                Invoke-Sqlcmd -ServerInstance $dbHost -Username $dbUsername -Password $dbPassword -Database $dbName -InputFile $initializeSampleDataScript -TrustServerCertificate
                
                Write-DeploymentLog "Sample data loaded successfully"
                
                # Verify stored procedures exist
                Write-DeploymentLog "Verifying stored procedures..."
                $verifyProcsQuery = "SELECT name FROM sys.objects WHERE type = 'P' AND name IN ('sp_SearchCustomers', 'sp_GetCustomerById', 'sp_UpdateCustomer', 'sp_CreateCustomer', 'sp_SearchCustomersAutocomplete') ORDER BY name"
                $procs = Invoke-Sqlcmd -ServerInstance $dbHost -Username $dbUsername -Password $dbPassword -Database $dbName -Query $verifyProcsQuery -TrustServerCertificate
                $procCount = ($procs | Measure-Object).Count
                Write-DeploymentLog "Verified $procCount/5 stored procedures exist"
                if ($procCount -lt 5) {
                    Write-DeploymentLog "WARNING: Not all stored procedures were created" "WARN"
                }
                
                Write-DeploymentLog "Database initialization completed successfully"
                
            } catch {
                Write-DeploymentLog "Database initialization failed: ${_}" "WARN"
                Write-DeploymentLog "Deployment will continue despite database initialization failure" "WARN"
                Write-DeploymentLog "Manual database setup may be required" "WARN"
                
                # Log error but don't fail deployment (per requirements 7.5)
                # This allows the application to deploy even if database initialization fails
            }
        }
        
    } else {
        Write-DeploymentLog "Database '$dbName' already exists - re-applying stored procedures"
        
        $databaseScriptsPath = "C:\Deploy\database"
        $storedProcsScript = Join-Path $databaseScriptsPath "CreateStoredProcedures_Task3.sql"
        $searchAutocompleteScript = Join-Path $databaseScriptsPath "CreateSearchCustomersAutocomplete.sql"
        
        try {
            # Re-run stored procedure scripts (they use IF OBJECT_ID/DROP/CREATE - inherently idempotent)
            Write-DeploymentLog "Running CreateStoredProcedures_Task3.sql to update stored procedures"
            Invoke-Sqlcmd -ServerInstance $dbHost -Username $dbUsername -Password $dbPassword -Database $dbName -InputFile $storedProcsScript -TrustServerCertificate
            
            Write-DeploymentLog "Stored procedures updated successfully"
            
            Write-DeploymentLog "Running CreateSearchCustomersAutocomplete.sql to update autocomplete procedure"
            Invoke-Sqlcmd -ServerInstance $dbHost -Username $dbUsername -Password $dbPassword -Database $dbName -InputFile $searchAutocompleteScript -TrustServerCertificate
            
            Write-DeploymentLog "Autocomplete procedure updated successfully"
            
            # Verify stored procedures exist
            Write-DeploymentLog "Verifying stored procedures..."
            $verifyProcsQuery = "SELECT name FROM sys.objects WHERE type = 'P' AND name IN ('sp_SearchCustomers', 'sp_GetCustomerById', 'sp_UpdateCustomer', 'sp_CreateCustomer', 'sp_SearchCustomersAutocomplete') ORDER BY name"
            $procs = Invoke-Sqlcmd -ServerInstance $dbHost -Username $dbUsername -Password $dbPassword -Database $dbName -Query $verifyProcsQuery -TrustServerCertificate
            $procCount = ($procs | Measure-Object).Count
            Write-DeploymentLog "Verified $procCount/5 stored procedures exist"
            if ($procCount -lt 5) {
                Write-DeploymentLog "WARNING: Not all stored procedures were created" "WARN"
            }
            
        } catch {
            Write-DeploymentLog "Stored procedure update failed: ${_}" "WARN"
            Write-DeploymentLog "Deployment will continue despite stored procedure update failure" "WARN"
        }
    }
    
    # ============================================================================
    # STEP 6: Verify Configuration
    # ============================================================================
    
    Write-DeploymentLog "Verifying configuration"
    
    # Verify Web.config was updated correctly
    try {
        [xml]$verifyConfig = Get-Content $webConfigPath
        $verifyConnection = $verifyConfig.configuration.connectionStrings.add | 
            Where-Object { $_.name -eq "LoanProcessingConnection" }
        
        if ($null -ne $verifyConnection -and -not [string]::IsNullOrEmpty($verifyConnection.connectionString)) {
            Write-DeploymentLog "Web.config verification passed - connection string is configured"
        } else {
            Write-DeploymentLog "Web.config verification failed - connection string not found" "WARN"
        }
    } catch {
        Write-DeploymentLog "Web.config verification failed: ${_}" "WARN"
    }
    
    Write-DeploymentLog "AfterInstall lifecycle hook completed successfully"
    exit 0
    
} catch {
    Write-DeploymentLog "Fatal error in AfterInstall hook: ${_}" "ERROR"
    Write-DeploymentLog "Stack trace: $(${_}.ScriptStackTrace)" "ERROR"
    
    # Exit with error code to fail deployment
    # Configuration failures should prevent deployment from continuing
    exit 1
}
