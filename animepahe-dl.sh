#!/usr/bin/env bash
# Render-optimized version: Uses yt-dlp with Cloudflare bypass

set -e
set -u

# --- CONFIGURATION ---
_HOST="https://animepahe.si"
_API_URL="$_HOST/api"
_REFERER_URL="https://kwik.cx/"
_USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# --- TOOLS ---
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "[ERROR] $1 command not found!" >&2
        exit 1
    fi
}

_CURL=$(command -v curl)
_JQ=$(command -v jq)
_YTDLP=$(command -v yt-dlp)

check_command curl
check_command jq
check_command yt-dlp

# --- PATHS ---
_SCRIPT_PATH=$(dirname "$(realpath "$0")")
_DOWNLOAD_DIR="$_SCRIPT_PATH/downloads"
_ANIME_LIST_FILE="$_SCRIPT_PATH/anime.list"
_SOURCE_FILE=".source.json"

mkdir -p "$_DOWNLOAD_DIR"

# --- ARGUMENT PARSING ---
set_args() {
    while getopts ":ha:s:e:r:o:" opt; do
        case $opt in
            a) _INPUT_ANIME_NAME="$OPTARG" ;;
            s) _ANIME_SLUG="$OPTARG" ;;
            e) _ANIME_EPISODE="$OPTARG" ;;
            r) _ANIME_RESOLUTION="$OPTARG" ;;
            o) _ANIME_AUDIO="$OPTARG" ;;
            h) usage ;;
            \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
        esac
    done
}

usage() {
    echo "Usage: $0 -a \"Anime Name\" -e episode [-r 1080|720|360] [-o eng|jpn]"
    echo "Example: $0 -a \"Jujutsu Kaisen\" -e 5 -r 1080 -o jpn"
    exit 1
}

# --- UTILITIES ---
log_info() { echo "[INFO] $1" >&2; }
log_warn() { echo "[WARN] $1" >&2; }
log_error() { echo "[ERROR] $1" >&2; }

get() {
    "$_CURL" -sS -L "$1" \
        -H "User-Agent: $_USER_AGENT" \
        -H "Referer: $_HOST" \
        --compressed
}

set_cookie() {
    local u
    u="$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)"
    _COOKIE="__ddg2_=$u"
}

# --- SEARCH ANIME ---
search_anime_by_name() {
    local query encoded_url response
    query="${1// /%20}"
    encoded_url="$_HOST/api?m=search&q=$query"
    
    response="$(get "$encoded_url")"
    
    if [[ "$("$_JQ" -r '.total' <<< "$response")" -eq "0" ]]; then
        echo ""
    else
        "$_JQ" -r '.data[0] | "[\(.session)] \(.title)"' <<< "$response"
    fi
}

# --- GET EPISODE DATA ---
get_episode_list() {
    get "${_API_URL}?m=release&id=${1}&sort=episode_asc&page=1"
}

download_source() {
    local anime_data
    mkdir -p "$_DOWNLOAD_DIR/$_ANIME_NAME"
    anime_data="$(get_episode_list "$_ANIME_SLUG")"
    echo "$anime_data" > "$_DOWNLOAD_DIR/$_ANIME_NAME/$_SOURCE_FILE"
}

# --- GET DOWNLOAD LINK ---
get_episode_link() {
    local episode_num session_id player_page links filtered_links final_link
    
    episode_num="$1"
    
    # Get session ID from source file
    session_id=$("$_JQ" -r '.data[] | select((.episode | tonumber) == ($num | tonumber)) | .session' \
        --arg num "$episode_num" < "$_DOWNLOAD_DIR/$_ANIME_NAME/$_SOURCE_FILE")
    
    if [[ -z "$session_id" ]]; then
        log_error "Episode $episode_num not found!"
        echo "ERROR_NOT_FOUND"
        return 1
    fi
    
    # Get player page
    player_url="$_HOST/play/$_ANIME_SLUG/$session_id"
    player_page="$("$_CURL" -sSL "$player_url" -H "User-Agent: $_USER_AGENT")"
    
    # Extract all video links
    links="$(echo "$player_page" | grep -o 'data-src="[^"]*"' | cut -d'"' -f2 | grep 'data-av1="0"')"
    
    if [[ -z "$links" ]]; then
        log_error "No video links found!"
        echo ""
        return 1
    fi
    
    # Filter by audio if specified
    filtered_links="$links"
    if [[ -n "${_ANIME_AUDIO:-}" ]]; then
        filtered_links="$(echo "$filtered_links" | grep "data-audio=\"$_ANIME_AUDIO\"" || echo "$filtered_links")"
    fi
    
    # Filter by resolution if specified
    if [[ -n "${_ANIME_RESOLUTION:-}" ]]; then
        filtered_links="$(echo "$filtered_links" | grep "data-resolution=\"$_ANIME_RESOLUTION\"" || echo "$filtered_links")"
        
        if [[ "$filtered_links" != "$links" ]]; then
            log_info "Selected resolution: $_ANIME_RESOLUTION"
        else
            log_warn "Resolution $_ANIME_RESOLUTION not found, using best available"
        fi
    fi
    
    # Get the final kwik link
    final_link="$(echo "$filtered_links" | grep kwik | head -1)"
    
    if [[ -z "$final_link" ]]; then
        log_error "No kwik link found!"
        echo ""
        return 1
    fi
    
    echo "$final_link"
    return 0
}

