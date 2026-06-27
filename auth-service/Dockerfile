FROM golang:1.21.13-alpine3.20 AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o auth-service .

FROM alpine:3.20.2
WORKDIR /app

RUN apk add --no-cache ca-certificates \
		&& addgroup -g 10001 -S app \
		&& adduser -u 10001 -S -D -H -G app app

COPY --from=builder /app/auth-service .

RUN chown app:app /app/auth-service

USER 10001:10001

EXPOSE 8001

HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
	CMD wget -q -O - http://127.0.0.1:8001/health > /dev/null || exit 1

CMD ["./auth-service"]
