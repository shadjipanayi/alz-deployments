metadata name = 'Migration Landing Zone - Monitoring and Data Protection'
metadata description = '''
Deploys the observability and data protection foundation for a migration landing zone:

- A Log Analytics workspace that is the single destination for platform, network, database and
  backup telemetry, with an enforced retention period and an optional daily ingestion cap.
- Saved Log Analytics queries used during migration cutover and in post-migration verification.
- An action group and Azure Monitor alert rules covering Azure service health, resource health and
  backup job failure, so that a failed migration or backup is detected rather than discovered.
- A Recovery Services Vault with soft delete, enhanced security, cross-region restore and both an
  Azure virtual machine backup policy and a SQL Server in Azure Virtual Machine backup policy.

The Recovery Services Vault is deployed alongside monitoring because backup verification is part of
the post-migration exit criteria defined in docs/Deployment_Methodology.md.
'''
metadata owner = 'Platform Engineering Lead'

targetScope = 'resourceGroup'

// =================================================================================================
// Parameters
// =================================================================================================

@description('Required. Azure region into which the monitoring resources are deployed.')
param location string

@description('Required. Tag object applied to every resource. Includes the mandatory provenance tags written by the pipeline.')
param tags object

@description('Required. Name of the Log Analytics workspace.')
@minLength(4)
@maxLength(63)
param logAnalyticsWorkspaceName string

@description('Required. Name of the Recovery Services Vault.')
@minLength(2)
@maxLength(50)
param recoveryServicesVaultName string

@description('Optional. Number of days telemetry is retained in the Log Analytics workspace. Regulated customers normally require 365 days or more.')
@minValue(30)
@maxValue(730)
param logRetentionInDays int = 90

@description('Optional. Daily ingestion cap in gigabytes. Use -1 for no cap. A cap protects against runaway ingestion cost during discovery and replication.')
param dailyQuotaInGb int = -1

@description('Optional. Distribution group or shared mailbox that receives platform alerts for this environment.')
param alertEmailAddress string = ''

@description('Optional. Short name shown in alert notifications. Maximum 12 characters.')
@maxLength(12)
param actionGroupShortName string = 'MigAlerts'

@description('Optional. Deploy Azure Monitor alert rules. Disable only for short-lived sandbox environments.')
param deployAlertRules bool = true

@description('Optional. Storage redundancy of the Recovery Services Vault. GeoRedundant is required where a regional outage must not cause backup loss.')
@allowed([
  'LocallyRedundant'
  'GeoRedundant'
  'ZoneRedundant'
])
param backupStorageRedundancy string = 'GeoRedundant'

@description('Optional. Enable cross-region restore. Only valid when backupStorageRedundancy is GeoRedundant.')
param enableCrossRegionRestore bool = true

@description('Optional. IANA or Windows time zone used to schedule backup jobs, for example "W. Europe Standard Time".')
param backupTimeZone string = 'UTC'

@description('Optional. Daily backup start time expressed as a full UTC timestamp. Only the time component is used by the service.')
param backupScheduleTimeUtc string = '2026-01-01T22:00:00Z'

@description('Optional. Number of daily virtual machine recovery points retained.')
@minValue(7)
@maxValue(9999)
param dailyRetentionInDays int = 30

@description('Optional. Number of weekly virtual machine recovery points retained.')
@minValue(1)
@maxValue(5163)
param weeklyRetentionInWeeks int = 12

@description('Optional. Number of monthly virtual machine recovery points retained.')
@minValue(1)
@maxValue(1188)
param monthlyRetentionInMonths int = 12

@description('Optional. Number of yearly virtual machine recovery points retained. Set to satisfy the customer records retention obligation.')
@minValue(1)
@maxValue(99)
param yearlyRetentionInYears int = 3

@description('Optional. Deploy the SQL Server in Azure Virtual Machine backup policy. Required for lift-and-shift database waves that are not migrating to a managed platform.')
param deploySqlBackupPolicy bool = true

// =================================================================================================
// Variables
// =================================================================================================

var deployActionGroup = !empty(alertEmailAddress)
var deployAlerts = deployAlertRules && deployActionGroup
var vmBackupPolicyName = 'policy-vm-daily'
var sqlBackupPolicyName = 'policy-sqlvm-daily'

// =================================================================================================
// Resources
// =================================================================================================

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionInDays
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaInGb
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// Saved searches used by the migration team during cutover and by the post-deployment verification
// script. Keeping them in source control means every engagement runs the same verification query.
resource savedSearchDeploymentProvenance 'Microsoft.OperationalInsights/workspaces/savedSearches@2023-09-01' = {
  parent: logAnalyticsWorkspace
  name: 'MigrationDeploymentProvenance'
  properties: {
    category: 'Migration Assurance'
    displayName: 'Deployments in the last 30 days with change request provenance'
    query: 'AzureActivity | where TimeGenerated > ago(30d) | where OperationNameValue has "MICROSOFT.RESOURCES/DEPLOYMENTS/WRITE" | project TimeGenerated, Caller, ResourceGroup, CorrelationId, ActivityStatusValue | order by TimeGenerated desc'
    version: 2
  }
}

