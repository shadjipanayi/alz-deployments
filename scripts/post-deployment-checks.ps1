#Requires -Version 7.2
<#
.SYNOPSIS
    Objective post-deployment verification for an Azure migration landing zone.

.DESCRIPTION
    Asserts that the deployed estate matches the security, governance and data protection posture
    that this practice commits to in every engagement. The script makes no changes; it only reads.

    It is executed automatically by deploy-dev.yml and deploy-prod.yml immediately after every
    deployment, and manually before a migration wave is signed off. A failing result blocks wave
    sign-off and must be raised as a defect.

    Verification groups:

      A. Resource organisation   - the four purpose-scoped resource groups exist and are tagged.
      B. Provenance              - every resource carries the mandatory deployment provenance tags.
      C. Networking              - virtual network, subnets, delegation, route table and network
                                   security group rules required by SQL Managed Instance.
      D. Identity and secrets    - Key Vault soft delete, purge protection, RBAC authorisation and
                                   absence of public network access.
      E. Monitoring              - Log Analytics workspace present with the contracted retention.
      F. Data protection         - Recovery Services Vault, soft delete and backup policies.
      G. Governance              - the migration governance policy assignment is present and
                                   enforcing.
      H. Database platform       - SQL Managed Instance readiness, private-only connectivity,
                                   minimum TLS version, auditing and managed databases.

.PARAMETER ParameterFile
    The customer parameter file that was deployed. Used to derive the expected resource names and
    the contracted configuration values.

.PARAMETER SubscriptionId
    The subscription the deployment targeted.

.PARAMETER OutputPath
    Optional path for the machine-readable verification record used as deployment evidence.

.PARAMETER WarnOnly
    Report failures without setting a non-zero exit code. Intended for exploratory runs only; never
    used by the pipeline.

.EXAMPLE
    ./scripts/post-deployment-checks.ps1 -ParameterFile ./parameters/customer-a-dev.json -SubscriptionId 3f1b2c4d-8a76-4d21-9e05-7c3a9b6d1e42

.NOTES
    Owner:           Platform Engineering Lead
    Audit relevance: Control 3.1 - demonstrates that deployments are verified rather than assumed,
                     using an objective, repeatable and automated check suite.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string] $ParameterFile,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string] $SubscriptionId,

    [Parameter()]
    [string] $OutputPath,

    [Parameter()]
    [switch] $WarnOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Checks = New-Object System.Collections.Generic.List[pscustomobject]

# Mandatory tags enforced by the deny policy in bicep/governance.bicep.
$script:ProvenanceTags = @('ManagedBy', 'SourceRepo', 'SourceCommit', 'DeploymentId', 'ChangeRequest')

$script:RegionAbbreviations = @{
    westeurope         = 'weu'
    northeurope        = 'neu'
    uksouth            = 'uks'
    ukwest             = 'ukw'
    swedencentral      = 'sec'
    germanywestcentral = 'gwc'
    francecentral      = 'frc'
    switzerlandnorth   = 'chn'
    norwayeast         = 'nwe'
    polandcentral      = 'plc'
    italynorth         = 'itn'
    eastus             = 'eus'
    eastus2            = 'eus2'
    centralus          = 'cus'
    westus2            = 'wus2'
    westus3            = 'wus3'
    canadacentral      = 'cac'
    uaenorth           = 'uan'
    southeastasia      = 'sea'
    australiaeast      = 'aue'
}

# -------------------------------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------------------------------

function Add-Check {
    param(
        [Parameter(Mandatory)] [string] $Group,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('Pass', 'Warn', 'Fail', 'Skip')] [string] $Status,
        [Parameter(Mandatory)] [string] $Detail,
        [Parameter()] [string] $Expected = '',
        [Parameter()] [string] $Actual = ''
    )

    $script:Checks.Add([pscustomobject]@{
            Group    = $Group
            Name     = $Name
            Status   = $Status
            Expected = $Expected
            Actual   = $Actual
            Detail   = $Detail
        })

    $marker = switch ($Status) {
        'Pass' { '[PASS]' }
        'Warn' { '[WARN]' }
        'Fail' { '[FAIL]' }
        'Skip' { '[SKIP]' }
    }
    $colour = switch ($Status) {
        'Pass' { 'Green' }
        'Warn' { 'Yellow' }
        'Fail' { 'Red' }
        'Skip' { 'DarkGray' }
    }

    Write-Host ("  {0} {1,-52} {2}" -f $marker, $Name, $Detail) -ForegroundColor $colour

    if ($env:GITHUB_ACTIONS -eq 'true') {
        if ($Status -eq 'Fail') { Write-Host "::error::[$Group] $Name - $Detail" }
        if ($Status -eq 'Warn') { Write-Host "::warning::[$Group] $Name - $Detail" }
    }
}

