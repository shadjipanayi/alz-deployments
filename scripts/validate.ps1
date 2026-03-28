#Requires -Version 7.2
<#
.SYNOPSIS
    Local and continuous integration validation gate for the Azure migration deployment factory.

.DESCRIPTION
    Runs exactly the checks that .github/workflows/validate.yml runs, so that a clean local result
    predicts a clean pipeline result. Running this script before opening a pull request is a
    mandatory step of the contribution process documented in CONTRIBUTING.md.

    Checks performed:

      1. Tooling            - confirms Azure CLI and Bicep are present and recent enough.
      2. Compile            - compiles every template in bicep/ to Azure Resource Manager JSON.
      3. Lint               - enforces the Bicep linter ruleset defined in bicepconfig.json.
      4. Secret scan        - blocks credentials from entering source control.
      5. Convention scan    - blocks hard-coded subscription, tenant and object identifiers, and
                              customer-specific values, from entering bicep/.
      6. Parameter files    - confirms every parameter file parses, declares the template it
                              configures, supplies every required parameter, and resolves its
                              administrator password from Key Vault rather than a literal value.
      7. Azure validation   - optional. Submits the deployment to Azure Resource Manager for
                              validation and produces a what-if preview.

.PARAMETER ParameterFile
    Path to a single customer parameter file to validate and preview against Azure. When omitted,
    only the offline checks run.

.PARAMETER SubscriptionId
    Target subscription for the Azure validation and what-if preview. Required with -ParameterFile.

.PARAMETER All
    Run the offline checks against every parameter file in parameters/.

.PARAMETER ScanOnly
    Run only the secret, convention and parameter file checks. Used by the pipeline scan job.

.PARAMETER FailOnWarning
    Treat warnings as failures. Used by the pipeline so that advisory findings cannot accumulate.

.PARAMETER OutputPath
    Optional path to write the machine-readable validation result, used as deployment evidence.

.EXAMPLE
    ./scripts/validate.ps1 -All

.EXAMPLE
    ./scripts/validate.ps1 -ParameterFile ./parameters/customer-a-dev.json -SubscriptionId 3f1b2c4d-8a76-4d21-9e05-7c3a9b6d1e42

.NOTES
    Owner:           DevOps Engineer
    Audit relevance: Control 3.1 - demonstrates that an objective, automated validation standard is
                     applied identically by engineers locally and by the pipeline.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string] $ParameterFile,

    [Parameter()]
    [string] $SubscriptionId,

    [Parameter()]
    [switch] $All,

    [Parameter()]
    [switch] $ScanOnly,

    [Parameter()]
    [switch] $FailOnWarning,

    [Parameter()]
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -------------------------------------------------------------------------------------------------
# Context
# -------------------------------------------------------------------------------------------------

$script:RepositoryRoot = Split-Path -Parent $PSScriptRoot
$script:BicepDirectory = Join-Path $RepositoryRoot 'bicep'
$script:ParameterDirectory = Join-Path $RepositoryRoot 'parameters'
$script:BuildDirectory = Join-Path $RepositoryRoot 'build'
$script:Results = New-Object System.Collections.Generic.List[pscustomobject]

# Identifiers that are legitimately present in templates. Every entry is a documented Azure
# built-in role or built-in policy definition. Any other GUID in bicep/ is a finding.
$script:AllowedIdentifiers = @(
    '00482a5a-887f-4fb3-b363-3b7fe8e74483'  # Key Vault Administrator
    '4633458b-17de-408a-b874-0445c86b69e6'  # Key Vault Secrets User
    'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'  # Key Vault Secrets Officer
    'acdd72a7-3385-48ef-bd42-f606fba81ae7'  # Reader
    'e56962a6-4747-49cd-b67b-bf8b01975c4c'  # Built-in policy: Allowed locations
    'e765b5de-1225-4ba3-bd56-1ac6695af988'  # Built-in policy: Allowed locations for resource groups
)

# Parameters every customer parameter file must supply. Optional parameters have template defaults
# and are deliberately not listed.
$script:RequiredParameters = @(
    'customerCode'
    'customerName'
    'environment'
    'location'
    'costCentre'
    'ownerEmail'
    'changeRequestId'
    'virtualNetworkAddressPrefix'
    'applicationSubnetPrefix'
    'dataSubnetPrefix'
    'sqlManagedInstanceSubnetPrefix'
    'privateEndpointSubnetPrefix'
    'allowedLocations'
)

