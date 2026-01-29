---
summary: "Azure Container Apps deployment plan for the Moltbot Gateway"
read_when:
  - You want a persistent Moltbot Gateway on Azure Container Apps
  - You need private Control UI access with secure outbound messaging
---

# Azure Container Apps: Moltbot Gateway deployment plan

This plan targets the January 2026 Moltbot Gateway-Node architecture. Build the
gateway image on **Node.js 22** and keep long-term memory on durable storage.

## Gateway-Node runtime checklist

- **Base image**: use a Node.js 22 image in your gateway container build.
- **Gateway entrypoint**: start the gateway process inside the container and
  expose port `18789` for the Control UI.
- **Stateful workspace**: mount `/home/node` so Moltbot can persist
  `~/.clawdbot/` and workspace files between revisions.
- **Gateway mode**: ensure `gateway.mode` is `local` so the gateway can start
  normally. See [Gateway configuration](/gateway/configuration).

Gateway start example:

```bash
moltbot gateway --port 18789
```

## Infrastructure overview

- **Compute**: Azure Container Apps (ACA) with a dedicated environment.
- **Storage**: Azure Files mounted at `/home/node` to persist `~/.clawdbot/` and
  gateway workspace data.
- **Control UI**: exposed only on a private VNet endpoint; access via Bastion or
  VPN.
- **Outbound access**: public egress for Slack and Microsoft Teams APIs.
- **Observability**: Log Analytics workspace for ACA logs and revisions.

## Bicep: Container Apps + Azure Files

```bicep
@description('Prefix for resource names')
param namePrefix string = 'moltbot'

@description('Azure region')
param location string = resourceGroup().location

@description('Container image for Moltbot Gateway (Node 22)')
param gatewayImage string

@description('Azure Files share name for /home/node')
param fileShareName string = 'moltbot-home'

@description('File share size in GB')
param fileShareQuota int = 100

@description('Container Apps environment VNet subnet ID')
param acaSubnetId string

@description('Private endpoint subnet ID')
param privateEndpointSubnetId string

@description('Log Analytics workspace ID')
param logAnalyticsWorkspaceId string

@description('Log Analytics shared key')
@secure()
param logAnalyticsSharedKey string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: '${namePrefix}sa'
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2022-09-01' = {
  name: '${storageAccount.name}/default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2022-09-01' = {
  name: '${storageAccount.name}/default/${fileShareName}'
  properties: {
    shareQuota: fileShareQuota
  }
}

resource containerEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: '${namePrefix}-aca-env'
  location: location
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: acaSubnetId
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspaceId
        sharedKey: logAnalyticsSharedKey
      }
    }
  }
}

resource envStorage 'Microsoft.App/managedEnvironments/storages@2023-05-01' = {
  name: '${containerEnv.name}/moltbot-home'
  properties: {
    azureFile: {
      accountName: storageAccount.name
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: fileShareName
      accessMode: 'ReadWrite'
    }
  }
}

resource gatewayApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: '${namePrefix}-gateway'
  location: location
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      ingress: {
        external: false
        targetPort: 18789
        transport: 'http'
      }
      registries: []
      secrets: [
        {
          name: 'storage-key'
          value: storageAccount.listKeys().keys[0].value
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'gateway'
          image: gatewayImage
          resources: {
            cpu: 1
            memory: '2Gi'
          }
          env: [
            {
              name: 'HOME'
              value: '/home/node'
            }
          ]
          volumeMounts: [
            {
              volumeName: 'home'
              mountPath: '/home/node'
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'home'
          storageType: 'AzureFile'
          storageName: envStorage.name
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 2
      }
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: '${namePrefix}-gateway-pe'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${namePrefix}-gateway-conn'
        properties: {
          privateLinkServiceId: gatewayApp.id
          groupIds: [
            'containerApps'
          ]
        }
      }
    ]
  }
}
```

## Terraform: Container Apps + Azure Files

