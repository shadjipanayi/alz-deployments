metadata name = 'Azure Infrastructure and Database Migration Landing Zone'
metadata description = '''
Subscription-scope orchestrator for a repeatable Azure migration landing zone.

This is the single entry point used by every customer engagement delivered by this practice. It
creates four purpose-scoped resource groups and coordinates the networking, identity, monitoring
and data protection, governance, and database platform modules. A new customer is onboarded by
adding a parameter file under parameters/ - no template in this repository is copied, forked or
edited per engagement.

Every resource deployed through this template receives the mandatory provenance tag set, which
allows any live Azure resource to be traced back to the approved change request, the reviewed
commit, and the pipeline run that created it. See docs/Audit_Evidence_Guide.md.
'''
metadata owner = 'Principal Azure Architect'

targetScope = 'subscription'

// =================================================================================================
// Customer identity
// =================================================================================================

@description('Required. Short lowercase customer code used in every resource name, for example ctso. Kept short so that globally unique names remain within service limits.')
@minLength(2)
@maxLength(6)
param customerCode string

@description('Required. Full customer legal or trading name, recorded as a tag for cost attribution and audit.')
@minLength(2)
param customerName string

@description('Required. Environment being deployed.')
@allowed([
  'dev'
  'tst'
  'uat'
  'prd'
])
param environment string

@description('Optional. Short workload moniker used in resource names, for example mig for a migration landing zone.')
@minLength(2)
@maxLength(8)
param workloadName string = 'mig'

@description('Required. Primary Azure region for the landing zone. Must be inside the customer data residency agreement.')
param location string

@description('Required. Cost centre or internal charge code recorded as a tag.')
param costCentre string

@description('Required. Email address of the accountable technical owner, recorded as a tag.')
param ownerEmail string

@description('Optional. Highest data classification the environment is approved to hold.')
@allowed([
  'Public'
  'Internal'
  'Confidential'
  'Restricted'
])
param dataClassification string = 'Confidential'

@description('Optional. Additional customer-specific tags merged into the standard tag set.')
param additionalTags object = {}

// =================================================================================================
// Deployment provenance - supplied by the CI/CD pipeline
// =================================================================================================

@description('Required. Identifier of the approved change request authorising this deployment, for example CR-0142. Validated by the pipeline before deployment begins.')
@minLength(4)
param changeRequestId string

@description('Optional. Repository that produced this deployment.')
param sourceRepository string = 'example-partner/alz-deployments'

@description('Optional. Short commit SHA of the reviewed commit that produced this deployment.')
param sourceCommit string = 'local'

@description('Optional. Identifier of the pipeline run that produced this deployment. Set to "manual" for an authorised workstation deployment to a development subscription.')
param deploymentId string = 'manual'

@description('Optional. UTC timestamp at which the deployment was initiated.')
param deploymentTimestamp string = utcNow('yyyy-MM-ddTHH:mm:ssZ')

// =================================================================================================
// Networking
// =================================================================================================

@description('Required. Address space of the landing zone virtual network in CIDR notation.')
param virtualNetworkAddressPrefix string

@description('Required. Address prefix of the application tier subnet.')
param applicationSubnetPrefix string

@description('Required. Address prefix of the data tier subnet.')
param dataSubnetPrefix string

@description('Required. Address prefix of the SQL Managed Instance subnet. A /24 is recommended.')
param sqlManagedInstanceSubnetPrefix string

@description('Required. Address prefix of the private endpoint subnet.')
param privateEndpointSubnetPrefix string

@description('Optional. Deploy an AzureBastionSubnet for secure administrative access during the migration.')
param deployBastionSubnet bool = false

@description('Optional. Address prefix of the AzureBastionSubnet. Required when deployBastionSubnet is true.')
param bastionSubnetPrefix string = ''

@description('Optional. Customer DNS servers, normally the on-premises or Azure-hosted domain controllers. Leave empty to use Azure-provided DNS.')
param customDnsServers array = []

@description('Optional. Resource ID of a connectivity hub virtual network to peer with.')
param hubVirtualNetworkResourceId string = ''

@description('Optional. Route application and data subnet egress through a hub network virtual appliance.')
param routeThroughHubAppliance bool = false

@description('Optional. Private IP address of the hub network virtual appliance.')
param nextHopApplianceIpAddress string = ''

// =================================================================================================
// Identity and secrets
// =================================================================================================

