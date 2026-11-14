#!/usr/bin/env bash
# Creates the backup agent identity and its no-delete role. Run by a person, not the pipeline.
set -euo pipefail
: "${P2_PREFIX:?Run: source ~/p2.env}"
ROLE_NAME="Backup Writer ($P2_PREFIX)"
RG_ID=$(az group show -n "$P2_RG" --query id -o tsv)
SA_ID=$(az storage account show -n "$P2_DATA_SA" -g "$P2_RG" --query id -o tsv)

echo "Creating the custom role (no delete)..."
if [ -z "$(az role definition list --name "$ROLE_NAME" --query "[0].id" -o tsv)" ]; then
  jq -n --arg name "$ROLE_NAME" --arg scope "$RG_ID" '{
    Name: $name, IsCustom: true,
    Description: "List, read and write backup blobs. Cannot delete.",
    Actions: [], NotActions: [],
    DataActions: [
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write",
      "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action"
    ],
    NotDataActions: [],
    AssignableScopes: [$scope]
  }' > /tmp/backup-role.json
  az role definition create --role-definition @/tmp/backup-role.json -o none
  sleep 30   # custom roles take a moment to become assignable
fi

echo "Creating the backup agent identity..."
APP_ID=$(az ad app list --display-name "backup-agent-$P2_PREFIX" --query "[0].appId" -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "backup-agent-$P2_PREFIX" --query appId -o tsv)
  sleep 20
fi
SP_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || az ad sp create --id "$APP_ID" --query id -o tsv)

az role assignment create --assignee-object-id "$SP_ID" --assignee-principal-type ServicePrincipal \
  --role "$ROLE_NAME" --scope "$SA_ID" -o none

echo "Creating a 180-day secret and saving it to ~/.backup-agent.env (outside the repo)..."
SECRET=$(az ad app credential reset --id "$APP_ID" --display-name backup-agent \
  --end-date "$(date -d '+180 days' +%F)" --query password -o tsv)
cat > ~/.backup-agent.env <<EOF
export AZCOPY_AUTO_LOGIN_TYPE=SPN
export AZCOPY_SPA_APPLICATION_ID=$APP_ID
export AZCOPY_SPA_CLIENT_SECRET=$SECRET
export AZCOPY_TENANT_ID=$(az account show --query tenantId -o tsv)
export BACKUP_ACCOUNT=$P2_DATA_SA
export BACKUP_SOURCE=$HOME/backup-source
EOF
chmod 600 ~/.backup-agent.env
echo "Done. Secret expires $(date -d '+180 days' +%F): put a reminder in your calendar."
