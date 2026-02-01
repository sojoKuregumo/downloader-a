import os
import asyncio
import glob
import shutil
import time
import re
import logging
import requests
from aiohttp import web
from pyrogram import Client, filters, idle
from pyrogram.types import Message

# --- CONFIGURATION ---
API_ID = int(os.environ.get("API_ID", "0"))
API_HASH = os.environ.get("API_HASH", "")
BOT_TOKEN = os.environ.get("BOT_TOKEN", "")
CHANNEL_1 = os.environ.get("CHANNEL_1", "")
CHANNEL_2 = os.environ.get("CHANNEL_2", "")
CHANNEL_3 = os.environ.get("CHANNEL_3", "")

# Convert channel IDs to integers if they exist
try:
    if CHANNEL_1: CHANNEL_1 = int(CHANNEL_1)
    if CHANNEL_2: CHANNEL_2 = int(CHANNEL_2)
    if CHANNEL_3: CHANNEL_3 = int(CHANNEL_3)
except ValueError:
    pass

# --- PATH SETUP ---
BASE_DIR = os.getcwd()
DOWNLOAD_DIR = os.path.join(BASE_DIR, "downloads")
SCRIPT_PATH = os.path.join(BASE_DIR, "animepahe-dl.sh")

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Client("render_bot", api_id=API_ID, api_hash=API_HASH, bot_token=BOT_TOKEN)
ACTIVE_TASKS = {}
SETTINGS = {"ch1": False, "ch2": False, "ch3": True}

# --- WEB SERVER (Required for Render) ---
async def web_server():
    async def handle(request):
        return web.Response(text="🤖 Bot is running")
    
    webapp = web.Application()
    webapp.router.add_get("/", handle)
    webapp.router.add_get("/health", handle)
    
    runner = web.AppRunner(webapp)
    await runner.setup()
    port = int(os.environ.get("PORT", 8080))
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()
    logger.info(f"Web server started on port {port}")

# --- ANIME INFO FETCHER ---
def get_anime_details(query):
    """Fetch anime details from Jikan API"""
    try:
        url = f"https://api.jikan.moe/v4/anime?q={requests.utils.quote(query)}&limit=1"
        response = requests.get(url, timeout=10)
        data = response.json()
        
        if data.get('data'):
            anime = data['data'][0]
            
            # Get image
            image_url = anime['images']['jpg']['large_image_url']
            if anime.get('trailer') and anime['trailer'].get('images'):
                max_img = anime['trailer']['images'].get('maximum_image_url')
                if max_img: 
                    image_url = max_img
            
            # Clean duration
            duration_raw = anime.get('duration', '24 min').replace(" per ep", "")
            
            return {
                "title": anime['title'],
                "native": anime.get('title_japanese', ''),
                "duration": duration_raw,
                "url": anime['url'],
                "image": image_url
            }
    except Exception as e:
        logger.error(f"Jikan API error: {e}")
    
    return None

# --- UTILITIES ---
def parse_episodes(ep_string):
    """Parse episode strings like '1,3,5-7' into list"""
    episodes = []
    if not ep_string:
        return episodes
    
    parts = ep_string.split(',')
    for part in parts:
        part = part.strip()
        if '-' in part:
            try:
                start, end = map(int, part.split('-'))
                episodes.extend(range(start, end + 1))
            except ValueError:
                pass
        else:
            try:
                episodes.append(int(part))
            except ValueError:
                pass
    
    return sorted(list(set(episodes)))

