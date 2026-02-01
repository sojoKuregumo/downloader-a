#!/usr/bin/env bash
set -e
set -u

# --- TOOLS ---
_CURL="$(command -v curl)"
_JQ="$(command -v jq)"
_YTDLP="$(command -v yt-dlp)"

_HOST="https://animepahe.si"
_API_URL="$_HOST/api"
_REFERER_URL="https://kwik.cx/"

_SCRIPT_PATH=$(dirname "$(realpath "$0")")
_DOWNLOAD_DIR="$_SCRIPT_PATH/downloads"
_ANIME_LIST_FILE="$_SCRIPT_PATH/anime.list"
_SOURCE_FILE=".source.json"

mkdir -p "$_DOWNLOAD_DIR"

_USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

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
    echo "Usage: $0 -a \"Anime Name\" -e episode [-r 1080|720] [-o eng|jpn]"
    echo "Example: $0 -a \"Jujutsu Kaisen\" -e 5 -r 1080"
    exit 1
}

# --- UTILITIES ---
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

search_anime_by_name() {
    local d n
    d="$(get "$_HOST/api?m=search&q=${1// /%20}")"
    n="$("$_JQ" -r '.total' <<< "$d")"
    if [[ "$n" -eq "0" ]]; then
        echo ""
    else
        "$_JQ" -r '.data[0] | "[\(.session)] \(.title)"' <<< "$d"
    fi
}

get_episode_list() { 
    get "${_API_URL}?m=release&id=${1}&sort=episode_asc&page=1"
}

download_source() {
    local d
    mkdir -p "$_DOWNLOAD_DIR/$_ANIME_NAME"
    d="$(get_episode_list "$_ANIME_SLUG")"
    echo "$d" > "$_DOWNLOAD_DIR/$_ANIME_NAME/$_SOURCE_FILE"
}

# --- GET EPISODE LINK ---
get_episode_link() {
    local s o l r=""
    s=$("$_JQ" -r '.data[] | select((.episode | tonumber) == ($num | tonumber)) | .session' --arg num "$1" < "$_DOWNLOAD_DIR/$_ANIME_NAME/$_SOURCE_FILE")
    
    if [[ -z "$s" ]]; then 
        echo "ERROR_NOT_FOUND"
        return
    fi
    
    # Get player page
    o="$("$_CURL" -sSL -H "User-Agent: $_USER_AGENT" "${_HOST}/play/${_ANIME_SLUG}/${s}")"
    
    # Extract Kwik links
    l="$(grep 'data-src=' <<< "$o" | grep 'data-av1="0"' | sed -E 's/.*data-src="([^"]+)".*/\1/')"

    # Filter by resolution if specified
    if [[ -n "${_ANIME_RESOLUTION:-}" ]]; then
        r="$(grep "data-resolution=\"$_ANIME_RESOLUTION\"" <<< "$l" || true)"
        if [[ -n "$r" ]]; then
            l="$r"
        else
            echo "[INFO] Resolution $_ANIME_RESOLUTION not found, using best available." >&2
        fi
    fi

    # Filter by audio if specified
    if [[ -n "${_ANIME_AUDIO:-}" ]]; then
        r="$(grep "data-audio=\"$_ANIME_AUDIO\"" <<< "$l" || true)"
        if [[ -n "$r" ]]; then
            l="$r"
        else
            echo "[INFO] Audio $_ANIME_AUDIO not found, using default." >&2
        fi
    fi

    # Get first valid link
    grep kwik <<< "$l" | head -1 || echo ""
}

# --- DOWNLOAD EPISODE ---
download_episode() {
    local num="$1"
    local v="$_DOWNLOAD_DIR/${_ANIME_NAME}/${num}.mp4"
    local yt_dlp_args=""

    echo "[INFO] Fetching link for episode $num..." >&2
    local l="$(get_episode_link "$num")"

    if [[ "$l" == "ERROR_NOT_FOUND" ]]; then
        echo "[ERROR] Episode $num not found!" >&2
        return 1
    fi

    if [[ -z "$l" ]]; then
        echo "[ERROR] Could not extract download link!" >&2
        return 1
    fi

    echo "[INFO] Found link: $l" >&2
    echo "[INFO] Starting download..." >&2

    # Build yt-dlp arguments
    yt_dlp_args=(
        "$l"
        -o "$v"
        --referer "https://kwik.cx/"
        --user-agent "$_USER_AGENT"
        --no-playlist
        --retries 3
        --fragment-retries 3
        --socket-timeout 30
        --retry-sleep 2
    )

    # Add impersonation if specified
    for arg in "$@"; do
        if [[ "$arg" == *"impersonate"* ]]; then
            yt_dlp_args+=(--extractor-args "generic:impersonate")
        fi
    done

    # Run yt-dlp
    if "$_YTDLP" "${yt_dlp_args[@]}"; then
        if [[ -f "$v" ]]; then
            echo "✅ Download successful: $v" >&2
            return 0
        fi
    fi
    
    echo "❌ Download failed." >&2
    return 1
}

# --- MAIN ---
main() {
    set_args "$@"
    
    # Check required arguments
    if [[ -z "${_INPUT_ANIME_NAME:-}" ]] && [[ -z "${_ANIME_SLUG:-}" ]]; then
        echo "[ERROR] You must specify anime name with -a or slug with -s" >&2
        usage
    fi
    
    if [[ -z "${_ANIME_EPISODE:-}" ]]; then
        echo "[ERROR] You must specify episode with -e" >&2
        usage
    fi
    
    set_cookie
    
    # Get anime info
    if [[ -n "${_INPUT_ANIME_NAME:-}" ]]; then
        echo "[INFO] Searching for: $_INPUT_ANIME_NAME" >&2
        search_res=$(search_anime_by_name "$_INPUT_ANIME_NAME")
        if [[ -z "$search_res" ]]; then
            echo "[ERROR] Anime not found!" >&2
            exit 1
        fi
        
        # Extract slug from [slug] title format
        _ANIME_SLUG="${search_res%%]*}"
        _ANIME_SLUG="${_ANIME_SLUG#[}"
        _ANIME_NAME="${search_res#*] }"
    else
        _ANIME_NAME="Unknown_Anime"
    fi
    
    # Sanitize anime name for filesystem
    _ANIME_NAME=$(echo "$_ANIME_NAME" | sed -E 's/[^[:alnum:] ._-]/_/g')
    
    echo "[INFO] Anime: $_ANIME_NAME" >&2
    echo "[INFO] Slug: $_ANIME_SLUG" >&2
    echo "[INFO] Episode: $_ANIME_EPISODE" >&2
    
    # Download source data
    download_source
    
    # Download episode(s)
    if [[ "$_ANIME_EPISODE" == *","* ]]; then
        IFS=',' read -ra EPS <<< "$_ANIME_EPISODE"
        for ep in "${EPS[@]}"; do
            download_episode "$ep" "$@"
        done
    else
        download_episode "$_ANIME_EPISODE" "$@"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
