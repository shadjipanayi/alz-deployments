#Requires -Version 7.2
<#
.SYNOPSIS
    Controlled deployment driver for the Azure migration deployment factory.

.DESCRIPTION
    Executes an Azure landing zone deployment using the same template, the same parameter file and
    the same provenance model as the GitHub Actions pipeline, and produces the same deployment
    evidence record.

    This script exists for two purposes:

      1. Preview. Engineers run it with -WhatIfOnly to understand the impact of a change before
         opening a pull request.
      2. Authorised development deployment. Engineers may deploy to a development subscription from
         a workstation while a change is being developed.

    It must NOT be used to deploy to a test, user acceptance or production subscription. Those
    deployments run through .github/workflows/deploy-prod.yml so that the approval record, the
    named approvers and the evidence bundle are produced. The script refuses to deploy to a
    non-development environment unless -OverrideEnvironmentGuard is supplied, which is itself an
    auditable event that must be justified on the change request.

.PARAMETER ParameterFile
    Path to the customer parameter file to deploy.

.PARAMETER SubscriptionId
    Target Azure subscription identifier.

.PARAMETER ChangeRequestId
    The approved change request authorising this deployment, for example CR-0142. Mandatory.

.PARAMETER WhatIfOnly
    Produce the what-if preview and stop. No change is made to Azure.

.PARAMETER SkipConfirmation
    Suppress the interactive confirmation prompt. Intended for automation only.

.PARAMETER OverrideEnvironmentGuard
    Permit a workstation deployment to a non-development environment. Requires a justification.

.PARAMETER Justification
    Reason the environment guard is being overridden. Recorded in the evidence record.

.PARAMETER EvidencePath
    Directory that receives the what-if preview and the deployment evidence record.

.EXAMPLE
    ./scripts/deploy.ps1 -ParameterFile ./parameters/customer-a-dev.json -SubscriptionId 3f1b2c4d-8a76-4d21-9e05-7c3a9b6d1e42 -ChangeRequestId CR-0142 -WhatIfOnly

.EXAMPLE
    ./scripts/deploy.ps1 -ParameterFile ./parameters/customer-a-dev.json -SubscriptionId 3f1b2c4d-8a76-4d21-9e05-7c3a9b6d1e42 -ChangeRequestId CR-0142

.NOTES
    Owner:           DevOps Engineer
    Audit relevance: Control 3.1 - the deployment path, provenance tagging and evidence record are
                     identical whether a deployment is initiated by the pipeline or by an engineer.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $ParameterFile,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string] $SubscriptionId,

    [Parameter(Mandatory)]
    [ValidatePattern('^CR-\d{3,6}$')]
    [string] $ChangeRequestId,

    [Parameter()]
    [switch] $WhatIfOnly,

    [Parameter()]
    [switch] $SkipConfirmation,

    [Parameter()]
    [switch] $OverrideEnvironmentGuard,

    [Parameter()]
    [string] $Justification,

    [Parameter()]
    [string] $EvidencePath = './evidence'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$templateFile = Join-Path $repositoryRoot 'bicep/main.bicep'
$configurationName = Split-Path $ParameterFile -LeafBase
$startedUtc = (Get-Date).ToUniversalTime()

function Write-Banner {
    param([string] $Text, [string] $Colour = 'Cyan')
    Write-Host ''
    Write-Host ('=' * 96) -ForegroundColor DarkCyan
    Write-Host $Text -ForegroundColor $Colour
    Write-Host ('=' * 96) -ForegroundColor DarkCyan
}

# -------------------------------------------------------------------------------------------------
# 1. Read and check the configuration
# -------------------------------------------------------------------------------------------------

Write-Banner 'Azure Migration Deployment Factory - deployment driver'

$configuration = Get-Content -Path $ParameterFile -Raw | ConvertFrom-Json -Depth 20
$environment = $configuration.parameters.environment.value
$location = $configuration.parameters.location.value
$customerName = $configuration.parameters.customerName.value
$customerCode = $configuration.parameters.customerCode.value

$declaredSubscription = $null
if ($configuration.PSObject.Properties.Name -contains 'metadata' -and
    $configuration.metadata.PSObject.Properties.Name -contains 'targetSubscriptionId') {
    $declaredSubscription = $configuration.metadata.targetSubscriptionId
}

