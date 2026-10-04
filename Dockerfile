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

EXPOSE 2398
EXPOSE 2400
EXPOSE 2401
EXPOSE 2599
EXPOSE 2600
EXPOSE 12399/udp
EXPOSE 12400/udp

USER 10001:10001

CMD ["sh", "-c", "telesrv & telesrv-admin & wait"]
