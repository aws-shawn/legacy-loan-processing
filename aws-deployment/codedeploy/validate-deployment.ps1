# validate-deployment.ps1 - CodeDeploy ValidateService hook
# Minimal version to avoid PowerShell parsing issues

$ErrorActionPreference = 'Stop'

try {
    Write-Host 'Checking IIS service...'
    $svc = Get-Service -Name W3SVC
    if ($svc.Status -ne 'Running') { throw 'IIS not running' }
    Write-Host 'IIS OK'

    Write-Host 'Checking website...'
    Import-Module WebAdministration
    $site = Get-Website -Name 'LoanProcessing'
    if ($site.State -ne 'Started') { throw 'Website not started' }
    Write-Host 'Website OK'

    Write-Host 'Testing HTTP...'
    $ok = $false
    for ($i = 1; $i -le 10; $i++) {
        try {
            $r = Invoke-WebRequest -Uri 'http://localhost/' -TimeoutSec 10 -UseBasicParsing
            if ($r.StatusCode -eq 200) { $ok = $true; break }
        } catch {
            Write-Host "Attempt $i failed, retrying..."
            Start-Sleep -Seconds 5
        }
    }
    if (-not $ok) { throw 'HTTP check failed' }
    Write-Host 'HTTP OK'

    Write-Host 'Validation passed'
    exit 0
} catch {
    Write-Host "Validation failed: $($_.Exception.Message)"
    exit 1
}
