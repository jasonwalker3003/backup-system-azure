output "data_account_name" {
  value = azurerm_storage_account.data.name
}
output "data_account_id" {
  value = azurerm_storage_account.data.id
}
output "blob_endpoint" {
  value = azurerm_storage_account.data.primary_blob_endpoint
}
