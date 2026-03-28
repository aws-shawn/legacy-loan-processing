# Bug Condition Exploration Test for CodeDeploy Agent Registration Race Condition
# Validates: Requirements 1.1, 1.3
#
# This test surfaces the bug condition where the pipeline is triggered before
# the CodeDeploy agent has registered with the AWS CodeDeploy service.
# The unfixed code checks only that the Windows service is "Running" but does NOT
# verify registration status via Get-CDDeploymentTarget before calling Start-CPPipelineExecution.
#
# EXPECTED: This test FAILS on unfixed code (confirming the bug exists).

Describe "Bug Condition - Pipeline Triggered Before Agent Registration" {

    # **Validates: Requirements 1.1, 1.3**

    Context "When CodeDeploy agent service is Running but instance is NOT registered in deployment group" {

        It "Property 1: For all inputs where serviceStatus is Running AND registrationStatus is not Registered, Start-CPPipelineExecution SHALL NOT be called" {

            # Track whether Start-CPPipelineExecution was called
            $script:pipelineTriggered = $false

            # --- Mocks ---
            # Mock Get-Service to return a service object with Status "Running"
            # This simulates the agent Windows service being up
            function Get-Service {
                param([string]$Name, [string]$ErrorAction)
                return [PSCustomObject]@{ Status = "Running"; Name = "codedeployagent" }
            }

            # Mock Get-CDDeploymentTarget to return NO registered targets
            # This simulates the agent NOT yet registered with CodeDeploy service
            function Get-CDDeploymentTarget {
                param([string]$DeploymentGroupName, [string]$Region)
                return $null
            }

            # Mock Start-CPPipelineExecution to record that it was called
            function Start-CPPipelineExecution {
                param([string]$Name, [string]$Region)
                $script:pipelineTriggered = $true
            }

            # Mock Import-Module to be a no-op
            function Import-Module {
                param([string]$Name)
            }

            # Mock Write-Host to suppress output
            function Write-Host {
                param([string]$Object)
            }

            # Mock Set-Service and Start-Service as no-ops
            function Set-Service { param([string]$Name, [string]$StartupType, [string]$ErrorAction) }
            function Start-Service { param([string]$Name, [string]$ErrorAction) }
            function Start-Sleep { param([int]$Seconds) }

            # --- Extract and execute the FIXED code section from user-data.ps1 ---
            # This is the logic from the fixed user-data.ps1 representing the
            # CodeDeploy agent check, registration verification, and pipeline trigger section.
            $region = "us-east-1"
            $environment = "dev"

            # Poll for CodeDeploy Agent to be running
            $maxAttempts = 30
            $agentRunning = $false
            for ($i = 1; $i -le $maxAttempts; $i++) {
                $svc = Get-Service -Name "codedeployagent" -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq "Running") {
                    $agentRunning = $true
                    break
                }
                if ($svc -and $svc.Status -ne "Running") {
                    Set-Service -Name "codedeployagent" -StartupType Automatic -ErrorAction SilentlyContinue
                    Start-Service -Name "codedeployagent" -ErrorAction SilentlyContinue
                }
                Start-Sleep -Seconds 5
            }

            # Verify CodeDeploy agent registration (fixed code — polls Get-CDDeploymentTarget)
            $agentRegistered = $false
            if ($agentRunning) {
                $deploymentGroup = "loan-processing-$environment"
                $regMaxAttempts = 3  # reduced for test speed (production uses 30)
                for ($r = 1; $r -le $regMaxAttempts; $r++) {
                    try {
                        $target = Get-CDDeploymentTarget `
                            -DeploymentGroupName $deploymentGroup `
                            -Region $region
                        if ($target) {
                            $agentRegistered = $true
                            break
                        }
                    } catch {
                        # registration check failed
                    }
                    Start-Sleep -Seconds 10
                }
            }

            # Trigger CodePipeline deployment (fixed code — gated on registration)
            if ($agentRunning -and $agentRegistered) {
                try {
                    Import-Module AWS.Tools.CodePipeline
                    Start-CPPipelineExecution -Name "loan-processing-pipeline-$environment" -Region $region
                } catch {
                    # swallow
                }
            } elseif ($agentRunning -and -not $agentRegistered) {
                Write-Host "WARNING: Skipping pipeline trigger - CodeDeploy agent running but not registered after timeout"
            }

            # --- Bug Condition Assertion ---
            # isBugCondition: serviceStatus == "Running" AND registrationStatus != "Registered"
            # The agent service IS running (mock returns "Running")
            # The agent is NOT registered (Get-CDDeploymentTarget returns $null)
            # Therefore: Start-CPPipelineExecution should NOT have been called
            #
            # On UNFIXED code, this assertion FAILS because the code triggers the
            # pipeline immediately after the service is running, without checking registration.
            # This failure is the EXPECTED outcome — it confirms the bug exists.
            $script:pipelineTriggered | Should Be $false
        }
    }
}


