#!/usr/bin/env bash
set -e

echo "🔧 Installing Tools for Render..."

# 1. Install Python Libs
pip install -r requirements.txt

# 2. Create local bin folder
mkdir -p bin
export PATH=$PWD/bin:$PATH

# 3. Install Node.js (CRITICAL for animepahe script)
if [ ! -f "bin/node" ]; then
    echo "⬇️ Downloading Node.js..."
    wget -q https://nodejs.org/dist/v18.16.0/node-v18.16.0-linux-x64.tar.xz
    tar -xf node-v18.16.0-linux-x64.tar.xz
    mv node-v18.16.0-linux-x64/bin/node bin/
    rm -rf node-*
fi

# 4. Install JQ (JSON Processor)
if [ ! -f "bin/jq" ]; then
    echo "⬇️ Downloading JQ..."
    wget -q -O bin/jq https://github.com/jqlang/jq/releases/download/jq-1.6/jq-linux64
    chmod +x bin/jq
fi

# 5. Install FFmpeg (Static Build)
if [ ! -f "bin/ffmpeg" ]; then
    echo "⬇️ Downloading FFmpeg..."
    wget -q https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
    tar -xf ffmpeg-release-amd64-static.tar.xz
    mv ffmpeg-*-amd64-static/ffmpeg bin/
    mv ffmpeg-*-amd64-static/ffprobe bin/
    rm -rf ffmpeg-*
fi

# 6. Install FZF (Script requires it to load, even if we don't use menu)
if [ ! -f "bin/fzf" ]; then
    echo "⬇️ Downloading FZF..."
    wget -q https://github.com/junegunn/fzf/releases/download/0.46.1/fzf-0.46.1-linux_amd64.tar.gz
    tar -xf fzf-0.46.1-linux_amd64.tar.gz
    mv fzf bin/
    rm fzf-*.tar.gz
fi

# 7. Permissions
chmod +x bin/*
chmod +x animepahe-dl.sh

echo "✅ Build Complete. Tools ready in ./bin"