# -------------------------------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------------------------------

function Add-Result {
    param(
        [Parameter(Mandatory)] [string] $Check,
        [Parameter(Mandatory)] [ValidateSet('Pass', 'Warn', 'Fail', 'Skip')] [string] $Status,
        [Parameter(Mandatory)] [string] $Message,
        [Parameter()] [string] $Target = ''
    )

    $script:Results.Add([pscustomobject]@{
            Check   = $Check
            Target  = $Target
            Status  = $Status
            Message = $Message
        })

    $prefix = switch ($Status) {
        'Pass' { '  [PASS]' }
        'Warn' { '  [WARN]' }
        'Fail' { '  [FAIL]' }
        'Skip' { '  [SKIP]' }
    }

    $colour = switch ($Status) {
        'Pass' { 'Green' }
        'Warn' { 'Yellow' }
        'Fail' { 'Red' }
        'Skip' { 'DarkGray' }
    }

    $line = if ($Target) { "$prefix $Check :: $Target - $Message" } else { "$prefix $Check - $Message" }
    Write-Host $line -ForegroundColor $colour

    if ($env:GITHUB_ACTIONS -eq 'true') {
        switch ($Status) {
            'Fail' { Write-Host "::error::$Check :: $Target - $Message" }
            'Warn' { Write-Host "::warning::$Check :: $Target - $Message" }
            default { }
        }
    }
}

function Write-Section {
    param([Parameter(Mandatory)] [string] $Title)
    Write-Host ''
    Write-Host ('=' * 96) -ForegroundColor DarkCyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('=' * 96) -ForegroundColor DarkCyan
}

function Test-Tooling {
    Write-Section '1. Tooling'

    $azure = Get-Command az -ErrorAction SilentlyContinue
    if (-not $azure) {
        Add-Result -Check 'Tooling' -Status 'Fail' -Message 'Azure CLI was not found on PATH. Install version 2.61.0 or later.'
        return $false
    }

    try {
        $version = (az version --output json 2>$null | ConvertFrom-Json).'azure-cli'
        Add-Result -Check 'Tooling' -Status 'Pass' -Message "Azure CLI $version detected." -Target 'az'
    }
    catch {
        Add-Result -Check 'Tooling' -Status 'Warn' -Message 'Azure CLI version could not be determined.' -Target 'az'
    }

    $bicepVersion = (az bicep version 2>&1) -join ' '
    if ($LASTEXITCODE -ne 0) {
        Add-Result -Check 'Tooling' -Status 'Fail' -Message 'Bicep is not installed. Run "az bicep install".' -Target 'bicep'
        return $false
    }

    Add-Result -Check 'Tooling' -Status 'Pass' -Message $bicepVersion.Trim() -Target 'bicep'
    return $true
}

function Invoke-TemplateCompilation {
    Write-Section '2. Compile templates'

    if (-not (Test-Path $BuildDirectory)) {
        New-Item -ItemType Directory -Path $BuildDirectory -Force | Out-Null
    }

    foreach ($template in Get-ChildItem -Path $BicepDirectory -Filter '*.bicep' | Sort-Object Name) {
        $output = & az bicep build --file $template.FullName --outdir $BuildDirectory 2>&1
        if ($LASTEXITCODE -ne 0) {
            Add-Result -Check 'Compile' -Status 'Fail' -Target $template.Name -Message (($output | Out-String).Trim())
        }
        else {
            Add-Result -Check 'Compile' -Status 'Pass' -Target $template.Name -Message 'Compiled successfully.'
        }
    }
}

function Invoke-TemplateLint {
    Write-Section '3. Lint templates'

    foreach ($template in Get-ChildItem -Path $BicepDirectory -Filter '*.bicep' | Sort-Object Name) {
        $output = & az bicep lint --file $template.FullName 2>&1
        $text = ($output | Out-String).Trim()

        if ($LASTEXITCODE -ne 0) {
            Add-Result -Check 'Lint' -Status 'Fail' -Target $template.Name -Message $text
        }
        elseif ($text -match 'Warning') {
            Add-Result -Check 'Lint' -Status 'Warn' -Target $template.Name -Message $text
        }
        else {
            Add-Result -Check 'Lint' -Status 'Pass' -Target $template.Name -Message 'No lint findings.'
        }
    }
}

