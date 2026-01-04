#!/bin/bash

# Thumbnail API Diagnostics Collection Script
# This script collects comprehensive system metrics and logs for debugging

set -euo pipefail

# Configuration
RELEASE_NAME="${RELEASE_NAME:-thumbnail-api-release}"
NAMESPACE="${NAMESPACE:-default}"
OUTPUT_DIR="diagnostics-$(date +%Y%m%d-%H%M%S)"
OUTPUT_FILE="${OUTPUT_DIR}.tar.gz"

echo "=========================================="
echo "Thumbnail API Diagnostics Collection"
echo "=========================================="
echo "Release: ${RELEASE_NAME}"
echo "Namespace: ${NAMESPACE}"
echo "Output: ${OUTPUT_FILE}"
echo ""

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Function to write section header
write_header() {
    echo "" >> "$1"
    echo "========================================" >> "$1"
    echo "$2" >> "$1"
    echo "========================================" >> "$1"
    echo "" >> "$1"
}

# Function to safely execute command and capture output
safe_exec() {
    local output_file="$1"
    shift
    echo "Collecting: $*"
    {
        echo "Command: $*"
        echo "Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
        echo ""
        "$@" 2>&1 || echo "Error executing command (exit code: $?)"
    } >> "${output_file}"
}

echo "Collecting cluster information..."
CLUSTER_INFO="${OUTPUT_DIR}/01-cluster-info.txt"

write_header "${CLUSTER_INFO}" "Cluster Information"
safe_exec "${CLUSTER_INFO}" kubectl cluster-info

write_header "${CLUSTER_INFO}" "Kubernetes Version"
safe_exec "${CLUSTER_INFO}" kubectl version --short

write_header "${CLUSTER_INFO}" "Node Information"
safe_exec "${CLUSTER_INFO}" kubectl get nodes -o wide

write_header "${CLUSTER_INFO}" "Node Resource Usage"
safe_exec "${CLUSTER_INFO}" kubectl top nodes

echo "Collecting Helm release information..."
HELM_INFO="${OUTPUT_DIR}/02-helm-info.txt"

write_header "${HELM_INFO}" "Helm Release Status"
safe_exec "${HELM_INFO}" helm status "${RELEASE_NAME}" -n "${NAMESPACE}"

write_header "${HELM_INFO}" "Helm Release History"
safe_exec "${HELM_INFO}" helm history "${RELEASE_NAME}" -n "${NAMESPACE}"

write_header "${HELM_INFO}" "Helm Release Values"
safe_exec "${HELM_INFO}" helm get values "${RELEASE_NAME}" -n "${NAMESPACE}"

write_header "${HELM_INFO}" "Helm Release Manifest"
safe_exec "${HELM_INFO}" helm get manifest "${RELEASE_NAME}" -n "${NAMESPACE}"

echo "Collecting pod information..."
POD_INFO="${OUTPUT_DIR}/03-pod-info.txt"

write_header "${POD_INFO}" "All Pods"
safe_exec "${POD_INFO}" kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" -o wide

write_header "${POD_INFO}" "Pod Details (YAML)"
safe_exec "${POD_INFO}" kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" -o yaml

write_header "${POD_INFO}" "Pod Resource Usage"
safe_exec "${POD_INFO}" kubectl top pods -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}"

write_header "${POD_INFO}" "Pod Descriptions"
for pod in $(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" -o jsonpath='{.items[*].metadata.name}'); do
    write_header "${POD_INFO}" "Pod Description: ${pod}"
    safe_exec "${POD_INFO}" kubectl describe pod "${pod}" -n "${NAMESPACE}"
done

echo "Collecting service information..."
SERVICE_INFO="${OUTPUT_DIR}/04-service-info.txt"

write_header "${SERVICE_INFO}" "Services"
safe_exec "${SERVICE_INFO}" kubectl get services -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" -o wide

write_header "${SERVICE_INFO}" "Service Details (YAML)"
safe_exec "${SERVICE_INFO}" kubectl get services -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" -o yaml

write_header "${SERVICE_INFO}" "Endpoints"
safe_exec "${SERVICE_INFO}" kubectl get endpoints -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}"

