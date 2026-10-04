ARG GO_IMAGE=golang:1.25-alpine
ARG ALPINE_IMAGE=alpine:3.22
ARG NODE_IMAGE=node:20-alpine

FROM ${GO_IMAGE} AS build-base

RUN apk add --no-cache ca-certificates git
WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY cmd/ ./cmd/
COPY deploy/ ./deploy/
COPY internal/ ./internal/

ENV CGO_ENABLED=0

# =========================
# BUILD TELEsrv
# =========================

FROM build-base AS build-server

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath \
    -ldflags="-s -w" \
    -o /out/telesrv ./cmd/telesrv

# =========================
# BUILD ADMIN
# =========================

FROM ${NODE_IMAGE} AS build-web

WORKDIR /src/cmd/telesrv-admin/web

COPY cmd/telesrv-admin/web/package.json cmd/telesrv-admin/web/package-lock.json ./
RUN npm ci

COPY cmd/telesrv-admin/web/ ./
RUN npm run build

FROM build-base AS build-admin

COPY --from=build-web /src/cmd/telesrv-admin/web/dist /src/cmd/telesrv-admin/web/dist

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath \
    -ldflags="-s -w" \
    -o /out/telesrv-admin ./cmd/telesrv-admin

# =========================
# RUNTIME
# =========================

FROM ${ALPINE_IMAGE} AS runtime-base

RUN apk add --no-cache ca-certificates tzdata \
    && addgroup -g 1000 app 2>/dev/null || true \
    && adduser -S -D -H -u 1000 -G app app 2>/dev/null || true \
    && install -d -o 1000 -g 1000 -m 0750 /app

WORKDIR /app
USER 1000:1000

# =========================
# FINAL
# =========================

FROM runtime-base AS admin

COPY --from=build-server /out/telesrv /usr/local/bin/telesrv
COPY --from=build-admin /out/telesrv-admin /usr/local/bin/telesrv-admin

ENV PORT=2600

EXPOSE 2398
EXPOSE 2600

USER 1000:1000

CMD ["sh", "-c", "telesrv & telesrv-admin & wait"]
