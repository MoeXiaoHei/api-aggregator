FROM golang:1.21 AS builder

WORKDIR /workspace

ENV GOPROXY=https://goproxy.cn,https://goproxy.io,direct
ENV GO111MODULE=on

COPY go.mod go.mod
COPY go.sum go.sum

RUN go mod download

COPY cmd/ cmd/
COPY pkg/ pkg/

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o aggregator cmd/aggregator/main.go

FROM alpine:latest
RUN apk --no-cache add ca-certificates
COPY --from=builder /workspace/aggregator /usr/local/bin/aggregator
ENTRYPOINT ["/usr/local/bin/aggregator"]
