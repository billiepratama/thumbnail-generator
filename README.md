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

#### 1. No Input Validation
**Current:** API accepts any file without validation
**Trade-off:** Simpler code, but invalid files cause worker failures
**Why:** Focus on core functionality for learning purposes
**Impact:** Worker marks jobs as failed, but wastes processing time

#### 2. No Authentication/Authorization
**Current:** Anyone can upload images and access all jobs
**Trade-off:** Public API without access control
**Why:** Out of scope for local development/learning
**Impact:** Not suitable for production use

#### 3. No Rate Limiting
**Current:** No limits on upload frequency or size
**Trade-off:** Vulnerable to abuse
**Why:** Simplifies implementation
**Impact:** Could be overwhelmed by rapid uploads

#### 4. Files Never Deleted
**Current:** Original images and thumbnails persist forever
**Trade-off:** Storage grows unbounded
**Why:** No cleanup logic implemented
**Impact:** Disk will eventually fill up

#### 5. No Job Retry Logic
**Current:** Failed jobs stay failed
**Trade-off:** Transient errors not recoverable
**Why:** Adds complexity
**Impact:** Network glitches or temporary issues cause permanent failures

#### 6. No Multi-Region Support
**Current:** Single-cluster deployment
**Trade-off:** No geographic distribution
**Why:** Learning environment
**Impact:** Higher latency for distant users

### What I'd Do Differently With More Time

#### 1. Add Input Validation
```python
# Validate file type and size before saving
MAX_FILE_SIZE = 10 * 1024 * 1024  # 10MB
ALLOWED_TYPES = {"image/jpeg", "image/png", "image/gif"}

if image.content_type not in ALLOWED_TYPES:
    raise HTTPException(400, "Invalid file type")
if image.size > MAX_FILE_SIZE:
    raise HTTPException(413, "File too large")
```

#### 2. Implement Cleanup Job
```python
# Kubernetes CronJob to delete old files
# Delete jobs older than 7 days
# Delete orphaned files
```

#### 3. Add Retry Logic
```python
# Store retry count in job metadata
# Move failed jobs to retry queue
# Exponential backoff (1s, 2s, 4s, 8s)
```

#### 4. Use Object Storage
```python
# Replace PVC with S3/MinIO
# Better for scaling
# Automatic redundancy
# No shared filesystem issues
```

---

## Production Considerations

### 1. Security

#### Authentication & Authorization
```yaml
# Add API authentication
- Implement API keys or OAuth2
- JWT tokens for stateless auth
- Role-based access control (RBAC)
```

#### Input Validation
```python
# Validate and sanitize inputs
- Check file signatures (magic bytes), not just extensions
- Limit file sizes
- Scan for malware/malicious images
- Rate limit per user/IP
```

#### Secrets Management
```yaml
# Don't hardcode credentials
# Use Kubernetes Secrets or external secret stores
- Redis password
- Object storage credentials
- API keys

# Example:
env:
  - name: REDIS_PASSWORD
    valueFrom:
      secretKeyRef:
        name: redis-secret
        key: password
```

### 2. Reliability

#### Health Checks
```yaml
# Add liveness and readiness probes
livenessProbe:
  httpGet:
    path: /health
    port: 8000
  initialDelaySeconds: 10
  periodSeconds: 30

readinessProbe:
  httpGet:
    path: /ready
    port: 8000
  initialDelaySeconds: 5
  periodSeconds: 10
```

### 3. Scalability

#### Horizontal Pod Autoscaling
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: worker-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: worker
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: External
    external:
      metric:
        name: redis_queue_depth
      target:
        type: Value
        value: "100"
```

#### Redis Clustering
```yaml
# Scale Redis for higher throughput
# Use Redis Cluster or Redis Sentinel
# Or managed service (AWS ElastiCache, Redis Cloud)

# For learning: Redis Sentinel for HA
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis-sentinel
spec:
  replicas: 3
  # ... sentinel configuration
```

#### Object Storage
```python
# Replace PVC with S3/MinIO/GCS
import boto3

s3_client = boto3.client('s3')

# Save original
s3_client.upload_fileobj(image.file, 'thumbnails-bucket', f'{job_id}_original.jpg')

# Save thumbnail
s3_client.upload_file(thumbnail_path, 'thumbnails-bucket', f'{job_id}_thumbnail.png')

# Serve via signed URLs
url = s3_client.generate_presigned_url('get_object',
    Params={'Bucket': 'thumbnails-bucket', 'Key': f'{job_id}_thumbnail.png'},
    ExpiresIn=3600)
```

#### CDN for Thumbnails
```python
# Serve thumbnails via CDN (CloudFront, Cloudflare)
# Cache thumbnails at edge locations
# Reduce load on API service
```