function Write-Group {
    param([Parameter(Mandatory)] [string] $Title)
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * 96) -ForegroundColor DarkGray
}

function Get-SafeProperty {
    <#
        Reads a property that may be absent from an Azure CLI response without terminating under
        Set-StrictMode. A missing property becomes an empty string, which surfaces as a failed
        assertion rather than an unhandled exception.
    #>
    param(
        [Parameter()] $InputObject,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter()] $Default = ''
    )

    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Invoke-AzJson {
    <#
        Runs an Azure CLI command and returns the parsed result, or $null when the resource does
        not exist. Errors are suppressed so that a missing resource becomes a failed check rather
        than a terminating exception.
    #>
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $raw = & az @Arguments --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($raw | Out-String))) {
        return $null
    }
    try {
        return ($raw | ConvertFrom-Json -Depth 30)
    }
    catch {
        return $null
    }
}

function Test-TagSet {
    param(
        [Parameter(Mandatory)] [string] $Group,
        [Parameter(Mandatory)] [string] $ResourceName,
        [Parameter()] $Tags
    )

    if (-not $Tags) {
        Add-Check -Group $Group -Name "Provenance tags on $ResourceName" -Status 'Fail' `
            -Expected ($ProvenanceTags -join ', ') -Actual 'none' `
            -Detail 'Resource carries no tags. It cannot be traced to an approved change.'
        return
    }

    $present = $Tags.PSObject.Properties.Name
    $missing = $ProvenanceTags | Where-Object { $present -notcontains $_ }

    if ($missing) {
        Add-Check -Group $Group -Name "Provenance tags on $ResourceName" -Status 'Fail' `
            -Expected ($ProvenanceTags -join ', ') -Actual ($present -join ', ') `
            -Detail "Missing provenance tags: $($missing -join ', ')."
    }
    else {
        Add-Check -Group $Group -Name "Provenance tags on $ResourceName" -Status 'Pass' `
            -Expected ($ProvenanceTags -join ', ') -Actual "ChangeRequest=$($Tags.ChangeRequest), SourceCommit=$($Tags.SourceCommit)" `
            -Detail 'Traceable to an approved change.'
    }
}

# -------------------------------------------------------------------------------------------------
# Context
# -------------------------------------------------------------------------------------------------

Write-Host ''
Write-Host 'Azure Migration Deployment Factory - post-deployment verification' -ForegroundColor White

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI was not found on PATH. Install version 2.61.0 or later.'
}

if (-not (Invoke-AzJson -Arguments @('account', 'show'))) {
    throw 'Not signed in to Azure. Run "az login" and retry.'
}

az account set --subscription $SubscriptionId | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Unable to select subscription $SubscriptionId."
}

$configuration = Get-Content -Path $ParameterFile -Raw | ConvertFrom-Json -Depth 20
$parameters = $configuration.parameters
$supplied = $parameters.PSObject.Properties.Name

function Get-ParameterValue {
    param([Parameter(Mandatory)] [string] $Name, [Parameter()] $Default = $null)
    if ($supplied -contains $Name -and $parameters.$Name.PSObject.Properties.Name -contains 'value') {
        return $parameters.$Name.value
    }
    return $Default
}

$customerCode = Get-ParameterValue -Name 'customerCode'
$customerName = Get-ParameterValue -Name 'customerName'
$environment = Get-ParameterValue -Name 'environment'
$workloadName = Get-ParameterValue -Name 'workloadName' -Default 'mig'
$location = Get-ParameterValue -Name 'location'
$vnetPrefix = Get-ParameterValue -Name 'virtualNetworkAddressPrefix'
$sqlSubnetPrefix = Get-ParameterValue -Name 'sqlManagedInstanceSubnetPrefix'
$expectedRetention = Get-ParameterValue -Name 'logRetentionInDays' -Default 90
$deploySqlMi = Get-ParameterValue -Name 'deploySqlManagedInstance' -Default $true
$expectedEnforcement = Get-ParameterValue -Name 'policyEnforcementMode' -Default 'Default'
$deployGovernance = Get-ParameterValue -Name 'deployGovernance' -Default $true

