metadata name = 'Migration Landing Zone - Networking'
metadata description = '''
Deploys the network foundation for an Azure infrastructure and database migration landing zone:
a virtual network, purpose-scoped subnets (application, data, SQL Managed Instance, private
endpoint and optional Azure Bastion), network security groups with explicit rule sets, the route
table mandated for SQL Managed Instance subnets, optional peering to a connectivity hub, and
diagnostic settings to a central Log Analytics workspace.

The SQL Managed Instance subnet is delegated to Microsoft.Sql/managedInstances and is protected by
the network security group rule set and user-defined route required by the service-aided subnet
configuration.
'''
metadata owner = 'Platform Engineering Lead'

targetScope = 'resourceGroup'

// =================================================================================================
// Parameters
// =================================================================================================

@description('Required. Azure region into which the network resources are deployed.')
param location string

@description('Required. Tag object applied to every resource. Includes the mandatory provenance tags written by the pipeline.')
param tags object

@description('Required. Name of the virtual network. Derived from docs/Naming_Standards.md by the calling template.')
@minLength(2)
@maxLength(64)
param virtualNetworkName string

@description('Required. Address space of the virtual network in CIDR notation, for example 10.20.0.0/16.')
param virtualNetworkAddressPrefix string

@description('Required. Address prefix of the application tier subnet.')
param applicationSubnetPrefix string

@description('Required. Address prefix of the data tier subnet used by migrated infrastructure-as-a-service database servers.')
param dataSubnetPrefix string

@description('Required. Address prefix of the SQL Managed Instance subnet. Must be at least a /27; a /24 is recommended to allow for scale-out and maintenance operations.')
param sqlManagedInstanceSubnetPrefix string

@description('Required. Address prefix of the subnet dedicated to private endpoints for platform-as-a-service resources.')
param privateEndpointSubnetPrefix string

@description('Optional. Address prefix of the AzureBastionSubnet. Must be at least a /26. Only used when deployBastionSubnet is true.')
param bastionSubnetPrefix string = ''

@description('Optional. Deploy an AzureBastionSubnet and its mandatory network security group for secure administrative access during migration.')
param deployBastionSubnet bool = false

@description('Optional. Name of the application tier subnet.')
param applicationSubnetName string = 'snet-app'

@description('Optional. Name of the data tier subnet.')
param dataSubnetName string = 'snet-data'

@description('Optional. Name of the SQL Managed Instance subnet.')
param sqlManagedInstanceSubnetName string = 'snet-sqlmi'

@description('Optional. Name of the private endpoint subnet.')
param privateEndpointSubnetName string = 'snet-pep'

@description('Optional. Custom DNS servers for the virtual network. Leave empty to use Azure-provided DNS. During migration this is normally set to the customer domain controllers.')
param customDnsServers array = []

@description('Optional. Resource ID of a connectivity hub virtual network to peer with. Leave empty for an isolated landing zone. The reciprocal peering is created from the hub subscription by the platform team.')
param hubVirtualNetworkResourceId string = ''

@description('Optional. Allow traffic forwarded by the hub network virtual appliance into this virtual network. Required when the hub runs Azure Firewall or a third-party appliance.')
param allowForwardedTrafficFromHub bool = true

@description('Optional. Use the hub network virtual appliance as the default gateway for the application and data subnets. Requires nextHopApplianceIpAddress to be supplied.')
param routeThroughHubAppliance bool = false

@description('Optional. Private IP address of the hub network virtual appliance. Required when routeThroughHubAppliance is true.')
param nextHopApplianceIpAddress string = ''

@description('Optional. Resource ID of the Log Analytics workspace that receives network diagnostic logs. Leave empty to skip diagnostic settings.')
param logAnalyticsWorkspaceId string = ''

@description('Optional. Number of days network flow and metric diagnostic data is retained in the workspace. Workspace-level retention governs the effective value.')
@minValue(30)
@maxValue(730)
param diagnosticRetentionInDays int = 90

// =================================================================================================
// Variables
// =================================================================================================

