metadata name = 'Migration Landing Zone - Azure SQL Managed Instance'
metadata description = '''
Deploys the Azure SQL Managed Instance that is the target platform for homogeneous SQL Server
database migrations, together with the migrated databases and their retention policies.

Security posture enforced by this template and verified by scripts/post-deployment-checks.ps1:

- The public data endpoint is disabled unconditionally. Client connectivity is via the delegated
  virtual network subnet only. Re-enabling it is additionally denied by bicep/governance.bicep.
- Minimum TLS version is pinned to 1.2.
- A Microsoft Entra security group is configured as the instance administrator so that no personal
  account holds standing administrative access.
- Auditing is enabled and streamed to the central Log Analytics workspace.
- Microsoft Defender for SQL is enabled.
- Every database receives an explicit short-term and long-term backup retention policy derived from
  the customer records retention obligation.

The SQL authentication administrator password is supplied as a secure parameter resolved from the
customer bootstrap Key Vault by Azure Resource Manager. It is never stored in this repository and
is never emitted as an output.
'''
metadata owner = 'Database Migration Lead'

targetScope = 'resourceGroup'

// =================================================================================================
// Parameters
// =================================================================================================

@description('Required. Azure region into which the managed instance is deployed. Must match the region of the delegated subnet.')
param location string

@description('Required. Tag object applied to every resource. Includes the mandatory provenance tags written by the pipeline.')
param tags object

@description('Required. Globally unique name of the SQL Managed Instance. Lowercase letters, numbers and hyphens only.')
@minLength(1)
@maxLength(63)
param managedInstanceName string

@description('Required. Resource ID of the subnet delegated to Microsoft.Sql/managedInstances. Supplied by the networking module.')
param subnetResourceId string

@description('Required. SQL authentication administrator login name. Must not be a reserved name such as admin, administrator, sa or root.')
@minLength(4)
@maxLength(128)
param administratorLogin string

@description('Required. SQL authentication administrator password. Supplied as a Key Vault reference from the customer parameter file and never stored in source control.')
@secure()
param administratorLoginPassword string

@description('Optional. Service tier. GeneralPurpose suits most migrated workloads; BusinessCritical is required where sub-second failover or read-scale replicas are contracted.')
@allowed([
  'GeneralPurpose'
  'BusinessCritical'
])
param serviceTier string = 'GeneralPurpose'

@description('Optional. Hardware generation SKU name. Must be consistent with serviceTier.')
@allowed([
  'GP_Gen5'
  'GP_G8IM'
  'GP_G8IH'
  'BC_Gen5'
  'BC_G8IM'
  'BC_G8IH'
])
param skuName string = 'GP_Gen5'

@description('Optional. Number of virtual cores allocated to the instance.')
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
param vCores int = 8

@description('Optional. Reserved storage in gigabytes. Must be a multiple of 32.')
@minValue(32)
@maxValue(16384)
param storageSizeInGB int = 256

@description('Optional. Licensing model. Use BasePrice where the customer has Software Assurance and qualifies for Azure Hybrid Benefit.')
@allowed([
  'LicenseIncluded'
  'BasePrice'
])
param licenseType string = 'LicenseIncluded'

@description('Optional. Instance collation. Must match the source SQL Server instance collation to avoid a post-migration collation conflict.')
param collation string = 'SQL_Latin1_General_CP1_CI_AS'

@description('Optional. Instance time zone. Must match the source instance where applications depend on local date arithmetic.')
param timezoneId string = 'UTC'

@description('Optional. Connection type. Proxy is the default for private connectivity; Redirect offers lower latency but requires ports 11000-11999 to be open from clients.')
@allowed([
  'Proxy'
  'Redirect'
  'Default'
])
param proxyOverride string = 'Proxy'

@description('Optional. Backup storage redundancy for automated backups. Geo is required where a regional outage must not cause backup loss.')
@allowed([
  'Geo'
  'GeoZone'
  'Local'
  'Zone'
])
param requestedBackupStorageRedundancy string = 'Geo'

@description('Optional. Deploy the instance across availability zones. Supported on BusinessCritical and on GeneralPurpose in selected regions only.')
param zoneRedundant bool = false

