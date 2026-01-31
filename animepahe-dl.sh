#!/usr/bin/env bash
set -e
set -u

# --- RENDER COMPATIBLE SETUP ---
_CURL="$(command -v curl)"
_JQ="$(command -v jq)"
_YTDLP="$(command -v yt-dlp)"  # We use this now!

_HOST="https://animepahe.si"
_ANIME_URL="$_HOST/anime"
_API_URL="$_HOST/api"
_REFERER_URL="https://kwik.cx/"

_SCRIPT_PATH=$(dirname "$(realpath "$0")")
_DOWNLOAD_DIR="$_SCRIPT_PATH/downloads"
_ANIME_LIST_FILE="$_SCRIPT_PATH/anime.list"
_SOURCE_FILE=".source.json"

mkdir -p "$_DOWNLOAD_DIR"

# Fake User-Agent to pass initial checks
_USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# --- FUNCTIONS ---

set_args() {
    _PARALLEL_JOBS=1
    while getopts ":hlda:s:e:r:t:o:" opt; do
        case $opt in
            a) _INPUT_ANIME_NAME="$OPTARG" ;;
            s) _ANIME_SLUG="$OPTARG" ;;
            e) _ANIME_EPISODE="$OPTARG" ;;
            l) _LIST_LINK_ONLY=true ;;
            r) _ANIME_RESOLUTION="$OPTARG" ;;
            t) _PARALLEL_JOBS="$OPTARG" ;;
            o) _ANIME_AUDIO="$OPTARG" ;;
            d) set -x ;;
            h) usage ;;
            \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
        esac
    done
}

print_info() { echo "[INFO] $1" >&2; }
print_warn() { echo "[WARNING] $1" >&2; }
print_error() { echo "[ERROR] $1" >&2; exit 1; }

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

get_episode_link() {
    local s o l r=""
    s=$("$_JQ" -r '.data[] | select((.episode | tonumber) == ($num | tonumber)) | .session' --arg num "$1" < "$_DOWNLOAD_DIR/$_ANIME_NAME/$_SOURCE_FILE")
    [[ "$s" == "" ]] && print_warn "Episode $1 not found!" && return
    
    # Get the player page
    o="$("$_CURL" --compressed -sSL -H "User-Agent: $_USER_AGENT" -H "Referer: $_HOST" -H "cookie: $_COOKIE" "${_HOST}/play/${_ANIME_SLUG}/${s}")"
    
    # Extract Kwik Link
    l="$(grep \<button <<< "$o" | grep data-src | sed -E 's/data-src="/\n/g' | grep 'data-av1="0"')"

    if [[ -n "${_ANIME_RESOLUTION:-}" ]]; then
        print_info "Select video resolution: $_ANIME_RESOLUTION"
        r="$(grep 'data-resolution="'"$_ANIME_RESOLUTION"'"' <<< "${r:-$l}")"
        [[ -z "${r:-}" ]] && print_warn "Resolution $_ANIME_RESOLUTION not found, using best available."
    fi

    if [[ -z "${r:-}" ]]; then
        grep kwik <<< "$l" | tail -1 | grep kwik | awk -F '"' '{print $1}'
    else
        awk -F '" ' '{print $1}' <<< "$r" | tail -1
    fi
}

# --- THE FIX: USE YT-DLP DIRECTLY ---
download_episode() {
    local num="$1"
    v="$_DOWNLOAD_DIR/${_ANIME_NAME}/${num}.mp4"

    print_info "Fetching Link for Episode $num..."
    l=$(get_episode_link "$num")

    if [[ "$l" != *"/"* ]]; then
        print_error "Failed to find download link."
    fi

    print_info "Found Link: $l"
    print_info "⬇️ Downloading via yt-dlp..."

    # Use yt-dlp to handle the complex Kwik decryption
    "$_YTDLP" "$l" \
        -o "$v" \
        --referer "https://kwik.cx/" \
        --user-agent "$_USER_AGENT" \
        --no-playlist \
        --retries 3 \
        --fragment-retries 3
        
    if [[ -f "$v" ]]; then
        print_info "✅ Download Complete: $v"
    else
        print_error "❌ Download Failed."
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
            print_error "Anime not found!"
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

    [[ "$_ANIME_SLUG" == "" ]] && print_error "Anime slug not found!"
    _ANIME_NAME="$(grep "$_ANIME_SLUG" "$_ANIME_LIST_FILE" | tail -1 | remove_slug | sed -E 's/[[:space:]]+$//' | sed -E 's/[^[:alnum:] ,\+\-\)\(]/_/g')"

    if [[ "$_ANIME_NAME" == "" ]]; then
        print_error "Anime name not found!"
    fi

    download_source
    
    if [[ -z "${_ANIME_EPISODE:-}" ]]; then
        print_error "You must specify episode with -e"
    fi
    
    # Support multiple episodes (comma separated)
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
