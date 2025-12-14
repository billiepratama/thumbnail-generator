import os
import time
import json
import logging
from PIL import Image
import redis

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# Environment variables for Redis connection
REDIS_HOST = os.getenv('REDIS_HOST', 'redis')
REDIS_PORT = int(os.getenv('REDIS_PORT', 6379))
REDIS_DB = int(os.getenv('REDIS_DB', 0))
INPUT_QUEUE = os.getenv('INPUT_QUEUE', 'thumbnail_jobs')

# Directory for storing images (should be a mounted volume)
IMAGE_STORAGE_PATH = os.getenv('IMAGE_STORAGE_PATH', '/app/storage')

# Thumbnail size
THUMBNAIL_SIZE = (100, 100)

def get_redis_client():
    """Establishes and returns a Redis client connection."""
    try:
        r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, db=REDIS_DB, decode_responses=True)
        r.ping()
        logging.info(f"Connected to Redis at {REDIS_HOST}:{REDIS_PORT}")
        return r
    except redis.exceptions.ConnectionError as e:
        logging.error(f"Could not connect to Redis: {e}")
        time.sleep(5) # Wait before retrying
        return get_redis_client() # Retry connection

def process_image_job(job_id: str, redis_client: redis.Redis):
    """Processes a single image thumbnail generation job."""
    job_key = f"job:{job_id}"
    try:
        job_data_str = redis_client.get(job_key)
        if not job_data_str:
            logging.warning(f"Job data not found for job_id: {job_id}. Skipping.")
            return

        job_data = json.loads(job_data_str)
        original_image_path = os.path.join(IMAGE_STORAGE_PATH, job_data['original_filename'])
        thumbnail_image_path = os.path.join(IMAGE_STORAGE_PATH, job_data['thumbnail_filename'])

        logging.info(f"Processing job {job_id}: {original_image_path} to {thumbnail_image_path}")

        # Update job status to processing
        job_data['status'] = 'processing'
        job_data['started_at'] = time.time()
        redis_client.set(job_key, json.dumps(job_data))

        # Check if original image exists
        if not os.path.exists(original_image_path):
            raise FileNotFoundError(f"Original image not found: {original_image_path}")

        # Open image, resize, and save
        with Image.open(original_image_path) as img:
            img.thumbnail(THUMBNAIL_SIZE)
            img.save(thumbnail_image_path, "PNG") # Save as PNG for consistency

        # Update job status to succeeded
        job_data['status'] = 'succeeded'
        job_data['finished_at'] = time.time()
        redis_client.set(job_key, json.dumps(job_data))
        logging.info(f"Job {job_id} succeeded. Thumbnail saved to {thumbnail_image_path}")

    except FileNotFoundError as e:
        logging.error(f"Job {job_id} failed: {e}")
        job_data['status'] = 'failed'
        job_data['error_message'] = str(e)
        redis_client.set(job_key, json.dumps(job_data))
    except Exception as e:
        logging.error(f"Error processing job {job_id}: {e}", exc_info=True)
        job_data['status'] = 'failed'
        job_data['error_message'] = str(e)
        redis_client.set(job_key, json.dumps(job_data))

def main():
    logging.info("Thumbnail worker started.")
    redis_client = get_redis_client()

    # Ensure the storage directory exists
    os.makedirs(IMAGE_STORAGE_PATH, exist_ok=True)
    logging.info(f"Image storage path set to: {IMAGE_STORAGE_PATH}")

    while True:
        try:
            # BLPOP blocks until an item is available
            # Returns a tuple: (list_name, item)
            item = redis_client.blpop(INPUT_QUEUE, timeout=0) # 0 means block indefinitely
            if item:
                queue_name, job_id = item
                logging.info(f"Received job_id: {job_id} from queue: {queue_name}")
                process_image_job(job_id, redis_client)
        except redis.exceptions.ConnectionError:
            logging.error("Lost connection to Redis. Attempting to reconnect...")
            redis_client = get_redis_client()
        except Exception as e:
            logging.error(f"An unhandled error occurred in the main loop: {e}", exc_info=True)
        time.sleep(1) # Small delay to prevent busy-waiting if an error loop occurs quickly

if __name__ == "__main__":
    main()