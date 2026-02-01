#!/usr/bin/env bash
set -e

echo "🔧 STARTING MASTER BUILD..."

# 1. INSTALL PYTHON LIBRARIES
pip install -r requirements.txt

# 2. SETUP LOCAL BIN FOLDER
mkdir -p bin
export PATH=$PWD/bin:$PATH

# 3. INSTALL NODE.JS
if [ ! -f "bin/node" ]; then
    echo "⬇️ Downloading Node.js..."
    wget -q https://nodejs.org/dist/v18.16.0/node-v18.16.0-linux-x64.tar.xz
    tar -xf node-v18.16.0-linux-x64.tar.xz
    mv node-v18.16.0-linux-x64/bin/node bin/
    rm -rf node-*
fi

# 4. INSTALL JQ
if [ ! -f "bin/jq" ]; then
    echo "⬇️ Downloading JQ..."
    wget -q -O bin/jq https://github.com/jqlang/jq/releases/download/jq-1.6/jq-linux64
    chmod +x bin/jq
fi

# 5. INSTALL FFMPEG
if [ ! -f "bin/ffmpeg" ]; then
    echo "⬇️ Downloading FFmpeg..."
    wget -q https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
    tar -xf ffmpeg-release-amd64-static.tar.xz
    mv ffmpeg-*-amd64-static/ffmpeg bin/
    mv ffmpeg-*-amd64-static/ffprobe bin/
    rm -rf ffmpeg-*
fi

# 6. INSTALL YT-DLP
if [ ! -f "bin/yt-dlp" ]; then
    echo "⬇️ Downloading yt-dlp..."
    wget -q https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -O bin/yt-dlp
    chmod +x bin/yt-dlp
fi

# 7. PERMISSIONS
chmod +x bin/*
chmod +x animepahe-dl.sh

echo "✅ BUILD COMPLETE"
