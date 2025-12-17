import os
import json
import logging
import uuid
import imghdr
from datetime import datetime

from fastapi import FastAPI, File, UploadFile, HTTPException, status
from fastapi.responses import JSONResponse, FileResponse
import redis

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# Environment variables for Redis connection
REDIS_HOST = os.getenv('REDIS_HOST', 'thumbnail-api-release-redis') # Corrected Redis service name
REDIS_PORT = int(os.getenv('REDIS_PORT', 6379))
REDIS_DB = int(os.getenv('REDIS_DB', 0))
JOB_QUEUE = os.getenv('JOB_QUEUE', 'thumbnail_jobs')

# Directory for storing images (should be a mounted volume)
IMAGE_STORAGE_PATH = os.getenv('IMAGE_STORAGE_PATH', '/app/storage')

# Allowed image types
ALLOWED_IMAGE_TYPES = {'jpeg', 'png', 'gif', 'bmp', 'webp', 'tiff'}
MAX_FILE_SIZE = 10 * 1024 * 1024  # 10MB

app = FastAPI(
    title="Thumbnail API",
    description="API for submitting images for thumbnail generation and fetching results.",
    version="0.1.0",
)

# Redis client instance
redis_client: redis.Redis = None

@app.on_event("startup")
async def startup_event():
    """Connect to Redis on startup."""
    global redis_client
    redis_client = get_redis_client()
    # Ensure the storage directory exists
    os.makedirs(IMAGE_STORAGE_PATH, exist_ok=True)
    logging.info(f"Image storage path set to: {IMAGE_STORAGE_PATH}")

def get_redis_client():
    """Establishes and returns a Redis client connection."""
    try:
        r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, db=REDIS_DB, decode_responses=True)
        r.ping()
        logging.info(f"Connected to Redis at {REDIS_HOST}:{REDIS_PORT}")
        return r
    except redis.exceptions.ConnectionError as e:
        logging.error(f"Could not connect to Redis: {e}")
        # In production, might want a more robust retry strategy or separate health check
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Could not connect to Redis service."
        )

# Health check endpoint
@app.get("/health")
async def health_check():
    """Check the health of the API and its connection to Redis."""
    try:
        if redis_client.ping():
            return {"status": "ok", "redis_connected": True}
        else:
            raise Exception("Redis ping failed")
    except Exception as e:
        logging.error(f"Health check failed: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Health check failed: {e}"
        )

def validate_image_file(file_content: bytes, filename: str) -> None:
    """
    Validates that the uploaded file is a valid image.
    Checks file size, MIME type, and magic bytes.

    Args:
        file_content: The file content as bytes
        filename: The original filename

    Raises:
        HTTPException: If validation fails
    """
    # Check file size
    if len(file_content) > MAX_FILE_SIZE:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"File size exceeds maximum allowed size of {MAX_FILE_SIZE / 1024 / 1024}MB"
        )

    # Check if file is empty
    if len(file_content) == 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Uploaded file is empty"
        )

    # Validate image type by checking magic bytes (file signature)
    image_type = imghdr.what(None, h=file_content)

    if image_type is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="File is not a valid image. Only image files are accepted."
        )

    if image_type not in ALLOWED_IMAGE_TYPES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Image type '{image_type}' is not supported. Allowed types: {', '.join(ALLOWED_IMAGE_TYPES)}"
        )

    logging.info(f"File validation passed: type={image_type}, size={len(file_content)} bytes")


@app.post("/jobs", status_code=status.HTTP_202_ACCEPTED)
async def submit_image_for_thumbnail(image: UploadFile = File(...)):
    """
    Submits an image file for thumbnail generation.
    Returns a job ID to track the process.
    """
    job_id = str(uuid.uuid4())

    # Use only server-generated filename to prevent path traversal
    original_filename = f"{job_id}_original.jpg"
    thumbnail_filename = f"{job_id}_thumbnail.png"

    original_file_path = os.path.join(IMAGE_STORAGE_PATH, original_filename)

    logging.info(f"Received image for job {job_id}. Original filename: {image.filename}")

    # Read and validate file content
    try:
        await image.seek(0)
        file_content = await image.read()

        # Validate the image file
        validate_image_file(file_content, image.filename)

        # Save validated image to storage
        with open(original_file_path, "wb") as buffer:
            buffer.write(file_content)
        logging.info(f"Image {original_filename} saved to {original_file_path}")
    except HTTPException:
        # Re-raise validation errors
        raise
    except Exception as e:
        logging.error(f"Failed to save image for job {job_id}: {e}", exc_info=True)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to save image: {e}"
        )

    # Create job data
    job_data = {
        "job_id": job_id,
        "original_filename": original_filename,
        "thumbnail_filename": thumbnail_filename,
        "status": "queued",
        "created_at": datetime.now().isoformat(),
        "started_at": None,
        "finished_at": None,
        "error_message": None
    }

    # Store job data in Redis
    redis_client.set(f"job:{job_id}", json.dumps(job_data))

    # Push job ID to the Redis queue
    redis_client.rpush(JOB_QUEUE, job_id)
    logging.info(f"Job {job_id} queued successfully.")

    return JSONResponse(
        content={
            "job_id": job_id,
            "status": "queued",
            "detail": "Job has been successfully queued for processing."
        },
        status_code=status.HTTP_202_ACCEPTED
    )

@app.get("/jobs")
async def list_all_jobs():
    """Lists all submitted job IDs and their current statuses."""
    all_job_keys = redis_client.keys("job:*")
    jobs = []
    for key in all_job_keys:
        job_data_str = redis_client.get(key)
        if job_data_str:
            job_data = json.loads(job_data_str)
            jobs.append({
                "job_id": job_data["job_id"],
                "status": job_data["status"],
                "created_at": job_data["created_at"]
            })
    # Sort by created_at in descending order
    jobs.sort(key=lambda x: x["created_at"], reverse=True)
    return {"jobs": jobs}


@app.get("/jobs/{job_id}")
async def get_job_status(job_id: str):
    """
    Retrieves the current status of a specific job.
    """
    job_data_str = redis_client.get(f"job:{job_id}")
    if not job_data_str:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Job not found.")

    job_data = json.loads(job_data_str)
    return job_data

@app.get("/jobs/{job_id}/thumbnail")
async def get_thumbnail(job_id: str):
    """
    Fetches the generated thumbnail image once the job has succeeded.
    """
    job_data_str = redis_client.get(f"job:{job_id}")
    if not job_data_str:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Job not found.")

    job_data = json.loads(job_data_str)
    if job_data['status'] == 'succeeded':
        thumbnail_path = os.path.join(IMAGE_STORAGE_PATH, job_data['thumbnail_filename'])
        if os.path.exists(thumbnail_path):
            return FileResponse(thumbnail_path, media_type="image/png")
        else:
            logging.error(f"Thumbnail file not found for succeeded job {job_id} at {thumbnail_path}")
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Thumbnail not found, despite job succeeding. Please contact support."
            )
    elif job_data['status'] == 'failed':
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Job failed with error: {job_data['error_message']}"
        )
    else:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"Job {job_id} is currently {job_data['status']}. Thumbnail not yet available."
        )