import os
import asyncio
import glob
import shutil
import logging
from aiohttp import web
from pyrogram import Client, filters, idle

# --- CONFIGURATION ---
API_ID = int(os.environ.get("API_ID", "0"))
API_HASH = os.environ.get("API_HASH", "")
BOT_TOKEN = os.environ.get("BOT_TOKEN", "")
MAIN_CHANNEL_ID = int(os.environ.get("MAIN_CHANNEL_ID", "0"))

# --- PATH SETUP (CRITICAL) ---
BASE_DIR = os.getcwd()
BIN_DIR = os.path.join(BASE_DIR, "bin")
DOWNLOAD_DIR = os.path.join(BASE_DIR, "downloads")
SCRIPT_PATH = os.path.join(BASE_DIR, "animepahe-dl.sh")

# Tell the system where our tools are
os.environ["PATH"] = BIN_DIR + os.pathsep + os.environ["PATH"]

logging.basicConfig(level=logging.INFO)
app = Client("render_direct", api_id=API_ID, api_hash=API_HASH, bot_token=BOT_TOKEN)
ACTIVE_TASKS = {}

# --- WEB SERVER (Keeps Render Alive) ---
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
    
    cmd_args = message.text[4:].strip()
    if not cmd_args: return await message.reply("Usage: `/dl -a \"Name\" -e 1`")

    ACTIVE_TASKS[message.chat.id] = True
    status = await message.reply(f"⬇️ **Starting...**")

    # Clean previous files
    if os.path.exists(DOWNLOAD_DIR): shutil.rmtree(DOWNLOAD_DIR)
    os.makedirs(DOWNLOAD_DIR, exist_ok=True)

    try:
        # Run Script (Force 1080p)
        full_cmd = f"bash {SCRIPT_PATH} {cmd_args} -r 1080"
        
        process = await asyncio.create_subprocess_shell(
            full_cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        
        await status.edit("⬇️ **Downloading... (Please Wait)**")
        stdout, stderr = await process.communicate()
        
        # Find the video file
        files = glob.glob(f"{DOWNLOAD_DIR}/**/*.mp4", recursive=True)
        
        if files:
            file_path = files[0]
            filename = os.path.basename(file_path)
            
            await status.edit(f"🚀 **Uploading:** `{filename}`")
            
            # Upload directly to channel
            await client.send_document(
                MAIN_CHANNEL_ID,
                document=file_path,
                caption=f"**{filename}**",
                force_document=True
            )
            
            await status.edit("✅ **Done!**")
            os.remove(file_path) # Delete immediately to free space
        else:
            # Send logs if failed
            log = stderr.decode().strip()[-800:] 
            if not log: log = stdout.decode().strip()[-800:]
            await status.edit(f"❌ **Download Failed.**\n\nLogs:\n`{log}`")

    except Exception as e:
        await status.edit(f"❌ Error: {e}")

    # Cleanup
    if os.path.exists(DOWNLOAD_DIR): shutil.rmtree(DOWNLOAD_DIR)
    ACTIVE_TASKS.pop(message.chat.id, None)

if __name__ == "__main__":
    loop = asyncio.get_event_loop()
    loop.create_task(web_server())
    app.start()
    print("🤖 Bot Online")
    idle()
    app.stop()
