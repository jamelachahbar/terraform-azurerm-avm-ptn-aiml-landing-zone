<#
.SYNOPSIS
    Configures the ARM_* environment variables Terraform uses to authenticate to
    Azure from an Azure DevOps Azure Resource Manager service connection.

.DESCRIPTION
    This script must run inside an AzureCLI@2 task that sets
    `addSpnToEnvironment: true`. That task exposes the service connection
    identity to the script as `servicePrincipalId`, `tenantId` and - for
    workload identity federation (OIDC) service connections - `idToken`.

    Workload identity federation is the supported AVM authentication model, so
    the federated token is preferred. A secret-based service connection is
    accepted with a warning so existing projects are not blocked while they
    migrate.

    Environment variables are set on the current process, so every Terraform,
    avm and hook invocation that follows in the same task inherits them.

.PARAMETER SubscriptionId
    Optional subscription to target. When omitted, the subscription configured
    on the service connection is used. Unresolved Azure Pipelines macros (for
    example `$(subscriptionId)` for a variable that was never defined) are
    treated as omitted.
#>
[CmdletBinding()]
param (
    [string] $SubscriptionId
)

$ErrorActionPreference = 'Stop'

if ($SubscriptionId -match '^\$\(.*\)$') {
    # An Azure Pipelines macro that could not be resolved at run time.
    $SubscriptionId = ''
}

if ([string]::IsNullOrWhiteSpace($env:servicePrincipalId)) {
    throw "The service connection identity was not exposed to this script. Set 'addSpnToEnvironment: true' on the AzureCLI@2 task."
}

$env:ARM_CLIENT_ID = $env:servicePrincipalId
$env:ARM_TENANT_ID = $env:tenantId

if (-not [string]::IsNullOrWhiteSpace($env:idToken)) {
    $env:ARM_USE_OIDC = 'true'
    $env:ARM_OIDC_TOKEN = $env:idToken
    Remove-Item -Path 'env:ARM_CLIENT_SECRET' -ErrorAction SilentlyContinue
}
elseif (-not [string]::IsNullOrWhiteSpace($env:servicePrincipalKey)) {
    Write-Warning 'The service connection does not use workload identity federation. Falling back to the service principal secret. AVM expects secretless federated credentials - convert the service connection to workload identity federation.'
    $env:ARM_USE_OIDC = 'false'
    $env:ARM_CLIENT_SECRET = $env:servicePrincipalKey
    Remove-Item -Path 'env:ARM_OIDC_TOKEN' -ErrorAction SilentlyContinue
}
else {
    throw 'The service connection provided neither a federated token nor a service principal secret. Recreate it using workload identity federation.'
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = az account show --query 'id' --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        throw 'Unable to resolve a subscription from the service connection. Set a subscription explicitly.'
    }
}
else {
    az account set --subscription $SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to select subscription '$SubscriptionId'. Check that the service connection identity has access to it."
    }
}

$env:ARM_SUBSCRIPTION_ID = $SubscriptionId

Write-Host "Terraform authenticates as client '$($env:ARM_CLIENT_ID)' in tenant '$($env:ARM_TENANT_ID)' against subscription '$($env:ARM_SUBSCRIPTION_ID)' (OIDC: $($env:ARM_USE_OIDC))."