def format_time_duration(seconds):
    """Format seconds to readable time"""
    if seconds < 60:
        return f"{int(seconds)}s"
    minutes = int(seconds // 60)
    sec = int(seconds % 60)
    if minutes < 60:
        return f"{minutes}m {sec}s"
    hours = int(minutes // 60)
    minutes = int(minutes % 60)
    return f"{hours}h {minutes}m"

async def get_video_resolution(filepath):
    """Get video resolution using ffprobe"""
    try:
        cmd = f"ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=s=x:p=0 '{filepath}'"
        process = await asyncio.create_subprocess_shell(
            cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        stdout, _ = await process.communicate()
        height = stdout.decode().strip()
        if height.isdigit():
            return f"{height}p"
    except Exception as e:
        logger.error(f"ffprobe error: {e}")
    
    return "Unknown"

# --- BOT COMMANDS ---
@app.on_message(filters.command(["start", "help"]))
async def start_cmd(client, message):
    help_text = """
**📱 Anime Download Bot**

**Commands:**
• `/dl -a "Anime Name" -e 1-5` - Download episodes
• `/dl -a "Anime" -e 1 -r 1080 -o eng` - With resolution & audio
• `/settings` - Check channel status
• `/cancel` - Cancel current download

**Examples:**
`/dl -a "Jujutsu Kaisen" -e 5`
`/dl -a "One Piece" -e 1000-1005 -r 720`
`/dl -a "Attack on Titan" -e 25 -o eng`

**Options:**
`-a` Anime name (in quotes)
`-e` Episode(s): 1, 5, 1-5
`-r` Resolution: 360, 720, 1080
`-o` Audio: eng (dub) or jpn (sub)
"""
    await message.reply(help_text)

@app.on_message(filters.command(["ch1", "ch2", "ch3"]))
async def toggle_channel(client, message):
    """Toggle channel auto-forwarding"""
    cmd = message.command[0]
    if cmd not in SETTINGS:
        await message.reply("⚠️ Invalid channel. Use ch1, ch2, or ch3")
        return
    
    if len(message.command) < 2:
        status = "ON" if SETTINGS[cmd] else "OFF"
        await message.reply(f"**{cmd.upper()}** is currently **{status}**\nUse: `/{cmd} on` or `/{cmd} off`")
        return
    
    state = message.command[1].lower()
    if state == "on":
        SETTINGS[cmd] = True
        await message.reply(f"✅ **{cmd.upper()} Enabled.**")
    elif state == "off":
        SETTINGS[cmd] = False
        await message.reply(f"❌ **{cmd.upper()} Disabled.**")
    else:
        await message.reply("⚠️ Use `on` or `off`")

@app.on_message(filters.command("settings"))
async def check_settings(client, message):
    """Show current settings"""
    def format_channel(ch_id, ch_key):
        if not ch_id:
            return f"❌ Not configured"
        status = "✅ ON" if SETTINGS[ch_key] else "❌ OFF"
        return f"{status} | ID: `{ch_id}`"
    
    status_text = f"""
**⚙️ Bot Settings**

**Channels:**
📢 **CH1:** {format_channel(CHANNEL_1, 'ch1')}
📢 **CH2:** {format_channel(CHANNEL_2, 'ch2')}
📢 **CH3:** {format_channel(CHANNEL_3, 'ch3')}

**Active Tasks:** {len(ACTIVE_TASKS)}
"""
    await message.reply(status_text)

# --- MAIN DOWNLOAD HANDLER ---
@app.on_message(filters.command("dl"))
async def dl_cmd(client, message):
    chat_id = message.chat.id
    
    # Check if busy
    if chat_id in ACTIVE_TASKS:
        await message.reply("⚠️ I'm busy with another download. Please wait or use `/cancel`")
        return
    
    # Parse command
    cmd_text = message.text[4:].strip()
    if not cmd_text:
        await start_cmd(client, message)
        return
    
    # Check for flags
    use_post = "-post" in cmd_text
    use_sticker = "-sticker" in cmd_text
    cmd_text = cmd_text.replace("-post", "").replace("-sticker", "").strip()
    
    # Parse episodes
    ep_match = re.search(r'-e\s+([\d,\-\*]+)', cmd_text)
    if not ep_match:
        await message.reply("❌ Missing episode `-e` parameter")
        return
    
    episode_str = ep_match.group(1)
    episode_list = parse_episodes(episode_str.replace('*', ''))
    
    if not episode_list:
        await message.reply("❌ Invalid episode format. Use: `-e 1`, `-e 1-5`, or `-e 1,3,5`")
        return
    
    # Parse resolution
    resolutions = ["1080", "720", "360"]
    res_match = re.search(r'-r\s+(\d+|all|best)', cmd_text)
    if res_match:
        res = res_match.group(1)
        if res == "all":
            resolutions = ["1080", "720", "360"]
        elif res != "best":
            resolutions = [res]
    
    # Parse audio
    audio_lang = "jpn"
    if "-o eng" in cmd_text:
        audio_lang = "eng"
    
    # Parse anime name
    name_match = re.search(r'-a\s+["\']([^"\']+)["\']', cmd_text)
    if not name_match:
        await message.reply("❌ Missing anime name `-a` parameter (use quotes)")
        return
    
    anime_query = name_match.group(1)
    status_msg = await message.reply("⏳ **Starting download...**")
    
    # Get anime info
    anime_info = get_anime_details(anime_query)
    if not anime_info:
        anime_info = {
            "title": anime_query.title(),
            "native": "",
            "duration": "24 min",
            "url": "",
            "image": None
        }
    
    # Prepare title
    display_title = anime_info['title']
    if audio_lang == "eng":
        display_title = f"{display_title} [English Dub]"
    
    # Register task
    ACTIVE_TASKS[chat_id] = {
        "status": "running",
        "start_time": time.time(),
        "total_episodes": len(episode_list)
    }
    
    try:
        # Process each episode
        for ep_index, ep_num in enumerate(episode_list):
            if chat_id not in ACTIVE_TASKS:
                break
            
            # Update status
            progress = f"[{ep_index + 1}/{len(episode_list)}]"
            await status_msg.edit_text(f"📥 **Downloading Episode {ep_num}...** {progress}")
            
            # Try each resolution until success
            for current_res in resolutions:
                if chat_id not in ACTIVE_TASKS:
                    break
                
                # Build command
                cmd_parts = [
                    "bash", SCRIPT_PATH,
                    f"-a \"{anime_query}\"",
                    f"-e {ep_num}",
                    f"-r {current_res}",
                    f"-o {audio_lang}",
                    "--extractor-args", "\"generic:impersonate\""
                ]
                full_cmd = " ".join(cmd_parts)
                
                logger.info(f"Running: {full_cmd}")
                start_time = time.time()
                
                # Run download script
                process = await asyncio.create_subprocess_shell(
                    full_cmd,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                    cwd=BASE_DIR
                )
                
                ACTIVE_TASKS[chat_id]["process"] = process
                
                # Wait for completion
                stdout, stderr = await process.communicate()
                download_time = time.time() - start_time
                
                # Check for downloaded file
                mp4_files = glob.glob(f"{DOWNLOAD_DIR}/**/*.mp4", recursive=True)
                
                if mp4_files:
                    # Get the newest file
                    file_path = max(mp4_files, key=os.path.getctime)
                    file_size = os.path.getsize(file_path) / (1024 * 1024)  # MB
                    
                    # Check Telegram file limit (50MB)
                    if file_size > 49:
                        await message.reply(f"⚠️ Episode {ep_num} is {file_size:.1f}MB (Telegram limit: 50MB). Skipping upload.")
                        os.remove(file_path)
                        continue
                    
                    # Get resolution
                    detected_res = await get_video_resolution(file_path)
                    
                    # Upload to user
                    await status_msg.edit_text(f"🚀 **Uploading Episode {ep_num}...** {progress}")
                    
                    file_caption = f"{display_title}\n• Episode {ep_num} [{detected_res}]"
                    
                    try:
                        sent_msg = await client.send_document(
                            chat_id=chat_id,
                            document=file_path,
                            caption=file_caption,
                            force_document=True
                        )
                        
                        # Auto-forward to enabled channels
                        for ch_key, ch_id in [("ch1", CHANNEL_1), ("ch2", CHANNEL_2), ("ch3", CHANNEL_3)]:
                            if ch_id and SETTINGS.get(ch_key, False):
                                try:
                                    await client.send_document(
                                        chat_id=ch_id,
                                        document=sent_msg.document.file_id,
                                        caption=file_caption
                                    )
                                except Exception as e:
                                    logger.error(f"Failed to forward to {ch_key}: {e}")
                        
                        upload_time = time.time() - start_time - download_time
                        
                        # Send success report
                        report = (
                            f"✅ **Episode {ep_num} Complete**\n"
                            f"📥 Download: `{format_time_duration(download_time)}`\n"
                            f"🚀 Upload: `{format_time_duration(upload_time)}`\n"
                            f"📁 Size: `{file_size:.1f}MB` | Quality: `{detected_res}`"
                        )
                        await message.reply(report)
                        
                    except Exception as e:
                        await message.reply(f"❌ Upload failed: {str(e)[:200]}")
                    
                    # Cleanup
                    try:
                        os.remove(file_path)
                        # Remove anime directory if empty
                        anime_dir = os.path.dirname(file_path)
                        if os.path.exists(anime_dir) and not os.listdir(anime_dir):
                            shutil.rmtree(anime_dir)
                    except:
                        pass
                    
                    break  # Success, move to next episode
                
                else:
                    # Download failed for this resolution
                    error_log = stderr.decode()[-500:] or stdout.decode()[-500:]
                    logger.error(f"Download failed for EP{ep_num} {current_res}p: {error_log}")
                    
                    if current_res == resolutions[-1]:  # Last resolution failed
                        await message.reply(f"❌ Failed to download Episode {ep_num} with any resolution")
    
    except Exception as e:
        logger.error(f"Download error: {e}")
        await message.reply(f"❌ Error: {str(e)[:200]}")
    
    finally:
        # Cleanup
        if os.path.exists(DOWNLOAD_DIR):
            shutil.rmtree(DOWNLOAD_DIR, ignore_errors=True)
        
        if chat_id in ACTIVE_TASKS:
            del ACTIVE_TASKS[chat_id]
        
        try:
            await status_msg.delete()
        except:
            pass

@app.on_message(filters.command("cancel"))
async def cancel_cmd(client, message):
    """Cancel current download"""
    chat_id = message.chat.id
    
    if chat_id not in ACTIVE_TASKS:
        await message.reply("⚠️ No active download to cancel")
        return
    
    task = ACTIVE_TASKS.get(chat_id)
    if task and "process" in task:
        try:
            task["process"].terminate()
        except:
            pass
    
    # Cleanup files
    try:
        if os.path.exists(DOWNLOAD_DIR):
            shutil.rmtree(DOWNLOAD_DIR, ignore_errors=True)
        
        # Clean any stray MP4 files
        for mp4 in glob.glob("*.mp4") + glob.glob("**/*.mp4", recursive=True):
            try:
                os.remove(mp4)
                dir_path = os.path.dirname(mp4)
                if os.path.exists(dir_path) and not os.listdir(dir_path):
                    shutil.rmtree(dir_path)
            except:
                pass
    except:
        pass
    
    if chat_id in ACTIVE_TASKS:
        del ACTIVE_TASKS[chat_id]
    
    await message.reply("🛑 **Download cancelled and cleaned up**")

# --- START BOT ---
async def main():
    """Start bot and web server"""
    # Start web server (required for Render)
    await web_server()
    
    # Start bot
    await app.start()
    logger.info("🤖 Bot started successfully!")
    
    # Get bot info
    me = await app.get_me()
    logger.info(f"Bot: @{me.username} (ID: {me.id})")
    
    # Keep running
    await idle()
    
    # Stop bot
    await app.stop()
    logger.info("Bot stopped")

if __name__ == "__main__":
    # Run the bot
    asyncio.run(main())