$regionAbbreviation = if ($RegionAbbreviations.ContainsKey($location)) { $RegionAbbreviations[$location] } else { $location.Substring(0, [Math]::Min(4, $location.Length)) }
$suffix = "$customerCode-$workloadName-$environment-$regionAbbreviation"

$resourceGroups = [ordered]@{
    network    = "rg-$suffix-network"
    management = "rg-$suffix-management"
    security   = "rg-$suffix-security"
    data       = "rg-$suffix-data"
}

$virtualNetworkName = "vnet-$suffix-001"
$workspaceName = "log-$suffix-001"
$vaultName = "rsv-$suffix-001"
$policyAssignmentName = "assign-migration-gov-$customerCode-$environment"

Write-Host "Customer      : $customerName ($customerCode)" -ForegroundColor DarkGray
Write-Host "Environment   : $environment" -ForegroundColor DarkGray
Write-Host "Region        : $location ($regionAbbreviation)" -ForegroundColor DarkGray
Write-Host "Subscription  : $SubscriptionId" -ForegroundColor DarkGray

# -------------------------------------------------------------------------------------------------
# A. Resource organisation
# -------------------------------------------------------------------------------------------------

Write-Group 'A. Resource organisation'

$existingGroups = @{}
foreach ($entry in $resourceGroups.GetEnumerator()) {
    $group = Invoke-AzJson -Arguments @('group', 'show', '--name', $entry.Value)
    if ($group) {
        $existingGroups[$entry.Key] = $group
        Add-Check -Group 'A' -Name "Resource group $($entry.Value)" -Status 'Pass' `
            -Expected 'Exists' -Actual $group.properties.provisioningState -Detail "Provisioned in $($group.location)."
        Test-TagSet -Group 'A' -ResourceName $entry.Value -Tags $group.tags
    }
    else {
        Add-Check -Group 'A' -Name "Resource group $($entry.Value)" -Status 'Fail' `
            -Expected 'Exists' -Actual 'Not found' -Detail 'The expected resource group was not created.'
    }
}

# -------------------------------------------------------------------------------------------------
# B. Provenance across the estate
# -------------------------------------------------------------------------------------------------

Write-Group 'B. Deployment provenance'

