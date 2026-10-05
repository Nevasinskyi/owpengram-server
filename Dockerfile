ARG GO_IMAGE=golang:1.25-alpine
ARG ALPINE_IMAGE=alpine:3.22

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS build-base

ARG TARGETOS
ARG TARGETARCH

RUN apk add --no-cache ca-certificates git

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY cmd/ ./cmd/
COPY deploy/ ./deploy/
COPY internal/ ./internal/
COPY data/ ./data/

ENV CGO_ENABLED=0

FROM build-base AS build-server

ARG VCS_REF=unknown
ARG VCS_BRANCH=unknown
ARG VCS_TREE_STATE=unknown
ARG BUILD_DATE=unknown

RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath \
    -ldflags="-s -w -X main.gitCommit=${VCS_REF} -X main.gitBranch=${VCS_BRANCH} -X main.gitTreeState=${VCS_TREE_STATE} -X main.buildTime=${BUILD_DATE}" \
    -o /out/telesrv \
    ./cmd/telesrv

FROM build-base AS build-admin

RUN apk add --no-cache nodejs npm

WORKDIR /src/cmd/telesrv-admin/web

RUN npm ci && npm run build

WORKDIR /src

RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath \
    -ldflags="-s -w" \
    -o /out/telesrv-admin \
    ./cmd/telesrv-admin

FROM ${ALPINE_IMAGE}

RUN apk add --no-cache \
    ca-certificates \
    tzdata \
    ffmpeg \
    openssl

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

COPY start.sh /usr/local/bin/start.sh

COPY --from=build-server \
    /out/telesrv \
    /usr/local/bin/telesrv

COPY --from=build-admin \
    /out/telesrv-admin \
    /usr/local/bin/telesrv-admin

COPY --chown=telesrv:telesrv \
    data/langpack/ \
    /usr/share/telesrv/langpack/

RUN chmod 0555 \
    /usr/local/bin/telesrv \
    /usr/local/bin/telesrv-admin \
    /usr/local/bin/telesrv-container-entrypoint \
    /usr/local/bin/start.sh

WORKDIR /app

USER 10001:10001

EXPOSE 2398
EXPOSE 2400
EXPOSE 2401
EXPOSE 2399
EXPOSE 2600
EXPOSE 12399/udp
EXPOSE 12400/udp

ENTRYPOINT ["/usr/local/bin/start.sh"]
