#!/usr/bin/env bash
set -e

echo "🔧 STARTING BUILD..."

# --- 1. INSTALL PYTHON LIBRARIES ---
echo "📦 Installing Python Dependencies..."
pip install -r requirements.txt

# --- 2. SETUP LOCAL TOOLS ---
mkdir -p bin
export PATH=$PWD/bin:$PATH

# Install Node.js
if [ ! -f "bin/node" ]; then
    echo "⬇️ Installing Node.js..."
    wget -q https://nodejs.org/dist/v18.16.0/node-v18.16.0-linux-x64.tar.xz
    tar -xf node-v18.16.0-linux-x64.tar.xz
    mv node-v18.16.0-linux-x64/bin/node bin/
    rm -rf node-*
fi

# Install JQ
if [ ! -f "bin/jq" ]; then
    echo "⬇️ Installing JQ..."
    wget -q -O bin/jq https://github.com/jqlang/jq/releases/download/jq-1.6/jq-linux64
    chmod +x bin/jq
fi

# Install FFmpeg
if [ ! -f "bin/ffmpeg" ]; then
    echo "⬇️ Installing FFmpeg..."
    wget -q https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
    tar -xf ffmpeg-release-amd64-static.tar.xz
    mv ffmpeg-*-amd64-static/ffmpeg bin/
    mv ffmpeg-*-amd64-static/ffprobe bin/
    rm -rf ffmpeg-*
fi

# Install FZF
if [ ! -f "bin/fzf" ]; then
    echo "⬇️ Installing FZF..."
    wget -q https://github.com/junegunn/fzf/releases/download/0.46.1/fzf-0.46.1-linux_amd64.tar.gz
    tar -xf fzf-0.46.1-linux_amd64.tar.gz
    mv fzf bin/
    rm fzf-*.tar.gz
fi

# Permissions
chmod +x bin/*
chmod +x animepahe-dl.sh

echo "✅ BUILD COMPLETE"
