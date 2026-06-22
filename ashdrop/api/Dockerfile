# ---- build stage ----
FROM golang:1.26-alpine AS build

WORKDIR /src

# Cache deps first
COPY go.mod go.sum ./
RUN go mod download

# Build a fully static binary. modernc.org/sqlite is pure Go, so CGO is off
# and the result needs no libc — it runs on a bare image.
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/ashdrop .

# ---- runtime stage ----
FROM alpine:3.20 AS run

# wget (busybox) is used by the healthcheck; add CA certs for good measure.
RUN apk add --no-cache ca-certificates \
	&& addgroup -S app && adduser -S app -G app \
	&& mkdir -p /data && chown app:app /data

COPY --from=build /out/ashdrop /usr/local/bin/ashdrop

ENV PORT=8080 \
	ASHDROP_DB=/data/ashdrop.db

EXPOSE 8080

# SQLite file lives here — mount a volume so drops survive restarts.
VOLUME ["/data"]

USER app

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
	CMD wget -qO- "http://127.0.0.1:${PORT}/healthz" || exit 1

ENTRYPOINT ["ashdrop"]
