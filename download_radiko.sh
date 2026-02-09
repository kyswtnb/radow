#!/bin/bash

# Load .env file if it exists
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

# Default values
STATION_ID=""
DURATION_MIN=""
OUTPUT_FILE=""
# USER_MAIL and USER_PASS should be set in .env or passed as arguments
INTERACTIVE=0
PROXY_URL=""
COOKIE_FILE="radiko_cookie.txt"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.212 Safari/537.36"

# Parse arguments
while getopts "s:d:o:u:p:ihx:" opt; do
  case $opt in
    s) STATION_ID=$OPTARG ;;
    d) DURATION_MIN=$OPTARG ;;
    o) OUTPUT_FILE=$OPTARG ;;
    u) USER_MAIL=$OPTARG ;;
    p) USER_PASS=$OPTARG ;;
    i) INTERACTIVE=1 ;;
    x) PROXY_URL=$OPTARG ;;
    h) 
      echo "Usage: $0 [-s STATION_ID] [-d DURATION_MIN] [-o OUTPUT_FILE] [-u MAIL] [-p PASS] [-i] [-h]"
      exit 0
      ;;
    \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
  esac
done

# Dependencies Check
for cmd in ffmpeg curl jq; do
  if ! command -v $cmd &> /dev/null; then
    echo "Error: $cmd is not installed."
    exit 1
  fi
done

# Functions

