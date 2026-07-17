# VoxTapp

Global push-to-talk voice dictation for macOS using [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with Metal acceleration.

Press a shortcut, speak, press again — your speech is transcribed and pasted wherever your cursor is. Works in any app.

![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-black)
![whisper.cpp](https://img.shields.io/badge/whisper.cpp-large--v3-blue)
![Hammerspoon](https://img.shields.io/badge/Hammerspoon-required-orange)

## Features

- **Global shortcut** (⌥⌘L) — works in any app (terminal, browser, editor, etc.)
- **Floating pill UI** — status indicator at the top of the screen (Recording / Transcribing / Done)
- **Auto language detection** — speaks Portuguese, English, or any mix
- **Metal GPU acceleration** — fast local inference on Apple Silicon
- **Auto-paste** — transcribed text is pasted where your cursor was
- **Auto-Enter** — optionally sends Enter after paste (configurable)
- **Keyboard controls** — Escape to cancel, Enter to stop & submit

## Requirements

| Dependency | Purpose | Install |
|---|---|---|
| macOS + Apple Silicon (M1–M4) | Metal GPU acceleration | — |
| [Homebrew](https://brew.sh) | Package manager | See below |
| **Hammerspoon** | Global hotkey, UI, window management | `brew install --cask hammerspoon` |
| **sox** | Audio capture from the mic | `brew install sox` |
| **ffmpeg** | Chunked WAV segmenting during recording | `brew install ffmpeg` |
| **whisper.cpp** | Local speech-to-text (offline) | Compiled from source by `install.sh` |
| **ggml-large-v3** model | High-accuracy transcription (~3 GB) | Downloaded by `install.sh` |
| **Silero VAD** model | Skips silence to avoid hallucinated text | Downloaded by `install.sh` |
| **cmake**, **git** | Build tools for whisper.cpp | Usually pre-installed on macOS |

> whisper.cpp runs entirely offline — no data is sent to the cloud.

## Install

### 1. Clone the repo

```bash
git clone https://github.com/kwana117/voxtapp.git
cd voxtapp
```

### 2. Run the installer

```bash
chmod +x install.sh
./install.sh
```

This script will:
1. Install `sox`, `ffmpeg` and `Hammerspoon` via Homebrew
2. Copy `hammerspoon-init.lua` to `~/.hammerspoon/init.lua` and the sounds to `~/.hammerspoon/sounds/`
3. Copy `dictate.sh` and `record-chunks.sh` to `~/scripts/`
4. Clone `whisper.cpp` into `~/whisper.cpp` and compile it with Metal + Accelerate acceleration
5. Download the `ggml-large-v3.bin` model (~3 GB) and the Silero VAD model (first run only)
6. Verify everything is in place

> The first run takes 5–15 minutes depending on your connection and machine.

### 3. Reload Hammerspoon

Open Hammerspoon (it appears in your menu bar) and click **Reload Config**.

### 4. Grant permissions

Hammerspoon needs two system permissions:

- **Accessibility** — System Settings → Privacy & Security → Accessibility → enable **Hammerspoon**
- **Microphone** — will prompt automatically on first recording

After granting Accessibility, reload Hammerspoon from the menu bar icon.

## Usage

| Shortcut | Action |
|---|---|
| **⌥⌘L** | Start recording |
| **⌥⌘L** again (or **Enter**) | Stop recording and transcribe |
| **Escape** | Cancel recording without transcribing |
| Click **Stop ↵** badge | Stop and transcribe (mouse alternative) |

1. Place your cursor in any text field (any app)
2. Press **⌥⌘L** — a pill appears at the top: "Recording..." with a pulsing red dot
3. Speak (any language — auto-detected)
4. Press **⌥⌘L** or **Enter** — pill changes to "Transcribing..."
5. Text is pasted where your cursor was; pill shows the result in green

## How it works

```
⌥⌘L pressed
     │
     ▼
Hammerspoon stores focused window → record-chunks.sh starts
     │
     ▼
sox (mic) → ffmpeg segmenter → 16kHz mono WAV chunks in /tmp/voxt-chunks/
     │
     ▼
Each chunk is transcribed as it lands (whisper.cpp, large-v3 + Metal GPU,
Silero VAD to skip silence, previous chunk's tail used as --prompt for
continuity)
     │
     ▼
⌥⌘L pressed again (or Enter) → last chunk flushed and transcribed
     │
     ▼
Chunks' text deduplicated and joined → clipboard → Hammerspoon focuses
original window → ⌘V paste
```

Transcription runs locally by default (`~/whisper.cpp`, compiled by `install.sh`).
It can optionally run on a remote Mac over SSH instead — see
[Transcribing on a remote Mac](#transcribing-on-a-remote-mac-optional).

State is managed via `/tmp/dictation.*` files (`.txt`, `.result`, `.state`, `.pid`) and `/tmp/voxt-chunks/`.

## Customization

### Change the global shortcut

Edit `~/.hammerspoon/init.lua`, find the `hs.eventtap` listener near the bottom, and change the key/modifier combo.

### Disable auto-Enter after paste

Edit `~/.hammerspoon/init.lua`, line ~11:

```lua
AUTO_ENTER = false   -- change from true to false
```

Reload Hammerspoon after any change (menu bar icon → Reload Config).

### Adjust transcription threads

Local transcription defaults to your Mac's core count. To override, set an env var before Hammerspoon starts (e.g. in `~/.voxtapp.env`, see below):

```bash
VOXT_LOCAL_THREADS=4
```

### Transcribing on a remote Mac (optional)

If you have a second, faster Mac on your network reachable over passwordless SSH, `dictate.sh` can send audio there for transcription instead of running whisper.cpp on this machine. Create `~/.voxtapp.env`:

```bash
VOXT_REMOTE_HOST="my-other-mac"          # SSH host/alias, must not prompt for a password
VOXT_REMOTE_WHISPER="/opt/homebrew/bin/whisper-cli"
VOXT_REMOTE_MODEL="/Users/otheruser/whisper.cpp/models/ggml-large-v3.bin"
VOXT_REMOTE_VAD_MODEL="/Users/otheruser/whisper.cpp/models/ggml-silero-v5.1.2.bin"
VOXT_REMOTE_TMP="/tmp"
VOXT_REMOTE_THREADS=8
```

The remote Mac needs whisper.cpp compiled and both models present (run `install.sh` there too, or copy `~/whisper.cpp` over). Without this file, or without `VOXT_REMOTE_HOST` set, transcription always runs locally.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Nothing happens on shortcut | Check Hammerspoon has Accessibility permission |
| "whisper-cli não encontrado" | Re-run `install.sh`; check `~/whisper.cpp/build/bin/` |
| Microphone not recording | Check Microphone permission for Hammerspoon in System Settings |
| Very slow transcription | Ensure Metal is enabled; check `~/whisper.cpp/build/bin/whisper-cli --help` |
| Text pasted to wrong window | Click your target window before pressing ⌥⌘L |
| Recording fails to start | Check `ffmpeg` and `sox` are installed (`brew install ffmpeg sox`) |

## License

MIT — Copyright 2026 João Gonçalo Dias
