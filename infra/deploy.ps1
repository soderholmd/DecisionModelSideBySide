#Requires -Version 7.2
[CmdletBinding()]
param(
    [switch]$Deploy,
    [switch]$Resume,
    [switch]$RecoverWebCredential,
    [string]$ResumeImageTag = '',
    [string]$SubscriptionId = '',
    [string]$ParametersFile = (Join-Path $PSScriptRoot 'main.parameters.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$auditPath = $null
if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { throw 'Specify -SubscriptionId explicitly. No Azure operations were attempted.' }
if (($Resume -or $RecoverWebCredential) -and !$Deploy) { throw 'Resume and credential recovery require -Deploy.' }
if ($RecoverWebCredential -and !$Resume) { throw 'Credential recovery requires -Resume and separate approval.' }
if ($Resume -and $ResumeImageTag -notmatch '^demo:[0-9]+$') { throw 'Resume requires an existing -ResumeImageTag such as demo:1795022709.' }
if ($ResumeImageTag -and !$Resume) { throw '-ResumeImageTag is only valid with -Resume.' }

function Write-DeploymentAudit {
    param([string]$Label, [string]$Status)
    if ($auditPath) {
        Add-Content -LiteralPath $auditPath -Value "$([DateTimeOffset]::UtcNow.ToString('o')) | $Label | $Status"
    }
}

function Invoke-AzJson {
    param([string[]]$Arguments, [switch]$Sensitive)
    $label = 'az ' + (($Arguments | Select-Object -First 3) -join ' ')
    Write-DeploymentAudit -Label $label -Status 'started'
    $result = & az @Arguments --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-DeploymentAudit -Label $label -Status 'failed'
        if ($Sensitive) { throw "Azure CLI failed during a sensitive operation ($($Arguments[0])). No further changes attempted." }
        throw "Azure CLI failed: $($result -join [Environment]::NewLine)"
    }
    Write-DeploymentAudit -Label $label -Status 'succeeded'
    if ($result) { ($result -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100 }
}

function Assert-Authentication {
    param([string]$AppResourceId, [string]$ClientId)
    $auth = Invoke-AzJson @('rest', '--method', 'get', '--url', "https://management.azure.com$AppResourceId/authConfigs/current?api-version=2026-07-01")
    $aad = $auth.properties.identityProviders.azureActiveDirectory
    $identities = @($aad.validation.defaultAuthorizationPolicy.allowedPrincipals.identities)
    $exclusions = @($auth.properties.globalValidation.excludedPaths)
    if (!$auth.properties.platform.enabled -or !$aad.enabled -or
        $auth.properties.globalValidation.unauthenticatedClientAction -ne 'RedirectToLoginPage' -or
        $auth.properties.globalValidation.redirectToProvider -ne 'azureactivedirectory' -or
        !$auth.properties.httpSettings.requireHttps -or
        $aad.registration.clientId -ne $ClientId -or
        $aad.registration.clientSecretSettingName -ne 'entra-web-secret' -or
        $aad.registration.openIdIssuer -ne "https://login.microsoftonline.com/$tenant/v2.0" -or
        $identities.Count -ne 1 -or $identities[0] -ne $allowedUser -or
        $exclusions.Count -ne 1 -or $exclusions[0] -ne '/healthz') {
        throw 'Authentication verification failed. Public ingress will not be enabled.'
    }
}

function Get-HttpStatus {
    param([string]$Url)
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(20)
    try {
        $response = $client.GetAsync($Url).GetAwaiter().GetResult()
        try { return [int]$response.StatusCode } finally { $response.Dispose() }
    } finally { $client.Dispose() }
}

function Remove-RecordedWebCredential {
    param([object]$Application, [string]$StatePath, [string]$RequestFile)
    if (!(Test-Path -LiteralPath $StatePath)) { throw 'Credential recovery requires the recorded directory state.' }
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $recorded = @($Application.passwordCredentials | Where-Object keyId -eq $state.credentialKeyId)
    if ($state.clientId -ne $Application.appId -or $state.applicationObjectId -ne $Application.id -or $recorded.Count -ne 1) {
        throw 'Credential recovery could not identify the exact recorded application credential. No credentials were removed.'
    }
    @{ keyId = $state.credentialKeyId } | ConvertTo-Json |
        Set-Content -LiteralPath $RequestFile -Encoding utf8
    $null = Invoke-AzJson @('rest', '--method', 'post', '--url',
        "https://graph.microsoft.com/v1.0/applications/$($Application.id)/removePassword", '--body', "@$RequestFile")
    Write-DeploymentAudit -Label 'Explicitly approved recovery of the one recorded unused web credential' -Status 'removed'
}

$root = Split-Path $PSScriptRoot -Parent
$parameters = Get-Content -LiteralPath $ParametersFile -Raw | ConvertFrom-Json -AsHashtable
$values = $parameters.parameters
$tenant = $values.tenantId.value
$allowedUser = $values.allowedUserObjectId.value
$group = $values.resourceGroupName.value
$appName = $values.appName.value
$registryName = $values.registryName.value
$location = $values.location.value
$sessionId = $values.sessionId.value
$template = Join-Path $PSScriptRoot 'main.bicep'
$appTemplate = Join-Path $PSScriptRoot 'modules\app.bicep'
$foundationTemplate = Join-Path $PSScriptRoot 'modules\foundation.bicep'
$expiry = [DateTimeOffset]$values.exemptionExpiresOn.value
if ($expiry -le [DateTimeOffset]::UtcNow) { throw 'The approved exemption has expired. Obtain approval for a new expiry before proceeding.' }

$account = Invoke-AzJson @('account', 'show', '--subscription', $SubscriptionId)
$user = Invoke-AzJson @('ad', 'signed-in-user', 'show')
if ($account.tenantId -ne $tenant -or $user.id -ne $allowedUser) {
    throw 'The active directory identity does not match the approved tenant and allowed user. No changes made.'
}
$groupExists = Invoke-AzJson @('group', 'exists', '--name', $group, '--subscription', $SubscriptionId)
if ($groupExists) {
    $existing = Invoke-AzJson @('group', 'show', '--name', $group, '--subscription', $SubscriptionId)
    if ($existing.tags.'app-onboard-session-id' -ne $sessionId) { throw 'The resource group is not owned by this deployment session.' }
}

if (!$IsWindows) { throw 'This script currently requires Windows to secure temporary credential files with user-only ACLs.' }
$temporary = Join-Path ([IO.Path]::GetTempPath()) "decision-deploy-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $temporary
try {
    $acl = Get-Acl -LiteralPath $temporary
    $acl.SetAccessRuleProtection($true, $false)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $temporary -AclObject $acl
    $runtimeParameters = Join-Path $temporary 'parameters.json'
    $graphBody = Join-Path $temporary 'graph.json'

    function Invoke-Infrastructure {
        param([bool]$IncludeApp, [bool]$Public, [string]$Image = '', [string]$ClientId = '', [string]$Secret = '')
        if ($Deploy -and $IncludeApp) {
            $appValues = @{
                location = $location
                tags = $groupTags
                appName = $appName
                environmentId = $foundationOutputs.environmentId.value
                registryServer = $foundationOutputs.registryServer.value
                identityId = $foundationOutputs.identityId.value
                identityClientId = $foundationOutputs.identityClientId.value
                modelAccountName = $values.modelAccountName.value
                containerImage = $Image
                externalIngress = $Public
                tenantId = $tenant
                allowedUserObjectId = $allowedUser
                webClientId = $ClientId
                webClientSecret = $Secret
            }
            $runtime = @{
                '$schema' = $parameters['$schema']
                contentVersion = $parameters.contentVersion
                parameters = @{}
            }
            foreach ($entry in $appValues.GetEnumerator()) { $runtime.parameters[$entry.Key] = @{ value = $entry.Value } }
            $arguments = @('deployment', 'group', 'create', '--subscription', $SubscriptionId,
                '--resource-group', $group, '--name', 'authenticated-app',
                '--template-file', $appTemplate, '--parameters', "@$runtimeParameters")
        } else {
            $runtime = $parameters | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
            $runtime.parameters.deployApp = @{ value = $IncludeApp }
            $runtime.parameters.externalIngress = @{ value = $Public }
            $runtime.parameters.containerImage = @{ value = $Image }
            $runtime.parameters.webClientId = @{ value = $ClientId }
            $runtime.parameters.webClientSecret = @{ value = $Secret }
            $command = if ($Deploy) { 'create' } else { 'what-if' }
            $arguments = @('deployment', 'sub', $command, '--subscription', $SubscriptionId,
                '--location', $location, '--name', "decision-$sessionId",
                '--template-file', $template, '--parameters', "@$runtimeParameters")
            if (!$Deploy) { $arguments += '--no-pretty-print' }
        }
        $runtime | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $runtimeParameters -Encoding utf8
        Invoke-AzJson -Arguments $arguments -Sensitive:($Deploy -and [bool]$Secret)
    }

    if (!$Deploy) {
        Invoke-Infrastructure -IncludeApp $true -Public $true `
            -Image 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest' `
            -ClientId '00000000-0000-0000-0000-000000000001' -Secret 'preview-only-not-a-credential'
        return
    }

    $baseId = "/subscriptions/$SubscriptionId/resourceGroups/$group"
    $appResourceId = "$baseId/providers/Microsoft.App/containerApps/$appName"
    $sessionPath = Join-Path $root ".copilot-azure\sessions\$sessionId"
    $statePath = Join-Path $sessionPath 'directory-state.json'
    $null = New-Item -ItemType Directory -Path $sessionPath -Force
    $auditPath = Join-Path $sessionPath 'deploy-audit.log'
    if ($groupExists) {
        $existingApps = @(Invoke-AzJson @('resource', 'list', '--resource-group', $group, '--subscription', $SubscriptionId) |
            Where-Object { $_.type -eq 'Microsoft.App/containerApps' -and $_.name -eq $appName })
        if ($existingApps.Count -eq 1) {
            if (!(Test-Path -LiteralPath $statePath)) { throw 'The existing app has no directory state. Manual recovery is required before redeploying.' }
            $existingState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            $liveApp = Invoke-AzJson @('resource', 'show', '--ids', $appResourceId, '--api-version', '2026-07-01', '--subscription', $SubscriptionId)
            if ($liveApp.properties.configuration.ingress.external) {
                Assert-Authentication -AppResourceId $appResourceId -ClientId $existingState.clientId
            }
        }
        $exemptions = Invoke-AzJson @('policy', 'exemption', 'list', '--scope', $baseId, '--subscription', $SubscriptionId)
        $existingWaiver = @($exemptions | Where-Object name -eq 'decision-demo-public-endpoints')
        if ($existingWaiver.Count -gt 1) { throw 'Ambiguous policy exemption state.' }
        if ($existingWaiver.Count -eq 1 -and
            [DateTimeOffset]$existingWaiver[0].expiresOn -ne $expiry) {
            throw 'The existing exemption expiry differs from the approved parameters. No automatic extension is permitted.'
        }
        if ($Resume) {
            if ($existingWaiver.Count -ne 1) { throw 'Resume requires the existing approved policy waiver.' }
            $expectedReferences = @(
                'ACRDenyPaasPublicIP', 'ContainerAppsEnvironmentDenyPublicIP',
                'Deny-ContainerApps-Public-Network-Access', 'Deny-Cognitive-Services-Public-Network-Access',
                'Deny-Cognitive-Services-Network-Access'
            )
            $waiver = $existingWaiver[0]
            if ($waiver.id -ne "$baseId/providers/Microsoft.Authorization/policyExemptions/decision-demo-public-endpoints" -or
                $waiver.policyAssignmentId -ne $values.policyAssignmentId.value -or $waiver.exemptionCategory -ne 'Waiver' -or
                @($waiver.policyDefinitionReferenceIds).Count -ne 5 -or
                @(Compare-Object $expectedReferences $waiver.policyDefinitionReferenceIds).Count -ne 0) {
                throw 'The existing policy waiver does not match the approved scope and five references.'
            }
        }
    }

    if ($Resume) {
        if (!$groupExists) { throw 'Resume requires the existing dedicated resource group.' }
        $foundationDeployment = Invoke-AzJson @('deployment', 'group', 'show', '--subscription', $SubscriptionId,
            '--resource-group', $group, '--name', 'foundation')
        $compiledFoundation = Invoke-AzJson @('bicep', 'build', '--file', $foundationTemplate, '--stdout')
        if ($foundationDeployment.properties.provisioningState -ne 'Succeeded' -or
            $foundationDeployment.properties.templateHash -ne $compiledFoundation.metadata._generator.templateHash) {
            throw 'The existing foundation does not match the current successfully deployed template. Do not resume; review the infrastructure changes.'
        }
        $expectedFoundation = @{
            location = $location
            environmentName = $values.environmentResourceName.value
            registryName = $registryName
            modelAccountName = $values.modelAccountName.value
            identityName = $values.identityName.value
            workspaceName = $values.workspaceName.value
        }
        foreach ($entry in $expectedFoundation.GetEnumerator()) {
            if ($foundationDeployment.properties.parameters.($entry.Key).value -ne $entry.Value) {
                throw "The deployed foundation parameter '$($entry.Key)' differs from the approved target."
            }
        }
        $imageTag = $ResumeImageTag
        $null = Invoke-AzJson @('acr', 'repository', 'show', '--subscription', $SubscriptionId,
            '--name', $registryName, '--image', $imageTag)
        Write-Host 'Resuming the existing validated foundation and image without rewriting its resources or waiver.'
    } else {
        Write-Host 'Provisioning the approved resource group, limited waiver, models, registry, and hosting environment.'
        $null = Invoke-Infrastructure -IncludeApp $false -Public $false
        $foundationDeployment = Invoke-AzJson @('deployment', 'group', 'show', '--subscription', $SubscriptionId,
            '--resource-group', $group, '--name', 'foundation')
        $imageTag = "demo:$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
        Write-Host 'Building the allow-listed runtime context in ACR.'
        Write-DeploymentAudit -Label 'az acr build --no-logs [runtime context]' -Status 'started'
        & az acr build --subscription $SubscriptionId --registry $registryName --image $imageTag `
            --no-logs --only-show-errors $root
        if ($LASTEXITCODE -ne 0) {
            Write-DeploymentAudit -Label 'az acr build --no-logs [runtime context]' -Status 'failed'
            throw 'ACR build failed. No alternative SKU, region, or security setting was applied.'
        }
        Write-DeploymentAudit -Label 'az acr build --no-logs [runtime context]' -Status 'succeeded'
    }
    $foundationOutputs = $foundationDeployment.properties.outputs
    $groupTags = (Invoke-AzJson @('group', 'show', '--subscription', $SubscriptionId, '--name', $group)).tags
    $url = "https://$appName.$($foundationOutputs.environmentDomain.value)"
    $registryServer = $foundationOutputs.registryServer.value
    $image = "$registryServer/$imageTag"
    $displayName = "$($values.environmentName.value)-web"
    $marker = "decision-demo:$SubscriptionId`:$group"
    $applications = @(Invoke-AzJson @('ad', 'app', 'list', '--display-name', $displayName) |
        Where-Object displayName -eq $displayName)
    if ($applications.Count -gt 1) { throw 'Multiple directory applications match the demo name; manual selection is required.' }
    if ($applications.Count -eq 1) {
        $application = $applications[0]
        if ($marker -notin $application.tags -or $application.signInAudience -ne 'AzureADMyOrg' -or
            !$application.web.implicitGrantSettings.enableIdTokenIssuance -or
            "$url/.auth/login/aad/callback" -notin $application.web.redirectUris) {
            throw 'Existing directory application does not match the approved deployment.'
        }
    } else {
        @{
            displayName = $displayName
            signInAudience = 'AzureADMyOrg'
            tags = @($marker)
            web = @{
                redirectUris = @("$url/.auth/login/aad/callback")
                implicitGrantSettings = @{ enableIdTokenIssuance = $true; enableAccessTokenIssuance = $false }
            }
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $graphBody -Encoding utf8
        $application = Invoke-AzJson @('rest', '--method', 'post', '--url',
            'https://graph.microsoft.com/v1.0/applications', '--body', "@$graphBody")
    }
    $objectId = $application.id
    $clientId = $application.appId
    $principals = @(Invoke-AzJson @('ad', 'sp', 'list', '--filter', "appId eq '$clientId'"))
    if ($principals.Count -gt 1) { throw 'Multiple service principals match the app ID.' }
    if ($principals.Count -eq 0) { $null = Invoke-AzJson @('ad', 'sp', 'create', '--id', $clientId) }

    $apps = @(Invoke-AzJson @('resource', 'list', '--resource-group', $group, '--subscription', $SubscriptionId) |
        Where-Object { $_.type -eq 'Microsoft.App/containerApps' -and $_.name -eq $appName })
    $secret = $null
    if ($apps.Count -eq 1) {
        $secrets = Invoke-AzJson -Arguments @('rest', '--method', 'post', '--url',
            "https://management.azure.com$appResourceId/listSecrets?api-version=2026-07-01") -Sensitive
        $saved = @($secrets.value | Where-Object name -eq 'entra-web-secret')
        if ($saved.Count -eq 1) { $secret = $saved[0].value }
    }
    if ($secret) {
        if ($RecoverWebCredential) { throw 'A saved application credential exists. Recovery will not rotate a recoverable credential; rerun without -RecoverWebCredential.' }
        if (!(Test-Path -LiteralPath $statePath)) { throw 'Existing secret has no matching directory state. Manual recovery is required; credentials will not be rotated.' }
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($state.clientId -ne $clientId -or
            [DateTimeOffset]$state.clientSecretExpiresOn -le [DateTimeOffset]::UtcNow -or
            $state.credentialKeyId -notin $application.passwordCredentials.keyId) {
            throw 'Existing web credential state is invalid or expired. Obtain approval before rotating it.'
        }
    } else {
        if ($RecoverWebCredential) {
            Remove-RecordedWebCredential -Application $application -StatePath $statePath -RequestFile $graphBody
        } elseif (@($application.passwordCredentials).Count -gt 0 -or (Test-Path -LiteralPath $statePath)) {
            throw 'The directory credential exists but its secret is not recoverable from the app. Obtain approval for credential recovery; no automatic rotation attempted.'
        }
        $secretExpiry = [DateTimeOffset]::UtcNow.AddDays(30).ToString('o')
        @{ passwordCredential = @{ displayName = 'decision-demo-web'; endDateTime = $secretExpiry } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $graphBody -Encoding utf8
        $password = Invoke-AzJson -Arguments @('rest', '--method', 'post', '--url',
            "https://graph.microsoft.com/v1.0/applications/$objectId/addPassword", '--body', "@$graphBody") -Sensitive
        $secret = $password.secretText
        if (!$secret) { throw 'The directory did not return a web credential.' }
        @{
            applicationObjectId = $objectId
            clientId = $clientId
            credentialKeyId = $password.keyId
            clientSecretExpiresOn = $secretExpiry
        } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
    }

    $null = Invoke-Infrastructure -IncludeApp $true -Public $false -Image $image -ClientId $clientId -Secret $secret
    Assert-Authentication -AppResourceId $appResourceId -ClientId $clientId
    $null = Invoke-Infrastructure -IncludeApp $true -Public $true -Image $image -ClientId $clientId -Secret $secret
    Assert-Authentication -AppResourceId $appResourceId -ClientId $clientId

    $healthy = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $health = Invoke-WebRequest "$url/healthz" -SkipHttpErrorCheck -TimeoutSec 10
            if ($health.StatusCode -eq 200 -and ($health.Content | ConvertFrom-Json).status -eq 'ok') {
                $healthy = $true
                break
            }
        } catch [System.Net.Http.HttpRequestException], [System.Threading.Tasks.TaskCanceledException] {
            Write-Warning "Health probe attempt $($attempt + 1) could not connect."
        }
        Start-Sleep -Seconds 5
    }
    if (!$healthy) { throw 'The deployed application did not become healthy. Resources remain allocated; inspect logs before retrying.' }
    $anonymousStatus = Get-HttpStatus "$url/api/config"
    if ($anonymousStatus -notin @(301, 302, 303, 307, 308, 401, 403)) {
        Write-Warning 'Anonymous access verification failed. Restricting ingress to the environment.'
        $null = Invoke-Infrastructure -IncludeApp $true -Public $false -Image $image -ClientId $clientId -Secret $secret
        throw 'Anonymous API access was not blocked. Public ingress has been disabled; deployment failed.'
    }
    [pscustomobject]@{
        url = $url
        applicationObjectId = $objectId
        clientId = $clientId
        exemptionExpiresOn = $values.exemptionExpiresOn.value
        hostingHealthy = $true
        authenticationConfigured = $true
        authenticatedInferenceVerification = 'Pending: sign in as the approved user and run both models.'
    }
} finally {
    $secret = $null
    Remove-Item -LiteralPath $temporary -Recurse -Force
}
