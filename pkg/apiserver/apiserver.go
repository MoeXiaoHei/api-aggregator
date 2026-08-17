package apiserver

import (
    "encoding/json"
    "fmt"
    "net/http"
    "os"
    "strings"
    "time"

    corev1 "k8s.io/api/core/v1"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/rest"
    "k8s.io/klog/v2"
)

type Config struct {
    AllowedNodes []string
}

type APIServer struct {
    KubeClient   *kubernetes.Clientset
    AllowedNodes []string
    AllowedMap   map[string]bool
}

func NewAPIServer(config *Config) *APIServer {
    allowedMap := make(map[string]bool)
    for _, node := range config.AllowedNodes {
        allowedMap[node] = true
    }
    return &APIServer{
        AllowedNodes: config.AllowedNodes,
        AllowedMap:   allowedMap,
    }
}

func (s *APIServer) Run() error {
    // 创建 Kubernetes 客户端
    kubeConfig, err := rest.InClusterConfig()
    if err != nil {
        return fmt.Errorf("failed to get in-cluster config: %v", err)
    }

    s.KubeClient, err = kubernetes.NewForConfig(kubeConfig)
    if err != nil {
        return fmt.Errorf("failed to create kube client: %v", err)
    }

    // 创建 HTTP Server
    mux := http.NewServeMux()
    mux.HandleFunc("/healthz", s.healthz)
    mux.HandleFunc("/readyz", s.readyz)
    mux.HandleFunc("/", s.handleRequest)

    port := 8443
    klog.Infof("Starting API aggregator on port %d", port)
    klog.Infof("Allowed nodes: %v", s.AllowedNodes)

    server := &http.Server{
        Addr:         fmt.Sprintf(":%d", port),
        Handler:      mux,
        ReadTimeout:  30 * time.Second,
        WriteTimeout: 30 * time.Second,
    }

    return server.ListenAndServeTLS("/etc/certs/tls.crt", "/etc/certs/tls.key")
}

func (s *APIServer) healthz(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    w.Write([]byte(`{"status":"healthy"}`))
}

func (s *APIServer) readyz(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    w.Write([]byte(`{"status":"ready"}`))
}

func (s *APIServer) handleRequest(w http.ResponseWriter, r *http.Request) {
    path := r.URL.Path
    method := r.Method

    klog.Infof("Request: %s %s", method, path)

    // 检查 Token
    authHeader := r.Header.Get("Authorization")
    if authHeader == "" || !strings.HasPrefix(authHeader, "Bearer ") {
        http.Error(w, "Unauthorized: missing token", http.StatusUnauthorized)
        return
    }

    // 解析路径
    parts := strings.Split(strings.Trim(path, "/"), "/")

    if len(parts) < 4 {
        s.proxyToK8s(w, r)
        return
    }

    namespace := parts[3]
    resource := ""
    podName := ""
    if len(parts) > 4 {
        resource = parts[4]
    }
    if len(parts) > 5 {
        podName = parts[5]
    }

    if resource != "pods" {
        s.proxyToK8s(w, r)
        return
    }

    switch method {
    case "GET":
        if podName == "" {
            s.listPods(w, r, namespace)
        } else {
            s.getPod(w, r, namespace, podName)
        }
    case "POST":
        s.createPod(w, r, namespace)
    case "PUT":
        s.updatePod(w, r, namespace, podName)
    case "DELETE":
        s.deletePod(w, r, namespace, podName)
    default:
        s.proxyToK8s(w, r)
    }
}

func (s *APIServer) listPods(w http.ResponseWriter, r *http.Request, namespace string) {
    fieldSelector := r.URL.Query().Get("fieldSelector")

    if strings.Contains(fieldSelector, "spec.nodeName") {
        nodeName := extractNodeName(fieldSelector)
        if nodeName != "" && !s.AllowedMap[nodeName] {
            http.Error(w, fmt.Sprintf("Node '%s' is not allowed", nodeName), http.StatusForbidden)
            return
        }
        s.proxyToK8s(w, r)
        return
    }

    pods, err := s.KubeClient.CoreV1().Pods(namespace).List(r.Context(), metav1.ListOptions{})
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }

    filtered := &corev1.PodList{
        TypeMeta: metav1.TypeMeta{
            Kind:       "PodList",
            APIVersion: "v1",
        },
        Items: []corev1.Pod{},
    }

    for _, pod := range pods.Items {
        if s.AllowedMap[pod.Spec.NodeName] {
            filtered.Items = append(filtered.Items, pod)
        }
    }

    klog.Infof("Returning %d pods from allowed nodes", len(filtered.Items))

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(filtered)
}