Write-Host "Customer            : $customerName ($customerCode)"
Write-Host "Configuration       : $configurationName"
Write-Host "Environment         : $environment"
Write-Host "Region              : $location"
Write-Host "Subscription        : $SubscriptionId"
Write-Host "Change request      : $ChangeRequestId"
Write-Host "Template            : bicep/main.bicep"
Write-Host "Parameters          : $ParameterFile"
Write-Host "Mode                : $(if ($WhatIfOnly) { 'Preview only' } else { 'Deploy' })"

if ($declaredSubscription -and $declaredSubscription -ne $SubscriptionId) {
    throw "The subscription supplied ($SubscriptionId) does not match metadata.targetSubscriptionId in $ParameterFile ($declaredSubscription). Refusing to proceed."
}

if (-not $WhatIfOnly -and $environment -ne 'dev' -and -not $OverrideEnvironmentGuard) {
    throw @"
Refusing to deploy to the '$environment' environment from a workstation.

Test, user acceptance and production deployments must run through GitHub Actions so that the
approval record, the named approvers, the Azure correlation identifier and the evidence bundle are
produced. See docs/Change_Management.md.

If there is a genuine, documented reason to override this control, supply -OverrideEnvironmentGuard
together with -Justification. The override is recorded in the evidence record and must be declared
on $ChangeRequestId.
"@
}

if ($OverrideEnvironmentGuard -and [string]::IsNullOrWhiteSpace($Justification)) {
    throw 'The environment guard override requires -Justification.'
}

# -------------------------------------------------------------------------------------------------
# 2. Confirm tooling and Azure context
# -------------------------------------------------------------------------------------------------

Write-Banner '1. Azure context'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found on PATH. Install version 2.61.0 or later.'
}

$account = az account show --output json 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'Not signed in to Azure. Run "az login" and retry.'
}

$accountObject = $account | ConvertFrom-Json
Write-Host "Signed in as        : $($accountObject.user.name)"
Write-Host "Tenant              : $($accountObject.tenantId)"

az account set --subscription $SubscriptionId | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Unable to select subscription $SubscriptionId. Confirm the identity has access."
}

# -------------------------------------------------------------------------------------------------
# 3. Preview
# -------------------------------------------------------------------------------------------------

Write-Banner '2. What-if preview'

if (-not (Test-Path $EvidencePath)) {
    New-Item -ItemType Directory -Path $EvidencePath -Force | Out-Null
}

$timestamp = $startedUtc.ToString('yyyyMMddHHmmss')
$deploymentName = "mig-$configurationName-$timestamp"
$whatIfPath = Join-Path $EvidencePath "whatif-$configurationName-$timestamp.txt"

$sourceCommit = 'unknown'
if (Get-Command git -ErrorAction SilentlyContinue) {
    $resolved = git -C $repositoryRoot rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($resolved)) {
        $sourceCommit = $resolved.Trim()
    }
}

$commonParameters = @(
    '--name', $deploymentName
    '--location', $location
    '--subscription', $SubscriptionId
    '--template-file', $templateFile
    '--parameters', "@$ParameterFile"
    '--parameters', "changeRequestId=$ChangeRequestId", "sourceCommit=$sourceCommit", "deploymentId=manual-$timestamp"
    '--only-show-errors'
)

& az deployment sub what-if @commonParameters | Tee-Object -FilePath $whatIfPath
if ($LASTEXITCODE -ne 0) {
    throw 'The what-if preview failed. Resolve the error before attempting a deployment.'
}

Write-Host ''
Write-Host "Preview written to $whatIfPath" -ForegroundColor DarkGray

if ($WhatIfOnly) {
    Write-Banner 'Preview complete. No change was made to Azure.' 'Green'
    exit 0
}

# -------------------------------------------------------------------------------------------------
# 4. Confirm
# -------------------------------------------------------------------------------------------------

Write-Banner '3. Confirmation'

if (-not $SkipConfirmation) {
    Write-Host 'Review the preview above before continuing.' -ForegroundColor Yellow
    Write-Host "You are about to deploy to $customerName ($environment) in subscription $SubscriptionId." -ForegroundColor Yellow
    $response = Read-Host 'Type the change request identifier to proceed, or anything else to abort'
    if ($response -cne $ChangeRequestId) {
        Write-Host 'Aborted by operator. No change was made to Azure.' -ForegroundColor Red
        exit 2
    }
}

if (-not $PSCmdlet.ShouldProcess("$customerName ($environment) in subscription $SubscriptionId", 'Deploy migration landing zone')) {
    Write-Host 'Aborted. No change was made to Azure.' -ForegroundColor Red
    exit 2
}