@description('Optional. Explicit Key Vault name. Leave empty to derive a deterministic globally unique name. Set explicitly where the customer has a naming mandate.')
@maxLength(24)
param keyVaultName string = ''

@description('Optional. Key Vault pricing tier.')
@allowed([
  'standard'
  'premium'
])
param keyVaultSku string = 'standard'

@description('Optional. Create a private endpoint for the Key Vault in the private endpoint subnet.')
param deployKeyVaultPrivateEndpoint bool = true

@description('Optional. Resource ID of the privatelink.vaultcore.azure.net private DNS zone.')
param keyVaultPrivateDnsZoneId string = ''

@description('Optional. Microsoft Entra object ID of the customer platform administrator group.')
param platformAdministratorGroupObjectId string = ''

@description('Optional. Microsoft Entra object ID of the customer database administrator group.')
param databaseAdministratorGroupObjectId string = ''

@description('Optional. Microsoft Entra object ID of the customer audit or read-only group.')
param auditorGroupObjectId string = ''

// =================================================================================================
// Monitoring and data protection
// =================================================================================================

@description('Optional. Telemetry retention in the Log Analytics workspace, in days.')
@minValue(30)
@maxValue(730)
param logRetentionInDays int = 90

@description('Optional. Daily Log Analytics ingestion cap in gigabytes. Use -1 for no cap.')
param dailyQuotaInGb int = -1

@description('Optional. Distribution group that receives platform alerts for this environment.')
param alertEmailAddress string = ''

@description('Optional. Storage redundancy of the Recovery Services Vault.')
@allowed([
  'LocallyRedundant'
  'GeoRedundant'
  'ZoneRedundant'
])
param backupStorageRedundancy string = 'GeoRedundant'

@description('Optional. Time zone used to schedule backup jobs.')
param backupTimeZone string = 'UTC'

@description('Optional. Daily backup start time expressed as a full UTC timestamp.')
param backupScheduleTimeUtc string = '2026-01-01T22:00:00Z'

@description('Optional. Number of daily virtual machine recovery points retained.')
@minValue(7)
param dailyRetentionInDays int = 30

@description('Optional. Number of weekly virtual machine recovery points retained.')
@minValue(1)
param weeklyRetentionInWeeks int = 12

@description('Optional. Number of monthly virtual machine recovery points retained.')
@minValue(1)
param monthlyRetentionInMonths int = 12

@description('Optional. Number of yearly virtual machine recovery points retained.')
@minValue(1)
param yearlyRetentionInYears int = 3

@description('Optional. Deploy the SQL Server in Azure Virtual Machine backup policy.')
param deploySqlBackupPolicy bool = true

// =================================================================================================
// Governance
// =================================================================================================

@description('Optional. Deploy the migration governance initiative and assignment.')
param deployGovernance bool = true

@description('Required. Azure regions the customer is permitted to deploy into.')
@minLength(1)
param allowedLocations array

@description('Optional. Enforcement mode of the governance assignment.')
@allowed([
  'Default'
  'DoNotEnforce'
])
param policyEnforcementMode string = 'Default'

@description('Optional. Resource group names excluded from the governance assignment. Documented, time-bound exceptions only.')
param policyExcludedResourceGroupNames array = []

// =================================================================================================
// SQL Managed Instance
// =================================================================================================

@description('Optional. Deploy the Azure SQL Managed Instance. Set to false for waves that contain no homogeneous database migration.')
param deploySqlManagedInstance bool = true

@description('Optional. Explicit SQL Managed Instance name. Leave empty to derive a deterministic globally unique name.')
@maxLength(63)
param sqlManagedInstanceName string = ''

@description('Optional. SQL authentication administrator login for the managed instance.')
@minLength(4)
param sqlAdministratorLogin string = 'sqlmigrationadmin'

@description('Optional. SQL authentication administrator password, supplied as a Key Vault reference from the customer parameter file. Required when deploySqlManagedInstance is true.')
@secure()
param sqlAdministratorPassword string = ''

@description('Optional. SQL Managed Instance service tier.')
@allowed([
  'GeneralPurpose'
  'BusinessCritical'
])
param sqlServiceTier string = 'GeneralPurpose'

@description('Optional. SQL Managed Instance SKU name.')
@allowed([
  'GP_Gen5'
  'GP_G8IM'
  'GP_G8IH'
  'BC_Gen5'
  'BC_G8IM'
  'BC_G8IH'
])
param sqlSkuName string = 'GP_Gen5'