func (s *APIServer) getPod(w http.ResponseWriter, r *http.Request, namespace, name string) {
    pod, err := s.KubeClient.CoreV1().Pods(namespace).Get(r.Context(), name, metav1.GetOptions{})
    if err != nil {
        http.Error(w, err.Error(), http.StatusNotFound)
        return
    }

    if !s.AllowedMap[pod.Spec.NodeName] {
        http.Error(w, fmt.Sprintf("Pod '%s' is on node '%s' which is not allowed", name, pod.Spec.NodeName), http.StatusForbidden)
        return
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(pod)
}

// 🔑 核心修改：createPod 支持智能调度
func (s *APIServer) createPod(w http.ResponseWriter, r *http.Request, namespace string) {
    var pod corev1.Pod
    if err := json.NewDecoder(r.Body).Decode(&pod); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }

    klog.Infof("Creating pod %s in namespace %s, nodeName: %s", pod.Name, namespace, pod.Spec.NodeName)

    // 1. 如果指定了 nodeName，检查是否在白名单中
    if pod.Spec.NodeName != "" {
        if !s.AllowedMap[pod.Spec.NodeName] {
            http.Error(w, fmt.Sprintf("Node '%s' is not allowed. Allowed nodes: %v",
                pod.Spec.NodeName, s.AllowedNodes), http.StatusForbidden)
            return
        }
        // 指定了白名单节点，直接创建
        created, err := s.KubeClient.CoreV1().Pods(namespace).Create(r.Context(), &pod, metav1.CreateOptions{})
        if err != nil {
            http.Error(w, err.Error(), http.StatusInternalServerError)
            return
        }
        w.Header().Set("Content-Type", "application/json")
        w.WriteHeader(http.StatusCreated)
        json.NewEncoder(w).Encode(created)
        return
    }

    // 2. 如果没有指定 nodeName，注入 nodeSelector
    // 让 Kubernetes 调度器选择最优的白名单节点
    if pod.Spec.NodeSelector == nil {
        pod.Spec.NodeSelector = make(map[string]string)
    }
    pod.Spec.NodeSelector["node-group"] = "allowed"
    klog.Infof("Auto-injected nodeSelector: node-group=allowed for pod %s", pod.Name)

    // 3. 创建 Pod（由 K8s 调度器调度）
    created, err := s.KubeClient.CoreV1().Pods(namespace).Create(r.Context(), &pod, metav1.CreateOptions{})
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }

    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(http.StatusCreated)
    json.NewEncoder(w).Encode(created)
}

func (s *APIServer) updatePod(w http.ResponseWriter, r *http.Request, namespace, name string) {
    existing, err := s.KubeClient.CoreV1().Pods(namespace).Get(r.Context(), name, metav1.GetOptions{})
    if err != nil {
        http.Error(w, err.Error(), http.StatusNotFound)
        return
    }

    if !s.AllowedMap[existing.Spec.NodeName] {
        http.Error(w, fmt.Sprintf("Pod '%s' is on node '%s' which is not allowed", name, existing.Spec.NodeName), http.StatusForbidden)
        return
    }

    var pod corev1.Pod
    if err := json.NewDecoder(r.Body).Decode(&pod); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }

    if pod.Spec.NodeName != "" && pod.Spec.NodeName != existing.Spec.NodeName {
        if !s.AllowedMap[pod.Spec.NodeName] {
            http.Error(w, fmt.Sprintf("Node '%s' is not allowed", pod.Spec.NodeName), http.StatusForbidden)
            return
        }
    }

    updated, err := s.KubeClient.CoreV1().Pods(namespace).Update(r.Context(), &pod, metav1.UpdateOptions{})
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }

    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(updated)
}

func (s *APIServer) deletePod(w http.ResponseWriter, r *http.Request, namespace, name string) {
    pod, err := s.KubeClient.CoreV1().Pods(namespace).Get(r.Context(), name, metav1.GetOptions{})
    if err != nil {
        http.Error(w, err.Error(), http.StatusNotFound)
        return
    }

    if !s.AllowedMap[pod.Spec.NodeName] {
        http.Error(w, fmt.Sprintf("Pod '%s' is on node '%s' which is not allowed", name, pod.Spec.NodeName), http.StatusForbidden)
        return
    }

    err = s.KubeClient.CoreV1().Pods(namespace).Delete(r.Context(), name, metav1.DeleteOptions{})
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }

    w.WriteHeader(http.StatusOK)
    w.Write([]byte(`{"status":"deleted"}`))
}

func (s *APIServer) proxyToK8s(w http.ResponseWriter, r *http.Request) {
    token, err := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }

    k8sURL := fmt.Sprintf("https://kubernetes.default.svc:443%s", r.URL.Path)
    if r.URL.RawQuery != "" {
        k8sURL = fmt.Sprintf("%s?%s", k8sURL, r.URL.RawQuery)
    }

    req, err := http.NewRequestWithContext(r.Context(), r.Method, k8sURL, nil)
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }

    req.Header.Set("Authorization", "Bearer "+string(token))
    for key, values := range r.Header {
        for _, value := range values {
            req.Header.Add(key, value)
        }
    }

    client := &http.Client{
        Timeout: 30 * time.Second,
    }
    resp, err := client.Do(req)
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }
    defer resp.Body.Close()

    for key, values := range resp.Header {
        for _, value := range values {
            w.Header().Add(key, value)
        }
    }
    w.WriteHeader(resp.StatusCode)

    var body []byte
    json.NewDecoder(resp.Body).Decode(&body)
    w.Write(body)
}

func extractNodeName(fieldSelector string) string {
    parts := strings.Split(fieldSelector, "=")
    if len(parts) == 2 && strings.TrimSpace(parts[0]) == "spec.nodeName" {
        return strings.TrimSpace(parts[1])
    }
    return ""
}