var applicationNsgName = 'nsg-${applicationSubnetName}-${virtualNetworkName}'
var dataNsgName = 'nsg-${dataSubnetName}-${virtualNetworkName}'
var sqlManagedInstanceNsgName = 'nsg-${sqlManagedInstanceSubnetName}-${virtualNetworkName}'
var privateEndpointNsgName = 'nsg-${privateEndpointSubnetName}-${virtualNetworkName}'
var bastionNsgName = 'nsg-bastion-${virtualNetworkName}'
var sqlManagedInstanceRouteTableName = 'rt-${sqlManagedInstanceSubnetName}-${virtualNetworkName}'
var workloadRouteTableName = 'rt-workload-${virtualNetworkName}'

var deployDiagnostics = !empty(logAnalyticsWorkspaceId)
var deployHubPeering = !empty(hubVirtualNetworkResourceId)
var deployWorkloadRouteTable = routeThroughHubAppliance && !empty(nextHopApplianceIpAddress)

// Application tier rules. Administrative access is only permitted from Azure Bastion when deployed.
var applicationBaseRules = [
  {
    name: 'AllowHttpsInboundFromVirtualNetwork'
    properties: {
      description: 'Permit application traffic from within the landing zone and peered hub.'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: applicationSubnetPrefix
      destinationPortRanges: [
        '443'
        '80'
      ]
      access: 'Allow'
      priority: 100
      direction: 'Inbound'
    }
  }
  {
    name: 'AllowAzureLoadBalancerInbound'
    properties: {
      description: 'Permit Azure infrastructure health probes.'
      protocol: '*'
      sourceAddressPrefix: 'AzureLoadBalancer'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
      access: 'Allow'
      priority: 4000
      direction: 'Inbound'
    }
  }
  {
    name: 'DenyInternetInbound'
    properties: {
      description: 'Explicitly deny inbound traffic sourced from the public internet.'
      protocol: '*'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
      access: 'Deny'
      priority: 4090
      direction: 'Inbound'
    }
  }
]

var applicationBastionRules = deployBastionSubnet ? [
  {
    name: 'AllowAdministrativeAccessFromBastion'
    properties: {
      description: 'Permit RDP and SSH from the Azure Bastion subnet only. Direct administrative access from elsewhere is denied.'
      protocol: 'Tcp'
      sourceAddressPrefix: bastionSubnetPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: applicationSubnetPrefix
      destinationPortRanges: [
        '22'
        '3389'
      ]
      access: 'Allow'
      priority: 110
      direction: 'Inbound'
    }
  }
] : []

var dataBaseRules = [
  {
    name: 'AllowSqlFromApplicationSubnet'
    properties: {
      description: 'Permit SQL Server traffic from the application tier only.'
      protocol: 'Tcp'
      sourceAddressPrefix: applicationSubnetPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: dataSubnetPrefix
      destinationPortRanges: [
        '1433'
        '1434'
      ]
      access: 'Allow'
      priority: 100
      direction: 'Inbound'
    }
  }
  {
    name: 'AllowAlwaysOnEndpointWithinDataSubnet'
    properties: {
      description: 'Permit SQL Server Always On availability group replica traffic within the data tier.'
      protocol: 'Tcp'
      sourceAddressPrefix: dataSubnetPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: dataSubnetPrefix
      destinationPortRange: '5022'
      access: 'Allow'
      priority: 120
      direction: 'Inbound'
    }
  }
  {
    name: 'AllowAzureLoadBalancerInbound'
    properties: {
      description: 'Permit Azure infrastructure health probes used by the availability group listener.'
      protocol: '*'
      sourceAddressPrefix: 'AzureLoadBalancer'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
      access: 'Allow'
      priority: 4000
      direction: 'Inbound'
    }
  }
  {
    name: 'DenyInternetInbound'
    properties: {
      description: 'Explicitly deny inbound traffic sourced from the public internet.'
      protocol: '*'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
      access: 'Deny'
      priority: 4090
      direction: 'Inbound'
    }
  }
]

