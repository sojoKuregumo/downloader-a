FROM python:3.11-slim

WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    jq \
    ffmpeg \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for better caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application files
COPY . .

# Make scripts executable
RUN chmod +x animepahe-dl.sh

# Create necessary directories
RUN mkdir -p downloads

# Set environment variables
ENV PORT=8080
ENV PYTHONUNBUFFERED=1

# Start command
CMD ["python", "bot.py"]
