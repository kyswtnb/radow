# Radiko Downloader (radow)

A powerful shell script to download radio programs from Radiko.jp, supporting **Interactive Mode**, **Premium Login**, and **Time Free** downloads with **Area Free** capability (via Proxy).

## Features

-   **Interactive Mode**: Browse Areas, Stations, Dates (Past 1 Week), and Programs via a simple menu.
-   **Premium Support**: Log in with your Radiko Premium account to access Area Free content (live).
-   **Time Free Support**: Download past programs using `yt-dlp`.
-   **Area Selection**: Choose any prefecture (JP1-JP47) to browse local stations.
-   **Proxy Support**: Bypass Area Free restrictions for Time Free downloads using a VPN/Proxy.
-   **Performance**: Utilizes `aria2` for faster downloads where possible.

## Prerequisites

-   **macOS** (Recommended/Tested) or Linux
-   **bash**
-   **ffmpeg** (Required for Live streams)
-   **curl**, **jq**
-   **yt-dlp** (Required for Time Free downloads)
-   **aria2** (Optional, for faster downloads)

### Installation (macOS)
```bash
brew install ffmpeg yt-dlp aria2 jq
```

## Setup

1.  Clone this repository.
2.  Make the script executable:
    ```bash
    chmod +x download_radiko.sh
    ```
3.  (Optional) Create a `.env` file for your Premium credentials to avoid entering them every time:
    ```bash
    USER_MAIL="your@email.com"
    USER_PASS="your_password"
    ```

## Usage

### Interactive Mode (Recommended)
Run with the `-i` flag to start the interactive wizard.
```bash
./download_radiko.sh -i
```
1.  **Select Area**: Choose your current area or any other prefecture.
2.  **Select Station**: Choose a radio station.
3.  **Select Date**: Choose from Today or the past 6 days.
4.  **Select Program**: Choose a program.
    -   **[ON AIR]**: Live recording starts correctly.
    -   **[PAST]**: Time Free download starts using `yt-dlp`.

### Manual Mode
Download a live stream by specifying Station ID and Duration (minutes).
```bash
./download_radiko.sh -s TBS -d 60 -o tbs_live.aac
```

### Proxy Usage (Bypassing Area Restrictions)
If you encounter **HTTP Error 403** when downloading Time Free content from outside the station's area (even with Premium), use the `-x` option to specify a Proxy/VPN located in that area (e.g., Tokyo).

```bash
./download_radiko.sh -i -x "http://user:pass@host:port"
```

## Options

| Option | Description |
| :--- | :--- |
| `-i` | Enable Interactive Mode |
| `-s [ID]` | Station ID (e.g., TBS, LFR) |
| `-d [MIN]` | Duration in minutes (Live only) |
| `-o [FILE]` | Output filename |
| `-u [MAIL]` | Radiko Email (overrides .env) |
| `-p [PASS]` | Radiko Password (overrides .env) |
| `-x [URL]` | Proxy URL (e.g., http://1.2.3.4:8080) |

## Limitations

-   **Time Free Area Free**: Downloading Time Free programs from outside your detected area is strictly restricted by Radiko. `yt-dlp` cannot bypass this alone. You **MUST** use a Proxy/VPN (`-x`) or record Live.
-   **Download Speed**: Some streams force sequential download (`ffmpeg`) instead of parallel (`aria2`) due to MIME type restrictions.