var dataBastionRules = deployBastionSubnet ? [
  {
    name: 'AllowAdministrativeAccessFromBastion'
    properties: {
      description: 'Permit RDP and SSH from the Azure Bastion subnet only.'
      protocol: 'Tcp'
      sourceAddressPrefix: bastionSubnetPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: dataSubnetPrefix
      destinationPortRanges: [
        '22'
        '3389'
      ]
      access: 'Allow'
      priority: 110
      direction: 'Inbound'
    }
  }
] : []

// SQL Managed Instance subnet rules. These reproduce the rule set required by the service-aided
// subnet configuration documented by Microsoft. Azure manages the remaining platform rules; no
// explicit deny rule is added here because a deny would break instance management traffic.
var sqlManagedInstanceRules = [
  {
    name: 'allow_management_inbound'
    properties: {
      description: 'Required by SQL Managed Instance for platform management traffic.'
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRanges: [
        '9000'
        '9003'
        '1438'
        '1440'
        '1452'
      ]
      access: 'Allow'
      priority: 100
      direction: 'Inbound'
    }
  }
  {
    name: 'allow_misubnet_inbound'
    properties: {
      description: 'Required by SQL Managed Instance for intra-subnet node communication.'
      protocol: '*'
      sourceAddressPrefix: sqlManagedInstanceSubnetPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
      access: 'Allow'
      priority: 200
      direction: 'Inbound'
    }
  }
  {
    name: 'allow_health_probe_inbound'
    properties: {
      description: 'Required by SQL Managed Instance for Azure infrastructure health probes.'
      protocol: '*'
      sourceAddressPrefix: 'AzureLoadBalancer'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
      access: 'Allow'
      priority: 300
      direction: 'Inbound'
    }
  }
  {
    name: 'allow_client_inbound_from_application'
    properties: {
      description: 'Permit database client traffic from the application tier to the managed instance.'
      protocol: 'Tcp'
      sourceAddressPrefix: applicationSubnetPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: sqlManagedInstanceSubnetPrefix
      destinationPortRanges: [
        '1433'
        '11000-11999'
      ]
      access: 'Allow'
      priority: 400
      direction: 'Inbound'
    }
  }
  {
    name: 'allow_client_inbound_from_data'
    properties: {
      description: 'Permit database migration traffic from the data tier during cutover waves.'
      protocol: 'Tcp'
      sourceAddressPrefix: dataSubnetPrefix
      sourcePortRange: '*'
      destinationAddressPrefix: sqlManagedInstanceSubnetPrefix
      destinationPortRanges: [
        '1433'
        '11000-11999'
      ]
      access: 'Allow'
      priority: 410
      direction: 'Inbound'
    }
  }
  {
    name: 'allow_management_outbound'
    properties: {
      description: 'Required by SQL Managed Instance for platform management traffic.'
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRanges: [
        '443'
        '12000'
      ]
      access: 'Allow'
      priority: 100
      direction: 'Outbound'
    }
  }
  {
    name: 'allow_misubnet_outbound'
    properties: {
      description: 'Required by SQL Managed Instance for intra-subnet node communication.'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: sqlManagedInstanceSubnetPrefix
      destinationPortRange: '*'
      access: 'Allow'
      priority: 200
      direction: 'Outbound'
    }
  }
]

// Rule set mandated for the AzureBastionSubnet.
var bastionRules = [
  {
    name: 'AllowHttpsInbound'
    properties: {
      protocol: 'Tcp'
      sourceAddressPrefix: 'Internet'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
      access: 'Allow'
      priority: 120
      direction: 'Inbound'
    }
  }
  {
    name: 'AllowGatewayManagerInbound'
    properties: {
      protocol: 'Tcp'
      sourceAddressPrefix: 'GatewayManager'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
      access: 'Allow'
      priority: 130
      direction: 'Inbound'
    }
  }
  {
    name: 'AllowAzureLoadBalancerInbound'
    properties: {
      protocol: 'Tcp'
      sourceAddressPrefix: 'AzureLoadBalancer'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '443'
      access: 'Allow'
      priority: 140
      direction: 'Inbound'
    }
  }
  {
    name: 'AllowBastionHostCommunicationInbound'
    properties: {
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: [
        '8080'
        '5701'
      ]
      access: 'Allow'
      priority: 150
      direction: 'Inbound'
    }
  }
  {
    name: 'AllowSshRdpOutbound'
    properties: {
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: [
        '22'
        '3389'
      ]
      access: 'Allow'
      priority: 100
      direction: 'Outbound'
    }
  }
  {
    name: 'AllowAzureCloudOutbound'
    properties: {
      protocol: 'Tcp'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'AzureCloud'
      destinationPortRange: '443'
      access: 'Allow'
      priority: 110
      direction: 'Outbound'
    }
  }
  {
    name: 'AllowBastionCommunicationOutbound'
    properties: {
      protocol: '*'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: 'VirtualNetwork'
      destinationPortRanges: [
        '8080'
        '5701'
      ]
      access: 'Allow'
      priority: 120
      direction: 'Outbound'
    }
  }
  {
    name: 'AllowGetSessionInformationOutbound'
    properties: {
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: 'Internet'
      destinationPortRanges: [
        '80'
        '443'
      ]
      access: 'Allow'
      priority: 130
      direction: 'Outbound'
    }
  }
]

