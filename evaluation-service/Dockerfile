FROM golang:1.21-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o evaluation-service .

FROM alpine:latest
WORKDIR /app
COPY --from=builder /app/evaluation-service .
EXPOSE 8001
CMD ["./evaluation-service"]
