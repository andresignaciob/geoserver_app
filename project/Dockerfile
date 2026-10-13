# syntax=docker/dockerfile:1
#
# GeoServer 2.28.x image built on top of the official OSGeo GeoServer image,
# with the SQL Server (mssql-jdbc) and MongoDB Java drivers baked in so both
# data stores are usable without any runtime download step.
#
# Build:
#   docker build -t my-geoserver:2.28 .
#
# Override the GeoServer patch version if needed, e.g.:
#   docker build --build-arg GS_VERSION=2.28.5 -t my-geoserver:2.28 .

ARG GS_VERSION=2.26.4

FROM docker.osgeo.org/geoserver:${GS_VERSION}

# ARGs must be re-declared after FROM to remain usable in this stage
ARG GS_VERSION=2.26.4
# Generic SourceForge redirector: it 302-redirects to whichever mirror is
# healthy for the requester, unlike a single hardcoded mirror hostname
# (e.g. sonik.dl.sourceforge.net) which can have DNS/connectivity issues.
ARG STABLE_PLUGIN_BASE_URL=https://sourceforge.net

LABEL maintainer="geoserver-heath" \
      description="GeoServer ${GS_VERSION} with SQL Server and MongoDB JDBC driver support"

USER root

# Download the official "sqlserver-plugin" (ships com.microsoft.sqlserver:mssql-jdbc)
# and "mongodb-plugin" (ships the MongoDB Java driver) extensions and drop their
# jars straight into the GeoServer webapp's WEB-INF/lib so the datastores are
# available as soon as the container starts, with no network access required
# at runtime. --retry handles transient mirror hiccups from the SourceForge
# redirector.
RUN set -eux; \
    curl -fsSL --retry 5 --retry-delay 3 --retry-connrefused -o /tmp/sqlserver-plugin.zip \
        "${STABLE_PLUGIN_BASE_URL}/projects/geoserver/files/GeoServer/${GS_VERSION}/extensions/geoserver-${GS_VERSION}-sqlserver-plugin.zip/download"; \
    curl -fsSL --retry 5 --retry-delay 3 --retry-connrefused -o /tmp/mongodb-plugin.zip \
        "${STABLE_PLUGIN_BASE_URL}/projects/geoserver/files/GeoServer/${GS_VERSION}/extensions/geoserver-${GS_VERSION}-mongodb-plugin.zip/download"; \
    curl -fsSL --retry 5 --retry-delay 3 --retry-connrefused -o /tmp/vectortiles-plugin.zip \
        "${STABLE_PLUGIN_BASE_URL}/projects/geoserver/files/GeoServer/${GS_VERSION}/extensions/geoserver-${GS_VERSION}-vectortiles-plugin.zip/download"; \
    mkdir -p /tmp/gs_plugins; \
    unzip -o /tmp/vectortiles-plugin.zip -d /tmp/gs_plugins; \
    unzip -o /tmp/sqlserver-plugin.zip -d /tmp/gs_plugins; \
    unzip -o /tmp/mongodb-plugin.zip -d /tmp/gs_plugins; \
    mv /tmp/gs_plugins/*.jar /usr/local/tomcat/webapps/geoserver/WEB-INF/lib/; \
    rm -rf /tmp/sqlserver-plugin.zip /tmp/mongodb-plugin.zip /tmp/vectortiles-plugin.zip /tmp/gs_plugins

COPY web.xml /usr/local/tomcat/webapps/geoserver/WEB-INF/web.xml

RUN set -eu; \
    server_xml=/opt/config/server.xml; \
    grep -q '<Engine name="Catalina" defaultHost="localhost">' "$server_xml"; \
    grep -q '^[[:space:]]*protocol="HTTP/1.1"[[:space:]]*$' "$server_xml"; \
    sed -i 's/^[[:space:]]*protocol="HTTP\/1.1"[[:space:]]*$/            protocol="HTTP\/1.1" scheme="https" secure="true"/' "$server_xml"; \
    grep -q 'protocol="HTTP/1.1" scheme="https" secure="true"' "$server_xml"