// Subnet collection. Subnets are declared inline on the virtual network so that a redeployment
// cannot race with, or silently remove, an independently managed subnet resource.
var coreSubnets = [
  {
    name: applicationSubnetName
    properties: {
      addressPrefix: applicationSubnetPrefix
      networkSecurityGroup: {
        id: applicationNsg.id
      }
      routeTable: deployWorkloadRouteTable ? {
        // Guarded by deployWorkloadRouteTable, which is also this resource's deployment condition.
        #disable-next-line BCP318
        id: workloadRouteTable.id
      } : null
      privateEndpointNetworkPolicies: 'Enabled'
      privateLinkServiceNetworkPolicies: 'Enabled'
    }
  }
  {
    name: dataSubnetName
    properties: {
      addressPrefix: dataSubnetPrefix
      networkSecurityGroup: {
        id: dataNsg.id
      }
      routeTable: deployWorkloadRouteTable ? {
        // Guarded by deployWorkloadRouteTable, which is also this resource's deployment condition.
        #disable-next-line BCP318
        id: workloadRouteTable.id
      } : null
      privateEndpointNetworkPolicies: 'Enabled'
      privateLinkServiceNetworkPolicies: 'Enabled'
      serviceEndpoints: [
        {
          service: 'Microsoft.Storage'
          locations: [
            location
          ]
        }
      ]
    }
  }
  {
    name: sqlManagedInstanceSubnetName
    properties: {
      addressPrefix: sqlManagedInstanceSubnetPrefix
      networkSecurityGroup: {
        id: sqlManagedInstanceNsg.id
      }
      routeTable: {
        id: sqlManagedInstanceRouteTable.id
      }
      delegations: [
        {
          name: 'Microsoft.Sql.managedInstances'
          properties: {
            serviceName: 'Microsoft.Sql/managedInstances'
          }
        }
      ]
      privateEndpointNetworkPolicies: 'Disabled'
      privateLinkServiceNetworkPolicies: 'Disabled'
    }
  }
  {
    name: privateEndpointSubnetName
    properties: {
      addressPrefix: privateEndpointSubnetPrefix
      networkSecurityGroup: {
        id: privateEndpointNsg.id
      }
      privateEndpointNetworkPolicies: 'Disabled'
      privateLinkServiceNetworkPolicies: 'Enabled'
    }
  }
]

var bastionSubnets = deployBastionSubnet ? [
  {
    name: 'AzureBastionSubnet'
    properties: {
      addressPrefix: bastionSubnetPrefix
      networkSecurityGroup: {
        // Guarded by deployBastionSubnet, which is also this resource's deployment condition.
        #disable-next-line BCP318
        id: bastionNsg.id
      }
    }
  }
] : []

var allSubnets = concat(coreSubnets, bastionSubnets)

// =================================================================================================
// Resources
// =================================================================================================

resource applicationNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: applicationNsgName
  location: location
  tags: tags
  properties: {
    securityRules: concat(applicationBaseRules, applicationBastionRules)
  }
}

resource dataNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: dataNsgName
  location: location
  tags: tags
  properties: {
    securityRules: concat(dataBaseRules, dataBastionRules)
  }
}

