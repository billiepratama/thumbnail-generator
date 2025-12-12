# Cogent Labs Thumbnail API Assignment

**Name:** [Your Name Here]

This repository contains the solution for the Cogent Labs Platform Infrastructure Engineer Assignment: a Thumbnail API with Kubernetes deployment.

## Table of Contents
1.  [Overview](#overview)
2.  [Architecture](#architecture)
3.  [Technical Choices & Reasoning](#technical-choices--reasoning)
4.  [Setup and Local Deployment](#setup-and-local-deployment)
    *   [Prerequisites](#prerequisites)
    *   [Building Docker Images](#building-docker-images)
    *   [Deploying to Kind Kubernetes Cluster](#deploying-to-kind-kubernetes-cluster)
    *   [Accessing the API](#accessing-the-api)
5.  [API Usage](#api-usage)
    *   [Submit Image (POST /jobs)](#submit-image-post-jobs)
    *   [List All Jobs (GET /jobs)](#list-all-jobs-get-jobs)
    *   [Get Job Status (GET /jobsjob_id)](#get-job-status-get-jobsjob_id)
    *   [Fetch Thumbnail (GET /jobsjob_id/thumbnail)](#fetch-thumbnail-get-jobsjob_idthumbnail)
6.  [Debugging and Observability](#debugging-and-observability)
    *   [Accessing Logs](#accessing-logs)
    *   [Checking Metrics](#checking-metrics)
7.  [Trade-offs and Future Improvements](#trade-offs-and-future-improvements)
    *   [Current Trade-offs](#current-trade-offs)
    *   [If I Had Additional Time](#if-i-had-additional-time)
    *   [Full Productionization Considerations](#full-productionization-considerations)

--- 

## 1. Overview

This project implements a long-running job API for generating 100x100 pixel thumbnails from submitted images. It's designed with scalability, resilience, and ease of on-premises deployment in mind, specifically targeting a Kubernetes environment managed via Helm.

The core idea is to decouple the image submission from the thumbnail generation process, utilizing a message queue and worker pattern.

## 2. Architecture

The system employs a classic **Queue-Worker architecture** orchestrated by Kubernetes.

![Thumbnail API Architecture](docs/architecture.png) <!-- Placeholder for an architecture diagram -->

The key components are:

*   **Web API Service (FastAPI):**
    *   Exposes REST endpoints for job submission, status checking, and thumbnail retrieval.
    *   Validates incoming image files.
    *   Saves original images to shared storage.
    *   Creates job metadata in Redis.
    *   Enqueues job IDs into a Redis list for processing.
*   **Task Queue (Redis List):**
    *   Acts as a message broker, holding job IDs for pending thumbnail generation tasks.
    *   Decouples the API from the worker, allowing independent scaling.
*   **Worker Service (Python Worker):**
    *   Continuously monitors the Redis queue for new job IDs.
    *   Retrieves job details and original image paths from Redis.
    *   Loads original images from shared storage.
    *   Generates 100x100 thumbnails using Pillow.
    *   Saves generated thumbnails back to shared storage.
    *   Updates job status (processing, succeeded, failed) in Redis.
*   **Shared Storage (Kubernetes Persistent Volume):**
    *   A common storage layer accessible by both the API and Worker pods.
    *   Stores original uploaded images and their corresponding generated thumbnails.
*   **Metadata Store (Redis Key-Value):**
    *   Stores comprehensive job details (status, filenames, timestamps, error messages) using job IDs as keys.

## 3. Technical Choices & Reasoning

*   **Language & Framework (Python with FastAPI):**
    *   **Reasoning:** Python is widely used for backend services, scripting, and data processing, offering a rich ecosystem of libraries. FastAPI provides high performance (comparable to Node.js and Go), automatic interactive API documentation (Swagger UI/ReDoc), and robust data validation out-of-the-box (Pydantic), significantly accelerating development and ensuring API quality. Its `async` capabilities are well-suited for I/O-bound tasks like file handling and Redis communication.
*   **Image Processing (Pillow):**
    *   **Reasoning:** Pillow is the de-facto standard for image manipulation in Python. It's mature, reliable, and efficient for tasks like resizing and format conversion.
*   **Task Queue & Metadata Store (Redis):**
    *   **Reasoning:** Redis is an extremely fast, in-memory data store that excels as both a message broker (using lists for queues) and a key-value store. Its simplicity, speed, and low resource footprint make it ideal for this assignment's requirements, especially for handling job queuing and storing transient job metadata without the overhead of a full relational database.
*   **Containerization (Docker):**
    *   **Reasoning:** Explicitly required by the assignment. Docker provides consistent environments across development and deployment, isolating the application and its dependencies. We use separate, slim images for the API and Worker to optimize resource usage and ensure clear separation of concerns.
*   **Orchestration (Kubernetes with Helm):**
    *   **Reasoning:** Explicitly required by the assignment. Kubernetes provides robust orchestration capabilities (self-healing, scaling, rolling updates). Helm simplifies the deployment and management of Kubernetes applications by packaging all necessary resources (Deployments, Services, PVCs) into a single, configurable chart, fulfilling the "single command deployment" requirement.
*   **Local Deployment Optimization (Resource Constraints):**
    *   **Reasoning:** Given the target local MacBook environment (8GB RAM), the Helm chart is pre-configured with conservative `resource requests` and `limits` (e.g., 128Mi for API, 256Mi for Worker) and `replicaCount: 1` for all components. This ensures the application runs within the available memory without oversubscribing resources or crashing the local `kind` cluster. Lightweight `alpine` base images were chosen in the Dockerfiles to further minimize footprint.

## 4. Setup and Local Deployment

This section guides you through setting up and deploying the Thumbnail API on a local `kind` Kubernetes cluster.

### Prerequisites

*   **Docker Desktop:** (or Docker Engine) for building and loading Docker images.
*   **kind (Kubernetes in Docker):** For running a local Kubernetes cluster.
    *   Installation: `brew install kind` (macOS) or `go install sigs.k8s.io/kind@v0.20.0`
*   **kubectl:** Kubernetes command-line tool.
    *   Installation: `brew install kubectl` (macOS)
*   **Helm:** Kubernetes package manager.
    *   Installation: `brew install helm` (macOS)
*   **Python 3.8+ & pip:** For local development/testing (though not strictly needed for deployment).

### Building Docker Images

Navigate to the project root directory (`~/Cogent/thumbnail-generator/`) and execute the following commands to build the Docker images for the API and Worker services:

```bash
# Build API image
docker build -t thumbnail-api:latest -f docker/api.Dockerfile .

# Build Worker image
docker build -t thumbnail-worker:latest -f docker/worker.Dockerfile .
```

### Deploying to Kind Kubernetes Cluster

1.  **Create a kind cluster:**
    ```bash
    kind create cluster --name thumbnail-cluster
    ```
2.  **Load Docker images into kind:**
    `kind` runs Kubernetes nodes as Docker containers. We need to load our locally built images into the cluster's nodes.
    ```bash
    kind load docker-image thumbnail-api:latest --name thumbnail-cluster
    kind load docker-image thumbnail-worker:latest --name thumbnail-cluster
    ```
3.  **Deploy with Helm:**
    Navigate back to the project root (`~/Cogent/thumbnail-generator/`) and run the Helm install command. This will deploy Redis, the API, the Worker, and the Persistent Volume Claim.
    ```bash
    helm install thumbnail-release ./helm/thumbnail-api
    ```
    This command will use the optimized `values.yaml` for your local environment.

### Accessing the API

To interact with the API from your local machine, you'll need to port-forward the API service:

```bash
kubectl port-forward svc/thumbnail-release-thumbnail-api 8000:80 --address 0.0.0.0
```
This command forwards local port `8000` to the API service's port `80`. The API will then be accessible at `http://localhost:8000`.

## 5. API Usage

The API provides the following endpoints:

### Submit Image (POST /jobs)

Submits an image file for thumbnail generation.
**Endpoint:** `POST http://localhost:8000/jobs`
**Headers:** `Content-Type: multipart/form-data`
**Body:** `image` (file upload)

**Example with `curl`:**

```bash
# Assuming you have an image file named 'my_image.jpg'
curl -X POST \
  -H "Content-Type: multipart/form-data" \
  -F "image=@my_image.jpg" \
  http://localhost:8000/jobs
```

**Example Response (202 Accepted):**

```json
{
  "job_id": "a1b2c3d4-e5f6-7890-1234-567890abcdef",
  "status": "queued",
  "detail": "Job has been successfully queued for processing."
}
```

### List All Jobs (GET /jobs)

Retrieves a list of all submitted jobs with their basic status.
**Endpoint:** `GET http://localhost:8000/jobs`

**Example with `curl`:**

```bash
curl http://localhost:8000/jobs
```

**Example Response (200 OK):**

```json
{
  "jobs": [
    {
      "job_id": "a1b2c3d4-e5f6-7890-1234-567890abcdef",
      "status": "succeeded",
      "created_at": "2025-12-11T12:00:00.000000"
    },
    {
      "job_id": "b2c3d4e5-f6a7-8901-2345-67890abcdef1",
      "status": "processing",
      "created_at": "2025-12-11T12:01:00.000000"
    }
  ]
}
```

### Get Job Status (GET /jobs/{job_id})

Retrieves the detailed status of a specific job.
**Endpoint:** `GET http://localhost:8000/jobs/{job_id}`

**Example with `curl`:**

```bash
curl http://localhost:8000/jobs/a1b2c3d4-e5f6-7890-1234-567890abcdef
```

**Example Response (200 OK):**

```json
{
  "job_id": "a1b2c3d4-e5f6-7890-1234-567890abcdef",
  "original_filename": "a1b2c3d4-e5f6-7890-1234-567890abcdef_original_my_image.jpg",
  "thumbnail_filename": "a1b2c3d4-e5f6-7890-1234-567890abcdef_thumbnail.png",
  "status": "succeeded",
  "created_at": "2025-12-11T12:00:00.000000",
  "started_at": "2025-12-11T12:00:01.000000",
  "finished_at": "2025-12-11T12:00:05.000000",
  "error_message": null
}
```

### Fetch Thumbnail (GET /jobs/{job_id}/thumbnail)

Downloads the generated thumbnail image if the job has succeeded.
**Endpoint:** `GET http://localhost:8000/jobs/{job_id}/thumbnail`

**Example with `curl`:**

```bash
curl -O http://localhost:8000/jobs/a1b2c3d4-e5f6-7890-1234-567890abcdef/thumbnail
# This will save the thumbnail to a file named 'thumbnail' in your current directory.
```

## 6. Debugging and Observability

For debugging and monitoring the application in a Kubernetes environment where direct access is limited, the following methods are provided:

### Accessing Logs

Both the API and Worker pods emit structured logs to `stdout`. These can be retrieved using `kubectl`.

*   **View API logs:**
    ```bash
    kubectl logs -l app.kubernetes.io/name=thumbnail-api,app.kubernetes.io/component=api
    # For a specific pod: kubectl logs <api-pod-name>
    ```
*   **View Worker logs:**
    ```bash
    kubectl logs -l app.kubernetes.io/name=thumbnail-api,app.kubernetes.io/component=worker
    # For a specific pod: kubectl logs <worker-pod-name>
    ```
*   **View Redis logs:** (less verbose, but useful for connection issues)
    ```bash
    kubectl logs -l app.kubernetes.io/name=thumbnail-api,app.kubernetes.io/component=redis
    ```

### Checking Metrics

While full Prometheus integration requires a dedicated setup, you can manually inspect the API's `/health` endpoint to check its basic status and Redis connectivity.

```bash
curl http://localhost:8000/health
```

**Future Integration for Full Metrics:**
In a production scenario, the API could expose a `/metrics` endpoint in Prometheus format, and the Worker could emit custom metrics (e.g., job processing times, queue lengths). A Prometheus instance configured to scrape these endpoints, along with Grafana for visualization, would provide comprehensive monitoring.

## 7. Trade-offs and Future Improvements

### Current Trade-offs

*   **Single Redis Instance:** For simplicity and local resource constraints, Redis is deployed as a single instance. This is a Single Point of Failure (SPOF).
*   **Persistent Volume Claim (PVC) Type:** The `ReadWriteOnce` PVC used is suitable for local `kind` clusters (often backed by local storage), but not for multi-node production clusters requiring shared access or distributed storage.
*   **Basic Security:** No authentication, authorization, or network policies are implemented. The API is open to anyone who can reach the endpoint.
*   **Limited Error Handling in Worker:** While basic `try-except` blocks are present, there are no retry mechanisms for transient failures or dead-letter queue (DLQ) for consistently failing jobs.
*   **Image Validation:** Image validation is basic (PIL `img.verify()`). More robust validation (e.g., MIME type checks, content analysis) might be needed.
*   **Hardcoded Thumbnail Size:** The thumbnail size is fixed at 100x100.
*   **Resource Limits:** The current resource limits are aggressive for local deployment. They would need to be adjusted upwards for any production environment.

### If I Had Additional Time

*   **Robust Redis Deployment:** Implement Redis Sentinel or Redis Cluster for high availability and fault tolerance.
*   **Kubernetes Horizontal Pod Autoscaler (HPA):** Configure HPA for the Worker Deployment, scaling the number of worker pods automatically based on Redis queue length or CPU utilization.
*   **S3-Compatible Object Storage:** Replace the Kubernetes PVC with an S3-compatible object store (e.g., MinIO, AWS S3, Google Cloud Storage). This provides highly scalable, durable, and easily shareable storage, eliminating the limitations of PVs for this use case.
*   **Advanced Error Handling & Retries:** Implement exponential backoff retries for worker jobs, and a dead-letter queue for failed jobs that require manual inspection or re-submission.
*   **Prometheus and Grafana Integration:** Fully integrate Prometheus for metrics collection and Grafana for dashboarding, providing real-time operational visibility.
*   **API Documentation Enhancement:** Further enrich the OpenAPI documentation with examples and clearer descriptions.
*   **Configurable Thumbnail Size:** Allow the client to specify desired thumbnail dimensions, perhaps with predefined limits.

### Full Productionization Considerations

*   **Security First:**
    *   **Authentication & Authorization:** Implement API keys, OAuth2, or JWT-based authentication for the API.
    *   **Network Policies:** Restrict network traffic between pods (e.g., only API can talk to Redis, workers can only talk to Redis and storage).
    *   **Secrets Management:** Use Kubernetes Secrets (or a secrets manager like HashiCorp Vault) to manage Redis credentials, if any.
    *   **TLS/SSL:** Secure API communication with HTTPS
*   **High Availability & Disaster Recovery:**
    *   **Multi-Zone Deployment:** Deploy across multiple Kubernetes availability zones/regions.
    *   **Database/Queue HA:** As mentioned, Redis Sentinel/Cluster for HA.
    *   **Backup & Restore:** Implement strategies for backing up persistent data (if using a persistent database) and object storage.
*   **Scalability & Performance:**
    *   **HPA:** Automatic scaling of API and Worker.
    *   **Load Balancing:** Ensure an appropriate LoadBalancer is in front of the API (e.g., NGINX Ingress, cloud provider LB).
    *   **Performance Testing:** Conduct load testing to identify bottlenecks and optimize.
*   **Observability:**
    *   **Centralized Logging:** Integrate with a centralized logging solution (e.g., ELK stack, Grafana Loki, Splunk).
    *   **Distributed Tracing:** Implement tracing (e.g., Jaeger, OpenTelemetry) to track requests across API and Worker.
    *   **Alerting:** Set up alerts based on key metrics (e.g., error rates, queue depth, processing latency).
*   **Cost Optimization:**
    *   Monitor resource usage and right-size Kubernetes nodes and pod resources.
    *   Consider spot instances for worker nodes if appropriate.
*   **CI/CD Pipeline:** Automate testing, building Docker images, and deploying Helm charts to ensure rapid and reliable delivery.

This comprehensive README covers the immediate requirements and future considerations, demonstrating a holistic approach to the assignment.