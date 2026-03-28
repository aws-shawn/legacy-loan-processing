# redeploy.ps1
# Tears down the EC2 instance and redeploys with updated user-data.ps1
# Run from the repo root: .\aws-deployment\redeploy.ps1

param(
    [switch]$SkipDestroy,
    [switch]$AutoApprove
)

$ErrorActionPreference = "Stop"
$tfDir = Join-Path $PSScriptRoot "terraform"

Write-Host "=== Deployment Automation Fixes - Redeploy ===" -ForegroundColor Cyan
Write-Host ""

# Step 0: Verify AWS credentials and terraform can reach AWS
Write-Host "[0/4] Verifying AWS credentials..." -ForegroundColor Yellow
try {
    # Read profile from terraform.tfvars if available
    $awsProfile = $null
    $tfvarsPath = Join-Path $tfDir "terraform.tfvars"
    if (Test-Path $tfvarsPath) {
        $match = Select-String -Path $tfvarsPath -Pattern 'aws_profile\s*=\s*"([^"]+)"'
        if ($match) { $awsProfile = $match.Matches[0].Groups[1].Value }
    }
    # Also honor AWS_PROFILE env var
    if (-not $awsProfile -and $env:AWS_PROFILE) { $awsProfile = $env:AWS_PROFILE }

    $profileArgs = @()
    if ($awsProfile) {
        $profileArgs = @("--profile", $awsProfile)
        $env:AWS_PROFILE = $awsProfile  # Set for terraform and subsequent calls
    }

    $identity = aws sts get-caller-identity --output json @profileArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "aws sts get-caller-identity failed (exit code $LASTEXITCODE): $identity"
    }
    $parsed = $identity | ConvertFrom-Json
    Write-Host "  Authenticated as: $($parsed.Arn) (profile: $($awsProfile ?? 'default'))" -ForegroundColor Green
} catch {
    Write-Host "  AWS authentication failed." -ForegroundColor Red
    Write-Host "  Error: $_" -ForegroundColor Red
    Write-Host ""
    if ($awsProfile) {
        Write-Host "  Fix: run 'aws sso login --profile $awsProfile' then retry." -ForegroundColor Yellow
    } else {
        Write-Host "  Fix: run 'aws sso login' or set `$env:AWS_PROFILE, then retry." -ForegroundColor Yellow
    }
    exit 1
}

# Verify terraform can also authenticate (catches stale SSO token edge cases)
Write-Host "  Verifying Terraform can reach AWS..." -ForegroundColor Yellow
Push-Location $tfDir
try {
    $planCheck = terraform plan -input=false -no-color 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errText = $planCheck | Out-String
        if ($errText -match "No valid credential" -or $errText -match "InvalidGrantException" -or $errText -match "refresh cached SSO") {
            Write-Host "  Terraform cannot authenticate to AWS." -ForegroundColor Red
            Write-Host "  Your SSO token may be expired." -ForegroundColor Red
            Write-Host ""
            Write-Host "  Fix: run 'aws sso login --profile $($awsProfile ?? 'default')' then retry." -ForegroundColor Yellow
            Pop-Location
            exit 1
        }
        # Non-auth errors during plan are ok (e.g., resources already destroyed)
        Write-Host "  Terraform auth OK (plan had non-auth warnings, continuing)." -ForegroundColor DarkYellow
    } else {
        Write-Host "  Terraform auth OK." -ForegroundColor Green
    }
} finally {
    Pop-Location
}

Write-Host ""

# Step 1: Commit and push changes
Write-Host "[1/4] Checking for uncommitted changes..." -ForegroundColor Yellow
$status = git status --porcelain
if ($status) {
    Write-Host "  Uncommitted changes found. Committing..." -ForegroundColor Yellow
    git add -A
    git commit -m "fix: deployment automation - replace sqlcmd with Invoke-Sqlcmd, add stored procs, fix blank search, fix FK constraints"
    git push origin main
    Write-Host "  Changes pushed to main." -ForegroundColor Green
} else {
    Write-Host "  Working tree clean." -ForegroundColor Green
}

# Step 2: Terraform destroy (to get fresh user-data)
if (-not $SkipDestroy) {
    Write-Host ""
    Write-Host "[2/4] Destroying infrastructure (fresh user-data requires new instance)..." -ForegroundColor Yellow
    if (-not $AutoApprove) {
        Write-Host "  This will destroy all AWS resources. Press Ctrl+C to cancel, or wait 10 seconds..." -ForegroundColor Red
        Start-Sleep -Seconds 10
    }
    Push-Location $tfDir
    terraform destroy -auto-approve
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Terraform destroy failed (exit code $LASTEXITCODE)." -ForegroundColor Red
        Pop-Location
        exit 1
    }
    Pop-Location
    Write-Host "  Infrastructure destroyed." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "[2/4] Skipping destroy (--SkipDestroy flag set)." -ForegroundColor DarkYellow
}

# Step 3: Terraform apply
Write-Host ""
Write-Host "[3/4] Applying infrastructure (new instance with SqlServer module)..." -ForegroundColor Yellow
Push-Location $tfDir
terraform apply -auto-approve
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Terraform apply failed (exit code $LASTEXITCODE)." -ForegroundColor Red
    Pop-Location
    exit 1
}
Pop-Location
Write-Host "  Infrastructure created." -ForegroundColor Green

# Step 4: Done
Write-Host ""
Write-Host "[4/4] Infrastructure is up. The CodePipeline will trigger automatically from the push." -ForegroundColor Yellow
Write-Host ""
Write-Host "=== Next steps ===" -ForegroundColor Cyan
Write-Host "  1. Monitor the pipeline in the AWS Console (CodePipeline)"
Write-Host "  2. Once deployed, verify: blank search returns all customers"
Write-Host "  3. Verify: search with term still returns filtered results"
Write-Host "  4. Push again to test idempotent redeployment"
Write-Host ""
