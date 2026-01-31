#!/usr/bin/env bash
set -e

echo "🔧 Starting Build Process..."

# 1. Install Python Dependencies
pip install -r requirements.txt

# 2. Create Local Bin Directory
mkdir -p bin
export PATH=$PWD/bin:$PATH

# 3. Install FFmpeg (Static Build)
if [ ! -f "bin/ffmpeg" ]; then
    echo "⬇️ Downloading FFmpeg..."
    wget -q https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
    tar -xf ffmpeg-release-amd64-static.tar.xz
    mv ffmpeg-*-amd64-static/ffmpeg bin/
    mv ffmpeg-*-amd64-static/ffprobe bin/
    rm -rf ffmpeg-*
fi

# 4. Install Node.js (Required for animepahe-dl)
if [ ! -f "bin/node" ]; then
    echo "⬇️ Downloading Node.js..."
    wget -q https://nodejs.org/dist/v18.16.0/node-v18.16.0-linux-x64.tar.xz
    tar -xf node-v18.16.0-linux-x64.tar.xz
    mv node-v18.16.0-linux-x64/bin/node bin/
    rm -rf node-*
fi

# 5. Install JQ (JSON Processor)
if [ ! -f "bin/jq" ]; then
    echo "⬇️ Downloading JQ..."
    wget -q -O bin/jq https://github.com/jqlang/jq/releases/download/jq-1.6/jq-linux64
    chmod +x bin/jq
fi

# 6. Install MEGA CMD (Extracted from DEB)
if [ ! -f "bin/mega-login" ]; then
    echo "⬇️ Downloading MegaCMD..."
    wget -q https://mega.nz/linux/repo/xUbuntu_22.04/amd64/megacmd-xUbuntu_22.04_amd64.deb
    ar x megacmd-xUbuntu_22.04_amd64.deb
    tar -xf data.tar.xz
    mv usr/bin/mega-* bin/
    rm -rf usr megacmd-* data.tar.xz debian-binary control.tar.xz
fi

# 7. Final Permissions
chmod +x bin/*
chmod +x animepahe-dl.sh

echo "✅ Build Complete. Tools installed in /bin"