@description('Optional. Number of virtual cores allocated to the managed instance.')
@allowed([
  4
  8
  16
  24
  32
  40
  64
  80
])
param sqlVCores int = 8

@description('Optional. Reserved managed instance storage in gigabytes. Must be a multiple of 32.')
@minValue(32)
@maxValue(16384)
param sqlStorageSizeInGB int = 256

@description('Optional. Managed instance licensing model. Use BasePrice to apply Azure Hybrid Benefit.')
@allowed([
  'LicenseIncluded'
  'BasePrice'
])
param sqlLicenseType string = 'LicenseIncluded'

@description('Optional. Managed instance collation. Must match the source SQL Server instance.')
param sqlCollation string = 'SQL_Latin1_General_CP1_CI_AS'

@description('Optional. Managed instance time zone. Must match the source SQL Server instance where applications depend on local date arithmetic.')
param sqlTimezoneId string = 'UTC'

@description('Optional. Managed instance backup storage redundancy.')
@allowed([
  'Geo'
  'GeoZone'
  'Local'
  'Zone'
])
param sqlBackupStorageRedundancy string = 'Geo'

@description('Optional. Deploy the managed instance across availability zones.')
param sqlZoneRedundant bool = false

@description('Optional. Display name of the Microsoft Entra group configured as managed instance administrator.')
param sqlEntraAdministratorName string = ''

@description('Optional. Microsoft Entra object ID of the group configured as managed instance administrator.')
param sqlEntraAdministratorObjectId string = ''

@description('Optional. Disable SQL authentication on the managed instance once all applications use Microsoft Entra authentication.')
param sqlEntraOnlyAuthentication bool = false

@description('Optional. Point-in-time restore history retained for every managed database, in days.')
@minValue(1)
@maxValue(35)
param sqlShortTermRetentionInDays int = 14

@description('Optional. Long-term weekly retention for managed databases, in ISO 8601 duration format.')
param sqlLongTermWeeklyRetention string = 'P12W'

@description('Optional. Long-term monthly retention for managed databases, in ISO 8601 duration format.')
param sqlLongTermMonthlyRetention string = 'P12M'

@description('Optional. Long-term yearly retention for managed databases, in ISO 8601 duration format.')
param sqlLongTermYearlyRetention string = 'P7Y'

@description('Optional. Databases managed on the instance. Each entry is an object with a name property and an optional collation property.')
param sqlDatabases array = []

// =================================================================================================
// Variables
// =================================================================================================

var regionAbbreviations = {
  westeurope: 'weu'
  northeurope: 'neu'
  uksouth: 'uks'
  ukwest: 'ukw'
  swedencentral: 'sec'
  germanywestcentral: 'gwc'
  francecentral: 'frc'
  switzerlandnorth: 'chn'
  norwayeast: 'nwe'
  polandcentral: 'plc'
  italynorth: 'itn'
  eastus: 'eus'
  eastus2: 'eus2'
  centralus: 'cus'
  westus2: 'wus2'
  westus3: 'wus3'
  canadacentral: 'cac'
  uaenorth: 'uan'
  southeastasia: 'sea'
  australiaeast: 'aue'
}

var regionAbbreviation = contains(regionAbbreviations, location) ? regionAbbreviations[location] : take(replace(location, ' ', ''), 4)
var resourceSuffix = '${customerCode}-${workloadName}-${environment}-${regionAbbreviation}'
var uniqueSuffix = take(uniqueString(subscription().subscriptionId, customerCode, workloadName, environment), 6)

var names = {
  networkResourceGroup: 'rg-${resourceSuffix}-network'
  managementResourceGroup: 'rg-${resourceSuffix}-management'
  securityResourceGroup: 'rg-${resourceSuffix}-security'
  dataResourceGroup: 'rg-${resourceSuffix}-data'
  virtualNetwork: 'vnet-${resourceSuffix}-001'
  logAnalyticsWorkspace: 'log-${resourceSuffix}-001'
  recoveryServicesVault: 'rsv-${resourceSuffix}-001'
  managedIdentity: 'id-${resourceSuffix}-001'
  keyVault: empty(keyVaultName) ? 'kv-${customerCode}-${environment}-${uniqueSuffix}' : keyVaultName
  sqlManagedInstance: empty(sqlManagedInstanceName) ? 'sqlmi-${resourceSuffix}-${uniqueSuffix}' : sqlManagedInstanceName
}

// Business and cost attribution tags.
var businessTags = {
  Customer: customerName
  CustomerCode: customerCode
  Environment: environment
  Workload: workloadName
  CostCentre: costCentre
  Owner: ownerEmail
  DataClassification: dataClassification
}

