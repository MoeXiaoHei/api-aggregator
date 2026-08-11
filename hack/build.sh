#!/bin/bash
set -e

IMAGE="oicq/api-aggregator:latest"

echo "🔨 Building API Aggregator..."

# 构建镜像
docker build -t ${IMAGE} .

# 推送镜像
docker push ${IMAGE}

echo "✅ Build complete!"
echo "Image: ${IMAGE}"
