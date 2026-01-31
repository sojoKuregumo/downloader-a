import os
import asyncio
import glob
import shutil
import logging
from aiohttp import web
from pyrogram import Client, filters, idle

# --- CONFIGURATION ---
API_ID = int(os.environ.get("API_ID"))
API_HASH = os.environ.get("API_HASH")
BOT_TOKEN = os.environ.get("BOT_TOKEN")
MAIN_CHANNEL_ID = int(os.environ.get("MAIN_CHANNEL_ID")) # Where to upload

# Setup Paths
BASE_DIR = os.getcwd()
BIN_DIR = os.path.join(BASE_DIR, "bin")
DOWNLOAD_DIR = os.path.join(BASE_DIR, "downloads")
SCRIPT_PATH = os.path.join(BASE_DIR, "animepahe-dl.sh")

# Add our custom bin folder to system PATH so the script finds node/jq/ffmpeg
os.environ["PATH"] += os.pathsep + BIN_DIR

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("Bot")

app = Client("render_direct", api_id=API_ID, api_hash=API_HASH, bot_token=BOT_TOKEN)
ACTIVE_TASKS = {}

# --- WEB SERVER (Keeps Render Awake) ---
async def web_server():
    async def handle(request): return web.Response(text="Bot Running")
    webapp = web.Application()
    webapp.router.add_get("/", handle)
    runner = web.AppRunner(webapp)
    await runner.setup()
    port = int(os.environ.get("PORT", 8080))
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()

# --- COMMAND ---
@app.on_message(filters.command("dl"))
async def download_handler(client, message):
    if message.chat.id in ACTIVE_TASKS:
        return await message.reply("⚠️ Busy! Wait for current download.")
    
    # Parse: /dl -a "Naruto" -e 1
    cmd = message.text[4:].strip()
    if not cmd: return await message.reply("Usage: `/dl -a \"Name\" -e 1`")

    ACTIVE_TASKS[message.chat.id] = True
    status = await message.reply(f"⬇️ **Starting Download...**\n`{cmd}`")

    # Clear previous downloads to save space
    if os.path.exists(DOWNLOAD_DIR): shutil.rmtree(DOWNLOAD_DIR)
    os.makedirs(DOWNLOAD_DIR, exist_ok=True)

    try:
        # Run the bash script
        # We use 'bash' explicitly
        proc = await asyncio.create_subprocess_exec(
            "bash", SCRIPT_PATH, *cmd.split(), "-r", "1080", # Force arguments
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        
        # Stream logs (optional, simple wait here)
        await status.edit("⬇️ **Downloading (Please Wait)...**")
        stdout, stderr = await proc.communicate()

        # Check for file
        files = glob.glob(f"{DOWNLOAD_DIR}/**/*.mp4", recursive=True)
        
        if files:
            file_path = files[0]
            filename = os.path.basename(file_path)
            
            await status.edit(f"🚀 **Uploading:** `{filename}`")
            
            # Upload to Channel
            await client.send_document(
                MAIN_CHANNEL_ID,
                document=file_path,
                caption=f"**{filename}**\n\nUploaded by Bot",
                force_document=True
            )
            
            await status.edit("✅ **Done!**")
            
            # CLEANUP IMMEDIATELY
            os.remove(file_path)
        else:
            # Send Error Log if no file
            err_log = stderr.decode()[-500:] # Last 500 chars
            await status.edit(f"❌ **Download Failed.**\nLogs:\n`{err_log}`")

    except Exception as e:
        await status.edit(f"❌ Error: {e}")
    
    # Cleanup
    if os.path.exists(DOWNLOAD_DIR): shutil.rmtree(DOWNLOAD_DIR)
    ACTIVE_TASKS.pop(message.chat.id, None)

if __name__ == "__main__":
    loop = asyncio.get_event_loop()
    loop.create_task(web_server())
    app.start()
    print("🤖 Direct Uploader Online")
    idle()
    app.stop()
