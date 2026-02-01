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

# --- PATH SETUP ---
BASE_DIR = os.getcwd()
DOWNLOAD_DIR = os.path.join(BASE_DIR, "downloads")
SCRIPT_PATH = os.path.join(BASE_DIR, "animepahe-dl.sh")

logging.basicConfig(level=logging.INFO)
app = Client("render_direct", api_id=API_ID, api_hash=API_HASH, bot_token=BOT_TOKEN)
ACTIVE_TASKS = {}

# --- WEB SERVER (Keeps Render Alive) ---
async def web_server():
    async def handle(request): 
        return web.Response(text="Bot Running")
    webapp = web.Application()
    webapp.router.add_get("/", handle)
    runner = web.AppRunner(webapp)
    await runner.setup()
    port = int(os.environ.get("PORT", 8080))
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()

# --- COMMAND HANDLER ---
@app.on_message(filters.command("dl"))
async def download_handler(client, message):
    if message.chat.id in ACTIVE_TASKS:
        return await message.reply("⚠️ Busy! Wait for current download.")
    
    cmd_args = message.text[4:].strip()
    if not cmd_args: 
        return await message.reply("Usage: `/dl -a \"Anime Name\" -e 1`\nExample: `/dl -a \"Jujutsu Kaisen\" -e 5`")

    ACTIVE_TASKS[message.chat.id] = True
    status = await message.reply("⬇️ **Starting download...**")

    # Clean previous files
    if os.path.exists(DOWNLOAD_DIR):
        shutil.rmtree(DOWNLOAD_DIR)
    os.makedirs(DOWNLOAD_DIR, exist_ok=True)

    try:
        # Run script with Cloudflare bypass and single thread (memory efficient)
        full_cmd = f"bash {SCRIPT_PATH} {cmd_args} -r 1080 --extractor-args 'generic:impersonate'"
        
        await status.edit("⬇️ **Fetching episode info...**")
        
        process = await asyncio.create_subprocess_shell(
            full_cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=BASE_DIR
        )
        
        await status.edit("⬇️ **Downloading... (This may take a few minutes)**")
        stdout, stderr = await process.communicate()
        
        # Find the video file
        files = glob.glob(f"{DOWNLOAD_DIR}/**/*.mp4", recursive=True)
        
        if files:
            file_path = files[0]
            file_size = os.path.getsize(file_path) / (1024*1024)  # MB
            filename = os.path.basename(file_path)
            
            if file_size > 49:  # Telegram has 50MB file limit
                await status.edit(f"⚠️ **File too large ({file_size:.1f}MB). Telegram limit is 50MB.**")
            else:
                await status.edit(f"🚀 **Uploading {filename} ({file_size:.1f}MB)...**")
                
                # Upload to channel
                await client.send_document(
                    MAIN_CHANNEL_ID,
                    document=file_path,
                    caption=f"**{filename}**",
                    force_document=True
                )
                
                await status.edit("✅ **Done! File uploaded to channel.**")
            
            # Cleanup
            os.remove(file_path)
        else:
            # Send error logs
            log = stderr.decode().strip()[-500:] or stdout.decode().strip()[-500:]
            error_msg = "❌ **Download failed.**\n"
            
            if "Cloudflare" in log:
                error_msg += "\n⚠️ Cloudflare blocking detected. The site might have updated protections."
            elif "ERROR_NOT_FOUND" in log:
                error_msg += "\n⚠️ Episode not found. Check the episode number."
            
            error_msg += f"\n\n`{log}`"
            await status.edit(error_msg)

    except Exception as e:
        await status.edit(f"❌ **Unexpected error:** `{str(e)[:200]}`")
    finally:
        # Final cleanup
        if os.path.exists(DOWNLOAD_DIR):
            shutil.rmtree(DOWNLOAD_DIR, ignore_errors=True)
        ACTIVE_TASKS.pop(message.chat.id, None)

# --- START BOT ---
if __name__ == "__main__":
    loop = asyncio.get_event_loop()
    loop.create_task(web_server())
    app.start()
    print("🤖 Bot Online")
    idle()
    app.stop()