resource sqlManagedInstanceNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: sqlManagedInstanceNsgName
  location: location
  tags: tags
  properties: {
    securityRules: sqlManagedInstanceRules
  }
}

resource privateEndpointNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: privateEndpointNsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowVirtualNetworkInbound'
        properties: {
          description: 'Private endpoints are reachable only from within the landing zone and peered networks.'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: privateEndpointSubnetPrefix
          destinationPortRange: '*'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'DenyInternetInbound'
        properties: {
          description: 'Explicitly deny inbound traffic sourced from the public internet.'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          access: 'Deny'
          priority: 4090
          direction: 'Inbound'
        }
      }
    ]
  }
}

resource bastionNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = if (deployBastionSubnet) {
  name: bastionNsgName
  location: location
  tags: tags
  properties: {
    securityRules: bastionRules
  }
}

// A user-defined route sending all traffic to the internet is mandatory for SQL Managed Instance
// subnets. Removing it, or forcing instance traffic through a network virtual appliance, breaks
// the management plane and is denied by review.
resource sqlManagedInstanceRouteTable 'Microsoft.Network/routeTables@2023-11-01' = {
  name: sqlManagedInstanceRouteTableName
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'sqlmi-to-internet'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'Internet'
        }
      }
    ]
  }
}

resource workloadRouteTable 'Microsoft.Network/routeTables@2023-11-01' = if (deployWorkloadRouteTable) {
  name: workloadRouteTableName
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'default-to-hub-appliance'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: nextHopApplianceIpAddress
        }
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: virtualNetworkName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        virtualNetworkAddressPrefix
      ]
    }
    dhcpOptions: empty(customDnsServers) ? null : {
      dnsServers: customDnsServers
    }
    subnets: allSubnets
  }
}

resource hubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = if (deployHubPeering) {
  parent: virtualNetwork
  name: 'peer-to-connectivity-hub'
  properties: {
    remoteVirtualNetwork: {
      id: hubVirtualNetworkResourceId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: allowForwardedTrafficFromHub
    allowGatewayTransit: false
    useRemoteGateways: false
  }
}

resource virtualNetworkDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployDiagnostics) {
  name: 'diag-${virtualNetworkName}'
  scope: virtualNetwork
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

resource applicationNsgDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployDiagnostics) {
  name: 'diag-${applicationNsgName}'
  scope: applicationNsg
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource dataNsgDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployDiagnostics) {
  name: 'diag-${dataNsgName}'
  scope: dataNsg
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource sqlManagedInstanceNsgDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (deployDiagnostics) {
  name: 'diag-${sqlManagedInstanceNsgName}'
  scope: sqlManagedInstanceNsg
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

// =================================================================================================
// Outputs
// =================================================================================================

@description('Resource ID of the virtual network.')
output virtualNetworkId string = virtualNetwork.id

@description('Name of the virtual network.')
output virtualNetworkName string = virtualNetwork.name

@description('Resource ID of the application tier subnet.')
output applicationSubnetId string = '${virtualNetwork.id}/subnets/${applicationSubnetName}'

@description('Resource ID of the data tier subnet.')
output dataSubnetId string = '${virtualNetwork.id}/subnets/${dataSubnetName}'

@description('Resource ID of the SQL Managed Instance subnet. Consumed by bicep/sql-managed-instance.bicep.')
output sqlManagedInstanceSubnetId string = '${virtualNetwork.id}/subnets/${sqlManagedInstanceSubnetName}'

@description('Resource ID of the private endpoint subnet.')
output privateEndpointSubnetId string = '${virtualNetwork.id}/subnets/${privateEndpointSubnetName}'

@description('Resource ID of the route table attached to the SQL Managed Instance subnet.')
output sqlManagedInstanceRouteTableId string = sqlManagedInstanceRouteTable.id

@description('Indicates whether a peering to a connectivity hub was created by this deployment.')
output hubPeeringDeployed bool = deployHubPeering

@description('Effective diagnostic retention in days, recorded for post-deployment verification.')
output diagnosticRetentionInDays int = diagnosticRetentionInDays
