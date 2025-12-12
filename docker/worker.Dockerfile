# Use a lightweight Python base image
FROM python:3.11-slim-buster

# Set environment variables
ENV PYTHONUNBUFFERED 1
ENV APP_HOME /app

# Create app directory
WORKDIR $APP_HOME

# Install dependencies
COPY src/worker/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source code
COPY src/worker/ .

# Command to run the worker
CMD ["python", "main.py"]