login() {
  if [ -n "$USER_MAIL" ] && [ -n "$USER_PASS" ]; then
    echo "--- Logging in as $USER_MAIL ---"
    CURL_ARGS=(-s -L -c "$COOKIE_FILE" -b "$COOKIE_FILE" -A "$UA" -d "mail=$USER_MAIL" -d "pass=$USER_PASS")
    if [ -n "$PROXY_URL" ]; then
      CURL_ARGS+=(-x "$PROXY_URL")
    fi
    LOGIN_RES=$(curl "${CURL_ARGS[@]}" https://radiko.jp/ap/member/login/login)
    
    # Check if login successful (usually check for specific cookie or response)
    # Radiko login returns JSON-like or just sets cookie.
    # Simple check: curl exit code is 0 (it is), so maybe check cookie file?
    if grep -q "radiko_session" "$COOKIE_FILE"; then
      echo "Login successful."
    else
      echo "Warning: Login might have failed. Cookie not found."
    fi
  fi
}

authenticate() {
  echo "--- Authentication 1 ---"
  
  # Auth 1
  CURL_ARGS=(-s -I -c "$COOKIE_FILE" -b "$COOKIE_FILE" -A "$UA" \
    -H "X-Radiko-App: pc_html5" \
    -H "X-Radiko-App-Version: 0.0.1" \
    -H "X-Radiko-User: dummy_user" \
    -H "X-Radiko-Device: pc")
  
  if [ -n "$PROXY_URL" ]; then
    CURL_ARGS+=(-x "$PROXY_URL")
  fi

  AUTH1_RESPONSE=$(curl "${CURL_ARGS[@]}" https://radiko.jp/v2/api/auth1)

  AUTH_TOKEN=$(echo "$AUTH1_RESPONSE" | grep -i "X-Radiko-AuthToken" | awk '{print $2}' | tr -d '\r')
  KEY_OFFSET=$(echo "$AUTH1_RESPONSE" | grep -i "X-Radiko-KeyOffset" | awk '{print $2}' | tr -d '\r')
  KEY_LENGTH=$(echo "$AUTH1_RESPONSE" | grep -i "X-Radiko-KeyLength" | awk '{print $2}' | tr -d '\r')

  if [ -z "$AUTH_TOKEN" ]; then
    echo "Error: Failed to get AuthToken"
    rm -f "$COOKIE_FILE"
    exit 1
  fi

  echo "AuthToken: $AUTH_TOKEN"

  FULL_KEY="bcd151073c03b352e1ef2fd66c32209da9ca0afa"
  PARTIAL_KEY=$(printf "%s" "$FULL_KEY" | dd bs=1 skip=$KEY_OFFSET count=$KEY_LENGTH 2>/dev/null | base64)

  echo "--- Authentication 2 ---"
  CURL_ARGS=(-s -i -c "$COOKIE_FILE" -b "$COOKIE_FILE" -A "$UA" \
    -H "X-Radiko-AuthToken: $AUTH_TOKEN" \
    -H "X-Radiko-PartialKey: $PARTIAL_KEY" \
    -H "X-Radiko-User: dummy_user" \
    -H "X-Radiko-Device: pc")
  
  if [ -n "$PROXY_URL" ]; then
    CURL_ARGS+=(-x "$PROXY_URL")
  fi

  AUTH2_RESPONSE=$(curl "${CURL_ARGS[@]}" https://radiko.jp/v2/api/auth2)

  if ! echo "$AUTH2_RESPONSE" | grep -q "200 OK"; then
    echo "Error: Auth2 failed."
    rm -f "$COOKIE_FILE"
    exit 1
  fi

  # Extract AreaID from Auth2 body (e.g., JP13,Tokyo,...)
  # We look for a line starting with JP
  AREA_ID=$(echo "$AUTH2_RESPONSE" | grep -o "JP[0-9]\+" | head -n 1)
  echo "AreaID: $AREA_ID"
}

get_stream_url_live() {
  local station=$1
  echo "--- Getting Live Stream URL for $station ---" >&2
  CURL_ARGS=(-s -c "$COOKIE_FILE" -b "$COOKIE_FILE" -A "$UA")
  if [ -n "$PROXY_URL" ]; then
    CURL_ARGS+=(-x "$PROXY_URL")
  fi
  STREAM_XML=$(curl "${CURL_ARGS[@]}" "http://radiko.jp/v2/station/stream_smh_multi/${station}.xml")
  STREAM_URL=$(echo "$STREAM_XML" | grep -o '<playlist_create_url>[^<]*</playlist_create_url>' | head -n 1 | sed 's/<[^>]*>//g')
  STREAM_URL=$(echo "$STREAM_URL" | sed 's/&amp;/\&/g')
  echo "$STREAM_URL"
}

download_ffmpeg() {
  local url=$1
  local duration=$2
  local output=$3
  
  echo "--- Downloading ---"
  FFMPEG_ARGS=(-headers "X-Radiko-AuthToken: $AUTH_TOKEN" -user_agent "$UA" -i "$url" -t "$duration" -c copy)
  if [ -n "$PROXY_URL" ]; then
    FFMPEG_ARGS+=(-http_proxy "$PROXY_URL")
  fi
  ffmpeg "${FFMPEG_ARGS[@]}" "$output"
}


# Interactive Functions

get_stations_xml() {
  local area_id=$1
  # Get station list XML
  CURL_ARGS=(-s -c "$COOKIE_FILE" -b "$COOKIE_FILE" -A "$UA")
  if [ -n "$PROXY_URL" ]; then
    CURL_ARGS+=(-x "$PROXY_URL")
  fi
  curl "${CURL_ARGS[@]}" "http://radiko.jp/v3/station/list/${area_id}.xml"
}

select_area() {
  echo "--- Select Area ---"
  
  # List of Prefectures (JP1 - JP47)
  local areas=(
    "JP1:Hokkaido" "JP2:Aomori" "JP3:Iwate" "JP4:Miyagi" "JP5:Akita" 
    "JP6:Yamagata" "JP7:Fukushima" "JP8:Ibaraki" "JP9:Tochigi" "JP10:Gunma" 
    "JP11:Saitama" "JP12:Chiba" "JP13:Tokyo" "JP14:Kanagawa" "JP15:Niigata" 
    "JP16:Toyama" "JP17:Ishikawa" "JP18:Fukui" "JP19:Yamanashi" "JP20:Nagano" 
    "JP21:Gifu" "JP22:Shizuoka" "JP23:Aichi" "JP24:Mie" "JP25:Shiga" 
    "JP26:Kyoto" "JP27:Osaka" "JP28:Hyogo" "JP29:Nara" "JP30:Wakayama" 
    "JP31:Tottori" "JP32:Shimane" "JP33:Okayama" "JP34:Hiroshima" "JP35:Yamaguchi" 
    "JP36:Tokushima" "JP37:Kagawa" "JP38:Ehime" "JP39:Kochi" "JP40:Fukuoka" 
    "JP41:Saga" "JP42:Nagasaki" "JP43:Kumamoto" "JP44:Oita" "JP45:Miyazaki" 
    "JP46:Kagoshima" "JP47:Okinawa"
  )

  # Display current area default
  echo "Current Detected Area: $AREA_ID" >&2
  echo "0. Use Detected Area" >&2
  
  for i in "${!areas[@]}"; do
    local area_code="${areas[$i]%%:*}"
    local area_name="${areas[$i]##*:}"
    printf "%2d. %-10s (%s)\n" "$((i+1))" "$area_name" "$area_code" >&2
  done

  echo -n "Enter number (0-47): " >&2
  read selection
  
  if [ "$selection" -eq 0 ]; then
    echo "Using detected area: $AREA_ID"
    return
  fi
  
  if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt 47 ]; then
    echo "Invalid selection. Using detected area."
    return
  fi

  local selected_item="${areas[$((selection-1))]}"
  AREA_ID="${selected_item%%:*}"
  echo "Selected Area: $AREA_ID"
}

select_station() {
  local xml=$1
  echo "--- Select Station ---"
  
  # Extract Station IDs and Names
  # Using simple grep/sed for XML parsing to avoid xmlstarlet dependency if possible, but basic structure is:
  # <station>
  #   <id>TBS</id>
  #   <name>TBSラジオ</name>
  # ...
  # We can capture id and name blocks.
  
  # Temporary usage of arrays
  local ids=()
  local names=()
  
  # Robust-ish one-liner to get ID and Name. 
  # Assumes <id> comes before <name> within <station> block.
  # Let's filter lines only containing id or name.
  
  local i=0
  while read -r line; do
    if [[ $line =~ "<id>" ]]; then
      id=$(echo "$line" | sed 's/.*<id>\(.*\)<\/id>.*/\1/')
      ids+=("$id")
    elif [[ $line =~ "<name>" ]]; then
      name=$(echo "$line" | sed 's/.*<name>\(.*\)<\/name>.*/\1/')
      names+=("$name")
    fi
  done < <(echo "$xml" | grep -E "<id>|<name>")

  # Display
  local count=${#ids[@]}
  for ((j=0; j<count; j++)); do
    echo "$((j+1)). ${names[$j]} (${ids[$j]})"
  done

  echo -n "Enter number (1-$count): " >&2
  read selection

  if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$count" ]; then
    echo "Invalid selection."
    exit 1
  fi

  STATION_ID=${ids[$((selection-1))]}
  echo "Selected: $STATION_ID"
}

select_date() {
  echo "--- Select Date ---"
  
  # Generate last 7 days
  local dates=()
  local display_dates=()
  
  for i in {0..6}; do
    # BSD date (macOS)
    d=$(date -v-${i}d +%Y%m%d)
    disp=$(date -v-${i}d "+%Y/%m/%d (%a)")
    dates+=("$d")
    display_dates+=("$disp")
  done
  
  for i in "${!display_dates[@]}"; do
    echo "$((i+1)). ${display_dates[$i]}"
  done
  
  echo -n "Enter number (1-7): " >&2
  read selection
  
  if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt 7 ]; then
    echo "Invalid selection. Using Today."
    SELECTED_DATE=${dates[0]}
  else
    SELECTED_DATE=${dates[$((selection-1))]}
  fi
  echo "Selected Date: $SELECTED_DATE"
}

get_programs_xml() {
  local station_id=$1
  local date=$2
  
  if [ -z "$date" ]; then
    date=$(date +%Y%m%d)
  fi
  
  # Get schedule for specific date
  CURL_ARGS=(-s -c "$COOKIE_FILE" -b "$COOKIE_FILE" -A "$UA")
  if [ -n "$PROXY_URL" ]; then
    CURL_ARGS+=(-x "$PROXY_URL")
  fi
  curl "${CURL_ARGS[@]}" "http://radiko.jp/v3/program/station/date/${date}/${station_id}.xml"
}

select_program() {
  local xml=$1
  echo "--- Select Program ---"

  # <prog ft="20240208100000" to="20240208110000">
  #   <title>Program Title</title>
  # </prog>
  
  local fts=()
  local tos=()
  local titles=()
  
  # Parse XML line by line (simplified)
  # We look for <prog ... ft="..." to="..." ...>
  
  local in_prog=0
  local current_ft=""
  local current_to=""
  
  # We use a temporary file to handle reading loop cleanly with variables
  echo "$xml" > radiko_schedule_temp.xml
  
  while read -r line; do
    if [[ $line =~ "<prog" ]]; then
      # Extract ft and to using grep/cut which is order-independent
      current_ft=$(echo "$line" | grep -o 'ft="[^"]*"' | cut -d'"' -f2)
      current_to=$(echo "$line" | grep -o 'to="[^"]*"' | cut -d'"' -f2)
      if [ -n "$current_ft" ] && [ -n "$current_to" ]; then
        in_prog=1
      fi
    elif [[ $in_prog -eq 1 && $line =~ "<title>" ]]; then
      title=$(echo "$line" | sed 's/.*<title>\(.*\)<\/title>.*/\1/')
      # Decode entities
      title=$(echo "$title" | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g')
      
      fts+=("$current_ft")
      tos+=("$current_to")
      titles+=("$title")
      in_prog=0
    fi
  done < radiko_schedule_temp.xml
  rm radiko_schedule_temp.xml

  local count=${#fts[@]}
  # Sort or Display. They are likely sorted by time.
  
  local now=$(date +%Y%m%d%H%M%S)

  for ((j=0; j<count; j++)); do
    start_time=${fts[$j]}
    end_time=${tos[$j]}
    title=${titles[$j]}
    
    # Format time for display (YYYYMMDDHHMMSS -> HH:MM)
    start_fmt="${start_time:8:2}:${start_time:10:2}"
    end_fmt="${end_time:8:2}:${end_time:10:2}"
    
    status=""
    if [ "$now" -ge "$start_time" ] && [ "$now" -lt "$end_time" ]; then
      status="[ON AIR]"
    elif [ "$now" -gt "$end_time" ]; then
      status="[PAST]"
    else
      status="[FUTURE]"
    fi
    
    echo "$((j+1)). $start_fmt - $end_fmt : $title $status"
  done

  echo -n "Enter number (1-$count): " >&2
  read selection

  if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "$count" ]; then
    echo "Invalid selection."
    exit 1
  fi

  local idx=$((selection-1))
  SELECTED_FT=${fts[$idx]}
  SELECTED_TO=${tos[$idx]}
  SELECTED_TITLE=${titles[$idx]}
  
  echo "Selected: $SELECTED_TITLE ($SELECTED_FT - $SELECTED_TO)"
  
  # Determine action based on time
  if [ "$now" -ge "$SELECTED_FT" ] && [ "$now" -lt "$SELECTED_TO" ]; then
    # On Air: Live Rec
    # Calculate duration
    # Convert to seconds? Mac date command logic needed.
    # Simple duration: We know end time. We record until end time?
    # Or just default duration?
    # User asked for "download", usually meaning getting the file.
    # For Live, we record remaining time? Or just start recording?
    # Let's ask duration or default to remaining.
    
    # Let's revert to simple duration for now or calculate.
    # Using Mac date for calc:
    # date -j -f "%Y%m%d%H%M%S" "20240208100000" "+%s"
    
    current_sec=$(date +%s)
    end_sec=$(date -j -f "%Y%m%d%H%M%S" "$SELECTED_TO" "+%s")
    remaining_sec=$((end_sec - current_sec))
    
    if [ $remaining_sec -le 0 ]; then remaining_sec=60; fi # Safety
    
    echo "Program is ON AIR. Recording for remaining $remaining_sec seconds..."
    DURATION_SEC=$remaining_sec
    MODE="LIVE"
    
  elif [ "$now" -gt "$SELECTED_TO" ]; then
    # Past: Time Free
    echo "Program is PAST. Using Time Free."
    MODE="TIMEFREE"
  else
    echo "Program is FUTURE. Cannot download yet."
    exit 0
  fi
}

get_stream_url_timefree() {
  local station=$1
  local ft=$2
  local to=$3
  echo "--- Getting Time Free URL ---" >&2
  # Time Free is M3U8 directly usually
  # https://radiko.jp/v2/api/ts/playlist.m3u8?station_id=TBS&l=15&ft=20240208010000&to=20240208030000
  echo "https://radiko.jp/v2/api/ts/playlist.m3u8?station_id=${station}&l=15&ft=${ft}&to=${to}"
}

# Main Execution Flow

login
authenticate

if [ "$INTERACTIVE" -eq 1 ]; then
  # 0. Select Area
  select_area

  # 1. Select Station
  STATIONS_XML=$(get_stations_xml "$AREA_ID")
  
  # If STATIONS_XML is empty or error
  if [ -z "$STATIONS_XML" ]; then
    echo "Error: Failed to fetch station list."
    exit 1
  fi
  
  select_station "$STATIONS_XML"
  
  # 2. Select Date
  select_date
  
  # 3. Select Program
  PROGRAMS_XML=$(get_programs_xml "$STATION_ID" "$SELECTED_DATE")
  select_program "$PROGRAMS_XML"
  
  # 3. Set output file if not set
  if [ -z "$OUTPUT_FILE" ]; then
    # Sanitize title
    safe_title=$(echo "$SELECTED_TITLE" | tr ' /:;*?\\' '_')
    OUTPUT_FILE="${safe_title}_${SELECTED_FT}.aac"
  fi
  

  if [ "$MODE" == "TIMEFREE" ]; then
    if command -v yt-dlp &> /dev/null; then
      echo "--- Downloading Time Free with yt-dlp ---"
      # Construct Page URL
      PAGE_URL="https://radiko.jp/#!/ts/${STATION_ID}/${SELECTED_FT}"
      # Prepare yt-dlp arguments
      YTDLP_ARGS=(--no-cache-dir --cookies "$COOKIE_FILE")
      
      if [ -n "$PROXY_URL" ]; then
        YTDLP_ARGS+=(--proxy "$PROXY_URL")
      fi

      if command -v aria2c &> /dev/null; then
         echo "Using aria2c for faster download..."
         yt-dlp "${YTDLP_ARGS[@]}" --downloader aria2c -o "$OUTPUT_FILE" "$PAGE_URL"
      else
         yt-dlp "${YTDLP_ARGS[@]}" -N 5 -o "$OUTPUT_FILE" "$PAGE_URL"
      fi
    else
      echo "Error: yt-dlp is required for Time Free downloads."
      echo "Please install yt-dlp (e.g., brew install yt-dlp)."
      echo "For speed boost, also install aria2 (brew install aria2)."
      exit 1
    fi
  elif [ "$MODE" == "LIVE" ]; then
    STREAM_URL=$(get_stream_url_live "$STATION_ID")
    download_ffmpeg "$STREAM_URL" "$DURATION_SEC" "$OUTPUT_FILE"
  fi

else
  # Non-Interactive Mode
  if [ -z "$STATION_ID" ]; then
    echo "Usage: $0 -s STATION_ID [-d DURATION_MIN] [-o OUTPUT_FILE] ..."
    exit 1
  fi

  if [ -z "$DURATION_MIN" ]; then
    DURATION_MIN=1
  fi
  
  if [ -z "$OUTPUT_FILE" ]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    OUTPUT_FILE="${STATION_ID}_${TIMESTAMP}.aac"
  fi

  DURATION_SEC=$(($DURATION_MIN * 60))
  STREAM_URL=$(get_stream_url_live "$STATION_ID")
  
  if [ -z "$STREAM_URL" ]; then
    echo "Error: Stream URL not found."
    exit 1
  fi

  download_ffmpeg "$STREAM_URL" "$DURATION_SEC" "$OUTPUT_FILE"
fi

rm -f "$COOKIE_FILE"
echo "Done."
