@description('Location for all resources')
param location string = resourceGroup().location

@description('Name for the Azure Container App')
param acaName string

@description('Display name for the Entra App')
param entraAppDisplayName string

@description('Full resource IDs of Storage Accounts that the MCP server will have access to through storage tools')
param storageResourceIds array

@description('Microsoft Foundry project resource ID for assigning Entra App role to Foundry project managed identity')
param foundryProjectResourceId string

@description('Service Management Reference for the Entra Application. Optional GUID used to link the app to a service in Azure.')
param serviceManagementReference string = ''

@description('Application Insights connection string. Use "DISABLED" to disable telemetry, or provide existing connection string. If omitted, new App Insights will be created.')
param appInsightsConnectionString string = ''

@description('Resource groups the MCP server should have Reader access to (for compute, advisor, and general resource visibility)')
param readerResourceGroupNames array

@description('Full resource IDs of Windows VMs to monitor with Azure Monitor Agent and perf data collection. Example: ["/subscriptions/.../resourceGroups/.../providers/Microsoft.Compute/virtualMachines/myVm"]')
param monitoredVmResourceIds array = []

// Deploy Log Analytics Workspace and Data Collection Rule for VM performance monitoring
module vmMonitoring 'modules/vm-monitoring-workspace.bicep' = {
  name: 'vm-monitoring-workspace'
  params: {
    location: location
    lawName: '${acaName}-law'
  }
}

// Deploy AMA extension and DCR association on each monitored Windows VM
module vmMonitoringAssociations 'modules/vm-monitoring-association.bicep' = [for (vmId, i) in monitoredVmResourceIds: {
  name: 'vm-monitoring-assoc-${i}'
  scope: resourceGroup(split(vmId, '/')[4])
  params: {
    vmName: split(vmId, '/')[8]
    dcrId: vmMonitoring.outputs.dcrId
    location: location
  }
}]

// Deploy Application Insights if appInsightsConnectionString is empty and not DISABLED
var appInsightsName = '${acaName}-insights'
//
module appInsights 'modules/application-insights.bicep' = {
  name: 'application-insights-deployment'
  params: {
    appInsightsConnectionString: appInsightsConnectionString
    name: appInsightsName
    location: location
  }
}

// Deploy Entra App
//var entraAppUniqueName = '${replace(toLower(entraAppDisplayName), ' ', '-')}-${uniqueString(resourceGroup().id)}'
//
//module entraApp 'modules/entra-app.bicep' = {
//  name: 'entra-app-deployment'
//  params: {
//    entraAppDisplayName: entraAppDisplayName
//    entraAppUniqueName: entraAppUniqueName
//    serviceManagementReference: serviceManagementReference
//  }
//}

// Deploy ACA Infrastructure to host Azure MCP Server
module acaInfrastructure 'modules/aca-infrastructure.bicep' = {
  name: 'aca-infrastructure-deployment'
  params: {
    name: acaName
    location: location
    appInsightsConnectionString: appInsights.outputs.connectionString
    azureMcpCollectTelemetry: string(!empty(appInsights.outputs.connectionString))
    azureAdTenantId: tenant().tenantId
    azureAdClientId: entraApp.outputs.entraAppClientId
    infrastructureSubnetId: '/subscriptions/a3802da5-4862-4f67-8e79-a3a493415113/resourceGroups/rg-ess-ess-aifoundry-eastus-spokenet-dev/providers/Microsoft.Network/virtualNetworks/vnet-ess-ess-aifoundry-eastus-dev/subnets/container_app_subnet'
    namespaces: ['storage', 'advisor', 'compute', 'monitor']
  }
}

// Role definitions (read-only roles for the --read-only Azure MCP Server flag)
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var monitoringReaderRoleId = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'

// Deploy Storage Blob Data Reader role assignment for each storage account
module acaStorageBlobRoleAssignments './modules/aca-role-assignment-resource.bicep' = [for (storageId, i) in storageResourceIds: {
  name: 'aca-storage-blob-role-${i}'
  params: {
    storageResourceId: storageId
    acaPrincipalId: acaInfrastructure.outputs.containerAppPrincipalId
    roleDefinitionId: storageBlobDataReaderRoleId
  }
}]