for svc in $(kubectl get services -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" -o jsonpath='{.items[*].metadata.name}'); do
    write_header "${SERVICE_INFO}" "Service Description: ${svc}"
    safe_exec "${SERVICE_INFO}" kubectl describe service "${svc}" -n "${NAMESPACE}"
done

echo "Collecting storage information..."
STORAGE_INFO="${OUTPUT_DIR}/05-storage-info.txt"

write_header "${STORAGE_INFO}" "PersistentVolumeClaims"
safe_exec "${STORAGE_INFO}" kubectl get pvc -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" -o wide

write_header "${STORAGE_INFO}" "PersistentVolumes"
safe_exec "${STORAGE_INFO}" kubectl get pv

write_header "${STORAGE_INFO}" "PVC Details (YAML)"
safe_exec "${STORAGE_INFO}" kubectl get pvc -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" -o yaml

echo "Collecting pod logs..."
LOGS_DIR="${OUTPUT_DIR}/06-logs"
mkdir -p "${LOGS_DIR}"

for pod in $(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" -o jsonpath='{.items[*].metadata.name}'); do
    echo "  - ${pod}"

    # Current logs
    kubectl logs "${pod}" -n "${NAMESPACE}" --tail=1000 > "${LOGS_DIR}/${pod}-current.log" 2>&1 || echo "Failed to get current logs" > "${LOGS_DIR}/${pod}-current.log"

    # Previous logs (if pod restarted)
    kubectl logs "${pod}" -n "${NAMESPACE}" --previous --tail=1000 > "${LOGS_DIR}/${pod}-previous.log" 2>&1 || echo "No previous logs available" > "${LOGS_DIR}/${pod}-previous.log"
done

echo "Collecting events..."
EVENTS_INFO="${OUTPUT_DIR}/07-events.txt"

write_header "${EVENTS_INFO}" "Recent Events (All Namespaces)"
safe_exec "${EVENTS_INFO}" kubectl get events --all-namespaces --sort-by='.lastTimestamp' --field-selector involvedObject.namespace="${NAMESPACE}"

write_header "${EVENTS_INFO}" "Warning Events"
safe_exec "${EVENTS_INFO}" kubectl get events -n "${NAMESPACE}" --field-selector type=Warning --sort-by='.lastTimestamp'

echo "Collecting Redis metrics..."
REDIS_METRICS="${OUTPUT_DIR}/08-redis-metrics.txt"

write_header "${REDIS_METRICS}" "Redis Info"
REDIS_POD=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=redis -o jsonpath='{.items[0].metadata.name}')
if [ -n "${REDIS_POD}" ]; then
    echo "Redis Pod: ${REDIS_POD}" >> "${REDIS_METRICS}"
    echo "" >> "${REDIS_METRICS}"

    write_header "${REDIS_METRICS}" "Redis Server Info"
    safe_exec "${REDIS_METRICS}" kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- redis-cli INFO SERVER

    write_header "${REDIS_METRICS}" "Redis Memory Info"
    safe_exec "${REDIS_METRICS}" kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- redis-cli INFO MEMORY

    write_header "${REDIS_METRICS}" "Redis Stats Info"
    safe_exec "${REDIS_METRICS}" kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- redis-cli INFO STATS

    write_header "${REDIS_METRICS}" "Redis Replication Info"
    safe_exec "${REDIS_METRICS}" kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- redis-cli INFO REPLICATION

    write_header "${REDIS_METRICS}" "Redis Clients Info"
    safe_exec "${REDIS_METRICS}" kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- redis-cli INFO CLIENTS

    write_header "${REDIS_METRICS}" "Redis Queue Length"
    safe_exec "${REDIS_METRICS}" kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- redis-cli LLEN thumbnail_jobs

    write_header "${REDIS_METRICS}" "Redis Keys Count"
    safe_exec "${REDIS_METRICS}" kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- redis-cli DBSIZE

    write_header "${REDIS_METRICS}" "Redis Job Keys Sample"
    safe_exec "${REDIS_METRICS}" kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- redis-cli --scan --pattern "job:*" --count 20
else
    echo "Redis pod not found" >> "${REDIS_METRICS}"
fi

echo "Collecting API metrics..."
API_METRICS="${OUTPUT_DIR}/09-api-metrics.txt"

write_header "${API_METRICS}" "API Health Check"
safe_exec "${API_METRICS}" curl -s http://localhost:8080/health

write_header "${API_METRICS}" "API Jobs List"
safe_exec "${API_METRICS}" curl -s http://localhost:8080/jobs

echo "Collecting resource quotas and limits..."
RESOURCES_INFO="${OUTPUT_DIR}/10-resources.txt"

write_header "${RESOURCES_INFO}" "Resource Quotas"
safe_exec "${RESOURCES_INFO}" kubectl get resourcequota -n "${NAMESPACE}"

write_header "${RESOURCES_INFO}" "Limit Ranges"
safe_exec "${RESOURCES_INFO}" kubectl get limitrange -n "${NAMESPACE}"

write_header "${RESOURCES_INFO}" "Pod Resource Requests and Limits"
safe_exec "${RESOURCES_INFO}" kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" -o custom-columns='NAME:.metadata.name,CPU_REQUEST:.spec.containers[*].resources.requests.cpu,CPU_LIMIT:.spec.containers[*].resources.limits.cpu,MEM_REQUEST:.spec.containers[*].resources.requests.memory,MEM_LIMIT:.spec.containers[*].resources.limits.memory'

echo "Creating summary report..."
SUMMARY="${OUTPUT_DIR}/00-SUMMARY.txt"

cat > "${SUMMARY}" << EOF
Thumbnail API Diagnostics Summary
==================================

Collection Time: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Release Name: ${RELEASE_NAME}
Namespace: ${NAMESPACE}

Quick Status Check
==================

EOF

echo "Pods:" >> "${SUMMARY}"
kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" -o wide >> "${SUMMARY}" 2>&1 || echo "Failed to get pods" >> "${SUMMARY}"

echo "" >> "${SUMMARY}"
echo "Services:" >> "${SUMMARY}"
kubectl get services -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" -o wide >> "${SUMMARY}" 2>&1 || echo "Failed to get services" >> "${SUMMARY}"

echo "" >> "${SUMMARY}"
echo "PVCs:" >> "${SUMMARY}"
kubectl get pvc -n "${NAMESPACE}" -l app.kubernetes.io/instance="${RELEASE_NAME}" >> "${SUMMARY}" 2>&1 || echo "Failed to get PVCs" >> "${SUMMARY}"

echo "" >> "${SUMMARY}"
echo "Recent Warnings:" >> "${SUMMARY}"
kubectl get events -n "${NAMESPACE}" --field-selector type=Warning --sort-by='.lastTimestamp' | tail -10 >> "${SUMMARY}" 2>&1 || echo "Failed to get events" >> "${SUMMARY}"

if [ -n "${REDIS_POD}" ]; then
    echo "" >> "${SUMMARY}"
    echo "Redis Queue Depth:" >> "${SUMMARY}"
    kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- redis-cli LLEN thumbnail_jobs >> "${SUMMARY}" 2>&1 || echo "Failed to get queue depth" >> "${SUMMARY}"

    echo "" >> "${SUMMARY}"
    echo "Redis Memory Usage:" >> "${SUMMARY}"
    kubectl exec -n "${NAMESPACE}" "${REDIS_POD}" -- redis-cli INFO MEMORY | grep used_memory_human >> "${SUMMARY}" 2>&1 || echo "Failed to get memory usage" >> "${SUMMARY}"
fi

cat >> "${SUMMARY}" << EOF

Files Collected
===============

01-cluster-info.txt        - Kubernetes cluster details
02-helm-info.txt          - Helm release information
03-pod-info.txt           - Pod status and descriptions
04-service-info.txt       - Service configurations
05-storage-info.txt       - PVC and PV information
06-logs/                  - Container logs (current and previous)
07-events.txt             - Kubernetes events
08-redis-metrics.txt      - Redis performance metrics
09-api-metrics.txt        - API health and jobs
10-resources.txt          - Resource quotas and limits

How to Use This Report
======================

1. Review 00-SUMMARY.txt for quick overview
2. Check 07-events.txt for warnings and errors
3. Examine 06-logs/ for application-level issues
4. Review 08-redis-metrics.txt for queue depth and memory
5. Check 03-pod-info.txt for pod restart counts and status

Common Issues to Check
======================

- Pod status not "Running" → Check 03-pod-info.txt and 07-events.txt
- High queue depth → Check 08-redis-metrics.txt
- Pod restarts → Check 06-logs/[pod]-previous.log
- Service connection issues → Check 04-service-info.txt endpoints
- Storage full → Check 05-storage-info.txt
- OOMKilled pods → Check 10-resources.txt and 03-pod-info.txt

EOF

echo ""
echo "Creating compressed archive..."
tar -czf "${OUTPUT_FILE}" "${OUTPUT_DIR}"

echo ""
echo "=========================================="
echo "Diagnostics collection complete!"
echo "=========================================="
echo ""
echo "Output file: ${OUTPUT_FILE}"
echo "Size: $(du -h "${OUTPUT_FILE}" | cut -f1)"
echo ""
echo "To extract: tar -xzf ${OUTPUT_FILE}"
echo ""
echo "You can now share ${OUTPUT_FILE} for debugging."
echo ""

# Cleanup directory (keep only the tar.gz)
rm -rf "${OUTPUT_DIR}"

echo "Done!"