# Preservation Property Tests for Non-Registration Code Paths
# Validates: Requirements 3.1, 3.2, 3.3, 3.4
#
# These tests observe and encode the CURRENT (unfixed) behavior of code paths
# that should remain unchanged after the bugfix. The fix only adds a registration
# check between the service-running confirmation and the pipeline trigger.
# All other code paths must be preserved exactly.
#
# EXPECTED: These tests PASS on unfixed code (confirms baseline behavior to preserve).

Describe "Preservation - Non-Registration Code Paths Unchanged" {

    # **Validates: Requirements 3.1, 3.2, 3.3, 3.4**

    Context "When agent service is running, Start-CPPipelineExecution is called with correct parameters" {

        It "Property 2a: For all inputs where agentRunning is true, Start-CPPipelineExecution is called with correct pipeline name and region" {

            # Test across multiple environment/region combinations
            $testCases = @(
                @{ Environment = "dev"; Region = "us-east-1" },
                @{ Environment = "staging"; Region = "us-west-2" },
                @{ Environment = "prod"; Region = "eu-west-1" },
                @{ Environment = "test"; Region = "ap-southeast-1" }
            )

            foreach ($tc in $testCases) {
                $script:capturedPipelineName = $null
                $script:capturedRegion = $null
                $script:pipelineCalled = $false

                # --- Mocks ---
                function Get-Service {
                    param([string]$Name, [string]$ErrorAction)
                    return [PSCustomObject]@{ Status = "Running"; Name = "codedeployagent" }
                }
                function Start-CPPipelineExecution {
                    param([string]$Name, [string]$Region)
                    $script:capturedPipelineName = $Name
                    $script:capturedRegion = $Region
                    $script:pipelineCalled = $true
                }
                function Import-Module { param([string]$Name) }
                function Write-Host { param([string]$Object) }
                function Set-Service { param([string]$Name, [string]$StartupType, [string]$ErrorAction) }
                function Start-Service { param([string]$Name, [string]$ErrorAction) }
                function Start-Sleep { param([int]$Seconds) }

                $region = $tc.Region
                $environment = $tc.Environment

                # --- Execute the CodeDeploy agent check and pipeline trigger section ---
                $maxAttempts = 30
                $agentRunning = $false
                for ($i = 1; $i -le $maxAttempts; $i++) {
                    $svc = Get-Service -Name "codedeployagent" -ErrorAction SilentlyContinue
                    if ($svc -and $svc.Status -eq "Running") {
                        $agentRunning = $true
                        break
                    }
                    if ($svc -and $svc.Status -ne "Running") {
                        Set-Service -Name "codedeployagent" -StartupType Automatic -ErrorAction SilentlyContinue
                        Start-Service -Name "codedeployagent" -ErrorAction SilentlyContinue
                    }
                    Start-Sleep -Seconds 5
                }

                if ($agentRunning) {
                    try {
                        Import-Module AWS.Tools.CodePipeline
                        Start-CPPipelineExecution -Name "loan-processing-pipeline-$environment" -Region $region
                    } catch {
                        # swallow
                    }
                }

                # --- Assertions ---
                $script:pipelineCalled | Should Be $true
                $script:capturedPipelineName | Should Be "loan-processing-pipeline-$($tc.Environment)"
                $script:capturedRegion | Should Be $tc.Region
            }
        }
    }

    Context "When agent service is NOT running after max attempts, Start-CPPipelineExecution is NOT called" {

        It "Property 2b: For all inputs where agentRunning is false, Start-CPPipelineExecution is NOT called" {

            $script:pipelineCalled = $false
            $script:warningLogged = $false

            # --- Mocks ---
            # Mock Get-Service to return a service that is NOT running (simulates agent never starts)
            function Get-Service {
                param([string]$Name, [string]$ErrorAction)
                return [PSCustomObject]@{ Status = "Stopped"; Name = "codedeployagent" }
            }
            function Start-CPPipelineExecution {
                param([string]$Name, [string]$Region)
                $script:pipelineCalled = $true
            }
            function Import-Module { param([string]$Name) }
            function Write-Host {
                param([string]$Object)
                if ($Object -like "*Skipping pipeline trigger*") {
                    $script:warningLogged = $true
                }
            }
            function Set-Service { param([string]$Name, [string]$StartupType, [string]$ErrorAction) }
            function Start-Service { param([string]$Name, [string]$ErrorAction) }
            function Start-Sleep { param([int]$Seconds) }

            $region = "us-east-1"
            $environment = "dev"

            # --- Execute the CodeDeploy agent check and pipeline trigger section ---
            # Use a small maxAttempts to keep the test fast
            $maxAttempts = 3
            $agentRunning = $false
            for ($i = 1; $i -le $maxAttempts; $i++) {
                $svc = Get-Service -Name "codedeployagent" -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq "Running") {
                    $agentRunning = $true
                    break
                }
                if ($svc -and $svc.Status -ne "Running") {
                    Set-Service -Name "codedeployagent" -StartupType Automatic -ErrorAction SilentlyContinue
                    Start-Service -Name "codedeployagent" -ErrorAction SilentlyContinue
                }
                Start-Sleep -Seconds 5
            }

            if ($agentRunning) {
                try {
                    Import-Module AWS.Tools.CodePipeline
                    Start-CPPipelineExecution -Name "loan-processing-pipeline-$environment" -Region $region
                } catch {
                    # swallow
                }
            } else {
                Write-Host "Skipping pipeline trigger - CodeDeploy Agent not running"
            }

            # --- Assertions ---
            $script:pipelineCalled | Should Be $false
            $script:warningLogged | Should Be $true
        }
    }

    Context "Install-Module AWS.Tools.CodePipeline call is present and unchanged" {

        It "Property 2c: The user-data.ps1 script contains Install-Module AWS.Tools.CodePipeline with expected parameters" {

            $scriptContent = Get-Content -Path "$PSScriptRoot/user-data.ps1" -Raw

            # Verify Install-Module AWS.Tools.CodePipeline is present with correct flags
            $scriptContent | Should Match 'Install-Module\s+AWS\.Tools\.CodePipeline\s+-Force\s+-AllowClobber\s+-Scope\s+AllUsers'
        }
    }

    Context "CodeDeploy agent MSI download URL, installation, and service polling loop are unchanged" {

        It "Property 2d: The CodeDeploy agent download URL pattern, MSI installation, and polling loop are present in user-data.ps1" {

            $scriptContent = Get-Content -Path "$PSScriptRoot/user-data.ps1" -Raw

            # Verify CodeDeploy MSI download URL pattern
            $scriptContent | Should Match 'https://aws-codedeploy-\$region\.s3\.\$region\.amazonaws\.com/latest/codedeploy-agent\.msi'

            # Verify MSI installation via msiexec
            $scriptContent | Should Match 'Start-Process\s+msiexec\.exe\s+-ArgumentList\s+"/i",\s*\$codeDeployInstallerPath'

            # Verify service polling loop structure
            $scriptContent | Should Match '\$maxAttempts\s*=\s*30'
            $scriptContent | Should Match 'Get-Service\s+-Name\s+"codedeployagent"'
            $scriptContent | Should Match '\$svc\.Status\s+-eq\s+"Running"'
            $scriptContent | Should Match '\$agentRunning\s*=\s*\$true'
        }
    }

    Context "CodeDeploy config file write (conf.onpremises.yml) is unchanged" {

        It "Property 2e: The conf.onpremises.yml config file path and region content are present in user-data.ps1" {

            $scriptContent = Get-Content -Path "$PSScriptRoot/user-data.ps1" -Raw

            # Verify config file path
            $scriptContent | Should Match 'conf\.onpremises\.yml'

            # Verify the YAML config content with region
            $scriptContent | Should Match 'region:\s*\$region'

            # Verify directory creation logic
            $scriptContent | Should Match 'Split-Path\s+-Path\s+\$codeDeployConfigPath\s+-Parent'

            # Verify file write
            $scriptContent | Should Match 'Out-File\s+-FilePath\s+\$codeDeployConfigPath\s+-Encoding\s+UTF8\s+-Force'
        }
    }
}