resource savedSearchFailedBackups 'Microsoft.OperationalInsights/workspaces/savedSearches@2023-09-01' = {
  parent: logAnalyticsWorkspace
  name: 'MigrationFailedBackupJobs'
  properties: {
    category: 'Migration Assurance'
    displayName: 'Failed backup jobs in the last 7 days'
    query: 'AddonAzureBackupJobs | where TimeGenerated > ago(7d) | where JobStatus == "Failed" | project TimeGenerated, BackupItemUniqueId, JobOperation, JobStatus, JobFailureCode | order by TimeGenerated desc'
    version: 2
  }
}

resource savedSearchSqlAuditActivity 'Microsoft.OperationalInsights/workspaces/savedSearches@2023-09-01' = {
  parent: logAnalyticsWorkspace
  name: 'MigrationSqlAuditActivity'
  properties: {
    category: 'Migration Assurance'
    displayName: 'SQL Managed Instance audit events in the last 24 hours'
    query: 'SQLSecurityAuditEvents | where TimeGenerated > ago(24h) | summarize EventCount = count() by ServerPrincipalName, DatabaseName, Statement_s = substring(Statement, 0, 120) | order by EventCount desc'
    version: 2
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (deployActionGroup) {
  name: 'ag-${logAnalyticsWorkspaceName}'
  location: 'Global'
  tags: tags
  properties: {
    groupShortName: actionGroupShortName
    enabled: true
    emailReceivers: [
      {
        name: 'MigrationOperations'
        emailAddress: alertEmailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

resource serviceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = if (deployAlerts) {
  name: 'alert-service-health'
  location: 'Global'
  tags: tags
  properties: {
    enabled: true
    description: 'Notifies the migration team of Azure service issues, planned maintenance and health advisories affecting this subscription.'
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ServiceHealth'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          // Guarded by deployAlerts, which requires deployActionGroup.
          #disable-next-line BCP318
          actionGroupId: actionGroup.id
        }
      ]
    }
  }
}

resource resourceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = if (deployAlerts) {
  name: 'alert-resource-health'
  location: 'Global'
  tags: tags
  properties: {
    enabled: true
    description: 'Notifies the migration team when a resource in this subscription becomes unavailable or degraded.'
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ResourceHealth'
        }
        {
          anyOf: [
            {
              field: 'properties.currentHealthStatus'
              equals: 'Degraded'
            }
            {
              field: 'properties.currentHealthStatus'
              equals: 'Unavailable'
            }
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          // Guarded by deployAlerts, which requires deployActionGroup.
          #disable-next-line BCP318
          actionGroupId: actionGroup.id
        }
      ]
    }
  }
}

resource deploymentFailureAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = if (deployAlerts) {
  name: 'alert-deployment-failure'
  location: 'Global'
  tags: tags
  properties: {
    enabled: true
    description: 'Notifies the migration team when an Azure Resource Manager deployment fails, including pipeline deployments from this repository.'
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'operationName'
          equals: 'Microsoft.Resources/deployments/write'
        }
        {
          field: 'status'
          equals: 'Failed'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          // Guarded by deployAlerts, which requires deployActionGroup.
          #disable-next-line BCP318
          actionGroupId: actionGroup.id
        }
      ]
    }
  }
}

resource recoveryServicesVault 'Microsoft.RecoveryServices/vaults@2023-04-01' = {
  name: recoveryServicesVaultName
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    restoreSettings: {
      crossSubscriptionRestoreSettings: {
        crossSubscriptionRestoreState: 'Enabled'
      }
    }
  }
}

// Soft delete and enhanced security protect recovery points against malicious or accidental
// deletion during and after the migration. Both are mandatory and are verified post-deployment.
resource vaultConfiguration 'Microsoft.RecoveryServices/vaults/backupconfig@2023-04-01' = {
  parent: recoveryServicesVault
  name: 'vaultconfig'
  properties: {
    enhancedSecurityState: 'Enabled'
    softDeleteFeatureState: 'Enabled'
    isSoftDeleteFeatureStateEditable: true
  }
}

resource vaultStorageConfiguration 'Microsoft.RecoveryServices/vaults/backupstorageconfig@2023-04-01' = {
  parent: recoveryServicesVault
  name: 'vaultstorageconfig'
  properties: {
    storageModelType: backupStorageRedundancy
    storageType: backupStorageRedundancy
    crossRegionRestoreFlag: backupStorageRedundancy == 'GeoRedundant' ? enableCrossRegionRestore : false
  }
}

