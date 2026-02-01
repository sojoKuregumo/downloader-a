#!/usr/bin/env bash
set -e
set -u
set -x  # 🚨 ENABLE DEBUG LOGS (No more empty logs)

# --- RENDER TOOLS ---
_CURL="$(command -v curl)"
_JQ="$(command -v jq)"
_YTDLP="$(command -v yt-dlp)"

_HOST="https://animepahe.si"
_ANIME_URL="$_HOST/anime"
_API_URL="$_HOST/api"
_REFERER_URL="https://kwik.cx/"

_SCRIPT_PATH=$(dirname "$(realpath "$0")")
_DOWNLOAD_DIR="$_SCRIPT_PATH/downloads"
_ANIME_LIST_FILE="$_SCRIPT_PATH/anime.list"
_SOURCE_FILE=".source.json"

mkdir -p "$_DOWNLOAD_DIR"

# Fake Chrome User-Agent
_USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# --- ARGUMENT PARSING ---
set_args() {
    _PARALLEL_JOBS=1
    while getopts ":hlda:s:e:r:t:o:" opt; do
        case $opt in
            a) _INPUT_ANIME_NAME="$OPTARG" ;;
            s) _ANIME_SLUG="$OPTARG" ;;
            e) _ANIME_EPISODE="$OPTARG" ;;
            r) _ANIME_RESOLUTION="$OPTARG" ;;
            o) _ANIME_AUDIO="$OPTARG" ;;
            d) set -x ;;
            h) usage ;;
            \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
        esac
    done
}

get() { 
    "$_CURL" -sS -L "$1" \
    -H "User-Agent: $_USER_AGENT" \
    -H "Referer: $_HOST" \
    -H "cookie: $_COOKIE" \
    --compressed
}

set_cookie() {
    local u; u="$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)"
    _COOKIE="__ddg2_=$u"
}

download_anime_list() {
    get "$_ANIME_URL" | grep "/anime/" | sed -E 's/.*anime\//[/;s/" title="/] /;s/\">.*/   /;s/" title/]/' > "$_ANIME_LIST_FILE"
}