$allResources = Invoke-AzJson -Arguments @('resource', 'list', '--subscription', $SubscriptionId)
if ($allResources) {
    $inScope = @($allResources | Where-Object { $resourceGroups.Values -contains $_.resourceGroup })
    $untagged = @($inScope | Where-Object {
            $tags = $_.tags
            (-not $tags) -or (($ProvenanceTags | Where-Object { $tags.PSObject.Properties.Name -notcontains $_ }).Count -gt 0)
        })

    if ($inScope.Count -eq 0) {
        Add-Check -Group 'B' -Name 'Resources present in the landing zone' -Status 'Fail' `
            -Expected 'One or more' -Actual '0' -Detail 'No resources were found in the expected resource groups.'
    }
    elseif ($untagged.Count -gt 0) {
        Add-Check -Group 'B' -Name 'All resources carry provenance tags' -Status 'Fail' `
            -Expected "$($inScope.Count) of $($inScope.Count)" -Actual "$($inScope.Count - $untagged.Count) of $($inScope.Count)" `
            -Detail "Untagged resources: $(($untagged | Select-Object -First 5 -ExpandProperty name) -join ', ')."
    }
    else {
        Add-Check -Group 'B' -Name 'All resources carry provenance tags' -Status 'Pass' `
            -Expected "$($inScope.Count) of $($inScope.Count)" -Actual "$($inScope.Count) of $($inScope.Count)" `
            -Detail 'Every resource can be traced to an approved change.'
    }
}
else {
    Add-Check -Group 'B' -Name 'Resource inventory' -Status 'Fail' -Detail 'The resource inventory could not be read.'
}

# -------------------------------------------------------------------------------------------------
# C. Networking
# -------------------------------------------------------------------------------------------------

Write-Group 'C. Networking'

$vnet = Invoke-AzJson -Arguments @('network', 'vnet', 'show', '--resource-group', $resourceGroups.network, '--name', $virtualNetworkName)

if (-not $vnet) {
    Add-Check -Group 'C' -Name "Virtual network $virtualNetworkName" -Status 'Fail' `
        -Expected 'Exists' -Actual 'Not found' -Detail 'The landing zone virtual network was not created.'
}
else {
    Add-Check -Group 'C' -Name "Virtual network $virtualNetworkName" -Status 'Pass' `
        -Expected $vnetPrefix -Actual ($vnet.addressSpace.addressPrefixes -join ', ') -Detail 'Virtual network provisioned.'

    if ($vnet.addressSpace.addressPrefixes -notcontains $vnetPrefix) {
        Add-Check -Group 'C' -Name 'Virtual network address space' -Status 'Fail' `
            -Expected $vnetPrefix -Actual ($vnet.addressSpace.addressPrefixes -join ', ') `
            -Detail 'The deployed address space does not match the approved configuration.'
    }
    else {
        Add-Check -Group 'C' -Name 'Virtual network address space' -Status 'Pass' `
            -Expected $vnetPrefix -Actual $vnetPrefix -Detail 'Matches the approved configuration.'
    }

    foreach ($expectedSubnet in @('snet-app', 'snet-data', 'snet-sqlmi', 'snet-pep')) {
        $subnet = $vnet.subnets | Where-Object { $_.name -eq $expectedSubnet }
        if ($subnet) {
            $nsgState = if ($subnet.PSObject.Properties.Name -contains 'networkSecurityGroup' -and $subnet.networkSecurityGroup) { 'protected' } else { 'unprotected' }
            $status = if ($nsgState -eq 'protected') { 'Pass' } else { 'Fail' }
            Add-Check -Group 'C' -Name "Subnet $expectedSubnet" -Status $status `
                -Expected 'Exists and protected by a network security group' -Actual "$($subnet.addressPrefix), $nsgState" `
                -Detail $(if ($status -eq 'Pass') { 'Subnet present and protected.' } else { 'Subnet has no network security group attached.' })
        }
        else {
            Add-Check -Group 'C' -Name "Subnet $expectedSubnet" -Status 'Fail' `
                -Expected 'Exists' -Actual 'Not found' -Detail 'A required subnet is missing.'
        }
    }

    $sqlSubnet = $vnet.subnets | Where-Object { $_.name -eq 'snet-sqlmi' }
    if ($sqlSubnet) {
        $delegation = $sqlSubnet.delegations | Where-Object { $_.serviceName -eq 'Microsoft.Sql/managedInstances' }
        if ($delegation) {
            Add-Check -Group 'C' -Name 'SQL Managed Instance subnet delegation' -Status 'Pass' `
                -Expected 'Microsoft.Sql/managedInstances' -Actual $delegation.serviceName -Detail 'Subnet is correctly delegated.'
        }
        else {
            Add-Check -Group 'C' -Name 'SQL Managed Instance subnet delegation' -Status 'Fail' `
                -Expected 'Microsoft.Sql/managedInstances' -Actual 'none' -Detail 'The managed instance cannot be deployed into an undelegated subnet.'
        }

        if ($sqlSubnet.PSObject.Properties.Name -contains 'routeTable' -and $sqlSubnet.routeTable) {
            Add-Check -Group 'C' -Name 'SQL Managed Instance subnet route table' -Status 'Pass' `
                -Expected 'Attached' -Actual 'Attached' -Detail 'The user-defined route required by the service is present.'
        }
        else {
            Add-Check -Group 'C' -Name 'SQL Managed Instance subnet route table' -Status 'Fail' `
                -Expected 'Attached' -Actual 'None' -Detail 'A route table with an internet default route is mandatory for this subnet.'
        }

        if ($sqlSubnetPrefix -and $sqlSubnet.addressPrefix -ne $sqlSubnetPrefix) {
            Add-Check -Group 'C' -Name 'SQL Managed Instance subnet prefix' -Status 'Fail' `
                -Expected $sqlSubnetPrefix -Actual $sqlSubnet.addressPrefix -Detail 'The deployed prefix does not match the approved configuration.'
        }
    }

    $sqlNsgName = "nsg-snet-sqlmi-$virtualNetworkName"
    $sqlNsg = Invoke-AzJson -Arguments @('network', 'nsg', 'show', '--resource-group', $resourceGroups.network, '--name', $sqlNsgName)
    if ($sqlNsg) {
        $requiredRules = @('allow_management_inbound', 'allow_misubnet_inbound', 'allow_health_probe_inbound', 'allow_management_outbound', 'allow_misubnet_outbound')
        $presentRules = @($sqlNsg.securityRules | Select-Object -ExpandProperty name)
        $missingRules = $requiredRules | Where-Object { $presentRules -notcontains $_ }
        if ($missingRules) {
            Add-Check -Group 'C' -Name 'SQL Managed Instance network security rules' -Status 'Fail' `
                -Expected ($requiredRules -join ', ') -Actual ($presentRules -join ', ') `
                -Detail "Missing mandatory rules: $($missingRules -join ', ')."
        }
        else {
            Add-Check -Group 'C' -Name 'SQL Managed Instance network security rules' -Status 'Pass' `
                -Expected "$($requiredRules.Count) mandatory rules" -Actual "$($presentRules.Count) rules present" `
                -Detail 'All mandatory service rules are present.'
        }
    }
    else {
        Add-Check -Group 'C' -Name 'SQL Managed Instance network security group' -Status 'Fail' `
            -Expected $sqlNsgName -Actual 'Not found' -Detail 'The network security group protecting the managed instance subnet is missing.'
    }
}

# -------------------------------------------------------------------------------------------------
# D. Identity and secrets
# -------------------------------------------------------------------------------------------------

Write-Group 'D. Identity and secrets'

$vaults = Invoke-AzJson -Arguments @('resource', 'list', '--resource-group', $resourceGroups.security, '--resource-type', 'Microsoft.KeyVault/vaults')
if ($vaults -and @($vaults).Count -gt 0) {
    $keyVaultName = @($vaults)[0].name
    $keyVault = Invoke-AzJson -Arguments @('keyvault', 'show', '--name', $keyVaultName)

    if ($keyVault) {
        Add-Check -Group 'D' -Name "Key Vault $keyVaultName" -Status 'Pass' -Expected 'Exists' -Actual 'Exists' -Detail 'Key Vault provisioned.'

        $assertions = @(
            @{ Name = 'Key Vault soft delete';            Expected = 'true';     Actual = "$($keyVault.properties.enableSoftDelete)";        Detail = 'Protects secrets from accidental deletion.' }
            @{ Name = 'Key Vault purge protection';       Expected = 'true';     Actual = "$($keyVault.properties.enablePurgeProtection)";   Detail = 'Prevents permanent destruction of encryption material.' }
            @{ Name = 'Key Vault RBAC authorisation';     Expected = 'true';     Actual = "$($keyVault.properties.enableRbacAuthorization)"; Detail = 'Permissions are visible in the standard access review.' }
            @{ Name = 'Key Vault public network access';  Expected = 'Disabled'; Actual = "$($keyVault.properties.publicNetworkAccess)";     Detail = 'The vault must not be reachable from the internet.' }
        )

        foreach ($assertion in $assertions) {
            $status = if ($assertion.Actual -eq $assertion.Expected) { 'Pass' } else { 'Fail' }
            Add-Check -Group 'D' -Name $assertion.Name -Status $status -Expected $assertion.Expected -Actual $assertion.Actual -Detail $assertion.Detail
        }
    }
}
else {
    Add-Check -Group 'D' -Name 'Key Vault' -Status 'Fail' -Expected 'Exists' -Actual 'Not found' `
        -Detail "No Key Vault was found in $($resourceGroups.security)."
}

$identities = Invoke-AzJson -Arguments @('resource', 'list', '--resource-group', $resourceGroups.security, '--resource-type', 'Microsoft.ManagedIdentity/userAssignedIdentities')
if ($identities -and @($identities).Count -gt 0) {
    Add-Check -Group 'D' -Name 'Migration automation managed identity' -Status 'Pass' `
        -Expected 'Exists' -Actual @($identities)[0].name -Detail 'Automation runs without a shared credential.'
}
else {
    Add-Check -Group 'D' -Name 'Migration automation managed identity' -Status 'Fail' `
        -Expected 'Exists' -Actual 'Not found' -Detail 'The user-assigned managed identity was not created.'
}

# -------------------------------------------------------------------------------------------------
# E. Monitoring
# -------------------------------------------------------------------------------------------------

Write-Group 'E. Monitoring'

$workspace = Invoke-AzJson -Arguments @('monitor', 'log-analytics', 'workspace', 'show', '--resource-group', $resourceGroups.management, '--workspace-name', $workspaceName)
if ($workspace) {
    Add-Check -Group 'E' -Name "Log Analytics workspace $workspaceName" -Status 'Pass' `
        -Expected 'Exists' -Actual $workspace.provisioningState -Detail 'Central telemetry destination provisioned.'

    $actualRetention = $workspace.retentionInDays
    $status = if ($actualRetention -ge $expectedRetention) { 'Pass' } else { 'Fail' }
    Add-Check -Group 'E' -Name 'Telemetry retention' -Status $status `
        -Expected "$expectedRetention days" -Actual "$actualRetention days" `
        -Detail $(if ($status -eq 'Pass') { 'Meets the contracted retention period.' } else { 'Retention is shorter than the approved configuration.' })
}
else {
    Add-Check -Group 'E' -Name "Log Analytics workspace $workspaceName" -Status 'Fail' `
        -Expected 'Exists' -Actual 'Not found' -Detail 'Without the workspace there is no audit or diagnostic destination.'
}

# -------------------------------------------------------------------------------------------------
# F. Data protection
# -------------------------------------------------------------------------------------------------

Write-Group 'F. Data protection'

$vault = Invoke-AzJson -Arguments @('resource', 'show', '--resource-group', $resourceGroups.management, '--name', $vaultName, '--resource-type', 'Microsoft.RecoveryServices/vaults')
if ($vault) {
    Add-Check -Group 'F' -Name "Recovery Services Vault $vaultName" -Status 'Pass' `
        -Expected 'Exists' -Actual 'Exists' -Detail 'Backup vault provisioned.'

    $backupProperties = Invoke-AzJson -Arguments @('backup', 'vault', 'backup-properties', 'show', '--name', $vaultName, '--resource-group', $resourceGroups.management)
    if ($backupProperties) {
        $softDelete = "$(Get-SafeProperty -InputObject $backupProperties -Name 'softDeleteFeatureState' -Default 'Unknown')"
        $status = if ($softDelete -match 'Enabled|AlwaysON') { 'Pass' } else { 'Fail' }
        Add-Check -Group 'F' -Name 'Backup soft delete' -Status $status `
            -Expected 'Enabled' -Actual $softDelete -Detail 'Protects recovery points from malicious or accidental deletion.'
    }
    else {
        Add-Check -Group 'F' -Name 'Backup soft delete' -Status 'Warn' `
            -Expected 'Enabled' -Actual 'Unknown' -Detail 'Backup properties could not be read. Confirm manually.'
    }

    $policies = Invoke-AzJson -Arguments @('backup', 'policy', 'list', '--vault-name', $vaultName, '--resource-group', $resourceGroups.management)
    $policyNames = if ($policies) { @($policies | Select-Object -ExpandProperty name) } else { @() }
    if ($policyNames -contains 'policy-vm-daily') {
        Add-Check -Group 'F' -Name 'Virtual machine backup policy' -Status 'Pass' `
            -Expected 'policy-vm-daily' -Actual 'policy-vm-daily' -Detail 'Migrated virtual machines have a policy to register against.'
    }
    else {
        Add-Check -Group 'F' -Name 'Virtual machine backup policy' -Status 'Fail' `
            -Expected 'policy-vm-daily' -Actual ($policyNames -join ', ') -Detail 'The standard virtual machine backup policy is missing.'
    }
}
else {
    Add-Check -Group 'F' -Name "Recovery Services Vault $vaultName" -Status 'Fail' `
        -Expected 'Exists' -Actual 'Not found' -Detail 'No backup vault means migrated workloads cannot be protected.'
}

# -------------------------------------------------------------------------------------------------
# G. Governance
# -------------------------------------------------------------------------------------------------

Write-Group 'G. Governance'

if ($deployGovernance) {
    $assignment = Invoke-AzJson -Arguments @('policy', 'assignment', 'show', '--name', $policyAssignmentName, '--scope', "/subscriptions/$SubscriptionId")
    if ($assignment) {
        Add-Check -Group 'G' -Name "Policy assignment $policyAssignmentName" -Status 'Pass' `
            -Expected 'Exists' -Actual 'Exists' -Detail 'The migration governance baseline is assigned.'

        $actualEnforcement = "$($assignment.enforcementMode)"
        $status = if ($actualEnforcement -eq $expectedEnforcement) { 'Pass' } else { 'Fail' }
        Add-Check -Group 'G' -Name 'Policy enforcement mode' -Status $status `
            -Expected $expectedEnforcement -Actual $actualEnforcement `
            -Detail $(if ($status -eq 'Pass') { 'Enforcement matches the approved configuration.' } else { 'Governance is not enforcing as configured.' })
    }
    else {
        Add-Check -Group 'G' -Name "Policy assignment $policyAssignmentName" -Status 'Fail' `
            -Expected 'Exists' -Actual 'Not found' -Detail 'Without the assignment the governance controls are not in force.'
    }
}
else {
    Add-Check -Group 'G' -Name 'Governance assignment' -Status 'Skip' -Detail 'Governance is disabled in this configuration.'
}

# -------------------------------------------------------------------------------------------------
# H. Database platform
# -------------------------------------------------------------------------------------------------

Write-Group 'H. Database platform'

if (-not $deploySqlMi) {
    Add-Check -Group 'H' -Name 'SQL Managed Instance' -Status 'Skip' -Detail 'Not in scope for this configuration.'
}
else {
    $instances = Invoke-AzJson -Arguments @('resource', 'list', '--resource-group', $resourceGroups.data, '--resource-type', 'Microsoft.Sql/managedInstances')
    if (-not $instances -or @($instances).Count -eq 0) {
        Add-Check -Group 'H' -Name 'SQL Managed Instance' -Status 'Fail' `
            -Expected 'Exists' -Actual 'Not found' -Detail "No managed instance was found in $($resourceGroups.data)."
    }
    else {
        $instanceName = @($instances)[0].name
        $instance = Invoke-AzJson -Arguments @('sql', 'mi', 'show', '--resource-group', $resourceGroups.data, '--name', $instanceName)

        if (-not $instance) {
            Add-Check -Group 'H' -Name "SQL Managed Instance $instanceName" -Status 'Fail' `
                -Expected 'Readable' -Actual 'Unavailable' -Detail 'The managed instance could not be read.'
        }
        else {
            $sku = Get-SafeProperty -InputObject $instance -Name 'sku'
            $tier = Get-SafeProperty -InputObject $sku -Name 'tier' -Default 'unknown'
            $cores = Get-SafeProperty -InputObject $instance -Name 'vCores' -Default 'unknown'
            $storage = Get-SafeProperty -InputObject $instance -Name 'storageSizeInGb' -Default 'unknown'
            $state = Get-SafeProperty -InputObject $instance -Name 'state' -Default 'unknown'

            Add-Check -Group 'H' -Name "SQL Managed Instance $instanceName" -Status 'Pass' `
                -Expected 'Exists' -Actual "$state" -Detail "Tier $tier, $cores vCores, $storage GB."

            $publicEndpoint = "$(Get-SafeProperty -InputObject $instance -Name 'publicDataEndpointEnabled' -Default 'unknown')"
            $status = if ($publicEndpoint -in @('False', 'false')) { 'Pass' } else { 'Fail' }
            Add-Check -Group 'H' -Name 'Public data endpoint disabled' -Status $status `
                -Expected 'False' -Actual $publicEndpoint `
                -Detail 'No migrated database may be reachable from the public internet.'

            $tls = "$(Get-SafeProperty -InputObject $instance -Name 'minimalTlsVersion' -Default 'unknown')"
            $status = if ($tls -in @('1.2', '1.3')) { 'Pass' } else { 'Fail' }
            Add-Check -Group 'H' -Name 'Minimum TLS version' -Status $status `
                -Expected '1.2 or higher' -Actual $tls -Detail 'Legacy transport security is prohibited.'

            $expectedDatabases = @(Get-ParameterValue -Name 'sqlDatabases' -Default @() | ForEach-Object { $_.name })
            if ($expectedDatabases.Count -gt 0) {
                $databases = Invoke-AzJson -Arguments @('sql', 'midb', 'list', '--resource-group', $resourceGroups.data, '--managed-instance', $instanceName)
                $actualDatabases = if ($databases) { @($databases | Select-Object -ExpandProperty name) } else { @() }
                $missingDatabases = $expectedDatabases | Where-Object { $actualDatabases -notcontains $_ }

                if ($missingDatabases) {
                    Add-Check -Group 'H' -Name 'Managed databases' -Status 'Fail' `
                        -Expected ($expectedDatabases -join ', ') -Actual ($actualDatabases -join ', ') `
                        -Detail "Missing databases: $($missingDatabases -join ', ')."
                }
                else {
                    Add-Check -Group 'H' -Name 'Managed databases' -Status 'Pass' `
                        -Expected "$($expectedDatabases.Count) databases" -Actual "$($actualDatabases.Count) databases" `
                        -Detail 'All approved databases are present.'
                }
            }

            $diagnostics = Invoke-AzJson -Arguments @('monitor', 'diagnostic-settings', 'list', '--resource', $instance.id)
            $diagnosticItems = if ($diagnostics -is [array]) { $diagnostics } else { Get-SafeProperty -InputObject $diagnostics -Name 'value' -Default @() }
            $diagnosticCount = @($diagnosticItems).Count
            if ($diagnosticCount -gt 0) {
                Add-Check -Group 'H' -Name 'Managed instance diagnostic settings' -Status 'Pass' `
                    -Expected 'At least one' -Actual "$diagnosticCount" -Detail 'Audit and diagnostic data is being collected.'
            }
            else {
                Add-Check -Group 'H' -Name 'Managed instance diagnostic settings' -Status 'Fail' `
                    -Expected 'At least one' -Actual '0' -Detail 'Without diagnostic settings the auditing configuration has no destination.'
            }
        }
    }
}