// Deploy Reader role assignment for each storage account (read storage account properties)
module acaStorageReaderRoleAssignments './modules/aca-role-assignment-resource.bicep' = [for (storageId, i) in storageResourceIds: {
  name: 'aca-storage-reader-role-${i}'
  params: {
    storageResourceId: storageId
    acaPrincipalId: acaInfrastructure.outputs.containerAppPrincipalId
    roleDefinitionId: readerRoleId
  }
}]

// Deploy Reader role assignment on each resource group (for compute, advisor, and general visibility)
module acaRgReaderRoleAssignments './modules/aca-role-assignment-rg.bicep' = [for (rgName, i) in readerResourceGroupNames: {
  name: 'aca-rg-reader-role-${i}'
  scope: resourceGroup(rgName)
  params: {
    acaPrincipalId: acaInfrastructure.outputs.containerAppPrincipalId
    roleDefinitionId: readerRoleId
  }
}]

// Deploy Monitoring Reader role assignment on each resource group (for monitor namespace — metrics, logs, alerts)
module acaRgMonitoringReaderRoleAssignments './modules/aca-role-assignment-rg.bicep' = [for (rgName, i) in readerResourceGroupNames: {
  name: 'aca-rg-monitoring-reader-role-${i}'
  scope: resourceGroup(rgName)
  params: {
    acaPrincipalId: acaInfrastructure.outputs.containerAppPrincipalId
    roleDefinitionId: monitoringReaderRoleId
  }
}]

// Deploy Log Analytics Reader role assignment on each resource group (for monitor namespace — LAW query access)
module acaRgLogAnalyticsReaderRoleAssignments './modules/aca-role-assignment-rg.bicep' = [for (rgName, i) in readerResourceGroupNames: {
  name: 'aca-rg-la-reader-role-${i}'
  scope: resourceGroup(rgName)
  params: {
    acaPrincipalId: acaInfrastructure.outputs.containerAppPrincipalId
    roleDefinitionId: logAnalyticsReaderRoleId
  }
}]

// Deploy Entra App role assignment for Microsoft Foundry project MI to access ACA
module foundryRoleAssignment './modules/foundry-role-assignment-entraapp.bicep' = {
  name: 'foundry-role-assignment'
  params: {
    foundryProjectResourceId: foundryProjectResourceId
    entraAppServicePrincipalObjectId: entraApp.outputs.entraAppServicePrincipalObjectId
    entraAppRoleId: entraApp.outputs.entraAppRoleId
  }
}

// Outputs for azd and other consumers
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_SUBSCRIPTION_ID string = subscription().subscriptionId
output AZURE_RESOURCE_GROUP string = resourceGroup().name
output AZURE_LOCATION string = location

// Entra App outputs
output ENTRA_APP_CLIENT_ID string = entraApp.outputs.entraAppClientId
output ENTRA_APP_OBJECT_ID string = entraApp.outputs.entraAppObjectId
output ENTRA_APP_SERVICE_PRINCIPAL_ID string = entraApp.outputs.entraAppServicePrincipalObjectId
output ENTRA_APP_ROLE_ID string = entraApp.outputs.entraAppRoleId
output ENTRA_APP_IDENTIFIER_URI string = entraApp.outputs.entraAppIdentifierUri

// ACA Infrastructure outputs
output CONTAINER_APP_URL string = acaInfrastructure.outputs.containerAppUrl
output CONTAINER_APP_NAME string = acaInfrastructure.outputs.containerAppName
output CONTAINER_APP_PRINCIPAL_ID string = acaInfrastructure.outputs.containerAppPrincipalId
output AZURE_CONTAINER_APP_ENVIRONMENT_ID string = acaInfrastructure.outputs.containerAppEnvironmentId

// Application Insights outputs
// VM Monitoring outputs
output LAW_RESOURCE_ID string = vmMonitoring.outputs.lawId
output LAW_NAME string = vmMonitoring.outputs.lawName

output APPLICATION_INSIGHTS_NAME string = appInsightsName
output APPLICATION_INSIGHTS_CONNECTION_STRING string = appInsights.outputs.connectionString
output AZURE_MCP_COLLECT_TELEMETRY string = string(!empty(appInsights.outputs.connectionString))