search_anime_by_name() {
    local d n
    d="$(get "$_HOST/api?m=search&q=${1// /%20}")"
    n="$("$_JQ" -r '.total' <<< "$d")"
    if [[ "$n" -eq "0" ]]; then
        echo ""
    else
        "$_JQ" -r '.data[] | "[\(.session)] \(.title)   "' <<< "$d" | tee -a "$_ANIME_LIST_FILE" | remove_slug
    fi
}

get_episode_list() { get "${_API_URL}?m=release&id=${1}&sort=episode_asc&page=${2}"; }

download_source() {
    local d p n
    mkdir -p "$_DOWNLOAD_DIR/$_ANIME_NAME"
    d="$(get_episode_list "$_ANIME_SLUG" "1")"
    p="$("$_JQ" -r '.last_page' <<< "$d")"
    if [[ "$p" -gt "1" ]]; then
        for i in $(seq 2 "$p"); do
            n="$(get_episode_list "$_ANIME_SLUG" "$i")"
            d="$(echo "$d $n" | "$_JQ" -s '.[0].data + .[1].data | {data: .}')"
        done
    fi
    echo "$d" > "$_DOWNLOAD_DIR/$_ANIME_NAME/$_SOURCE_FILE"
}

# --- RESTORED LOGIC FOR RESOLUTION SELECTION ---
get_episode_link() {
    local s o l r=""
    s=$("$_JQ" -r '.data[] | select((.episode | tonumber) == ($num | tonumber)) | .session' --arg num "$1" < "$_DOWNLOAD_DIR/$_ANIME_NAME/$_SOURCE_FILE")
    
    if [[ "$s" == "" ]]; then 
        echo "ERROR_NOT_FOUND"
        return
    fi
    
    # Get Player Page
    o="$("$_CURL" --compressed -sSL -H "User-Agent: $_USER_AGENT" -H "Referer: $_HOST" -H "cookie: $_COOKIE" "${_HOST}/play/${_ANIME_SLUG}/${s}")"
    
    # Extract Kwik Links
    l="$(grep \<button <<< "$o" | grep data-src | sed -E 's/data-src="/\n/g' | grep 'data-av1="0"')"

    # Filter by Audio (Dub/Sub) if requested
    if [[ -n "${_ANIME_AUDIO:-}" ]]; then
        echo "[INFO] Filtering for Audio: $_ANIME_AUDIO" >&2
        r="$(grep 'data-audio="'"$_ANIME_AUDIO"'"' <<< "$l")"
        if [[ -z "${r:-}" ]]; then
            echo "[WARN] $_ANIME_AUDIO not found, falling back." >&2
        else
            l="$r"
        fi
    fi

    # Filter by Resolution (360, 720, 1080)
    if [[ -n "${_ANIME_RESOLUTION:-}" ]]; then
        echo "[INFO] Filtering for Resolution: $_ANIME_RESOLUTION" >&2
        r="$(grep 'data-resolution="'"$_ANIME_RESOLUTION"'"' <<< "$l")"
        
        if [[ -z "${r:-}" ]]; then
             echo "[WARN] Resolution $_ANIME_RESOLUTION not found. Using best available." >&2
        else
             l="$r"
        fi
    fi

    # Extract the final URL (Kwik Link)
    final_link=$(grep kwik <<< "$l" | tail -1 | grep kwik | awk -F '"' '{print $1}')
    echo "$final_link"
}

# --- YT-DLP DOWNLOADER ---
download_episode() {
    local num="$1"
    v="$_DOWNLOAD_DIR/${_ANIME_NAME}/${num}.mp4"

    echo "[INFO] Fetching Link for Episode $num..." >&2
    l=$(get_episode_link "$num")

    if [[ "$l" == "ERROR_NOT_FOUND" ]]; then
        echo "[ERROR] Episode $num not found in list." >&2
        return
    fi

    if [[ -z "$l" ]]; then
        echo "[ERROR] Could not extract Kwik Link." >&2
        return
    fi

    echo "[INFO] Found Kwik Link: $l" >&2
    echo "[INFO] Starting yt-dlp..." >&2

    # Run YT-DLP (Capture output so we don't have empty logs)
    "$_YTDLP" "$l" \
        -o "$v" \
        --referer "https://kwik.cx/" \
        --user-agent "$_USER_AGENT" \
        --no-playlist \
        --retries 3

    if [[ -f "$v" ]]; then
        echo "✅ Download Success: $v" >&2
    else
        echo "❌ Download Failed." >&2
        exit 1
    fi
}

remove_brackets() { awk -F']' '{print $1}' | sed -E 's/^\[//'; }
remove_slug() { awk -F'] ' '{print $2}'; }
get_slug_from_name() { grep "] $1" "$_ANIME_LIST_FILE" | tail -1 | remove_brackets; }

main() {
    set_args "$@"
    set_cookie

    if [[ -n "${_INPUT_ANIME_NAME:-}" ]]; then
        search_res=$(search_anime_by_name "$_INPUT_ANIME_NAME")
        if [[ -z "$search_res" ]]; then
            echo "[ERROR] Anime not found!" >&2
            exit 1
        fi
        _ANIME_NAME=$(head -n 1 <<< "$search_res")
        _ANIME_SLUG="$(get_slug_from_name "$_ANIME_NAME")"
    else
        download_anime_list
        if [[ -z "${_ANIME_SLUG:-}" ]]; then
            _ANIME_NAME=$(head -n 1 <<< "$(remove_slug < "$_ANIME_LIST_FILE")")
            _ANIME_SLUG="$(get_slug_from_name "$_ANIME_NAME")"
        fi
    fi

    [[ "$_ANIME_SLUG" == "" ]] && echo "[ERROR] Anime slug not found!" >&2 && exit 1
    _ANIME_NAME="$(grep "$_ANIME_SLUG" "$_ANIME_LIST_FILE" | tail -1 | remove_slug | sed -E 's/[[:space:]]+$//' | sed -E 's/[^[:alnum:] ,\+\-\)\(]/_/g')"

    if [[ "$_ANIME_NAME" == "" ]]; then
        echo "[ERROR] Anime name parsing failed!" >&2
        exit 1
    fi

    download_source
    
    if [[ -z "${_ANIME_EPISODE:-}" ]]; then
        echo "[ERROR] You must specify episode with -e" >&2
        exit 1
    fi
    
    # Split commas for multiple episodes
    if [[ "$_ANIME_EPISODE" == *","* ]]; then
        IFS=',' read -ra EPS <<< "$_ANIME_EPISODE"
        for ep in "${EPS[@]}"; do
            download_episode "$ep"
        done
    else
        download_episode "$_ANIME_EPISODE"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
