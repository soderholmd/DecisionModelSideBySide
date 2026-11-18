targetScope = 'subscription'

param location string
param environmentName string
param sessionId string
param deployedBy string
param createdAt string
param resourceGroupName string
param environmentResourceName string
param appName string
param registryName string
param modelAccountName string
param identityName string
param workspaceName string
param tenantId string
param allowedUserObjectId string
param policyAssignmentId string
param exemptionExpiresOn string
param deployApp bool = false
param externalIngress bool = false
param containerImage string = ''
param webClientId string = ''
@secure()
param webClientSecret string = ''

var tags = {
  'app-onboard-skill': 'true'
  'app-onboard-session-id': sessionId
  'created-at': createdAt
  environment: environmentName
  'deployed-by': deployedBy
}

resource rg 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module exemption './modules/exemption.bicep' = {
  name: 'public-endpoint-waiver'
  scope: rg
  params: {
    policyAssignmentId: policyAssignmentId
    expiresOn: exemptionExpiresOn
  }
}

module foundation './modules/foundation.bicep' = {
  name: 'foundation'
  scope: rg
  dependsOn: [exemption]
  params: {
    location: location
    tags: tags
    environmentName: environmentResourceName
    registryName: registryName
    modelAccountName: modelAccountName
    identityName: identityName
    workspaceName: workspaceName
  }
}

module app './modules/app.bicep' = if (deployApp) {
  name: 'authenticated-app'
  scope: rg
  params: {
    location: location
    tags: tags
    appName: appName
    environmentId: foundation.outputs.environmentId
    registryServer: foundation.outputs.registryServer
    identityId: foundation.outputs.identityId
    identityClientId: foundation.outputs.identityClientId
    modelAccountName: modelAccountName
    containerImage: containerImage
    externalIngress: externalIngress
    tenantId: tenantId
    allowedUserObjectId: allowedUserObjectId
    webClientId: webClientId
    webClientSecret: webClientSecret
  }
}

output registryServer string = foundation.outputs.registryServer
output environmentDomain string = foundation.outputs.environmentDomain
output appUrl string = 'https://${appName}.${foundation.outputs.environmentDomain}'
