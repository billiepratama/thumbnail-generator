# Use a lightweight Python base image
FROM python:3.11-slim-buster

# Set environment variables
ENV PYTHONUNBUFFERED 1
ENV APP_HOME /app

# Create app directory
WORKDIR $APP_HOME

# Install dependencies
COPY src/api/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source code
COPY src/api/ .

# Expose the port FastAPI runs on
EXPOSE 8000

# Command to run the application
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
