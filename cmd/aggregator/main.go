package main

import (
    "flag"
    "strings"

    "k8s.io/klog/v2"
    "github.com/yourname/api-aggregator/pkg/apiserver"
)

var (
    allowedNodes = flag.String("allowed-nodes", "", "Comma-separated list of allowed node names")
)

func main() {
    // 🔑 关键：先调用 klog.InitFlags 初始化 klog 的 flag
    klog.InitFlags(nil)
    
    // 然后解析所有 flag（包括 -v）
    flag.Parse()

    if *allowedNodes == "" {
        klog.Fatal("--allowed-nodes must be set")
    }

    nodeList := strings.Split(*allowedNodes, ",")
    for i := range nodeList {
        nodeList[i] = strings.TrimSpace(nodeList[i])
    }

    klog.Infof("Allowed nodes: %v", nodeList)

    config := &apiserver.Config{
        AllowedNodes: nodeList,
    }

    server := apiserver.NewAPIServer(config)
    if err := server.Run(); err != nil {
        klog.Fatalf("Failed to run API server: %v", err)
    }
}