// Provenance tags. These are mandatory, are enforced by the deny policy in bicep/governance.bicep,
// and form the first link of the audit traceability chain described in docs/Audit_Evidence_Guide.md.
var provenanceTags = {
  ManagedBy: 'IaC'
  SourceRepo: sourceRepository
  SourceCommit: sourceCommit
  DeploymentId: deploymentId
  ChangeRequest: changeRequestId
  DeployedUtc: deploymentTimestamp
}

var tags = union(businessTags, provenanceTags, additionalTags)

var deployBastion = deployBastionSubnet && !empty(bastionSubnetPrefix)
var deploySqlPlatform = deploySqlManagedInstance && !empty(sqlAdministratorPassword)

// =================================================================================================
// Resource groups
// =================================================================================================

resource networkResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.networkResourceGroup
  location: location
  tags: union(tags, {
    Purpose: 'Networking'
  })
}

resource managementResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.managementResourceGroup
  location: location
  tags: union(tags, {
    Purpose: 'Monitoring and data protection'
  })
}

resource securityResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.securityResourceGroup
  location: location
  tags: union(tags, {
    Purpose: 'Identity and secrets'
  })
}

resource dataResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: names.dataResourceGroup
  location: location
  tags: union(tags, {
    Purpose: 'Database platform'
  })
}

// =================================================================================================
// Modules
// =================================================================================================

// Monitoring is deployed first because every other module streams diagnostics to its workspace.
module monitoring 'monitoring.bicep' = {
  name: 'deploy-monitoring-${environment}'
  scope: managementResourceGroup
  params: {
    location: location
    tags: tags
    logAnalyticsWorkspaceName: names.logAnalyticsWorkspace
    recoveryServicesVaultName: names.recoveryServicesVault
    logRetentionInDays: logRetentionInDays
    dailyQuotaInGb: dailyQuotaInGb
    alertEmailAddress: alertEmailAddress
    actionGroupShortName: take('${customerCode}${environment}', 12)
    backupStorageRedundancy: backupStorageRedundancy
    backupTimeZone: backupTimeZone
    backupScheduleTimeUtc: backupScheduleTimeUtc
    dailyRetentionInDays: dailyRetentionInDays
    weeklyRetentionInWeeks: weeklyRetentionInWeeks
    monthlyRetentionInMonths: monthlyRetentionInMonths
    yearlyRetentionInYears: yearlyRetentionInYears
    deploySqlBackupPolicy: deploySqlBackupPolicy
  }
}

module networking 'networking.bicep' = {
  name: 'deploy-networking-${environment}'
  scope: networkResourceGroup
  params: {
    location: location
    tags: tags
    virtualNetworkName: names.virtualNetwork
    virtualNetworkAddressPrefix: virtualNetworkAddressPrefix
    applicationSubnetPrefix: applicationSubnetPrefix
    dataSubnetPrefix: dataSubnetPrefix
    sqlManagedInstanceSubnetPrefix: sqlManagedInstanceSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    deployBastionSubnet: deployBastion
    bastionSubnetPrefix: bastionSubnetPrefix
    customDnsServers: customDnsServers
    hubVirtualNetworkResourceId: hubVirtualNetworkResourceId
    routeThroughHubAppliance: routeThroughHubAppliance
    nextHopApplianceIpAddress: nextHopApplianceIpAddress
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    diagnosticRetentionInDays: logRetentionInDays
  }
}

