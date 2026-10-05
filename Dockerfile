ARG GO_IMAGE=golang:1.25-alpine
ARG ALPINE_IMAGE=alpine:3.22

FROM ${GO_IMAGE} AS build-base

RUN apk add --no-cache ca-certificates git

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY cmd/ ./cmd/
COPY deploy/ ./deploy/
COPY internal/ ./internal/
COPY data/ ./data/


FROM build-base AS build-server

ENV CGO_ENABLED=0

RUN go build \
    -p 1 \
    -trimpath \
    -ldflags="-s -w" \
    -o /out/telesrv \
    ./cmd/telesrv


FROM build-base AS build-admin

RUN apk add --no-cache nodejs npm

WORKDIR /src/cmd/telesrv-admin/web

RUN npm ci && npm run build

WORKDIR /src

ENV CGO_ENABLED=0

RUN go build \
    -p 1 \
    -trimpath \
    -ldflags="-s -w" \
    -o /out/telesrv-admin \
    ./cmd/telesrv-admin


FROM ${ALPINE_IMAGE} AS runtime-base

RUN apk add --no-cache \
    ca-certificates \
    tzdata \
    ffmpeg \
    openssl \
    postgresql-client

RUN addgroup -S -g 10001 telesrv \
    && adduser -S -D -H -u 10001 -G telesrv telesrv \
    && install -d -o telesrv -g telesrv -m 0750 \
       /app \
       /var/lib/telesrv \
       /var/lib/telesrv/blobs \
       /var/lib/telesrv/blob-staging \
       /var/lib/telesrv/maptiles \
       /var/lib/telesrv/livestream

COPY deploy/docker/docker-entrypoint.sh \
    /usr/local/bin/telesrv-container-entrypoint

RUN chmod 0555 /usr/local/bin/telesrv-container-entrypoint

WORKDIR /app


FROM runtime-base AS blitz

COPY --from=build-server /out/telesrv \
    /usr/local/bin/telesrv

COPY --from=build-admin /out/telesrv-admin \
    /usr/local/bin/telesrv-admin

COPY data/langpack/ \
    /usr/share/telesrv/langpack/

RUN chmod 0555 \
    /usr/local/bin/telesrv \
    /usr/local/bin/telesrv-admin


COPY <<'EOF' /usr/local/bin/reset-migration.sh
#!/bin/sh

set -e

echo "[migration] Waiting for PostgreSQL..."

until pg_isready -d "$DATABASE_URL" >/dev/null 2>&1; do
    echo "[migration] PostgreSQL is not ready..."
    sleep 2
done

echo "[migration] Checking dirty migrations..."

DIRTY_VERSION="$(psql "$DATABASE_URL" -tAc \
    "SELECT version FROM schema_migrations WHERE dirty = true ORDER BY version DESC LIMIT 1;" \
    | tr -d '[:space:]')"

if [ -z "$DIRTY_VERSION" ]; then
    echo "[migration] No dirty migrations found."
else
    echo "[migration] Found dirty migration: $DIRTY_VERSION"

    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c \
        "UPDATE schema_migrations SET dirty = false WHERE version = $DIRTY_VERSION;"

    echo "[migration] Dirty flag reset successfully."
fi

echo "[migration] Starting telesrv..."

exec /usr/local/bin/telesrv
EOF

RUN chmod 0555 /usr/local/bin/reset-migration.sh


EXPOSE 2398
EXPOSE 2400
EXPOSE 2401
EXPOSE 2599
EXPOSE 2600
EXPOSE 12399/udp
EXPOSE 12400/udp

USER 10001:10001

CMD ["/usr/local/bin/reset-migration.sh"]
