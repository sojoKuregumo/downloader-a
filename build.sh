#!/usr/bin/env bash
set -e

echo "🔧 Starting Render build process..."

# --- 1. INSTALL PYTHON DEPENDENCIES ---
echo "📦 Installing Python dependencies..."
pip install --upgrade pip
pip install -r requirements.txt

# --- 2. INSTALL YT-DLP WITH CLOUDFLARE BYPASS ---
echo "⬇️ Installing yt-dlp with Cloudflare support..."
pip install -U yt-dlp
pip install brotli brotlicffi pycryptodomex websockets

# --- 3. INSTALL ESSENTIAL TOOLS ---
echo "⬇️ Installing essential tools..."

# Install jq (JSON processor)
if ! command -v jq &> /dev/null; then
    echo "  Installing jq..."
    wget -q -O /tmp/jq https://github.com/jqlang/jq/releases/download/jq-1.6/jq-linux64
    chmod +x /tmp/jq
    mv /tmp/jq /usr/local/bin/jq 2>/dev/null || true
fi

# Install ffmpeg (for video info)
if ! command -v ffmpeg &> /dev/null || ! command -v ffprobe &> /dev/null; then
    echo "  Installing ffmpeg..."
    apt-get update && apt-get install -y ffmpeg 2>/dev/null || \
    yum install -y ffmpeg 2>/dev/null || \
    echo "  Could not install ffmpeg, continuing without it..."
fi

# --- 4. SETUP PERMISSIONS ---
echo "🔒 Setting up permissions..."
chmod +x animepahe-dl.sh
chmod +x build.sh

# --- 5. CREATE REQUIRED DIRECTORIES ---
echo "📁 Creating directories..."
mkdir -p downloads

# --- 6. CHECK INSTALLATIONS ---
echo "🔍 Verifying installations..."

if command -v python3 &> /dev/null; then
    python3 --version
else
    echo "⚠️ Python3 not found!"
fi

if command -v yt-dlp &> /dev/null; then
    echo "✅ yt-dlp installed: $(yt-dlp --version)"
else
    echo "❌ yt-dlp installation failed!"
fi

if command -v jq &> /dev/null; then
    echo "✅ jq installed: $(jq --version)"
else
    echo "❌ jq installation failed!"
fi

# --- 7. CLEANUP ---
echo "🧹 Cleaning up..."
rm -rf /tmp/* /var/cache/* 2>/dev/null || true

echo "✅ Build completed successfully!"
echo ""
echo "📋 Environment ready for:"
echo "   • Python bot with Pyrogram"
echo "   • yt-dlp with Cloudflare bypass"
echo "   • Anime downloading via animepahe"