@description('Optional. Resource ID of a maintenance configuration that defines the customer-approved patching window. Leave empty to use the default Azure-managed window.')
param maintenanceConfigurationId string = ''

@description('Optional. Resource ID of a user-assigned managed identity used by the instance for Azure resource access such as Key Vault backed encryption.')
param userAssignedIdentityResourceId string = ''

@description('Optional. Display name of the Microsoft Entra security group configured as instance administrator.')
param entraAdministratorName string = ''

@description('Optional. Microsoft Entra object ID of the security group configured as instance administrator. Strongly recommended; leave empty only where the customer has not yet provisioned the group.')
param entraAdministratorObjectId string = ''

@description('Optional. Principal type of the Microsoft Entra administrator.')
@allowed([
  'Group'
  'User'
  'Application'
])
param entraAdministratorPrincipalType string = 'Group'

@description('Optional. Disable SQL authentication once the migration cutover is complete and all applications use Microsoft Entra authentication.')
param entraOnlyAuthentication bool = false

@description('Optional. Enable Microsoft Defender for SQL on the instance.')
param enableDefenderForSql bool = true

@description('Optional. Number of days of point-in-time restore history retained for every database.')
@minValue(1)
@maxValue(35)
param shortTermRetentionInDays int = 14

@description('Optional. Long-term weekly backup retention in ISO 8601 duration format, for example P12W. Use an empty string to disable.')
param longTermWeeklyRetention string = 'P12W'

@description('Optional. Long-term monthly backup retention in ISO 8601 duration format, for example P12M. Use an empty string to disable.')
param longTermMonthlyRetention string = 'P12M'

@description('Optional. Long-term yearly backup retention in ISO 8601 duration format, for example P7Y. Set from the customer records retention obligation.')
param longTermYearlyRetention string = 'P7Y'

@description('Optional. Week of the year whose backup is retained for the yearly period.')
@minValue(1)
@maxValue(52)
param longTermWeekOfYear int = 1

@description('Optional. Databases created on the instance. Each entry is an object with a required name property and an optional collation property. Databases restored by the migration service are added to this list after cutover so that their retention policy is managed as code.')
param databases array = []

@description('Optional. Resource ID of the Log Analytics workspace that receives audit and diagnostic data. Leave empty to skip, although auditing then has no destination and the deployment will be flagged by post-deployment checks.')
param logAnalyticsWorkspaceId string = ''

// =================================================================================================
// Variables
// =================================================================================================

var useUserAssignedIdentity = !empty(userAssignedIdentityResourceId)
var configureEntraAdministrator = !empty(entraAdministratorObjectId) && !empty(entraAdministratorName)
var deployDiagnostics = !empty(logAnalyticsWorkspaceId)
var deployLongTermRetention = !empty(longTermWeeklyRetention) || !empty(longTermMonthlyRetention) || !empty(longTermYearlyRetention)

var instanceIdentity = useUserAssignedIdentity ? {
  type: 'SystemAssigned,UserAssigned'
  userAssignedIdentities: {
    '${userAssignedIdentityResourceId}': {}
  }
} : {
  type: 'SystemAssigned'
}

var entraAdministrators = configureEntraAdministrator ? {
  administratorType: 'ActiveDirectory'
  principalType: entraAdministratorPrincipalType
  login: entraAdministratorName
  sid: entraAdministratorObjectId
  tenantId: tenant().tenantId
  azureADOnlyAuthentication: entraOnlyAuthentication
} : null

// Audit action groups selected to satisfy the evidence requirements of a regulated migration:
// authentication outcomes, schema and permission changes, and all completed batches.
var auditActionsAndGroups = [
  'SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP'
  'FAILED_DATABASE_AUTHENTICATION_GROUP'
  'BATCH_COMPLETED_GROUP'
  'DATABASE_PERMISSION_CHANGE_GROUP'
  'SCHEMA_OBJECT_CHANGE_GROUP'
  'DATABASE_PRINCIPAL_CHANGE_GROUP'
]

// =================================================================================================
// Resources
// =================================================================================================

