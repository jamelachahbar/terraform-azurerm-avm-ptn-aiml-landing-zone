# Azure DevOps pipelines

Azure Pipelines equivalents of this repository's GitHub Actions automation, for
teams that mirror the module into Azure DevOps.

| File | Purpose |
| --- | --- |
| [`pipelines/avm-terraform-ci.yml`](pipelines/avm-terraform-ci.yml) | CI. Runs `avm test unit`, `avm pr-check`, `avm test integration` and `avm test e2e` for every example. |
| [`pipelines/avm-terraform-cd.yml`](pipelines/avm-terraform-cd.yml) | CD. Plans and applies a deployable configuration with remote state and environment approvals. |
| [`pipelines/templates/`](pipelines/templates) | Step templates that install `Avm.Authoring` and run `avm` commands. |
| [`pipelines/scripts/`](pipelines/scripts) | PowerShell used by the pipelines to configure Azure authentication and drive Terraform. |

The GitHub workflows in [`.github/workflows`](../.github/workflows) remain the
authoritative gate for contributions to the upstream AVM repository. These
pipelines run the same `Avm.Authoring` commands so both systems validate a
change identically.

## Prerequisites

- An agent pool whose image provides PowerShell 7.4 or later, and Terraform for
  the CD pipeline. The Microsoft-hosted `ubuntu-latest` image provides both.
- An Azure Resource Manager service connection that uses **workload identity
  federation**. AVM requires secretless federated credentials; a secret-based
  service connection still works but logs a warning.
- The service connection identity needs permissions to deploy the landing zone
  in the test or target subscription, and `Storage Blob Data Contributor` on the
  state container used by the CD pipeline.

Create the pipelines with **Pipelines > New pipeline > Azure Repos Git >
Existing Azure Pipelines YAML file**, then select the file you want.

## CI pipeline

Runs on pull requests to `main` and on `main`, and maps to the managed GitHub
workflow as follows:

| GitHub job | Azure Pipelines job | Command |
| --- | --- | --- |
| Unit tests | `validate` / `unit_tests` | `avm test unit` |
| PR check | `validate` / `pr_check` | `avm pr-check` |
| Integration tests | `azure_tests` / `integration_tests` | `avm test integration` |
| Discover e2e examples | `azure_tests` / `discover_examples` | `avm test e2e --list` |
| End-to-end tests | `azure_tests` / `e2e_tests` | `avm test e2e --example <name>` |

Parameters let you pick the service connection, agent image, `Avm.Authoring`
version, the variable groups to link, which tiers to run, and an explicit list
of examples instead of discovery. The end-to-end job expands one matrix leg per
discovered example, so every example is reported and destroyed even when another
one fails.

Supported variables:

| Variable | Required | Purpose |
| --- | --- | --- |
| `avmTestSubscriptionIds` | No | JSON array of subscription ids, or of `{ "id": "...", "name": "..." }` objects. Examples are distributed across them round robin to stay inside quota. Defaults to the service connection subscription. |
| `GITHUB_TOKEN` | No | Personal access token used for managed-file synchronization and other GitHub reads, to avoid anonymous rate limits. Store it as a secret variable. |
| `TF_VAR_*` | No | Inputs consumed by examples and tests. |

`TF_VAR_enable_telemetry` is set to `false` and `TF_IN_AUTOMATION` to `1`, which
matches the AVM CI defaults.

Azure DevOps evaluates approvals and checks on the resources a job consumes, so
gate Azure-touching runs by adding **Approvals and checks** to the service
connection used by the CI pipeline.

## CD pipeline

Manual or scheduled (`trigger: none`). The `plan` stage publishes a
`terraform-plan` artifact that holds the plan file and a readable
`tfplan.txt` summary; the `apply` stage applies exactly that plan after the
Azure DevOps environment approvals pass.

Parameters select the service connection, the environment that gates the apply,
the configuration directory (`examples/default` by default), an optional
`-var-file`, an optional subscription override, and whether to plan a destroy.

Remote state is mandatory and is supplied through variables, usually from a
variable group:

| Variable | Required | Purpose |
| --- | --- | --- |
| `backendResourceGroupName` | Yes | Resource group holding the state storage account. |
| `backendStorageAccountName` | Yes | State storage account. |
| `backendContainerName` | Yes | State container. Defaults to `tfstate`. |
| `backendKey` | Yes | State blob name. Defaults to `aiml-landing-zone.tfstate`. |
| `TF_VAR_*` | No | Inputs for the configuration being deployed. |

The examples in this repository do not declare a backend, so the pipeline writes
a `backend_override.tf` override file in the working directory before
`terraform init`. Nothing in the repository is modified: the override file is
generated in the agent workspace only, and the repository already ignores
`*_override.tf`.

Create the target environment under **Pipelines > Environments** and add the
approvals or other checks the deployment requires. Use a separate state blob
(`backendKey`) per environment.

## Authentication

Azure credentials are never stored in the pipelines. Every Azure-touching step
runs inside an `AzureCLI@2` task with `addSpnToEnvironment: true`, and
[`Set-AzureTerraformEnvironment.ps1`](pipelines/scripts/Set-AzureTerraformEnvironment.ps1)
converts the service connection identity into the environment variables
Terraform expects:

- `ARM_CLIENT_ID` and `ARM_TENANT_ID` from the service connection;
- `ARM_OIDC_TOKEN` plus `ARM_USE_OIDC=true` from the federated token; and
- `ARM_SUBSCRIPTION_ID` from the parameter, or from the service connection
  subscription when no override is supplied.
