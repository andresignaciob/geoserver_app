#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

on_error() {
  local exit_code=$?
  log "ERROR: deployment failed at line ${BASH_LINENO[0]} with exit code ${exit_code}" >&2
  exit "$exit_code"
}

trap on_error ERR

log "Starting GeoServer App Service deployment"

: "${GS_VERSION:?Set GS_VERSION}"
: "${IMAGE_TAG:?Set IMAGE_TAG, typically the source commit SHA}"
: "${ACR_NAME:?Set ACR_NAME}"
: "${ACR_LOGIN_SERVER:?Set ACR_LOGIN_SERVER}"
: "${RESOURCE_GROUP:?Set AZURE_RESOURCE_GROUP}"
: "${WEBAPP_NAME:?Set AZURE_WEBAPP_NAME}"
: "${ADMIN_USER:?Set GEOSERVER_ADMIN_USER}"
: "${ADMIN_PASSWORD:?Set GEOSERVER_ADMIN_PASSWORD secret}"
: "${STORAGE_ACCOUNT:?Set AZURE_STORAGE_ACCOUNT}"
: "${STORAGE_KEY:?Set AZURE_STORAGE_KEY secret}"
: "${SHARE_DATA:?Set AZURE_APPSERVICE_SHARE_DATA}"

image="${ACR_LOGIN_SERVER}/geoserver:${IMAGE_TAG}"
if (( ${#STORAGE_KEY} >= 5 )); then
  storage_key_suffix="${STORAGE_KEY: -5}"
else
  storage_key_suffix="<short-key>"
fi

log "Configuration validated for resource group '${RESOURCE_GROUP}', web app '${WEBAPP_NAME}', image '${image}'"
log "Using storage account '${STORAGE_ACCOUNT}' with storage key suffix '*****${storage_key_suffix}'"
log "Signing in to Azure Container Registry '${ACR_NAME}'"
az acr login --name "$ACR_NAME"

log "Building Docker image"
docker build \
  --file project/Dockerfile \
  --build-arg "GS_VERSION=${GS_VERSION}" \
  --tag "$image" \
  project

log "Pushing Docker image to '${ACR_LOGIN_SERVER}'"
docker push "$image"
log "Docker image pushed successfully"

log "Creating or verifying Azure File Share '${SHARE_DATA}'"
az storage share create \
  --name "$SHARE_DATA" \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --only-show-errors \
  --output none

log "Removing obsolete App Service storage mounts"
for mount_id in geoserver-web geoserver-data geoserver-fonts geoserver-certs geoserver-storage; do
  mount_count="$(az webapp config storage-account list \
    --resource-group "$RESOURCE_GROUP" \
    --name "$WEBAPP_NAME" \
    --query "[?name=='${mount_id}'] | length(@)" \
    --output tsv)"
  if [[ "$mount_count" != "0" ]]; then
    az webapp config storage-account delete \
      --resource-group "$RESOURCE_GROUP" \
      --name "$WEBAPP_NAME" \
      --custom-id "$mount_id" \
      --only-show-errors \
      --output none
  fi
done

log "Configuring Azure File Share mount at /opt/geoserver"
az webapp config storage-account add \
  --resource-group "$RESOURCE_GROUP" --name "$WEBAPP_NAME" \
  --custom-id geoserver-storage --storage-type AzureFiles \
  --account-name "$STORAGE_ACCOUNT" --share-name "$SHARE_DATA" \
  --access-key "$STORAGE_KEY" --mount-path /opt/geoserver \
  --only-show-errors --output none

log "Configuring App Service container image"
az webapp config container set \
  --name "$WEBAPP_NAME" --resource-group "$RESOURCE_GROUP" \
  --container-image-name "$image" \
  --container-registry-url "https://${ACR_LOGIN_SERVER}" \
  --enable-app-service-storage true \
  --only-show-errors --output none

log "Enabling managed identity authentication for ACR pulls"
az webapp config set \
  --name "$WEBAPP_NAME" --resource-group "$RESOURCE_GROUP" \
  --generic-configurations '{"acrUseManagedIdentityCreds":true}' \
  --only-show-errors --output none

log "Configuring GeoServer application settings"
az webapp config appsettings set \
  --name "$WEBAPP_NAME" --resource-group "$RESOURCE_GROUP" \
  --settings \
    WEBSITES_PORT=8080 \
    WEBSITES_CONTAINER_START_TIME_LIMIT=1800 \
    "GEOSERVER_ADMIN_USER=${ADMIN_USER}" \
    "GEOSERVER_ADMIN_PASSWORD=${ADMIN_PASSWORD}" \
    GEOSERVER_DATA_DIR=/opt/geoserver/data_dir \
    GEOWEBCACHE_CACHE_DIR=/opt/geoserver/data_dir/gwc \
  --only-show-errors --output none

log "Restarting App Service"
az webapp restart --name "$WEBAPP_NAME" --resource-group "$RESOURCE_GROUP" \
  --only-show-errors --output none

health_url="https://${WEBAPP_NAME}.azurewebsites.net/geoserver/web/"
log "Waiting for GeoServer health endpoint: ${health_url}"
for attempt in $(seq 1 60); do
  if curl --fail --silent --show-error --output /dev/null "$health_url"; then
    log "GeoServer is healthy at ${health_url}"
    exit 0
  fi
  if (( attempt == 1 || attempt % 5 == 0 )); then
    log "Health check attempt ${attempt}/60 failed; retrying in 20 seconds"
  fi
  sleep 20
done
log "ERROR: GeoServer did not become healthy at ${health_url}" >&2
exit 1