module identity 'identity.bicep' = {
  name: 'deploy-identity-${environment}'
  scope: securityResourceGroup
  params: {
    location: location
    tags: tags
    managedIdentityName: names.managedIdentity
    keyVaultName: names.keyVault
    keyVaultSku: keyVaultSku
    allowPublicNetworkAccess: false
    deployKeyVaultPrivateEndpoint: deployKeyVaultPrivateEndpoint
    privateEndpointSubnetId: networking.outputs.privateEndpointSubnetId
    keyVaultPrivateDnsZoneId: keyVaultPrivateDnsZoneId
    platformAdministratorGroupObjectId: platformAdministratorGroupObjectId
    databaseAdministratorGroupObjectId: databaseAdministratorGroupObjectId
    auditorGroupObjectId: auditorGroupObjectId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module sqlManagedInstance 'sql-managed-instance.bicep' = if (deploySqlPlatform) {
  name: 'deploy-sqlmi-${environment}'
  scope: dataResourceGroup
  params: {
    location: location
    tags: tags
    managedInstanceName: names.sqlManagedInstance
    subnetResourceId: networking.outputs.sqlManagedInstanceSubnetId
    administratorLogin: sqlAdministratorLogin
    administratorLoginPassword: sqlAdministratorPassword
    serviceTier: sqlServiceTier
    skuName: sqlSkuName
    vCores: sqlVCores
    storageSizeInGB: sqlStorageSizeInGB
    licenseType: sqlLicenseType
    collation: sqlCollation
    timezoneId: sqlTimezoneId
    requestedBackupStorageRedundancy: sqlBackupStorageRedundancy
    zoneRedundant: sqlZoneRedundant
    userAssignedIdentityResourceId: identity.outputs.managedIdentityId
    entraAdministratorName: sqlEntraAdministratorName
    entraAdministratorObjectId: sqlEntraAdministratorObjectId
    entraOnlyAuthentication: sqlEntraOnlyAuthentication
    shortTermRetentionInDays: sqlShortTermRetentionInDays
    longTermWeeklyRetention: sqlLongTermWeeklyRetention
    longTermMonthlyRetention: sqlLongTermMonthlyRetention
    longTermYearlyRetention: sqlLongTermYearlyRetention
    databases: sqlDatabases
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module governance 'governance.bicep' = if (deployGovernance) {
  name: 'deploy-governance-${environment}'
  params: {
    customerCode: customerCode
    environment: environment
    location: location
    allowedLocations: allowedLocations
    enforcementMode: policyEnforcementMode
    excludedResourceGroupNames: policyExcludedResourceGroupNames
  }
}

// =================================================================================================
// Outputs - deployment evidence record
// =================================================================================================

@description('Customer code this deployment belongs to.')
output customerCode string = customerCode

@description('Environment this deployment targets.')
output environment string = environment

@description('Azure subscription the deployment targeted.')
output subscriptionId string = subscription().subscriptionId

@description('Change request that authorised this deployment. Recorded as evidence for Control 3.1.')
output changeRequestId string = changeRequestId

@description('Reviewed commit that produced this deployment.')
output sourceCommit string = sourceCommit

@description('Pipeline run that produced this deployment.')
output deploymentId string = deploymentId

@description('UTC timestamp at which the deployment was initiated.')
output deploymentTimestamp string = deploymentTimestamp

@description('Names of the resource groups created by this deployment.')
output resourceGroupNames array = [
  networkResourceGroup.name
  managementResourceGroup.name
  securityResourceGroup.name
  dataResourceGroup.name
]

@description('Resource ID of the landing zone virtual network.')
output virtualNetworkId string = networking.outputs.virtualNetworkId

@description('Resource ID of the SQL Managed Instance subnet.')
output sqlManagedInstanceSubnetId string = networking.outputs.sqlManagedInstanceSubnetId

@description('Resource ID of the Log Analytics workspace.')
output logAnalyticsWorkspaceId string = monitoring.outputs.logAnalyticsWorkspaceId

@description('Resource ID of the Recovery Services Vault.')
output recoveryServicesVaultId string = monitoring.outputs.recoveryServicesVaultId

@description('Name of the Recovery Services Vault.')
output recoveryServicesVaultName string = monitoring.outputs.recoveryServicesVaultName

@description('Name of the Key Vault. This is a resource name, not a secret.')
output keyVaultName string = identity.outputs.keyVaultName

@description('Resource ID of the migration automation managed identity.')
output managedIdentityId string = identity.outputs.managedIdentityId

@description('Name of the SQL Managed Instance, or an empty string when the database platform was not deployed.')
#disable-next-line BCP318
output sqlManagedInstanceName string = deploySqlPlatform ? sqlManagedInstance.outputs.managedInstanceName : ''

@description('Fully qualified domain name of the SQL Managed Instance, or an empty string when the database platform was not deployed.')
#disable-next-line BCP318
output sqlManagedInstanceFqdn string = deploySqlPlatform ? sqlManagedInstance.outputs.managedInstanceFqdn : ''

@description('Name of the governance policy assignment, or an empty string when governance was not deployed.')
#disable-next-line BCP318
output policyAssignmentName string = deployGovernance ? governance.outputs.assignmentName : ''

@description('Regions this customer is permitted to deploy into.')
output allowedLocations array = allowedLocations

@description('Tag set applied to every resource created by this deployment.')
output appliedTags object = tags
