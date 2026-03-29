metadata name = 'Migration Landing Zone - Governance'
metadata description = '''
Deploys policy-as-code governance for a migration landing zone at subscription scope:

- Three custom policy definitions that enforce the controls this practice commits to in every
  engagement: deployment provenance tagging, no public database endpoint, and backup coverage for
  migrated virtual machines.
- A policy initiative that combines the custom definitions with the Azure built-in location
  restrictions, parameterised from the customer parameter file.
- A subscription-scope assignment with explicit non-compliance messaging so that a blocked
  deployment tells the engineer which control was violated and where it is documented.

Policy effects are declared literally rather than through template parameters. This is deliberate:
it guarantees that the enforced behaviour is identical in every customer subscription and cannot be
weakened by a parameter file change that bypasses architecture review.
'''
metadata owner = 'Governance and Compliance Manager'

targetScope = 'subscription'

// =================================================================================================
// Parameters
// =================================================================================================

@description('Required. Short customer code used to name the initiative and assignment, for example ctso.')
@minLength(2)
@maxLength(10)
param customerCode string

@description('Required. Environment moniker used to name the assignment.')
@allowed([
  'dev'
  'tst'
  'uat'
  'prd'
])
param environment string

@description('Required. Azure regions into which the customer is permitted to deploy resources. Enforced by the built-in allowed-location policies.')
@minLength(1)
param allowedLocations array

@description('Required. Primary region of the assignment managed identity and of policy remediation tasks.')
param location string

@description('Optional. Enforcement mode of the initiative assignment. Use DoNotEnforce during the initial assessment window so that non-compliance is reported without blocking the migration, then switch to Default.')
@allowed([
  'Default'
  'DoNotEnforce'
])
param enforcementMode string = 'Default'

@description('Optional. Resource group names excluded from the initiative. Used only for documented, time-bound exceptions approved by the Governance and Compliance Manager.')
param excludedResourceGroupNames array = []

@description('Optional. Contact recorded in policy metadata so that a blocked engineer knows who owns the control.')
param policyOwnerContact string = 'cloud-security@partner.example'

// =================================================================================================
// Variables
// =================================================================================================

var initiativeName = 'init-migration-governance-${customerCode}'
var assignmentName = 'assign-migration-gov-${customerCode}-${environment}'

// Built-in policy definitions combined into the initiative.
var builtInAllowedLocations = tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e56962a6-4747-49cd-b67b-bf8b01975c4c')
var builtInAllowedLocationsForResourceGroups = tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e765b5de-1225-4ba3-bd56-1ac6695af988')

var notScopes = [for rgName in excludedResourceGroupNames: subscriptionResourceId('Microsoft.Resources/resourceGroups', rgName)]

var policyMetadata = {
  category: 'Migration Governance'
  version: '1.0.0'
  owner: policyOwnerContact
  source: 'https://github.com/example-partner/alz-deployments'
}

// =================================================================================================
// Custom policy definitions
// =================================================================================================

// Control: every resource must carry the provenance tags written by the deployment pipeline. This
// is what allows an auditor to trace a live Azure resource back to the reviewed change that created
// it, and it mechanically prevents resources being created outside the pipeline.
resource denyMissingProvenanceTags 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 'deny-missing-provenance-tags'
  properties: {
    displayName: 'Deny resources that are missing deployment provenance tags'
    description: 'Resources must carry the ManagedBy, SourceRepo, SourceCommit, DeploymentId and ChangeRequest tags written by the deployment pipeline. Resources created outside the pipeline cannot satisfy this policy. See docs/Naming_Standards.md.'
    policyType: 'Custom'
    mode: 'Indexed'
    metadata: policyMetadata
    policyRule: {
      if: {
        anyOf: [
          {
            field: 'tags[\'ManagedBy\']'
            exists: 'false'
          }
          {
            field: 'tags[\'ManagedBy\']'
            notEquals: 'IaC'
          }
          {
            field: 'tags[\'SourceRepo\']'
            exists: 'false'
          }
          {
            field: 'tags[\'SourceCommit\']'
            exists: 'false'
          }
          {
            field: 'tags[\'DeploymentId\']'
            exists: 'false'
          }
          {
            field: 'tags[\'ChangeRequest\']'
            exists: 'false'
          }
        ]
      }
      then: {
        effect: 'Deny'
      }
    }
  }
}

// Control: no migrated database is ever reachable from the public internet. The template already
// sets publicDataEndpointEnabled to false; this policy prevents it being re-enabled by any means,
// including a portal change, a script, or a future template edit that escapes review.
resource denySqlManagedInstancePublicEndpoint 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 'deny-sqlmi-public-endpoint'
  properties: {
    displayName: 'Deny public data endpoints on Azure SQL Managed Instance'
    description: 'The SQL Managed Instance public data endpoint exposes the database to the internet and is prohibited. Client connectivity is provided through the delegated subnet and private connectivity only. See docs/Architecture.md.'
    policyType: 'Custom'
    mode: 'Indexed'
    metadata: policyMetadata
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Sql/managedInstances'
          }
          {
            field: 'Microsoft.Sql/managedInstances/publicDataEndpointEnabled'
            equals: 'true'
          }
        ]
      }
      then: {
        effect: 'Deny'
      }
    }
  }
}

