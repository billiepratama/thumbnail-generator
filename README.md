# Thumbnail Generation Service

A microservices-based application that generates thumbnails from uploaded images asynchronously using FastAPI, Redis, and Kubernetes.

## Table of Contents
- [Architecture Overview](#architecture-overview)
- [Installation & Usage](#installation--usage)
- [Technical Choices & Reasoning](#technical-choices--reasoning)
- [Trade-offs & Limitations](#trade-offs--limitations)
- [Production Considerations](#production-considerations)

---

## Architecture Overview

### System Components

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│   Client    │────────>│  API Service│────────>│    Redis    │
│             │         │  (FastAPI)  │         │   (Queue)   │
└─────────────┘         └─────────────┘         └──────┬──────┘
                              │                         │
                              │                         │
                              v                         v
                        ┌───────────┐          ┌──────────────┐
                        │  Shared   │<────────│Worker Service│
                        │  Storage  │         │   (Python)   │
                        │   (PVC)   │         └──────────────┘
                        └───────────┘
```

**Flow:**
1. Client uploads image via HTTP POST to API
2. API saves image to shared storage and queues job in Redis
3. Worker picks job from Redis queue (BLPOP)
4. Worker generates thumbnail (100×100 PNG) and saves to shared storage
5. Client downloads thumbnail via HTTP GET

### Services

- **API Service**: FastAPI application accepting image uploads and serving thumbnails
- **Worker Service**: Background process consuming queue and generating thumbnails
- **Redis**: Message queue (Redis List) and job metadata storage (Redis Strings)
- **Shared Storage**: PersistentVolumeClaim for file sharing between services

---

## Installation & Usage

### Prerequisites

- Docker
- Kind (Kubernetes in Docker)
- Helm 3
- kubectl

### Quick Start

#### 1. Build Docker Images

```bash
# Clone repository
cd /path/to/personal-learning

# Build images
docker build -f docker/api.Dockerfile -t thumbnail-api:latest .
docker build -f docker/worker.Dockerfile -t thumbnail-worker:latest .
```

#### 2. Create Kind Cluster

```bash
# Create cluster with port mapping configuration
kind create cluster --config kind-config.yaml
```

The `kind-config.yaml` configures port mapping so you can access the API at `localhost:8080` without manual port-forwarding:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: thumbnail-cluster
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080  # NodePort inside Kind
    hostPort: 8080        # Port on your machine
    protocol: TCP
```

#### 3. Load Images into Kind

```bash
kind load docker-image thumbnail-api:latest --name thumbnail-cluster
kind load docker-image thumbnail-worker:latest --name thumbnail-cluster
```

#### 4. Deploy with Helm

```bash
helm install thumbnail-api-release ./helm/thumbnail-api
```

#### 5. Verify Deployment

```bash
kubectl get pods
# Should show: api, worker, and redis pods running

kubectl get services
# Should show: thumbnail-api-release-api and thumbnail-api-release-redis
```

#### 6. Test the Application

The API is accessible at `http://localhost:8080` (no port-forwarding needed):

```bash
# Health check
curl http://localhost:8080/health

# Upload image
curl -X POST http://localhost:8080/jobs -F "image=@test_image.jpg"
# Returns: {"job_id": "abc-123...", "status": "queued"}

# Check job status
curl http://localhost:8080/jobs/abc-123...
# Returns: {"job_id": "abc-123...", "status": "succeeded", ...}

# Download thumbnail
curl http://localhost:8080/jobs/abc-123.../thumbnail -o thumbnail.png

# List all jobs
curl http://localhost:8080/jobs
```

### Cleanup

```bash
# Uninstall Helm release
helm uninstall thumbnail-api-release

# Delete Kind cluster
kind delete cluster --name thumbnail-cluster
```

### Debugging

When you need to troubleshoot issues or collect system information for sharing with others:

```bash
# Run the diagnostics collection script
./scripts/collect-diagnostics.sh
```

This script collects comprehensive information about your deployment including:
- Pod status and logs
- Service configurations
- Redis metrics (queue depth, memory usage)
- Kubernetes events and warnings
- Resource usage

The script generates a compressed file (e.g., `diagnostics-20231215-103045.tar.gz`) that you can share with others for debugging. The file contains all relevant information organized into separate text files for easy review.

---

## Technical Choices & Reasoning

### 1. Architecture: Microservices with Queue-Based Communication

**Choice:** Separate API and Worker services communicating via Redis queue

**Reasoning:**
- **Asynchronous processing**: Image processing can be slow; API returns immediately (HTTP 202)
- **Scalability**: Can scale workers independently based on queue depth
- **Reliability**: If worker crashes, jobs remain in queue
- **Separation of concerns**: API handles HTTP, Worker handles image processing

### 2. FastAPI Framework

**Choice:** FastAPI for the API service

**Reasoning:**
- **Modern & fast**: Built on Starlette/Uvicorn (ASGI), handles async well
- **Auto-documentation**: Built-in OpenAPI/Swagger UI at `/docs`
- **Easy file uploads**: Native multipart/form-data support

### 3. Redis for Queue and Metadata

**Choice:** Single Redis instance for both queue (List) and job metadata (Strings)

**Reasoning:**
- **Simple**: One dependency instead of separate queue + database
- **Efficient**: BLPOP provides blocking queue semantics (no polling)
- **Atomic operations**: RPUSH/BLPOP guarantee exactly-once delivery
- **Fast**: In-memory storage, sub-millisecond latency

**Alternative considered:** RabbitMQ/Kafka (rejected: overkill for this use case)

### 4. Shared Storage (PVC)

**Choice:** PersistentVolumeClaim mounted by both API and Worker

**Reasoning:**
- **Large files**: Images too large for Redis
- **Efficient**: Direct file I/O faster than network transfer
- **Simple**: Both services access same filesystem

**Alternative considered:** Object storage like S3 (rejected: adds complexity for local dev)

### 5. Python 3.11 slim-buster Base Image

**Choice:** `python:3.11-slim-buster` for Docker images

**Reasoning:**
- **Small**: ~120MB base (vs ~900MB full image)
- **Compatible**: glibc ensures all Python packages work (vs Alpine's musl)
- **Secure**: Minimal attack surface
- **Stable**: Debian-based, well-supported

### 6. Helm for Kubernetes Deployment

**Choice:** Helm chart for packaging Kubernetes resources

**Reasoning:**
- **Simplicity**: One command to deploy entire stack
- **Configurability**: values.yaml for environment-specific settings
- **Version control**: Track deployment changes
- **Reusability**: Easy to deploy to different clusters

### 7. StatefulSet for Redis

**Choice:** StatefulSet (not Deployment) for Redis

**Reasoning:**
- **Stable network identity**: Predictable hostname
- **Ordered deployment**: Better for stateful services
- **Future-ready**: Easier to add persistence or replication later

---

## Trade-offs & Limitations

### What's Missing / Trade-offs Made

#### 1. No Authentication/Authorization

- **Current:** Anyone can upload images and access all jobs
- **Trade-off:** Public API without access control
- **Why:** Out of scope for local development/learning
- **Impact:** Not suitable for production use

#### 2. No Rate Limiting

- **Current:** No limits on upload frequency or size
- **Trade-off:** Vulnerable to abuse
- **Why:** Simplifies implementation
- **Impact:** Could be overwhelmed by rapid uploads

#### 3. Files Never Deleted

- **Current:** Original images and thumbnails persist forever
- **Trade-off:** Storage grows unbounded
- **Why:** No cleanup logic implemented
- **Impact:** Disk will eventually fill up

#### 4. No Job Retry Logic

- **Current:** Failed jobs stay failed
- **Trade-off:** Transient errors not recoverable
- **Why:** Adds complexity
- **Impact:** Network glitches or temporary issues cause permanent failures

#### 5. No Multi-Region Support

- **Current:** Single-cluster deployment
- **Trade-off:** No geographic distribution
- **Why:** Learning environment
- **Impact:** Higher latency for distant users

### What I'd Do Differently With More Time

#### 1. Implement Cleanup Job

Create a Kubernetes CronJob to automatically delete old job records and files after a retention period (e.g., 7 days), preventing unbounded storage growth.

#### 2. Add Retry Logic

Implement automatic retry mechanism for failed jobs with exponential backoff, allowing recovery from transient errors like temporary network issues or resource unavailability.

#### 3. Use Object Storage

Replace PersistentVolumeClaim with object storage (S3, MinIO, or GCS) for better scalability, automatic redundancy, and elimination of shared filesystem limitations.

---

## Production Considerations

### 1. Security

#### Authentication & Authorization

Implement API authentication using API keys, OAuth2, or JWT tokens. Add role-based access control (RBAC) to manage user permissions and restrict access to sensitive operations.

#### Input Validation

The application includes basic file type validation. For production, enhance with malware scanning, stricter file signature validation, and implement rate limiting per user or IP address to prevent abuse.

#### Secrets Management

Use Kubernetes Secrets or external secret stores (HashiCorp Vault, AWS Secrets Manager) to manage sensitive credentials like Redis passwords, object storage credentials, and API keys instead of hardcoding them.

### 2. Scalability

#### Horizontal Pod Autoscaling

Configure HorizontalPodAutoscaler to automatically scale worker pods based on Redis queue depth or CPU utilization. This ensures the system can handle variable workloads efficiently by adding or removing worker instances as needed.

#### Redis Clustering

For high-throughput production workloads, replace single Redis instance with Redis Cluster or Redis Sentinel for high availability. Alternatively, use managed services like AWS ElastiCache or Redis Cloud for simplified operations.

#### Object Storage

Replace PersistentVolumeClaim with cloud object storage (S3, MinIO, GCS) for better scalability and redundancy. Store original images and thumbnails in buckets and serve them via pre-signed URLs for secure, direct access.

### 3. Monitoring & Observability System

#### Prometheus for Metrics Collection

**Purpose:** Collects and stores time-series metrics from all services

**Key Metrics to Track:**
- **API Service:** Request rate, latency (p50/p95/p99), error rate, jobs queued per minute
- **Worker Service:** Jobs processed, processing duration, success/failure rate, queue lag
- **Redis:** Queue depth, memory usage, connections, operations per second
- **System:** CPU/memory usage per pod, pod restarts, storage utilization

#### Grafana for Visualization

**Purpose:** Creates dashboards to visualize metrics collected by Prometheus

**Features:**
- Real-time dashboards showing system overview
- Custom dashboards for application-specific metrics
- Historical data analysis and trend identification
- Visual alerts when thresholds are breached

**Dashboard Examples:**
- System overview (CPU, memory, pod status)
- API performance (request rates, latency percentiles)
- Worker performance (throughput, processing time)
- Redis metrics (queue depth trends, memory usage)

#### AlertManager for Alerting

**Purpose:** Sends notifications when metrics exceed defined thresholds

**Notification Channels:**
- Email
- Slack
- PagerDuty
- Webhook integrations

#### Implementation Benefits

- **Proactive issue detection:** Alerts before users are impacted
- **Performance optimization:** Identify bottlenecks through metrics analysis
- **Capacity planning:** Track growth trends for resource planning
- **Debugging:** Historical data helps diagnose past incidents
- **SLA tracking:** Monitor uptime and performance against targets
