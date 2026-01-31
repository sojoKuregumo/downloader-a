#!/usr/bin/env bash
set -e
set -u

# --- RENDER COMPATIBLE SETUP ---
_CURL="$(command -v curl)"
_JQ="$(command -v jq)"
_NODE="$(command -v node)"
_FFMPEG="$(command -v ffmpeg)"

_HOST="https://animepahe.si"
_ANIME_URL="$_HOST/anime"
_API_URL="$_HOST/api"
_REFERER_URL="https://kwik.cx/"

_SCRIPT_PATH=$(dirname "$(realpath "$0")")
_DOWNLOAD_DIR="$_SCRIPT_PATH/downloads"
_ANIME_LIST_FILE="$_SCRIPT_PATH/anime.list"
_SOURCE_FILE=".source.json"

mkdir -p "$_DOWNLOAD_DIR"

# --- 1. USER AGENT SPOOFING (The Fix) ---
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

print_info() { [[ -z "${_LIST_LINK_ONLY:-}" ]] && echo "[INFO] $1" >&2; }
print_warn() { [[ -z "${_LIST_LINK_ONLY:-}" ]] && echo "[WARNING] $1" >&2; }
print_error() { echo "[ERROR] $1" >&2; exit 1; }

# UPDATED GET FUNCTION (Passes Headers)
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
    
    # Fetch player page
    o="$("$_CURL" --compressed -sSL -H "User-Agent: $_USER_AGENT" -H "Referer: $_HOST" -H "cookie: $_COOKIE" "${_HOST}/play/${_ANIME_SLUG}/${s}")"
    l="$(grep \<button <<< "$o" | grep data-src | sed -E 's/data-src="/\n/g' | grep 'data-av1="0"')"

    if [[ -n "${_ANIME_RESOLUTION:-}" ]]; then
        print_info "Select video resolution: $_ANIME_RESOLUTION"
        r="$(grep 'data-resolution="'"$_ANIME_RESOLUTION"'"' <<< "${r:-$l}")"
        [[ -z "${r:-}" ]] && print_warn "Selected video resolution is not available, fallback to default"
    fi

    if [[ -z "${r:-}" ]]; then
        grep kwik <<< "$l" | tail -1 | grep kwik | awk -F '"' '{print $1}'
    else
        awk -F '" ' '{print $1}' <<< "$r" | tail -1
    fi
}

get_playlist_link() {
    local s l
    # 🚨 UPDATED EXTRACTION LOGIC 🚨
    # 1. Fetch Kwik Page pretending to be Chrome
    s="$("$_CURL" --compressed -sS \
        -H "User-Agent: $_USER_AGENT" \
        -H "Referer: $_REFERER_URL" \
        -H "cookie: $_COOKIE" "$1")"
    
    # 2. Extract Javascript (More flexible grep)
    # Extracts everything inside <script>...eval(...)...</script>
    js_code=$(echo "$s" | grep -o "<script>.*eval(.*).*</script>" | sed -E 's/<script>//;s/<\/script>//')

    # 3. Clean JS for Node execution
    # Replace document/window calls with console.log so Node outputs the decoded URL
    clean_js=$(echo "$js_code" | \
        sed -E 's/document/process/g' | \
        sed -E 's/querySelector/exit/g' | \
        sed -E 's/eval\(/console.log\(/g')

    if [[ -z "$clean_js" ]]; then
        echo ""
        return
    fi

    # 4. Run in Node to decrypt
    l="$("$_NODE" -e "$clean_js" | grep 'source=' | sed -E "s/.m3u8';.*/.m3u8/" | sed -E "s/.*const source='//")"
    echo "$l"
}

