metadata name = 'Migration Landing Zone - Identity and Secrets'
metadata description = '''
Deploys the identity and secret management foundation for a migration landing zone:

- A user-assigned managed identity used by migration automation, backup agents and the SQL
  Managed Instance for Azure resource access, so that no shared credential is required.
- An RBAC-enabled Key Vault with soft delete and purge protection permanently enabled, restricted
  network access, and optional private endpoint integration.
- Scoped Azure RBAC role assignments for the delivery team, the customer platform administrators,
  the customer database administrators and the customer read-only auditors.

No secret value is ever created, read or emitted by this template. Secrets are populated
out-of-band by an authorised operator and consumed through Key Vault references.
'''
metadata owner = 'Cloud Security Lead'

targetScope = 'resourceGroup'

// =================================================================================================
// Parameters
// =================================================================================================

@description('Required. Azure region into which the identity resources are deployed.')
param location string

@description('Required. Tag object applied to every resource. Includes the mandatory provenance tags written by the pipeline.')
param tags object

@description('Required. Name of the user-assigned managed identity used by migration automation.')
@minLength(3)
@maxLength(128)
param managedIdentityName string

@description('Required. Globally unique name of the Key Vault. Between 3 and 24 alphanumeric characters and hyphens.')
@minLength(3)
@maxLength(24)
param keyVaultName string

@description('Optional. Key Vault pricing tier. Use premium only where hardware security module backed keys are a customer requirement.')
@allowed([
  'standard'
  'premium'
])
param keyVaultSku string = 'standard'

@description('Optional. Number of days a deleted Key Vault object is recoverable. Purge protection is always enabled, so this value is also the minimum unrecoverable window.')
@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

@description('Optional. Allow access to the Key Vault from public networks. Disabled by default; enable only with a documented exception approved by the Cloud Security Lead.')
param allowPublicNetworkAccess bool = false

@description('Optional. IPv4 CIDR ranges permitted to reach the Key Vault when public network access is enabled. Typically the delivery team egress addresses during the build phase only.')
param allowedIpRanges array = []

@description('Optional. Create a private endpoint for the Key Vault. Requires privateEndpointSubnetId to be supplied.')
param deployKeyVaultPrivateEndpoint bool = false

@description('Optional. Resource ID of the subnet that hosts private endpoints. Required when deployKeyVaultPrivateEndpoint is true.')
param privateEndpointSubnetId string = ''

@description('Optional. Resource ID of the privatelink.vaultcore.azure.net private DNS zone. When supplied the private endpoint is automatically registered.')
param keyVaultPrivateDnsZoneId string = ''

@description('Optional. Microsoft Entra object ID of the customer platform administrator group. Granted Key Vault Administrator on the vault.')
param platformAdministratorGroupObjectId string = ''

@description('Optional. Microsoft Entra object ID of the customer database administrator group. Granted Key Vault Secrets Officer on the vault.')
param databaseAdministratorGroupObjectId string = ''

@description('Optional. Microsoft Entra object ID of the customer audit or read-only group. Granted Reader on the resource group.')
param auditorGroupObjectId string = ''

@description('Optional. Resource ID of the Log Analytics workspace that receives Key Vault diagnostic logs. Leave empty to skip diagnostic settings.')
param logAnalyticsWorkspaceId string = ''

// =================================================================================================
// Variables
// =================================================================================================

// Well-known Azure built-in role definition identifiers.
var roleDefinitionIds = {
  keyVaultAdministrator: '00482a5a-887f-4fb3-b363-3b7fe8e74483'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0445c86b69e6'
  keyVaultSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
}

var deployDiagnostics = !empty(logAnalyticsWorkspaceId)
var deployPrivateEndpoint = deployKeyVaultPrivateEndpoint && !empty(privateEndpointSubnetId)
var registerPrivateDns = deployPrivateEndpoint && !empty(keyVaultPrivateDnsZoneId)

var ipRules = [for ipRange in allowedIpRanges: {
  value: ipRange
}]