resource virtualMachineBackupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-04-01' = {
  parent: recoveryServicesVault
  name: vmBackupPolicyName
  dependsOn: [
    vaultStorageConfiguration
  ]
  properties: {
    backupManagementType: 'AzureIaasVM'
    policyType: 'V2'
    instantRpRetentionRangeInDays: 5
    timeZone: backupTimeZone
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicyV2'
      scheduleRunFrequency: 'Daily'
      dailySchedule: {
        scheduleRunTimes: [
          backupScheduleTimeUtc
        ]
      }
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [
          backupScheduleTimeUtc
        ]
        retentionDuration: {
          count: dailyRetentionInDays
          durationType: 'Days'
        }
      }
      weeklySchedule: {
        daysOfTheWeek: [
          'Sunday'
        ]
        retentionTimes: [
          backupScheduleTimeUtc
        ]
        retentionDuration: {
          count: weeklyRetentionInWeeks
          durationType: 'Weeks'
        }
      }
      monthlySchedule: {
        retentionScheduleFormatType: 'Weekly'
        retentionScheduleWeekly: {
          daysOfTheWeek: [
            'Sunday'
          ]
          weeksOfTheMonth: [
            'First'
          ]
        }
        retentionTimes: [
          backupScheduleTimeUtc
        ]
        retentionDuration: {
          count: monthlyRetentionInMonths
          durationType: 'Months'
        }
      }
      yearlySchedule: {
        retentionScheduleFormatType: 'Weekly'
        monthsOfYear: [
          'January'
        ]
        retentionScheduleWeekly: {
          daysOfTheWeek: [
            'Sunday'
          ]
          weeksOfTheMonth: [
            'First'
          ]
        }
        retentionTimes: [
          backupScheduleTimeUtc
        ]
        retentionDuration: {
          count: yearlyRetentionInYears
          durationType: 'Years'
        }
      }
    }
  }
}

resource sqlServerBackupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2023-04-01' = if (deploySqlBackupPolicy) {
  parent: recoveryServicesVault
  name: sqlBackupPolicyName
  dependsOn: [
    vaultStorageConfiguration
  ]
  properties: {
    backupManagementType: 'AzureWorkload'
    workLoadType: 'SQLDataBase'
    settings: {
      timeZone: backupTimeZone
      issqlcompression: true
      isCompression: true
    }
    subProtectionPolicy: [
      {
        policyType: 'Full'
        schedulePolicy: {
          schedulePolicyType: 'SimpleSchedulePolicy'
          scheduleRunFrequency: 'Daily'
          scheduleRunTimes: [
            backupScheduleTimeUtc
          ]
        }
        retentionPolicy: {
          retentionPolicyType: 'LongTermRetentionPolicy'
          dailySchedule: {
            retentionTimes: [
              backupScheduleTimeUtc
            ]
            retentionDuration: {
              count: dailyRetentionInDays
              durationType: 'Days'
            }
          }
          weeklySchedule: {
            daysOfTheWeek: [
              'Sunday'
            ]
            retentionTimes: [
              backupScheduleTimeUtc
            ]
            retentionDuration: {
              count: weeklyRetentionInWeeks
              durationType: 'Weeks'
            }
          }
        }
      }
      {
        policyType: 'Log'
        schedulePolicy: {
          schedulePolicyType: 'LogSchedulePolicy'
          scheduleFrequencyInMins: 60
        }
        retentionPolicy: {
          retentionPolicyType: 'SimpleRetentionPolicy'
          retentionDuration: {
            count: dailyRetentionInDays
            durationType: 'Days'
          }
        }
      }
    ]
  }
}

resource recoveryServicesVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${recoveryServicesVaultName}'
  scope: recoveryServicesVault
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Health'
        enabled: true
      }
    ]
  }
}

// =================================================================================================
// Outputs
// =================================================================================================

@description('Resource ID of the Log Analytics workspace. Consumed by every other module for diagnostic settings.')
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id

@description('Name of the Log Analytics workspace.')
output logAnalyticsWorkspaceName string = logAnalyticsWorkspace.name

@description('Customer ID of the Log Analytics workspace, used when configuring migration agents.')
output logAnalyticsWorkspaceCustomerId string = logAnalyticsWorkspace.properties.customerId

@description('Effective telemetry retention in days, recorded for post-deployment verification.')
output logRetentionInDays int = logRetentionInDays

@description('Resource ID of the Recovery Services Vault.')
output recoveryServicesVaultId string = recoveryServicesVault.id

@description('Name of the Recovery Services Vault.')
output recoveryServicesVaultName string = recoveryServicesVault.name

@description('Name of the virtual machine backup policy created in the vault.')
output virtualMachineBackupPolicyName string = virtualMachineBackupPolicy.name

@description('Name of the SQL Server in Azure Virtual Machine backup policy, or an empty string when not deployed.')
output sqlServerBackupPolicyName string = deploySqlBackupPolicy ? sqlBackupPolicyName : ''

@description('Resource ID of the action group receiving platform alerts, or an empty string when alerting is not configured.')
// Guarded by deployActionGroup, which is also the action group deployment condition.
#disable-next-line BCP318
output actionGroupId string = deployActionGroup ? actionGroup.id : ''
