provider "azurerm" {
  features {}
}

resource "random_pet" "suffix" {
  // Since azurerm doesn't allow "-" in registry name, use an alphabet as a
  // separator.
  separator = "o"
}

locals {
  name         = "fluxTest${random_pet.suffix.id}"
  project_name = "fluxProj${random_pet.suffix.id}"
  repo_name    = "fluxRepo${random_pet.suffix.id}"
}

module "aks" {
  source = "git::https://github.com/fluxcd/test-infra.git//tf-modules/azure/aks"

  name      = local.name
  location  = var.azure_location
  tags      = var.tags
  enable_wi = var.enable_wi
}

module "acr" {
  source = "git::https://github.com/fluxcd/test-infra.git//tf-modules/azure/acr"

  name     = local.name
  location = var.azure_location
  // By default, azure nodes have no access to ACR. We have to pass the AKS principal id to the modules
  // Additionally, when workload identity is enabled, we also want to give permissions to managed identity.
  aks_principal_id = var.enable_wi ? [module.aks.principal_id, azurerm_user_assigned_identity.wi-id[0].principal_id] : [module.aks.principal_id]
  resource_group   = module.aks.resource_group
  admin_enabled    = true
  tags             = var.tags

  depends_on = [module.aks]
}

resource "azurerm_user_assigned_identity" "wi-id" {
  count               = var.enable_wi ? 1 : 0
  location            = var.azure_location
  name                = local.name
  resource_group_name = module.aks.resource_group
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "federated-identity2" {
  count               = var.enable_wi ? 1 : 0
  name                = local.name
  resource_group_name = module.aks.resource_group
  audience            = ["api://AzureADTokenExchange"]
  issuer              = module.aks.cluster_oidc_url
  parent_id           = azurerm_user_assigned_identity.wi-id[count.index].id
  subject             = "system:serviceaccount:${var.wi_k8s_sa_ns}:${var.wi_k8s_sa_name}"

  depends_on = [module.aks]
}

data "azurerm_role_definition" "aks-user-role" {
  name  = "Azure Kubernetes Service Cluster User Role"
  scope = module.aks.cluster_id
}

resource "azurerm_role_assignment" "list-cluster-user-creds" {
  count              = var.enable_wi ? 1 : 0
  principal_id       = azurerm_user_assigned_identity.wi-id[0].principal_id
  scope              = module.aks.cluster_id
  role_definition_id = data.azurerm_role_definition.aks-user-role.id
}

provider "azuredevops" {
  org_service_url       = "https://dev.azure.com/${var.azuredevops_org}"
  personal_access_token = var.azuredevops_pat
}

module "devops" {
  count = var.enable_wi ? 1 : 0
  source = "git::https://github.com/fluxcd/test-infra.git//tf-modules/azure/devops"
  providers = {
    azuredevops = azuredevops
  }

  project_name    = local.project_name
  repository_name = local.repo_name
}
