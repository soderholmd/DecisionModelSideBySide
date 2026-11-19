#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent
$deployScript = Join-Path $root 'infra\deploy.ps1'
$parameters = Get-Content (Join-Path $root 'infra\main.parameters.example.json') -Raw | ConvertFrom-Json -AsHashtable
$parameters.parameters.exemptionExpiresOn.value = [DateTimeOffset]::UtcNow.AddDays(30).ToString('o')
$tenant = $parameters.parameters.tenantId.value
$allowedUser = $parameters.parameters.allowedUserObjectId.value
$testSubscriptionId = '00000000-0000-0000-0000-000000000002'
$global:decisionInfraTest = @{
    user = $allowedUser
    calls = [Collections.Generic.List[object]]::new()
}
$temporary = Join-Path ([IO.Path]::GetTempPath()) "decision-infra-test-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $temporary

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}

function az {
    param([Parameter(ValueFromRemainingArguments)][string[]]$CliArguments)
    $global:decisionInfraTest.calls.Add($CliArguments)
    if ($CliArguments -contains '--subscription') {
        Assert-True ($CliArguments[[Array]::IndexOf($CliArguments, '--subscription') + 1] -eq $testSubscriptionId) 'The explicit subscription was not preserved.'
    }
    $global:LASTEXITCODE = 0
    switch ($CliArguments[0..1] -join ' ') {
        'account show' { @{ tenantId = $tenant } | ConvertTo-Json }
        'ad signed-in-user' { @{ id = $global:decisionInfraTest.user } | ConvertTo-Json }
        'group exists' { 'false' }
        'deployment sub' {
            Assert-True ($CliArguments[2] -eq 'what-if') 'Preview attempted a deployment.'
            $file = $CliArguments[[Array]::IndexOf($CliArguments, '--parameters') + 1].TrimStart('@')
            $preview = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            Assert-True $preview.parameters.deployApp.value 'Preview omitted the application.'
            @{ status = 'WhatIfOnly'; parameterPath = $file } | ConvertTo-Json
        }
        default { throw "Unexpected Azure command in preview: $($CliArguments -join ' ')" }
    }
}