// =================================================================================================
// Resources
// =================================================================================================

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  location: location
  tags: tags
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: keyVaultSku
    }
    tenantId: tenant().tenantId
    // Azure RBAC is used in place of legacy vault access policies so that permissions are visible
    // in the same access review as all other Azure permissions.
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    // Purge protection is intentionally not parameterised. It cannot be disabled once set, which is
    // exactly the control required to prevent destruction of migration encryption material.
    enablePurgeProtection: true
    enabledForDeployment: false
    enabledForDiskEncryption: true
    enabledForTemplateDeployment: true
    publicNetworkAccess: allowPublicNetworkAccess ? 'Enabled' : 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: allowPublicNetworkAccess && !empty(allowedIpRanges) ? 'Deny' : (allowPublicNetworkAccess ? 'Allow' : 'Deny')
      ipRules: ipRules
      virtualNetworkRules: []
    }
  }
}

// The migration automation identity can read secrets but can neither list nor modify them.
resource secretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, managedIdentity.id, roleDefinitionIds.keyVaultSecretsUser)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionIds.keyVaultSecretsUser)
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    description: 'Allows migration automation to read connection secrets at deployment and cutover time.'
  }
}

resource platformAdministratorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(platformAdministratorGroupObjectId)) {
  name: guid(keyVault.id, platformAdministratorGroupObjectId, roleDefinitionIds.keyVaultAdministrator)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionIds.keyVaultAdministrator)
    principalId: platformAdministratorGroupObjectId
    principalType: 'Group'
    description: 'Customer platform administrators manage vault configuration and key lifecycle.'
  }
}

resource databaseAdministratorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(databaseAdministratorGroupObjectId)) {
  name: guid(keyVault.id, databaseAdministratorGroupObjectId, roleDefinitionIds.keyVaultSecretsOfficer)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionIds.keyVaultSecretsOfficer)
    principalId: databaseAdministratorGroupObjectId
    principalType: 'Group'
    description: 'Customer database administrators rotate database credentials held in the vault.'
  }
}

resource auditorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(auditorGroupObjectId)) {
  name: guid(resourceGroup().id, auditorGroupObjectId, roleDefinitionIds.reader)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionIds.reader)
    principalId: auditorGroupObjectId
    principalType: 'Group'
    description: 'Customer audit function holds read-only visibility of the security resource group.'
  }
}

resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = if (deployPrivateEndpoint) {
  name: 'pep-${keyVaultName}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'plsc-${keyVaultName}'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: [
            'vault'
          ]
          requestMessage: 'Automated private endpoint connection created by the migration landing zone deployment.'
        }
      }
    ]
  }
}

resource keyVaultPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = if (registerPrivateDns) {
  // Guarded by registerPrivateDns, which implies the private endpoint was deployed.
  #disable-next-line BCP318
  parent: keyVaultPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-vaultcore-azure-net'
        properties: {
          privateDnsZoneId: keyVaultPrivateDnsZoneId
        }
      }
    ]
  }
}

resource keyVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployDiagnostics) {
  name: 'diag-${keyVaultName}'
  scope: keyVault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
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

// =================================================================================================
// Outputs
// =================================================================================================

@description('Resource ID of the user-assigned managed identity.')
output managedIdentityId string = managedIdentity.id

@description('Name of the user-assigned managed identity.')
output managedIdentityName string = managedIdentity.name

@description('Microsoft Entra object ID of the user-assigned managed identity service principal.')
output managedIdentityPrincipalId string = managedIdentity.properties.principalId

@description('Client ID of the user-assigned managed identity, used when configuring migration agents.')
output managedIdentityClientId string = managedIdentity.properties.clientId

@description('Resource ID of the Key Vault. This is a resource identifier, not a secret.')
output keyVaultId string = keyVault.id

@description('Name of the Key Vault.')
output keyVaultName string = keyVault.name

@description('Data plane URI of the Key Vault, used to construct Key Vault references.')
output keyVaultUri string = keyVault.properties.vaultUri

@description('Indicates whether the Key Vault is reachable from public networks. Expected to be false in all customer environments.')
output keyVaultPublicNetworkAccessEnabled bool = allowPublicNetworkAccess
