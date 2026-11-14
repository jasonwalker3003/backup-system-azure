data "azurerm_resource_group" "main" {
  name = "rg-${var.prefix}"
}

locals {
  rg         = data.azurerm_resource_group.main.name
  location   = data.azurerm_resource_group.main.location
  containers = toset(["documents", "photos", "database", "reports"])
  tags       = { project = "backup-system", owner = "jason", env = "prod" }
}

# ---------- The backup vault ----------
resource "azurerm_storage_account" "data" {
  name                            = "st${var.prefix}data"
  resource_group_name             = local.rg
  location                        = local.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS" # 3 copies in one data centre; Archive tier needs LRS/GRS
  access_tier                     = "Hot"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true # every overwrite keeps the old version
    delete_retention_policy {
      days = 14 # deleted blobs recoverable for 14 days
    }
    container_delete_retention_policy {
      days = 14 # deleted containers too
    }
  }

  # Version-level immutability: each saved version is locked for retention_days.
  # Can only be switched on when the account is created. NEVER set state = "Locked" in the lab.
  immutability_policy {
    state                         = "Unlocked"
    period_since_creation_in_days = var.retention_days
    allow_protected_append_writes = false
  }

  tags = local.tags
}

resource "azurerm_storage_container" "c" {
  for_each              = local.containers
  name                  = each.key
  storage_account_id    = azurerm_storage_account.data.id
  container_access_type = "private"
}

# ---------- Cost control: move old data to cheaper tiers ----------
resource "azurerm_storage_management_policy" "tiering" {
  storage_account_id = azurerm_storage_account.data.id

  rule {
    name    = "tier-and-expire"
    enabled = true
    filters {
      blob_types = ["blockBlob"]
    }
    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 30
        tier_to_archive_after_days_since_modification_greater_than = 90
        delete_after_days_since_modification_greater_than          = 365
      }
      version {
        change_tier_to_cool_after_days_since_creation = 30
        delete_after_days_since_creation              = 90 # "any day in the last 90"
      }
    }
  }
}

# ---------- Monitoring: log writes, alert when the heartbeat goes missing ----------
resource "azurerm_log_analytics_workspace" "logs" {
  name                = "log-${var.prefix}"
  resource_group_name = local.rg
  location            = local.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 0.2 # cost guard
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "blob" {
  name                       = "blob-to-log-analytics"
  target_resource_id         = "${azurerm_storage_account.data.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.logs.id
  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }
}

resource "azurerm_monitor_action_group" "email" {
  name                = "ag-${var.prefix}"
  resource_group_name = local.rg
  short_name          = "backupops"
  email_receiver {
    name                    = "owner"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
  tags = local.tags
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "missed_backup" {
  name                  = "alert-${var.prefix}-missed-backup"
  resource_group_name   = local.rg
  location              = local.location
  description           = "No successful backup heartbeat within the window"
  severity              = 2
  scopes                = [azurerm_log_analytics_workspace.logs.id]
  evaluation_frequency  = "PT1H"
  window_duration       = var.missed_backup_window
  skip_query_validation = true # the StorageBlobLogs table only appears after the first logged write

  criteria {
    query                   = <<-KQL
      StorageBlobLogs
      | where OperationName in ("PutBlob", "PutBlockList")
      | where StatusText == "Success"
      | where Uri has "/reports/"
    KQL
    time_aggregation_method = "Count"
    operator                = "LessThan"
    threshold               = 1
    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  auto_mitigation_enabled = true
  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }
  tags = local.tags
}
