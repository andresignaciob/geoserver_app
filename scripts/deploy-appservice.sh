#!/usr/bin/env bash
set -euo pipefail

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
: "${SHARE_FONTS:?Set AZURE_APPSERVICE_SHARE_FONTS}"
: "${SHARE_CERTS:?Set AZURE_APPSERVICE_SHARE_CERTS}"

image="${ACR_LOGIN_SERVER}/geoserver:${IMAGE_TAG}"

az acr login --name "$ACR_NAME"
docker build \
  --file project/Dockerfile \
  --build-arg "GS_VERSION=${GS_VERSION}" \
  --tag "$image" \
  project
docker push "$image"

for share in "$SHARE_DATA" "$SHARE_FONTS" "$SHARE_CERTS"; do
  az storage share create \
    --name "$share" \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --only-show-errors \
    --output none
done

web_mount_count="$(az webapp config storage-account list \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --query "[?name=='geoserver-web'] | length(@)" \
  --output tsv)"
if [[ "$web_mount_count" != "0" ]]; then
  az webapp config storage-account delete \
    --resource-group "$RESOURCE_GROUP" \
    --name "$WEBAPP_NAME" \
    --custom-id geoserver-web \
    --only-show-errors \
    --output none
fi

az webapp config storage-account add \
  --resource-group "$RESOURCE_GROUP" --name "$WEBAPP_NAME" \
  --custom-id geoserver-data --storage-type AzureFiles \
  --account-name "$STORAGE_ACCOUNT" --share-name "$SHARE_DATA" \
  --access-key "$STORAGE_KEY" --mount-path /opt/geoserver/data_dir \
  --only-show-errors --output none
az webapp config storage-account add \
  --resource-group "$RESOURCE_GROUP" --name "$WEBAPP_NAME" \
  --custom-id geoserver-fonts --storage-type AzureFiles \
  --account-name "$STORAGE_ACCOUNT" --share-name "$SHARE_FONTS" \
  --access-key "$STORAGE_KEY" --mount-path /opt/fonts \
  --only-show-errors --output none
az webapp config storage-account add \
  --resource-group "$RESOURCE_GROUP" --name "$WEBAPP_NAME" \
  --custom-id geoserver-certs --storage-type AzureFiles \
  --account-name "$STORAGE_ACCOUNT" --share-name "$SHARE_CERTS" \
  --access-key "$STORAGE_KEY" --mount-path /etc/certs \
  --only-show-errors --output none

az webapp config container set \
  --name "$WEBAPP_NAME" --resource-group "$RESOURCE_GROUP" \
  --container-image-name "$image" \
  --container-registry-url "https://${ACR_LOGIN_SERVER}" \
  --enable-app-service-storage true \
  --only-show-errors --output none
az webapp config set \
  --name "$WEBAPP_NAME" --resource-group "$RESOURCE_GROUP" \
  --generic-configurations '{"acrUseManagedIdentityCreds":true}' \
  --only-show-errors --output none
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
az webapp restart --name "$WEBAPP_NAME" --resource-group "$RESOURCE_GROUP" \
  --only-show-errors --output none

health_url="https://${WEBAPP_NAME}.azurewebsites.net/geoserver/web/"
for attempt in $(seq 1 60); do
  if curl --fail --silent --show-error --output /dev/null "$health_url"; then
    echo "GeoServer is healthy at ${health_url}"
    exit 0
  fi
  sleep 20
done
echo "GeoServer did not become healthy at ${health_url}" >&2
exit 1