try {
    foreach ($arguments in @(@{}, @{ SubscriptionId = '   ' })) {
        $rejected = $false
        try { & $deployScript @arguments }
        catch {
            if ($_.Exception.Message -notlike 'Specify -SubscriptionId explicitly.*') { throw }
            $rejected = $true
        }
        Assert-True $rejected 'A missing or blank subscription was accepted.'
        Assert-True ($global:decisionInfraTest.calls.Count -eq 0) 'Azure was called without an explicit subscription.'
    }
    $parameterFile = Join-Path $temporary 'parameters.json'
    $parameters | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $parameterFile -Encoding utf8
    $preview = & $deployScript -SubscriptionId $testSubscriptionId -ParametersFile $parameterFile
    Assert-True ($preview.status -eq 'WhatIfOnly') 'Preview did not complete.'
    Assert-True (!(Test-Path -LiteralPath $preview.parameterPath)) 'Temporary deployment parameters were not removed.'
    Assert-True ($global:decisionInfraTest.calls.Count -eq 4) 'Unexpected operations were performed by the preview.'

    $global:decisionInfraTest.calls.Clear()
    $global:decisionInfraTest.user = 'not-the-approved-user'
    $rejected = $false
    try { & $deployScript -SubscriptionId $testSubscriptionId -ParametersFile $parameterFile -Deploy }
    catch {
        if ($_.Exception.Message -notlike '*identity does not match*') { throw }
        $rejected = $true
    }
    Assert-True $rejected 'An unapproved identity was allowed to deploy.'
    Assert-True ($global:decisionInfraTest.calls.Count -eq 2) 'The identity mismatch did not stop subsequent operations.'

    $ast = [Management.Automation.Language.Parser]::ParseFile($deployScript, [ref]$null, [ref]$null)
    $authFunction = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-Authentication'
    }, $true)
    . ([scriptblock]::Create($authFunction.Extent.Text))
    function Invoke-AzJson { param([string[]]$Arguments) return $script:auth }
    $valid = @{
        properties = @{
            platform = @{ enabled = $true }
            httpSettings = @{ requireHttps = $true }
            globalValidation = @{
                unauthenticatedClientAction = 'RedirectToLoginPage'
                redirectToProvider = 'azureactivedirectory'
                excludedPaths = @('/healthz')
            }
            identityProviders = @{
                azureActiveDirectory = @{
                    enabled = $true
                    registration = @{
                        clientId = 'test-client'
                        clientSecretSettingName = 'entra-web-secret'
                        openIdIssuer = "https://login.microsoftonline.com/$tenant/v2.0"
                    }
                    validation = @{ defaultAuthorizationPolicy = @{ allowedPrincipals = @{ identities = @($allowedUser) } } }
                }
            }
        }
    }
    $script:auth = $valid
    Assert-Authentication -AppResourceId '/test/app' -ClientId 'test-client'
    $unsafeChanges = @(
        { $script:auth.properties.platform.enabled = $false },
        { $script:auth.properties.globalValidation.unauthenticatedClientAction = 'AllowAnonymous' },
        { $script:auth.properties.globalValidation.excludedPaths += '/api/*' },
        { $script:auth.properties.identityProviders.azureActiveDirectory.registration.openIdIssuer = 'https://login.microsoftonline.com/common/v2.0' },
        { $script:auth.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities += 'another-user' }
    )
    foreach ($change in $unsafeChanges) {
        $script:auth = $valid | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        & $change
        $rejected = $false
        try { Assert-Authentication -AppResourceId '/test/app' -ClientId 'test-client' }
        catch {
            if ($_.Exception.Message -notlike 'Authentication verification failed*') { throw }
            $rejected = $true
        }
        Assert-True $rejected 'An unsafe authentication configuration passed verification.'
    }
    $removeFunction = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-RecordedWebCredential'
    }, $true)
    . ([scriptblock]::Create($removeFunction.Extent.Text))
    function Write-DeploymentAudit { param([string]$Label, [string]$Status) }
    $global:decisionInfraTest.removals = [Collections.Generic.List[object]]::new()
    function Invoke-AzJson {
        param([string[]]$Arguments)
        $file = $Arguments[[Array]::IndexOf($Arguments, '--body') + 1].TrimStart('@')
        $global:decisionInfraTest.removals.Add(@{
            url = $Arguments[[Array]::IndexOf($Arguments, '--url') + 1]
            body = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        })
    }
    $application = @{
        id = 'app-object'
        appId = 'app-client'
        passwordCredentials = @(@{ keyId = 'recorded-key' }, @{ keyId = 'unrelated-key' })
    }
    $statePath = Join-Path $temporary 'directory-state.json'
    $requestFile = Join-Path $temporary 'request.json'
    @{ clientId = 'wrong-client'; applicationObjectId = 'app-object'; credentialKeyId = 'recorded-key' } |
        ConvertTo-Json | Set-Content -LiteralPath $statePath
    $rejected = $false
    try { Remove-RecordedWebCredential -Application $application -StatePath $statePath -RequestFile $requestFile }
    catch {
        if ($_.Exception.Message -notlike '*could not identify the exact recorded*') { throw }
        $rejected = $true
    }
    Assert-True ($rejected -and $global:decisionInfraTest.removals.Count -eq 0) 'Recovery attempted to remove a credential from an unmatched application.'
    @{ clientId = 'app-client'; applicationObjectId = 'app-object'; credentialKeyId = 'recorded-key' } |
        ConvertTo-Json | Set-Content -LiteralPath $statePath
    Remove-RecordedWebCredential -Application $application -StatePath $statePath -RequestFile $requestFile
    Assert-True ($global:decisionInfraTest.removals.Count -eq 1) 'Recovery did not remove exactly one credential.'
    $removal = $global:decisionInfraTest.removals[0]
    Assert-True ($removal.body.keyId -eq 'recorded-key' -and $removal.url -eq 'https://graph.microsoft.com/v1.0/applications/app-object/removePassword') 'Recovery targeted the wrong application or credential.'

    $appFunction = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Infrastructure'
    }, $true)
    . ([scriptblock]::Create($appFunction.Extent.Text))
    $Deploy = $true
    $values = $parameters.parameters
    $location = $values.location.value
    $group = $values.resourceGroupName.value
    $appName = $values.appName.value
    $SubscriptionId = 'test-subscription'
    $appTemplate = Join-Path $root 'infra\modules\app.bicep'
    $groupTags = @{ 'app-onboard-session-id' = $values.sessionId.value }
    $foundationOutputs = @{
        environmentId = @{ value = '/test/environment' }
        registryServer = @{ value = 'test.azurecr.io' }
        identityId = @{ value = '/test/identity' }
        identityClientId = @{ value = 'test-identity-client' }
    }
    $runtimeParameters = Join-Path $temporary 'app-parameters.json'
    function Invoke-AzJson {
        param([string[]]$Arguments, [switch]$Sensitive)
        Assert-True (($Arguments[0..2] -join ' ') -eq 'deployment group create') 'App deployment would rewrite subscription foundation resources.'
        Assert-True ($Arguments[[Array]::IndexOf($Arguments, '--template-file') + 1] -eq $appTemplate) 'App deployment did not select the app-only module.'
        Assert-True (($Arguments -join ' ') -notmatch 'test-only-secret') 'A credential was passed in a native command argument.'
        Assert-True ([bool]$Sensitive) 'Secure deployment errors would not be redacted.'
    }
    Invoke-Infrastructure -IncludeApp $true -Public $false -Image 'test.azurecr.io/demo:1' -ClientId 'test-client' -Secret 'test-only-secret'
    $appParameters = Get-Content -LiteralPath $runtimeParameters -Raw | ConvertFrom-Json
    Assert-True (!$appParameters.parameters.externalIngress.value) 'Initial app deployment is not internal.'
    Assert-True ($appParameters.parameters.environmentId.value -eq '/test/environment') 'App deployment lost its foundation wiring.'
    Assert-True ($appParameters.parameters.webClientSecret.value -eq 'test-only-secret') 'Secure file transport lost the credential.'
    'Passed: explicit subscription requirement/forwarding, preview/identity/auth gates, exact credential recovery and app-only secure deployment wiring.'
} finally {
    Remove-Item -LiteralPath $temporary -Recurse -Force
    Remove-Variable -Name decisionInfraTest -Scope Global
}
