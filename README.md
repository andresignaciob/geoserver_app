# GeoServer on Azure App Service

The repository builds GeoServer `2.26.4` with the SQL Server, MongoDB and Vector Tiles extensions. The extensions are installed in the image at build time; the container does not need to download them on startup.

## Run locally

From `project/`, create a local environment file from `.env.example` and set a strong admin password:

```powershell
if (!(Test-Path .env)) { Copy-Item .env.example .env }
docker compose -f docker-compose.local.yml up --build
```

GeoServer is available at `http://localhost:8080/geoserver/web/`. The local Compose file uses Docker-managed volumes and does not require an Azure account or CIFS support. Stop it with `docker compose -f docker-compose.local.yml down`; data remains in the volumes. Do not use `down --volumes` unless you intend to delete that data.

## Azure storage layout

The root `docker-compose.yml` is the CIFS configuration for a Linux Docker host. It mounts three folders from `AZURE_FILE_SHARE` in the storage account: `data_dir`, `fonts`, and `certs`. It is not the mechanism App Service uses to mount storage.

App Service mounts the complete Azure Files share at `/opt/geoserver`. The share must contain these subdirectories:

| Share subdirectory | Container path |
| --- | --- |
| `data_dir/` | `/opt/geoserver/data_dir` |
| `fonts/` | `/opt/geoserver/fonts` |
| `certs/` | `/opt/geoserver/certs` |

The deployment creates the share if needed and configures one App Service storage mount. Before first production use, copy the existing `data_dir`, `fonts`, and `certs` folder contents into these corresponding subdirectories, for example with Azure Storage Explorer. Do not start production against an empty share if it contains data needed by the service.

`web.xml` and the GeoServer application files/plugins stay inside the versioned container image; App Service does not mount `WEB-INF`. On deployment, the script removes old App Service mounts used by the previous layout, but leaves their Azure File Shares and contents untouched. Review and remove old shares manually only after confirming they are no longer needed.
Tomcat honors the reverse proxy's `X-Forwarded-Proto` header, so HTTPS-terminated requests retain the external HTTPS scheme when GeoServer builds redirects. Any other reverse proxy in front of this image must send that header.
The image also configures the Tomcat HTTP connector with `scheme="https"` and `secure="true"` during the Docker build, so GeoServer generates HTTPS redirects when running behind the HTTPS-terminating App Service proxy.

## App Service prerequisites

Create a Linux App Service with a custom-container-capable plan and an Azure Container Registry. Use a plan with memory/CPU sized for the GeoServer workload; the default JVM heap in Compose is 2 GB. Configure the App Service system-assigned identity and grant it `AcrPull` on the registry so the app can pull the private image without registry passwords. Configure TLS/custom domain and restrict the GeoServer admin endpoint at the network or access-restriction layer before exposing it publicly.

Start with one App Service instance. GeoServer writes to the data directory and GeoWebCache; scaling horizontally requires a deliberate GeoServer clustering/cache strategy and validation of shared-storage locking/consistency. Also ensure storage networking/firewall rules allow App Service to reach Azure Files; use VNet integration and private networking where required by policy.

The GitHub Actions identity uses OIDC. Create a federated credential for this repository and its deployment branch/environment. Grant that identity permission to push to ACR, update the App Service configuration and restart the app. App Service's own managed identity separately needs `AcrPull` on ACR. The workflow identity also needs permission to configure the Web App's storage mounts; it uses the supplied storage key to create the shares.

Set these GitHub repository variables:

- `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
- `AZURE_RESOURCE_GROUP`, `AZURE_WEBAPP_NAME`, `WEBAPP_URL`
- `ACR_NAME`, `ACR_LOGIN_SERVER`
- `AZURE_STORAGE_ACCOUNT`
- `AZURE_APPSERVICE_SHARE_DATA`
- `GEOSERVER_ADMIN_USER`

Set these GitHub repository secrets:

- `AZURE_STORAGE_KEY`
- `GEOSERVER_ADMIN_PASSWORD`

Push to `main` (or run the workflow manually) to build an immutable image tagged with the commit SHA, push it to ACR, configure storage mounts and App Service settings, deploy, restart, and check `/geoserver/web/` for health. The workflow sets `WEBSITES_PORT=8080` and a longer container startup timeout. Pin and review action versions according to your organization's supply-chain policy.

## Deploy with Azure DevOps

Create a pipeline from `azure-pipelines.yml` and an Azure Resource Manager service connection named by the `AZURE_SERVICE_CONNECTION` pipeline variable. Prefer workload identity federation for that connection. Its identity needs permission to push images to ACR and update/restart the Web App. The App Service managed identity separately needs `AcrPull` on ACR. The storage account key is passed only as a secret pipeline variable to configure the Azure Files shares and App Service mounts.

Set these pipeline variables (or place them in a restricted variable group):

- `AZURE_SERVICE_CONNECTION` (name of the Azure Resource Manager service connection)
- `ACR_NAME`, `ACR_LOGIN_SERVER`
- `AZURE_RESOURCE_GROUP`, `AZURE_WEBAPP_NAME`, `WEBAPP_URL`
- `AZURE_STORAGE_ACCOUNT`
- `AZURE_APPSERVICE_SHARE_DATA`
- `GEOSERVER_ADMIN_USER`

Set `AZURE_STORAGE_KEY` and `GEOSERVER_ADMIN_PASSWORD` as secret variables. Limit variable-group and service-connection permissions to this pipeline. The pipeline deploys on pushes to `main` and can also be run manually; configure Azure DevOps approvals/checks on the production environment or pipeline before enabling automatic production deployment.

Both CI systems invoke `scripts/deploy-appservice.sh`, so image tagging, storage setup, App Service configuration and health verification follow the same steps.

## Deployment notes

- The current configuration keeps GeoServer `2.26.4`; change the Compose build argument and the workflow's `GS_VERSION` together when upgrading.
- Store secrets in GitHub/Azure secret stores only. Do not commit `.env` or storage keys.
- App Service mounts should be configured before the container starts. Keep application files such as `WEB-INF` in the image; persist only GeoServer data and externally managed resources.
- The root Compose file requires a Linux Docker engine with CIFS mount support. For ordinary workstation development, use `docker-compose.local.yml` instead.