```hcl
variable "name_prefix" { type = string }
variable "location" { type = string }
variable "gateway_image" { type = string }
variable "aca_subnet_id" { type = string }
variable "private_endpoint_subnet_id" { type = string }
variable "log_analytics_workspace_id" { type = string }
variable "log_analytics_shared_key" { type = string }

resource "azurerm_storage_account" "moltbot" {
  name                     = "${var.name_prefix}sa"
  resource_group_name      = azurerm_resource_group.moltbot.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_share" "home" {
  name                 = "moltbot-home"
  storage_account_name = azurerm_storage_account.moltbot.name
  quota                = 100
}

resource "azurerm_container_app_environment" "moltbot" {
  name                       = "${var.name_prefix}-aca-env"
  location                   = var.location
  resource_group_name        = azurerm_resource_group.moltbot.name
  infrastructure_subnet_id   = var.aca_subnet_id
  log_analytics_workspace_id = var.log_analytics_workspace_id
}

resource "azurerm_container_app_environment_storage" "home" {
  name                         = "moltbot-home"
  container_app_environment_id = azurerm_container_app_environment.moltbot.id
  account_name                 = azurerm_storage_account.moltbot.name
  share_name                   = azurerm_storage_share.home.name
  access_key                   = azurerm_storage_account.moltbot.primary_access_key
  access_mode                  = "ReadWrite"
}

resource "azurerm_container_app" "gateway" {
  name                         = "${var.name_prefix}-gateway"
  container_app_environment_id = azurerm_container_app_environment.moltbot.id
  resource_group_name          = azurerm_resource_group.moltbot.name
  revision_mode                = "Single"

  ingress {
    external_enabled = false
    target_port      = 18789
    transport        = "http"
  }

  template {
    container {
      name   = "gateway"
      image  = var.gateway_image
      cpu    = 1
      memory = "2Gi"

      env {
        name  = "HOME"
        value = "/home/node"
      }

      volume_mounts {
        name = "home"
        path = "/home/node"
      }
    }

    volume {
      name = "home"
      storage_type = "AzureFile"
      storage_name = azurerm_container_app_environment_storage.home.name
    }

    min_replicas = 1
    max_replicas = 2
  }
}

resource "azurerm_private_endpoint" "gateway" {
  name                = "${var.name_prefix}-gateway-pe"
  location            = var.location
  resource_group_name = azurerm_resource_group.moltbot.name
  subnet_id           = var.private_endpoint_subnet_id

  private_service_connection {
    name                           = "${var.name_prefix}-gateway-conn"
    private_connection_resource_id = azurerm_container_app.gateway.id
    subresource_names              = ["containerApps"]
    is_manual_connection           = false
  }
}
```

## Network and security

- **Private Control UI**: keep ACA ingress internal-only and attach a private
  endpoint in a locked subnet. Access via **Azure Bastion** or **VPN Gateway**
  on the same VNet, and add a private DNS zone for the endpoint so the Control
  UI hostname resolves on the private network.
- **Outbound channels**: allow egress to Slack and Microsoft Teams APIs through
  a NAT Gateway or Azure Firewall with FQDN rules for the API endpoints.
- **Secrets**: use ACA secrets for gateway tokens, Slack tokens, and Teams app
  credentials; do not bake secrets into images.

## Azure OpenAI “Brain” configuration

Azure OpenAI exposes OpenAI-compatible endpoints, so treat it as a custom model
provider and point `models.providers` at your deployment base URL. Follow the
custom provider pattern in [Model providers](/concepts/model-providers) and
[Gateway configuration](/gateway/configuration).

- **Provider selection**: register a custom provider with your Azure OpenAI
  base URL and API key placeholder.
- **Resource isolation**: keep the Azure OpenAI resource in the same region as
  the ACA environment for latency and data locality.
- **Model routing**: set `agents.defaults.model.primary` to your Azure OpenAI
  deployment ID (provider/model) so all inference uses your Azure allocation.

Example (JSON5):

```json5
{
  env: { AZURE_OPENAI_API_KEY: "set-in-aca-secrets" },
  agents: {
    defaults: {
      model: { primary: "azure-openai/gpt-4o" },
      models: { "azure-openai/gpt-4o": { alias: "Azure GPT-4o" } }
    }
  },
  models: {
    mode: "merge",
    providers: {
      "azure-openai": {
        baseUrl: "https://<resource-name>.openai.azure.com/openai/deployments/<deployment>/v1",
        apiKey: "${AZURE_OPENAI_API_KEY}",
        api: "openai-completions",
        models: [
          {
            id: "gpt-4o",
            name: "Azure GPT-4o",
            reasoning: false,
            input: ["text"],
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
            contextWindow: 128000,
            maxTokens: 8192
          }
        ]
      }
    }
  }
}
```

## Business workflow integration roadmap

1. **GitHub**
   - Install the Moltbot GitHub App or configure a webhook to the gateway.
   - Use gateway hooks to enqueue system events on PR creation, CI failure, or
     deployment status changes.
2. **Azure DevOps Boards**
   - Subscribe to ADO service hooks and send them to the gateway webhook.
   - Map work item updates to system events so the next heartbeat can summarize
     changes.
3. **CRM (HubSpot or Salesforce)**
   - Use CRM webhooks to post ticket events into the gateway.
   - Tag high-priority tickets to trigger immediate heartbeat alerts.

## Heartbeat engine (proactive alerts)

Use heartbeats to check deployment status and escalate to Slack when needed.

```yaml
agents:
  defaults:
    heartbeat:
      every: "15m"
      target: "slack"
      to: "slack:channel:ops-alerts"
      prompt: |
        Read HEARTBEAT.md if it exists (workspace context). Follow it strictly.
        Check deployment status and urgent support tickets. If any critical
        failures exist, post an alert with the system name, impact, and next
        action. If everything is healthy, reply HEARTBEAT_OK.
```

Optionally, have CI/CD or ticketing systems call the gateway webhook to trigger
an immediate heartbeat for high-priority events. See [Webhook automation](/automation/webhook)
and [Heartbeat](/gateway/heartbeat).