# --- DOWNLOAD EPISODE ---
download_episode() {
    local episode_num kwik_link output_file yt_dlp_args
    
    episode_num="$1"
    output_file="$_DOWNLOAD_DIR/${_ANIME_NAME}/Episode_${episode_num}.mp4"
    
    log_info "Fetching link for episode $episode_num..."
    
    kwik_link="$(get_episode_link "$episode_num")"
    
    if [[ "$kwik_link" == "ERROR_NOT_FOUND" ]] || [[ -z "$kwik_link" ]]; then
        log_error "Failed to get download link for episode $episode_num"
        return 1
    fi
    
    log_info "Found link: ${kwik_link:0:60}..."
    
    # Create yt-dlp arguments
    yt_dlp_args=(
        "$kwik_link"
        -o "$output_file"
        --referer "$_REFERER_URL"
        --user-agent "$_USER_AGENT"
        --no-playlist
        --retries 3
        --fragment-retries 3
        --socket-timeout 30
        --retry-sleep 2
        --throttled-rate 100K
        --concurrent-fragments 2  # Reduced for Render memory limits
    )
    
    # Add Cloudflare impersonation if in arguments
    for arg in "$@"; do
        if [[ "$arg" == *"impersonate"* ]]; then
            yt_dlp_args+=(--extractor-args "generic:impersonate")
            log_info "Using Cloudflare impersonation"
        fi
    done
    
    # Run yt-dlp
    log_info "Starting download with yt-dlp..."
    
    if "$_YTDLP" "${yt_dlp_args[@]}"; then
        if [[ -f "$output_file" ]]; then
            file_size=$(du -h "$output_file" | cut -f1)
            log_info "✅ Download successful: $output_file ($file_size)"
            return 0
        fi
    fi
    
    log_error "❌ Download failed for episode $episode_num"
    return 1
}

# --- MAIN ---
main() {
    set_args "$@"
    
    # Validate arguments
    if [[ -z "${_INPUT_ANIME_NAME:-}" ]] && [[ -z "${_ANIME_SLUG:-}" ]]; then
        log_error "Anime name (-a) or slug (-s) is required"
        usage
    fi
    
    if [[ -z "${_ANIME_EPISODE:-}" ]]; then
        log_error "Episode number (-e) is required"
        usage
    fi
    
    # Set cookie
    set_cookie
    
    # Get anime info
    if [[ -n "${_INPUT_ANIME_NAME:-}" ]]; then
        log_info "Searching for: $_INPUT_ANIME_NAME"
        
        search_result="$(search_anime_by_name "$_INPUT_ANIME_NAME")"
        
        if [[ -z "$search_result" ]]; then
            log_error "Anime '$_INPUT_ANIME_NAME' not found!"
            exit 1
        fi
        
        # Extract slug: [slug] title
        _ANIME_SLUG="${search_result%%]*}"
        _ANIME_SLUG="${_ANIME_SLUG#[}"
        _ANIME_NAME="${search_result#*] }"
    else
        _ANIME_NAME="Anime_$_ANIME_SLUG"
    fi
    
    # Sanitize anime name for filesystem
    _ANIME_NAME="$(echo "$_ANIME_NAME" | tr -cd '[:alnum:] ._-' | sed 's/\.\.*/./g')"
    
    log_info "Anime: $_ANIME_NAME"
    log_info "Slug: $_ANIME_SLUG"
    log_info "Episode(s): $_ANIME_EPISODE"
    log_info "Resolution: ${_ANIME_RESOLUTION:-best}"
    log_info "Audio: ${_ANIME_AUDIO:-jpn}"
    
    # Download episode list
    download_source
    
    # Process episodes
    if [[ "$_ANIME_EPISODE" == *","* ]]; then
        IFS=',' read -ra episodes <<< "$_ANIME_EPISODE"
        success_count=0
        
        for ep in "${episodes[@]}"; do
            ep="$(echo "$ep" | xargs)"  # Trim whitespace
            if download_episode "$ep" "$@"; then
                success_count=$((success_count + 1))
            fi
        done
        
        log_info "Completed $success_count/${#episodes[@]} episodes"
        
        if [[ $success_count -eq 0 ]]; then
            exit 1
        fi
    else
        # Single episode
        if ! download_episode "$_ANIME_EPISODE" "$@"; then
            exit 1
        fi
    fi
}

# --- EXECUTE ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
