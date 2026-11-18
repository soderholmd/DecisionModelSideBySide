param location string
param tags object
param environmentName string
param registryName string
param modelAccountName string
param identityName string
param workspaceName string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: identityName
  location: location
  tags: tags
}

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: registryName
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: json('0.1') }
  }
}

resource environment 'Microsoft.App/managedEnvironments@2026-07-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    publicNetworkAccess: 'Enabled'
    workloadProfiles: [
      { name: 'Consumption', workloadProfileType: 'Consumption' }
    ]
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: workspace.properties.customerId
        sharedKey: workspace.listKeys().primarySharedKey!
      }
    }
  }
}

resource models 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: modelAccountName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: modelAccountName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: { defaultAction: 'Allow' }
  }
}

resource chat 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: models
  name: 'gpt-5.2'
  sku: { name: 'GlobalStandard', capacity: 100 }
  properties: {
    model: { format: 'OpenAI', name: 'gpt-5.2', version: '2025-12-11' }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource decision 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: models
  name: 'decision-1-1'
  sku: { name: 'GlobalStandard', capacity: 500 }
  dependsOn: [chat]
  properties: {
    model: { format: 'Microsoft', name: 'Microsoft-Decision-1.1', version: '1' }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource registryPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, identity.id, 'AcrPull')
  scope: registry
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d'
    )
  }
}

resource chatInference 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(models.id, identity.id, 'OpenAIUser')
  scope: models
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
    )
  }
}

resource decisionInference 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(models.id, identity.id, 'CognitiveServicesUser')
  scope: models
  properties: {
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'a97b65f3-24c7-4388-baec-2e87135dc908'
    )
  }
}

output environmentId string = environment.id
output environmentDomain string = environment.properties.defaultDomain
output registryServer string = registry.properties.loginServer
output identityId string = identity.id
output identityClientId string = identity.properties.clientId