# -------------------------------------------------------------------------------------------------
# 5. Deploy
# -------------------------------------------------------------------------------------------------

Write-Banner '4. Deployment'

$deploymentOutputPath = Join-Path $EvidencePath "deployment-$configurationName-$timestamp.json"
$deploymentSucceeded = $true
$correlationId = ''
$provisioningState = 'Unknown'

& az deployment sub create @commonParameters --output json | Set-Content -Path $deploymentOutputPath -Encoding utf8

if ($LASTEXITCODE -ne 0) {
    $deploymentSucceeded = $false
    Write-Host ''
    Write-Host 'DEPLOYMENT FAILED. Collecting failure detail ...' -ForegroundColor Red

    $failurePath = Join-Path $EvidencePath "failure-$configurationName-$timestamp.json"
    & az deployment operation sub list `
        --name $deploymentName `
        --subscription $SubscriptionId `
        --query "[?properties.provisioningState=='Failed'].{resource:properties.targetResource.resourceName, type:properties.targetResource.resourceType, code:properties.statusMessage.error.code, message:properties.statusMessage.error.message}" `
        --output json 2>$null | Set-Content -Path $failurePath -Encoding utf8

    if (Test-Path $failurePath) {
        Get-Content $failurePath | Write-Host
        Write-Host "Failure detail written to $failurePath" -ForegroundColor DarkGray
    }
}
else {
    $deployment = Get-Content -Path $deploymentOutputPath -Raw | ConvertFrom-Json -Depth 20
    $correlationId = $deployment.properties.correlationId
    $provisioningState = $deployment.properties.provisioningState
    Write-Host ''
    Write-Host "Provisioning state  : $provisioningState" -ForegroundColor Green
    Write-Host "Correlation ID      : $correlationId" -ForegroundColor Green
    Write-Host "Deployment name     : $deploymentName" -ForegroundColor Green
}

# -------------------------------------------------------------------------------------------------
# 6. Evidence record
# -------------------------------------------------------------------------------------------------

Write-Banner '5. Evidence record'

$record = [ordered]@{
    evidenceType             = 'DeploymentRecord'
    control                  = '3.1 Repeatable Deployment'
    origin                   = 'Workstation (scripts/deploy.ps1)'
    customer                 = $customerName
    customerCode             = $customerCode
    configuration            = $configurationName
    environment              = $environment
    region                   = $location
    changeRequestId          = $ChangeRequestId
    templateFile             = 'bicep/main.bicep'
    parameterFile            = $ParameterFile
    subscriptionId           = $SubscriptionId
    deploymentName           = $deploymentName
    azureCorrelationId       = $correlationId
    provisioningState        = $provisioningState
    outcome                  = $(if ($deploymentSucceeded) { 'Succeeded' } else { 'Failed' })
    initiatedBy              = $accountObject.user.name
    sourceCommit             = $sourceCommit
    environmentGuardOverride = [bool] $OverrideEnvironmentGuard
    overrideJustification    = $Justification
    startedUtc               = $startedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    completedUtc             = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    whatIfPreview            = $whatIfPath
}

$recordPath = Join-Path $EvidencePath "deployment-record-$configurationName-$timestamp.json"
$record | ConvertTo-Json -Depth 6 | Set-Content -Path $recordPath -Encoding utf8
Write-Host "Evidence record written to $recordPath" -ForegroundColor DarkGray

if (-not $deploymentSucceeded) {
    Write-Banner 'DEPLOYMENT FAILED. Invoke the rollback plan if the rollback trigger criteria are met.' 'Red'
    exit 1
}

# -------------------------------------------------------------------------------------------------
# 7. Verify
# -------------------------------------------------------------------------------------------------

Write-Banner '6. Post-deployment verification'

$checksPath = Join-Path $EvidencePath "postdeploy-$configurationName-$timestamp.json"
& (Join-Path $PSScriptRoot 'post-deployment-checks.ps1') `
    -ParameterFile $ParameterFile `
    -SubscriptionId $SubscriptionId `
    -OutputPath $checksPath

$checksExitCode = $LASTEXITCODE

if ($checksExitCode -ne 0) {
    Write-Banner 'DEPLOYMENT COMPLETED BUT VERIFICATION FAILED. Raise a defect and do not sign off the wave.' 'Red'
    exit 1
}

Write-Banner 'DEPLOYMENT COMPLETED AND VERIFIED.' 'Green'
Write-Host 'Record the outcome on the deployment request issue, then obtain customer sign-off.' -ForegroundColor Gray
exit 0
