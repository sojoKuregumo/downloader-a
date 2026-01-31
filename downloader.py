import os
import sys
import glob
import shutil
import re
import asyncio
import subprocess
import psutil
import logging
from aiohttp import web
from pyrogram import Client, filters, idle

# --- CONFIGURATION ---
API_ID = int(os.environ.get("API_ID", "0"))
API_HASH = os.environ.get("API_HASH", "")
BOT_TOKEN = os.environ.get("BOT_TOKEN", "")
MEGA_EMAIL = os.environ.get("MEGA_EMAIL", "")
MEGA_PASS = os.environ.get("MEGA_PASS", "")

# --- PATHS (DYNAMIC) ---
BASE_DIR = os.getcwd()
BIN_DIR = os.path.join(BASE_DIR, "bin")
DOWNLOAD_DIR = os.path.join(BASE_DIR, "downloads")
SCRIPT_PATH = os.path.join(BASE_DIR, "animepahe-dl.sh")
MEGA_ROOT = "/Root/AnimeDownloads"

# Add local bin to PATH so script finds ffmpeg/node/mega
os.environ["PATH"] += os.pathsep + BIN_DIR

# --- LOGGING ---
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("Downloader")

app = Client("render_bot", api_id=API_ID, api_hash=API_HASH, bot_token=BOT_TOKEN)
ACTIVE_TASKS = {}

# --- WEB SERVER (REQUIRED FOR RENDER) ---
async def web_server():
    async def handle(request): return web.Response(text="Bot is Running")
    webapp = web.Application()
    webapp.router.add_get("/", handle)
    runner = web.AppRunner(webapp)
    await runner.setup()
    port = int(os.environ.get("PORT", 8080))
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()
    logger.info(f"🌍 Web Server running on port {port}")

# --- HELPERS ---
def start_mega_server():
    """Starts the MEGA CMD server in background"""
    logger.info("☁️ Starting MegaCMD Server...")
    subprocess.Popen(["mega-cmd-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    asyncio.sleep(5)

def mega_login():
    """Logs into Mega"""
    start_mega_server()
    # Check if already logged in
    who = subprocess.run(["mega-whoami"], capture_output=True, text=True)
    if "Account e-mail:" in who.stdout:
        return True
    
    logger.info("🔑 Logging into Mega...")
    login = subprocess.run(["mega-login", MEGA_EMAIL, MEGA_PASS], capture_output=True)
    return login.returncode == 0

def parse_episodes(ep_string):
    episodes = []
    parts = ep_string.split(',')
    for part in parts:
        if '-' in part:
            try:
                start, end = map(int, part.split('-'))
                episodes.extend(range(start, end + 1))
            except: pass
        elif part.isdigit():
            episodes.append(int(part))
    return sorted(list(set(episodes)))

# --- COMMANDS ---
@app.on_message(filters.command(["stats", "storage"]))
async def stats_cmd(client, message):
    cpu = psutil.cpu_percent()
    ram = psutil.virtual_memory().percent
    
    mega_proc = subprocess.run(['mega-df', '-h'], capture_output=True, text=True)
    mega_res = mega_proc.stdout.strip() if mega_proc.returncode == 0 else "Not Logged In"
    
    msg = (
        f"🤖 **System Status**\n"
        f"💻 CPU: `{cpu}%` | RAM: `{ram}%`\n\n"
        f"☁️ **Mega Storage:**\n`{mega_res}`"
    )
    await message.reply(msg)

@app.on_message(filters.command("dl"))
async def dl_cmd(client, message):
    chat_id = message.chat.id
    if chat_id in ACTIVE_TASKS: return await message.reply("⚠️ Bot is busy. Wait for current batch.")

    cmd_text = message.text[4:].strip()
    if not cmd_text: return await message.reply("Usage: `/dl -a Name -e 1-5`")

    # Parse Arguments manually
    try:
        if "-e" not in cmd_text: return await message.reply("❌ Missing `-e` (Episodes)")
        
        # Extract Anime Name
        name_match = re.search(r'-a\s+["\']([^"\']+)["\']', cmd_text)
        anime_name = name_match.group(1) if name_match else "Anime"
        
        # Extract Episodes
        ep_match = re.search(r'-e\s+([\d,-]+)', cmd_text)
        episodes = parse_episodes(ep_match.group(1)) if ep_match else []
        
        # Extract Resolution
        res = "720" # Default
        if "-r 1080" in cmd_text: res = "1080"
        elif "-r 360" in cmd_text: res = "360"

    except Exception as e:
        return await message.reply(f"❌ Parse Error: {e}")

    ACTIVE_TASKS[chat_id] = True
    status = await message.reply(f"🚀 **Queueing:** `{anime_name}`\nEpisodes: `{len(episodes)}`")

    # Create Mega Folder
    safe_name = anime_name.replace(" ", "_")
    subprocess.run(["mega-mkdir", "-p", f"{MEGA_ROOT}/{safe_name}"])

    success = 0
    
    # --- DOWNLOAD LOOP ---
    for ep in episodes:
        if chat_id not in ACTIVE_TASKS: break
        
        # Clean downloads folder
        if os.path.exists(DOWNLOAD_DIR): shutil.rmtree(DOWNLOAD_DIR)
        os.makedirs(DOWNLOAD_DIR, exist_ok=True)

        await status.edit(f"⬇️ **Downloading:** Ep {ep} [{res}p]...")

        # Construct Bash Command
        # We use strict args for the script to avoid menus
        cmd = [
            "bash", SCRIPT_PATH,
            "-a", anime_name,
            "-e", str(ep),
            "-r", res
        ]

        try:
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE
            )
            stdout, stderr = await process.communicate()
            
            # Find the file
            files = glob.glob(f"{DOWNLOAD_DIR}/**/*.mp4", recursive=True)
            
            if files:
                local_file = files[0]
                await status.edit(f"☁️ **Uploading:** Ep {ep}...")
                
                # Upload to Mega
                up = subprocess.run(
                    ["mega-put", local_file, f"{MEGA_ROOT}/{safe_name}/"],
                    capture_output=True
                )
                
                if up.returncode == 0:
                    success += 1
                else:
                    await client.send_message(chat_id, f"❌ Mega Upload Failed Ep {ep}")
            else:
                # Log error if file not found
                err_msg = stderr.decode().strip()[-300:]
                if "Episode" in err_msg and "not found" in err_msg:
                    await client.send_message(chat_id, f"⚠️ Ep {ep} not found on AnimePahe.")
                else:
                    print(f"DL Fail Ep {ep}: {err_msg}")

        except Exception as e:
            print(f"Error Loop: {e}")

        await asyncio.sleep(2)

    await status.edit(f"✅ **Batch Complete**\nUploaded: {success}/{len(episodes)}")
    ACTIVE_TASKS.pop(chat_id, None)

@app.on_message(filters.command("cancel"))
async def cancel_handler(client, message):
    if message.chat.id in ACTIVE_TASKS:
        ACTIVE_TASKS.pop(message.chat.id, None)
        await message.reply("🛑 Stopped.")
    else:
        await message.reply("Nothing to stop.")

if __name__ == "__main__":
    if not mega_login():
        print("❌ CRITICAL: Mega Login Failed! Check Env Vars.")
    
    loop = asyncio.get_event_loop()
    loop.create_task(web_server())
    app.start()
    print("🤖 Bot Online")
    idle()
    app.stop()