resource managedInstance 'Microsoft.Sql/managedInstances@2023-08-01-preview' = {
  name: managedInstanceName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: serviceTier
  }
  identity: instanceIdentity
  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    administrators: entraAdministrators
    subnetId: subnetResourceId
    licenseType: licenseType
    vCores: vCores
    storageSizeInGB: storageSizeInGB
    collation: collation
    timezoneId: timezoneId
    proxyOverride: proxyOverride
    // Non-negotiable security baseline. Also enforced by the deny policy in bicep/governance.bicep.
    publicDataEndpointEnabled: false
    minimalTlsVersion: '1.2'
    requestedBackupStorageRedundancy: requestedBackupStorageRedundancy
    zoneRedundant: zoneRedundant
    maintenanceConfigurationId: empty(maintenanceConfigurationId) ? null : maintenanceConfigurationId
    primaryUserAssignedIdentityId: useUserAssignedIdentity ? userAssignedIdentityResourceId : null
  }
}

resource instanceDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployDiagnostics) {
  name: 'diag-${managedInstanceName}'
  scope: managedInstance
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// Auditing targets Azure Monitor rather than a storage account so that audit records land in the
// same workspace as every other control evidence stream and are covered by workspace retention.
resource auditingSettings 'Microsoft.Sql/managedInstances/auditingSettings@2023-08-01-preview' = {
  parent: managedInstance
  name: 'default'
  dependsOn: [
    instanceDiagnostics
  ]
  properties: {
    state: 'Enabled'
    isAzureMonitorTargetEnabled: deployDiagnostics
    auditActionsAndGroups: auditActionsAndGroups
    retentionDays: 0
  }
}

resource defenderForSql 'Microsoft.Sql/managedInstances/securityAlertPolicies@2023-08-01-preview' = if (enableDefenderForSql) {
  parent: managedInstance
  name: 'Default'
  properties: {
    state: 'Enabled'
    emailAccountAdmins: true
    emailAddresses: []
    disabledAlerts: []
    retentionDays: 0
  }
}

resource managedDatabases 'Microsoft.Sql/managedInstances/databases@2023-08-01-preview' = [for database in databases: {
  parent: managedInstance
  name: database.name
  location: location
  tags: tags
  properties: {
    collation: contains(database, 'collation') ? database.collation : collation
    createMode: 'Default'
  }
}]

resource shortTermRetentionPolicies 'Microsoft.Sql/managedInstances/databases/backupShortTermRetentionPolicies@2023-08-01-preview' = [for (database, index) in databases: {
  parent: managedDatabases[index]
  name: 'default'
  properties: {
    retentionDays: shortTermRetentionInDays
  }
}]

resource longTermRetentionPolicies 'Microsoft.Sql/managedInstances/databases/backupLongTermRetentionPolicies@2023-08-01-preview' = [for (database, index) in databases: if (deployLongTermRetention) {
  parent: managedDatabases[index]
  name: 'default'
  properties: {
    weeklyRetention: longTermWeeklyRetention
    monthlyRetention: longTermMonthlyRetention
    yearlyRetention: longTermYearlyRetention
    weekOfYear: longTermWeekOfYear
  }
}]

// =================================================================================================
// Outputs
// =================================================================================================

@description('Resource ID of the SQL Managed Instance.')
output managedInstanceId string = managedInstance.id

@description('Name of the SQL Managed Instance.')
output managedInstanceName string = managedInstance.name

@description('Fully qualified domain name used by applications to connect over private connectivity.')
output managedInstanceFqdn string = managedInstance.properties.fullyQualifiedDomainName

@description('Microsoft Entra object ID of the instance system-assigned managed identity.')
output managedInstancePrincipalId string = managedInstance.identity.principalId

@description('Confirms that the public data endpoint is disabled. Asserted by scripts/post-deployment-checks.ps1.')
output publicDataEndpointEnabled bool = managedInstance.properties.publicDataEndpointEnabled

@description('Effective minimum TLS version. Asserted by scripts/post-deployment-checks.ps1.')
output minimalTlsVersion string = managedInstance.properties.minimalTlsVersion

@description('Names of the databases managed by this deployment.')
output managedDatabaseNames array = [for database in databases: database.name]

@description('Indicates whether a Microsoft Entra administrator group was configured on the instance.')
output entraAdministratorConfigured bool = configureEntraAdministrator