download_episodes() {
    local origel el uniqel
    origel=()
    if [[ "$1" == *","* ]]; then
        IFS="," read -ra ADDR <<< "$1"
        for n in "${ADDR[@]}"; do origel+=("$n"); done
    else
        origel+=("$1")
    fi

    el=()
    for i in "${origel[@]}"; do
        if [[ "$i" == *"*"* ]]; then
            local eps fst lst
            eps="$("$_JQ" -r '.data[].episode' "$_DOWNLOAD_DIR/$_ANIME_NAME/$_SOURCE_FILE" | sort -nu)"
            fst="$(head -1 <<< "$eps")"
            lst="$(tail -1 <<< "$eps")"
            i="${fst}-${lst}"
        fi
        if [[ "$i" == *"-"* ]]; then
            s=$(awk -F '-' '{print $1}' <<< "$i")
            e=$(awk -F '-' '{print $2}' <<< "$i")
            for n in $(seq "$s" "$e"); do el+=("$n"); done
        else
            el+=("$i")
        fi
    done

    IFS=" " read -ra uniqel <<< "$(printf '%s\n' "${el[@]}" | sort -n -u | tr '\n' ' ')"
    [[ ${#uniqel[@]} == 0 ]] && print_error "Wrong episode number!"
    for e in "${uniqel[@]}"; do download_episode "$e"; done
}

get_thread_number() {
    local sn
    sn="$(grep -c "^https" "$1")"
    if [[ "$sn" -lt "$_PARALLEL_JOBS" ]]; then echo "$sn"; else echo "$_PARALLEL_JOBS"; fi
}

download_file() {
    local s
    # Added User-Agent to download command too
    s=$("$_CURL" -k -sS \
        -H "User-Agent: $_USER_AGENT" \
        -H "Referer: $_REFERER_URL" \
        -H "cookie: $_COOKIE" \
        -C - "$1" -L -g -o "$2" --connect-timeout 5 --compressed || echo "$?")
        
    if [[ "$s" -ne 0 ]]; then
        print_warn "Download was aborted. Retry..."
        download_file "$1" "$2"
    fi
}

decrypt_file() {
    local of=${1%%.encrypted}
    "$_OPENSSL" aes-128-cbc -d -K "$2" -iv 0 -in "${1}" -out "${of}" 2>/dev/null
}

download_segments() {
    local op="$2"
    export _CURL _REFERER_URL _USER_AGENT _COOKIE op
    export -f download_file print_warn
    xargs -I {} -P "$(get_thread_number "$1")" bash -c 'url="{}"; file="${url##*/}.encrypted"; download_file "$url" "${op}/${file}"' < <(grep "^https" "$1")
}

generate_filelist() {
    grep "^https" "$1" | sed -E "s/https.*\//file '/" | sed -E "s/$/'/" > "$2"
}

decrypt_segments() {
    local kf kl k
    kf="${2}/mon.key"
    kl=$(grep "#EXT-X-KEY:METHOD=" "$1" | awk -F '"' '{print $2}')
    download_file "$kl" "$kf"
    k="$(od -A n -t x1 "$kf" | tr -d ' \n')"
    export _OPENSSL k
    export -f decrypt_file
    xargs -I {} -P "$(get_thread_number "$1")" bash -c 'decrypt_file "{}" "$k"' < <(ls "${2}/"*.encrypted)
}

download_episode() {
    local num="$1" l pl v erropt='' extpicky=''
    v="$_DOWNLOAD_DIR/${_ANIME_NAME}/${num}.mp4"

    l=$(get_episode_link "$num")
    [[ "$l" != *"/"* ]] && print_warn "Wrong download link or episode $1 not found!" && return

    pl=$(get_playlist_link "$l")
    [[ -z "${pl:-}" ]] && print_warn "Missing video list! Skip downloading!" && return

    if [[ -z ${_LIST_LINK_ONLY:-} ]]; then
        print_info "Downloading Episode $1..."
        [[ -z "${_DEBUG_MODE:-}" ]] && erropt="-v error"
        if ffmpeg -h full 2>/dev/null| grep extension_picky >/dev/null; then extpicky="-extension_picky 0"; fi

        if [[ ${_PARALLEL_JOBS:-} -gt 1 ]]; then
            local opath plist cpath fname
            fname="file.list"
            cpath="$(pwd)"
            opath="$_DOWNLOAD_DIR/$_ANIME_NAME/${num}"
            plist="${opath}/playlist.m3u8"
            rm -rf "$opath"; mkdir -p "$opath"
            download_file "$pl" "$plist"
            print_info "Start parallel jobs with $(get_thread_number "$plist") threads"
            download_segments "$plist" "$opath"
            decrypt_segments "$plist" "$opath"
            generate_filelist "$plist" "${opath}/$fname"
            ! cd "$opath" && print_warn "Cannot change directory to $opath" && return
            "$_FFMPEG" -f concat -safe 0 -i "$fname" -c copy $erropt -y "$v"
            ! cd "$cpath" && print_warn "Cannot change directory to $cpath" && return
            [[ -z "${_DEBUG_MODE:-}" ]] && rm -rf "$opath" || return 0
        else
            "$_FFMPEG" $extpicky -headers "Referer: $_REFERER_URL" -headers "User-Agent: $_USER_AGENT" -i "$pl" -c copy $erropt -y "$v"
        fi
    else
        echo "$pl"
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
    
    download_episodes "$_ANIME_EPISODE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