# -------------------------------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------------------------------

Write-Host ''
Write-Host ('=' * 96) -ForegroundColor DarkCyan
Write-Host 'Verification summary' -ForegroundColor Cyan
Write-Host ('=' * 96) -ForegroundColor DarkCyan

$summary = [ordered]@{
    Pass = @($Checks | Where-Object Status -EQ 'Pass').Count
    Warn = @($Checks | Where-Object Status -EQ 'Warn').Count
    Fail = @($Checks | Where-Object Status -EQ 'Fail').Count
    Skip = @($Checks | Where-Object Status -EQ 'Skip').Count
}

$Checks | Group-Object Group | ForEach-Object {
    $failed = @($_.Group | Where-Object Status -EQ 'Fail').Count
    $outcome = if ($failed -gt 0) { "FAIL ($failed)" } else { 'PASS' }
    Write-Host ("  Group {0}: {1,-10} {2} checks" -f $_.Name, $outcome, $_.Count)
}

Write-Host ''
Write-Host ("Passed: {0}   Warnings: {1}   Failures: {2}   Skipped: {3}" -f $summary.Pass, $summary.Warn, $summary.Fail, $summary.Skip)

if ($OutputPath) {
    $record = [ordered]@{
        evidenceType   = 'PostDeploymentVerification'
        control        = '3.1 Repeatable Deployment'
        customer       = $customerName
        customerCode   = $customerCode
        environment    = $environment
        region         = $location
        subscriptionId = $SubscriptionId
        parameterFile  = $ParameterFile
        executedUtc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        outcome        = $(if ($summary.Fail -gt 0) { 'Fail' } else { 'Pass' })
        summary        = $summary
        checks         = @($Checks)
    }

    $directory = Split-Path -Parent $OutputPath
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $record | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding utf8
    Write-Host "Verification record written to $OutputPath" -ForegroundColor DarkGray
}

if ($summary.Fail -gt 0 -and -not $WarnOnly) {
    Write-Host ''
    Write-Host 'VERIFICATION FAILED. Do not sign off this deployment. Raise a defect and remediate.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'VERIFICATION PASSED.' -ForegroundColor Green
exit 0
