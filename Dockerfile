FROM golang:1.21 AS builder

WORKDIR /workspace

ENV GOPROXY=https://mirrors.aliyun.com/goproxy/,https://goproxy.cn,https://goproxy.io,direct
ENV GO111MODULE=on

# 复制 go mod 文件
COPY go.mod go.mod
COPY go.sum go.sum

# 下载依赖
RUN go mod download

# 复制源码
COPY cmd/ cmd/
COPY pkg/ pkg/

# 构建
# RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -a -o aggregator cmd/aggregator/main.go
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        GOARCH=amd64; \
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then \
        GOARCH=arm64; \
    else \
        echo "Unsupported architecture: $ARCH"; \
        exit 1; \
    fi && \
    echo "Building for architecture: $GOARCH" && \
    CGO_ENABLED=0 GOOS=linux GOARCH=${GOARCH} go build -a -o aggregator cmd/aggregator/main.go
# 最终镜像
FROM alpine:latest
RUN apk --no-cache add ca-certificates
COPY --from=builder /workspace/aggregator /usr/local/bin/aggregator
ENTRYPOINT ["/usr/local/bin/aggregator"]
