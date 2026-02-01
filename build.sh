#!/usr/bin/env bash
set -e

echo "🔧 STARTING BUILD..."

# --- 1. INSTALL PYTHON LIBRARIES ---
echo "📦 Installing Python Dependencies..."
pip install -r requirements.txt

# --- 2. INSTALL YT-DLP WITH CLOUDFLARE BYPASS ---
echo "⬇️ Installing yt-dlp with Cloudflare bypass..."
pip install -U yt-dlp
pip install brotli brotlicffi pycryptodomex websockets

# --- 3. SETUP ESSENTIAL TOOLS ---
mkdir -p bin
export PATH=$PWD/bin:$PATH

# Install JQ (lightweight JSON parser)
if [ ! -f "bin/jq" ]; then
    echo "⬇️ Installing JQ..."
    wget -q -O bin/jq https://github.com/jqlang/jq/releases/download/jq-1.6/jq-linux64
    chmod +x bin/jq
fi

# Permissions
chmod +x bin/*
chmod +x animepahe-dl.sh

echo "✅ BUILD COMPLETE"
