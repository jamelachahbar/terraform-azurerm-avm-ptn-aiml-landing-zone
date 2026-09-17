<#
.SYNOPSIS
    Runs a Terraform plan or apply for a configuration in this repository with
    state stored in an Azure Storage account.

.DESCRIPTION
    Intended for the Azure DevOps continuous delivery pipeline. Authentication
    is expected to be configured already - run Set-AzureTerraformEnvironment.ps1
    inside the same AzureCLI@2 task first.

    The deployable configurations in this repository (the `examples` roots) do
    not declare a backend, so a Terraform override file is generated in the
    working directory to add the `azurerm` backend before initialization.

.PARAMETER Action
    `plan` writes a plan file, `apply` applies a previously saved plan file.

.PARAMETER ConfigurationDirectory
    Terraform root directory, relative to the repository root or absolute.

.PARAMETER PlanFile
    Absolute path of the plan file to write (plan) or apply.

.PARAMETER VarFile
    Optional `-var-file` passed to `terraform plan`.

.PARAMETER Destroy
    Plans the destruction of all managed resources instead of creating or
    updating them. Applying that plan tears the deployment down.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidateSet('plan', 'apply')]
    [string] $Action,

    [Parameter(Mandatory)]
    [string] $ConfigurationDirectory,

    [Parameter(Mandatory)]
    [string] $PlanFile,

    [string] $VarFile,

    [switch] $Destroy,

    [string] $BackendResourceGroupName,

    [string] $BackendStorageAccountName,

    [string] $BackendContainerName,

    [string] $BackendKey
)

$ErrorActionPreference = 'Stop'

function Resolve-PipelineValue {
    param ([string] $Value)

    # An Azure Pipelines macro for a variable that was never defined is passed
    # through unexpanded; treat it as an empty value.
    if ($Value -match '^\$\(.*\)$') {
        return ''
    }

    return $Value
}

function Invoke-Terraform {
    param ([Parameter(Mandatory)] [string[]] $Arguments)

    Write-Host "terraform $($Arguments -join ' ')"
    & terraform @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "terraform $($Arguments[0]) failed with exit code $LASTEXITCODE."
    }
}

if (-not (Get-Command -Name 'terraform' -ErrorAction SilentlyContinue)) {
    throw 'Terraform was not found on the agent. Use an agent image that ships Terraform, or install it before this step.'
}

$backend = [ordered] @{
    resource_group_name  = Resolve-PipelineValue $BackendResourceGroupName
    storage_account_name = Resolve-PipelineValue $BackendStorageAccountName
    container_name       = Resolve-PipelineValue $BackendContainerName
    key                  = Resolve-PipelineValue $BackendKey
}

$missing = @($backend.Keys | Where-Object { [string]::IsNullOrWhiteSpace($backend[$_]) })
if ($missing.Count -gt 0) {
    throw "Remote state is not configured. Set the pipeline variables for: $($missing -join ', ')."
}

$VarFile = Resolve-PipelineValue $VarFile

$configurationPath = Resolve-Path -Path $ConfigurationDirectory
Push-Location -Path $configurationPath
try {
    Write-Host "Terraform working directory: $configurationPath"

    # Override files let the pipeline add the backend without modifying the
    # configuration that is committed to the repository.
    $backendOverride = @'
terraform {
  backend "azurerm" {}
}
'@
    Set-Content -Path (Join-Path $configurationPath 'backend_override.tf') -Value $backendOverride -Encoding utf8

    $initArguments = @('init', '-input=false', '-no-color', '-reconfigure')
    foreach ($key in $backend.Keys) {
        $initArguments += "-backend-config=$key=$($backend[$key])"
    }
    $initArguments += '-backend-config=use_azuread_auth=true'
    if ($env:ARM_USE_OIDC -eq 'true') {
        $initArguments += '-backend-config=use_oidc=true'
    }

    Invoke-Terraform -Arguments $initArguments

    if ($Action -eq 'plan') {
        Invoke-Terraform -Arguments @('validate', '-no-color')

        $planArguments = @('plan', '-input=false', '-no-color', '-lock-timeout=5m', "-out=$PlanFile")
        if ($Destroy.IsPresent) {
            $planArguments += '-destroy'
        }
        if (-not [string]::IsNullOrWhiteSpace($VarFile)) {
            $planArguments += "-var-file=$VarFile"
        }

        Invoke-Terraform -Arguments $planArguments

        # A readable copy of the plan travels with the pipeline artifact so
        # approvers can review it before the apply stage runs.
        & terraform show -no-color $PlanFile | Set-Content -Path "$PlanFile.txt" -Encoding utf8
        if ($LASTEXITCODE -ne 0) {
            throw "terraform show failed with exit code $LASTEXITCODE."
        }
    }
    else {
        if (-not (Test-Path -Path $PlanFile -PathType Leaf)) {
            throw "Plan file '$PlanFile' was not found. Run the plan stage first."
        }

        Invoke-Terraform -Arguments @('apply', '-input=false', '-no-color', '-lock-timeout=5m', $PlanFile)
    }
}
finally {
    Pop-Location
}