function Invoke-SecretScan {
    Write-Section '4. Secret scan'

    $patterns = [ordered]@{
        'Literal password assignment'   = '(?i)\b(password|passwd|pwd|adminPassword|administratorLoginPassword)\b\s*[:=]\s*[''"][^''"]{6,}[''"]'
        'Literal secret or key'         = '(?i)\b(secret|apikey|api_key|accesskey|access_key|clientsecret|client_secret)\b\s*[:=]\s*[''"][^''"]{8,}[''"]'
        'Storage account key'           = '(?i)AccountKey\s*='
        'Shared access signature'       = '(?i)\bsig=[A-Za-z0-9%]{20,}'
        'Private key material'          = '-----BEGIN (RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----'
        'Connection string with secret' = '(?i)(Server|Data Source)=.*(Password|Pwd)='
        'Bearer token'                  = '(?i)\bBearer\s+[A-Za-z0-9\-._~+/]{30,}'
    }

    $scanPaths = @(
        Join-Path $RepositoryRoot 'bicep'
        Join-Path $RepositoryRoot 'scripts'
        Join-Path $RepositoryRoot '.github'
        Join-Path $RepositoryRoot 'parameters'
    ) | Where-Object { Test-Path $_ }

    $files = Get-ChildItem -Path $scanPaths -Recurse -File |
        Where-Object { $_.Extension -in @('.bicep', '.json', '.yml', '.yaml', '.ps1', '.sh', '.md') }

    $findings = 0
    foreach ($file in $files) {
        # This script necessarily contains the detection patterns themselves.
        if ($file.FullName -eq $PSCommandPath) { continue }

        $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        foreach ($pattern in $patterns.GetEnumerator()) {
            $matchResults = [regex]::Matches($content, $pattern.Value)
            foreach ($matchResult in $matchResults) {
                $findings++
                $relative = $file.FullName.Substring($RepositoryRoot.Length).TrimStart('\', '/')
                $lineNumber = ($content.Substring(0, $matchResult.Index) -split "`n").Count
                Add-Result -Check 'SecretScan' -Status 'Fail' -Target "$relative`:$lineNumber" `
                    -Message "$($pattern.Key) detected. Secrets must be supplied through a Key Vault reference. See SECURITY.md section 3."
            }
        }
    }

    if ($findings -eq 0) {
        Add-Result -Check 'SecretScan' -Status 'Pass' -Message "No credential patterns detected across $($files.Count) files."
    }
}

function Invoke-ConventionScan {
    Write-Section '5. Convention scan'

    $guidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $customerNames = @('contoso', 'northwind', 'fabrikam', 'ctso', 'nwfn')
    $findings = 0

    foreach ($template in Get-ChildItem -Path $BicepDirectory -Filter '*.bicep') {
        $content = Get-Content -Path $template.FullName -Raw
        $lines = $content -split "`r?`n"

        for ($index = 0; $index -lt $lines.Count; $index++) {
            $line = $lines[$index]
            $lineNumber = $index + 1

            foreach ($guidMatch in [regex]::Matches($line, $guidPattern)) {
                if ($AllowedIdentifiers -notcontains $guidMatch.Value.ToLowerInvariant()) {
                    $findings++
                    Add-Result -Check 'Conventions' -Status 'Fail' -Target "bicep/$($template.Name):$lineNumber" `
                        -Message "Hard-coded identifier $($guidMatch.Value) found. Subscription, tenant and object identifiers belong in parameter files, not templates."
                }
            }

            foreach ($customer in $customerNames) {
                if ($line -match "(?i)\b$customer\b" -and $line -notmatch '^\s*(//|\*)') {
                    $findings++
                    Add-Result -Check 'Conventions' -Status 'Fail' -Target "bicep/$($template.Name):$lineNumber" `
                        -Message "Customer-specific value '$customer' found in a template. Templates must be customer agnostic."
                }
            }
        }

        if ($content -notmatch "(?m)^metadata name\s*=") {
            $findings++
            Add-Result -Check 'Conventions' -Status 'Fail' -Target "bicep/$($template.Name)" `
                -Message 'Template is missing the mandatory "metadata name" declaration. See CONTRIBUTING.md section 8.'
        }

        if ($content -notmatch "(?m)^metadata owner\s*=") {
            $findings++
            Add-Result -Check 'Conventions' -Status 'Fail' -Target "bicep/$($template.Name)" `
                -Message 'Template is missing the mandatory "metadata owner" declaration. See CONTRIBUTING.md section 8.'
        }

        if ($content -notmatch "(?m)^targetScope\s*=") {
            $findings++
            Add-Result -Check 'Conventions' -Status 'Fail' -Target "bicep/$($template.Name)" `
                -Message 'Template does not declare targetScope explicitly. See CONTRIBUTING.md section 8.'
        }

        $parameterDeclarations = [regex]::Matches($content, "(?m)^param\s+(\w+)")
        foreach ($declaration in $parameterDeclarations) {
            $name = $declaration.Groups[1].Value
            $preceding = $content.Substring(0, $declaration.Index)
            $lastLines = ($preceding -split "`r?`n") | Select-Object -Last 4
            if (($lastLines -join "`n") -notmatch '@description\(') {
                $findings++
                Add-Result -Check 'Conventions' -Status 'Fail' -Target "bicep/$($template.Name)" `
                    -Message "Parameter '$name' has no @description decorator. Every parameter must be documented."
            }
        }
    }

    if ($findings -eq 0) {
        Add-Result -Check 'Conventions' -Status 'Pass' -Message 'All templates are customer agnostic, documented and correctly scoped.'
    }
}

function Test-ParameterFile {
    param([Parameter(Mandatory)] [System.IO.FileInfo] $File)

    $relative = "parameters/$($File.Name)"
    $isSample = $File.Name -eq 'sample-customer.json'

    try {
        $document = Get-Content -Path $File.FullName -Raw | ConvertFrom-Json -Depth 20
    }
    catch {
        Add-Result -Check 'Parameters' -Status 'Fail' -Target $relative -Message "File is not valid JSON: $($_.Exception.Message)"
        return
    }

    if (-not ($document.PSObject.Properties.Name -contains 'parameters')) {
        Add-Result -Check 'Parameters' -Status 'Fail' -Target $relative -Message 'File does not contain a "parameters" object.'
        return
    }

    $supplied = $document.parameters.PSObject.Properties.Name
    $missing = $RequiredParameters | Where-Object { $supplied -notcontains $_ }
    if ($missing) {
        Add-Result -Check 'Parameters' -Status 'Fail' -Target $relative -Message "Missing required parameters: $($missing -join ', ')."
    }

    $metadata = if ($document.PSObject.Properties.Name -contains 'metadata') { $document.metadata } else { $null }
    $metadataFields = if ($metadata) { $metadata.PSObject.Properties.Name } else { @() }

    if ($metadataFields -notcontains 'template') {
        Add-Result -Check 'Parameters' -Status 'Warn' -Target $relative -Message 'metadata.template is not declared. Record which template this file configures.'
    }

    # The administrator password must be a Key Vault reference, never a literal value.
    if ($supplied -contains 'sqlAdministratorPassword') {
        $password = $document.parameters.sqlAdministratorPassword
        if ($password.PSObject.Properties.Name -contains 'value') {
            Add-Result -Check 'Parameters' -Status 'Fail' -Target $relative `
                -Message 'sqlAdministratorPassword supplies a literal value. It must use a Key Vault reference. See SECURITY.md section 3.'
        }
        elseif ($password.PSObject.Properties.Name -contains 'reference') {
            Add-Result -Check 'Parameters' -Status 'Pass' -Target $relative -Message 'Administrator password resolves from Key Vault.'
        }
    }

    # Address space sanity: every subnet prefix must fall inside the virtual network address space.
    if (($supplied -contains 'virtualNetworkAddressPrefix')) {
        $vnetPrefix = $document.parameters.virtualNetworkAddressPrefix.value
        $vnetOctets = ($vnetPrefix -split '/')[0] -split '\.'
        foreach ($subnetParameter in @('applicationSubnetPrefix', 'dataSubnetPrefix', 'sqlManagedInstanceSubnetPrefix', 'privateEndpointSubnetPrefix')) {
            if ($supplied -notcontains $subnetParameter) { continue }
            $subnetPrefix = $document.parameters.$subnetParameter.value
            $subnetOctets = ($subnetPrefix -split '/')[0] -split '\.'
            if ($subnetOctets[0] -ne $vnetOctets[0] -or $subnetOctets[1] -ne $vnetOctets[1]) {
                Add-Result -Check 'Parameters' -Status 'Fail' -Target $relative `
                    -Message "$subnetParameter ($subnetPrefix) does not fall inside virtualNetworkAddressPrefix ($vnetPrefix)."
            }
        }

        if ($supplied -contains 'sqlManagedInstanceSubnetPrefix') {
            $maskLength = [int](($document.parameters.sqlManagedInstanceSubnetPrefix.value -split '/')[1])
            if ($maskLength -gt 27) {
                Add-Result -Check 'Parameters' -Status 'Fail' -Target $relative `
                    -Message "The SQL Managed Instance subnet is a /$maskLength. Azure requires at least a /27; a /24 is recommended."
            }
            elseif ($maskLength -gt 24) {
                Add-Result -Check 'Parameters' -Status 'Warn' -Target $relative `
                    -Message "The SQL Managed Instance subnet is a /$maskLength. A /24 is recommended to allow for scale operations."
            }
        }
    }

    # Production configurations must carry the customer approval and maintenance window metadata.
    if ($File.Name -like '*-prod.json') {
        foreach ($field in @('customerApproval', 'maintenanceWindow')) {
            if ($metadataFields -notcontains $field -or [string]::IsNullOrWhiteSpace($metadata.$field)) {
                Add-Result -Check 'Parameters' -Status 'Fail' -Target $relative `
                    -Message "Production configuration does not record metadata.$field. See docs/Change_Management.md."
            }
        }

        if (($supplied -contains 'policyEnforcementMode') -and $document.parameters.policyEnforcementMode.value -ne 'Default') {
            Add-Result -Check 'Parameters' -Status 'Fail' -Target $relative `
                -Message 'Production configurations must enforce policy. Set policyEnforcementMode to Default.'
        }

        if (($supplied -contains 'logRetentionInDays') -and $document.parameters.logRetentionInDays.value -lt 180) {
            Add-Result -Check 'Parameters' -Status 'Warn' -Target $relative `
                -Message "Production telemetry retention is $($document.parameters.logRetentionInDays.value) days. Most regulated customers require 365 or more."
        }
    }

    # Unresolved onboarding markers must never reach a real customer configuration.
    $raw = Get-Content -Path $File.FullName -Raw
    if (-not $isSample -and $raw -match 'REPLACE') {
        Add-Result -Check 'Parameters' -Status 'Fail' -Target $relative -Message 'File still contains unresolved REPLACE markers from the onboarding template.'
    }

    if (-not ($script:Results | Where-Object { $_.Target -eq $relative -and $_.Status -eq 'Fail' })) {
        Add-Result -Check 'Parameters' -Status 'Pass' -Target $relative -Message 'Configuration is complete and conforms to the standard.'
    }
}

function Invoke-ParameterValidation {
    Write-Section '6. Parameter files'

    $files = if ($ParameterFile) {
        @(Get-Item -Path $ParameterFile)
    }
    else {
        Get-ChildItem -Path $ParameterDirectory -Filter '*.json' | Sort-Object Name
    }

    foreach ($file in $files) {
        Test-ParameterFile -File $file
    }
}

function Invoke-AzureValidation {
    Write-Section '7. Azure validation and preview'

    if (-not $ParameterFile -or -not $SubscriptionId) {
        Add-Result -Check 'AzureValidation' -Status 'Skip' -Message 'Supply -ParameterFile and -SubscriptionId to validate against Azure.'
        return
    }

    $account = az account show --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
        Add-Result -Check 'AzureValidation' -Status 'Skip' -Message 'Not signed in to Azure. Run "az login" to enable this check.'
        return
    }

    $document = Get-Content -Path $ParameterFile -Raw | ConvertFrom-Json -Depth 20
    $location = $document.parameters.location.value
    $template = Join-Path $BicepDirectory 'main.bicep'
    $deploymentName = "validate-$(Split-Path $ParameterFile -LeafBase)-$(Get-Date -Format 'yyyyMMddHHmmss')"

    Write-Host "Validating $ParameterFile against subscription $SubscriptionId in $location ..." -ForegroundColor Gray

    $validateOutput = & az deployment sub validate `
        --name $deploymentName `
        --location $location `
        --subscription $SubscriptionId `
        --template-file $template `
        --parameters "@$ParameterFile" `
        --parameters changeRequestId='CR-LOCAL' sourceCommit='local' deploymentId='local' `
        --only-show-errors 2>&1

    if ($LASTEXITCODE -ne 0) {
        Add-Result -Check 'AzureValidation' -Status 'Fail' -Target $ParameterFile -Message (($validateOutput | Out-String).Trim())
        return
    }

    Add-Result -Check 'AzureValidation' -Status 'Pass' -Target $ParameterFile -Message 'Azure Resource Manager accepted the deployment.'

    Write-Host 'Producing what-if preview ...' -ForegroundColor Gray
    & az deployment sub what-if `
        --name $deploymentName `
        --location $location `
        --subscription $SubscriptionId `
        --template-file $template `
        --parameters "@$ParameterFile" `
        --parameters changeRequestId='CR-LOCAL' sourceCommit='local' deploymentId='local' `
        --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        Add-Result -Check 'AzureValidation' -Status 'Fail' -Target $ParameterFile -Message 'The what-if preview could not be produced.'
    }
    else {
        Add-Result -Check 'AzureValidation' -Status 'Pass' -Target $ParameterFile -Message 'What-if preview produced. Review it before requesting approval.'
    }
}

# -------------------------------------------------------------------------------------------------
# Execution
# -------------------------------------------------------------------------------------------------

Write-Host ''
Write-Host 'Azure Migration Deployment Factory - validation gate' -ForegroundColor White
Write-Host "Repository: $RepositoryRoot" -ForegroundColor DarkGray
Write-Host "Mode:       $(if ($ScanOnly) { 'Scan only' } elseif ($ParameterFile) { "Single configuration ($ParameterFile)" } else { 'All configurations' })" -ForegroundColor DarkGray

if (-not $ScanOnly) {
    if (Test-Tooling) {
        Invoke-TemplateCompilation
        Invoke-TemplateLint
    }
    else {
        Add-Result -Check 'Compile' -Status 'Skip' -Message 'Skipped because required tooling is unavailable.'
        Add-Result -Check 'Lint' -Status 'Skip' -Message 'Skipped because required tooling is unavailable.'
    }
}

Invoke-SecretScan
Invoke-ConventionScan
Invoke-ParameterValidation

if (-not $ScanOnly) {
    Invoke-AzureValidation
}

# -------------------------------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------------------------------

Write-Section 'Summary'

$summary = [ordered]@{
    Pass = @($Results | Where-Object Status -EQ 'Pass').Count
    Warn = @($Results | Where-Object Status -EQ 'Warn').Count
    Fail = @($Results | Where-Object Status -EQ 'Fail').Count
    Skip = @($Results | Where-Object Status -EQ 'Skip').Count
}

Write-Host ("Passed: {0}   Warnings: {1}   Failures: {2}   Skipped: {3}" -f $summary.Pass, $summary.Warn, $summary.Fail, $summary.Skip)

if ($OutputPath) {
    $record = [ordered]@{
        evidenceType = 'ValidationRecord'
        control      = '3.1 Repeatable Deployment'
        repository   = 'alz-deployments'
        executedUtc  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        executedBy   = $env:USERNAME ?? $env:USER ?? 'unknown'
        mode         = $(if ($ScanOnly) { 'ScanOnly' } else { 'Full' })
        summary      = $summary
        results      = @($Results)
    }
    $directory = Split-Path -Parent $OutputPath
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $record | ConvertTo-Json -Depth 6 | Set-Content -Path $OutputPath -Encoding utf8
    Write-Host "Validation record written to $OutputPath" -ForegroundColor DarkGray
}

if ($summary.Fail -gt 0) {
    Write-Host ''
    Write-Host 'VALIDATION FAILED. Resolve every failure before opening a pull request.' -ForegroundColor Red
    exit 1
}

if ($FailOnWarning -and $summary.Warn -gt 0) {
    Write-Host ''
    Write-Host 'VALIDATION FAILED. Warnings are treated as failures in this mode.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'VALIDATION PASSED.' -ForegroundColor Green
exit 0