// Control: a migrated virtual machine that is not protected by Azure Backup is an unaccepted risk.
// The effect is audit rather than deny because backup registration necessarily happens after the
// virtual machine exists; the finding drives the post-migration exit criteria.
resource auditVirtualMachinesWithoutBackup 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 'audit-vm-without-backup'
  properties: {
    displayName: 'Audit migrated virtual machines that are not protected by Azure Backup'
    description: 'Every virtual machine in a migration landing zone must be registered with the Recovery Services Vault before the wave can be signed off. See docs/Deployment_Methodology.md, phase 7.'
    policyType: 'Custom'
    mode: 'Indexed'
    metadata: policyMetadata
    policyRule: {
      if: {
        field: 'type'
        equals: 'Microsoft.Compute/virtualMachines'
      }
      then: {
        effect: 'AuditIfNotExists'
        details: {
          type: 'Microsoft.RecoveryServices/backupprotecteditems'
        }
      }
    }
  }
}

// =================================================================================================
// Initiative
// =================================================================================================

resource migrationGovernanceInitiative 'Microsoft.Authorization/policySetDefinitions@2023-04-01' = {
  name: initiativeName
  properties: {
    displayName: 'Migration governance baseline for ${customerCode}'
    description: 'Baseline governance applied to every migration landing zone delivered by this practice. Combines partner custom controls with Azure built-in location restrictions.'
    policyType: 'Custom'
    metadata: policyMetadata
    policyDefinitionGroups: [
      {
        name: 'provenance'
        displayName: 'Deployment provenance and traceability'
        description: 'Controls that guarantee every resource can be traced to an approved change.'
      }
      {
        name: 'data-protection'
        displayName: 'Data protection'
        description: 'Controls that protect migrated data from exposure and loss.'
      }
      {
        name: 'residency'
        displayName: 'Data residency'
        description: 'Controls that keep customer data inside the contractually agreed regions.'
      }
    ]
    policyDefinitions: [
      {
        policyDefinitionReferenceId: 'deny-missing-provenance-tags'
        policyDefinitionId: denyMissingProvenanceTags.id
        groupNames: [
          'provenance'
        ]
      }
      {
        policyDefinitionReferenceId: 'deny-sqlmi-public-endpoint'
        policyDefinitionId: denySqlManagedInstancePublicEndpoint.id
        groupNames: [
          'data-protection'
        ]
      }
      {
        policyDefinitionReferenceId: 'audit-vm-without-backup'
        policyDefinitionId: auditVirtualMachinesWithoutBackup.id
        groupNames: [
          'data-protection'
        ]
      }
      {
        policyDefinitionReferenceId: 'allowed-locations'
        policyDefinitionId: builtInAllowedLocations
        groupNames: [
          'residency'
        ]
        parameters: {
          listOfAllowedLocations: {
            value: allowedLocations
          }
        }
      }
      {
        policyDefinitionReferenceId: 'allowed-locations-resource-groups'
        policyDefinitionId: builtInAllowedLocationsForResourceGroups
        groupNames: [
          'residency'
        ]
        parameters: {
          listOfAllowedLocations: {
            value: allowedLocations
          }
        }
      }
    ]
  }
}

// =================================================================================================
// Assignment
// =================================================================================================

resource migrationGovernanceAssignment 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: assignmentName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'Migration governance baseline - ${customerCode} ${environment}'
    description: 'Assigns the migration governance initiative to the ${environment} subscription for ${customerCode}. Managed exclusively by bicep/governance.bicep.'
    policyDefinitionId: migrationGovernanceInitiative.id
    enforcementMode: enforcementMode
    notScopes: notScopes
    nonComplianceMessages: [
      {
        message: 'This resource violates the migration governance baseline. Review docs/Naming_Standards.md and docs/Architecture.md, then raise a change request if an exception is genuinely required.'
      }
      {
        policyDefinitionReferenceId: 'deny-missing-provenance-tags'
        message: 'Resources must be created by the deployment pipeline so that they carry ManagedBy, SourceRepo, SourceCommit, DeploymentId and ChangeRequest tags. Manual portal creation is not permitted in this subscription.'
      }
      {
        policyDefinitionReferenceId: 'deny-sqlmi-public-endpoint'
        message: 'The SQL Managed Instance public data endpoint is prohibited. Use the delegated subnet and private connectivity.'
      }
      {
        policyDefinitionReferenceId: 'allowed-locations'
        message: 'This region is outside the customer data residency agreement. Permitted regions are configured in the customer parameter file.'
      }
    ]
  }
}

// =================================================================================================
// Outputs
// =================================================================================================

@description('Resource ID of the migration governance initiative.')
output initiativeId string = migrationGovernanceInitiative.id

@description('Name of the migration governance initiative.')
output initiativeName string = migrationGovernanceInitiative.name

@description('Resource ID of the subscription-scope policy assignment.')
output assignmentId string = migrationGovernanceAssignment.id

@description('Name of the subscription-scope policy assignment. Verified by scripts/post-deployment-checks.ps1.')
output assignmentName string = migrationGovernanceAssignment.name

@description('Microsoft Entra object ID of the assignment managed identity, used for policy remediation tasks.')
output assignmentPrincipalId string = migrationGovernanceAssignment.identity.principalId

@description('Effective enforcement mode of the assignment, recorded as deployment evidence.')
output enforcementMode string = enforcementMode

@description('Regions the customer is permitted to deploy into, recorded as deployment evidence.')
output allowedLocations array = allowedLocations
