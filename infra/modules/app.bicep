param location string
param tags object
param appName string
param environmentId string
param registryServer string
param identityId string
param identityClientId string
param modelAccountName string
param containerImage string
param externalIngress bool
param tenantId string
param allowedUserObjectId string
param webClientId string
@secure()
param webClientSecret string

resource app 'Microsoft.App/containerApps@2026-07-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    managedEnvironmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: externalIngress
        targetPort: 8000
        transport: 'auto'
        allowInsecure: false
      }
      secrets: [{ name: 'entra-web-secret', value: webClientSecret }]
      registries: [{ server: registryServer, identity: identityId }]
    }
    template: {
      containers: [
        {
          name: 'demo'
          image: containerImage
          resources: { cpu: json('1.0'), memory: '2Gi' }
          env: [
            { name: 'MOCK_MODELS', value: 'false' }
            { name: 'AZURE_CLIENT_ID', value: identityClientId }
            { name: 'AZURE_OPENAI_ENDPOINT', value: 'https://${modelAccountName}.openai.azure.com/' }
            { name: 'AZURE_OPENAI_API_VERSION', value: '2024-10-21' }
            { name: 'AZURE_OPENAI_DEPLOYMENT', value: 'gpt-5.2' }
            { name: 'AZURE_OPENAI_INPUT_USD_PER_MILLION', value: '1.75' }
            { name: 'AZURE_OPENAI_OUTPUT_USD_PER_MILLION', value: '14' }
            { name: 'AZURE_OPENAI_CACHED_INPUT_USD_PER_MILLION', value: '0.175' }
            { name: 'DECISION_ENDPOINT', value: 'https://${modelAccountName}.services.ai.azure.com' }
            { name: 'DECISION_DEPLOYMENT', value: 'decision-1-1' }
            { name: 'DECISION_USD_PER_MILLION', value: '0.042' }
          ]
          probes: [
            for kind in ['Liveness', 'Readiness']: {
              type: kind
              httpGet: { path: '/healthz', port: 8000 }
              initialDelaySeconds: 10
              periodSeconds: 10
              timeoutSeconds: 3
              failureThreshold: 6
            }
          ]
        }
      ]
      scale: { minReplicas: 1, maxReplicas: 1 }
    }
  }
}

resource authentication 'Microsoft.App/containerApps/authConfigs@2026-07-01' = {
  parent: app
  name: 'current'
  properties: {
    platform: { enabled: true }
    httpSettings: { requireHttps: true }
    globalValidation: {
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
      excludedPaths: ['/healthz']
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: webClientId
          clientSecretSettingName: 'entra-web-secret'
          openIdIssuer: uri(environment().authentication.loginEndpoint, '${tenantId}/v2.0')
        }
        validation: {
          allowedAudiences: [webClientId, 'api://${webClientId}']
          defaultAuthorizationPolicy: {
            allowedPrincipals: { identities: [allowedUserObjectId] }
          }
        }
      }
    }
  }
}
