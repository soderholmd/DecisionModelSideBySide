param policyAssignmentId string
param expiresOn string

resource waiver 'Microsoft.Authorization/policyExemptions@2022-07-01-preview' = {
  name: 'decision-demo-public-endpoints'
  properties: {
    displayName: 'Time-limited public endpoints for authenticated Decision demo'
    description: 'Dedicated demo resource group only. Browser access requires Entra sign-in; model APIs require managed identity. Expiry does not remove resources.'
    policyAssignmentId: policyAssignmentId
    policyDefinitionReferenceIds: [
      'ACRDenyPaasPublicIP'
      'ContainerAppsEnvironmentDenyPublicIP'
      'Deny-ContainerApps-Public-Network-Access'
      'Deny-Cognitive-Services-Public-Network-Access'
      'Deny-Cognitive-Services-Network-Access'
    ]
    exemptionCategory: 'Waiver'
    expiresOn: expiresOn
  }
}
