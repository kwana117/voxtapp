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
| **sox** | Audio recording (`rec` command) | `brew install sox` |
| **whisper.cpp** | Local speech-to-text (offline) | Compiled from source by `install.sh` |
| **ggml-large-v3** model | High-accuracy transcription (~3 GB) | Downloaded by `install.sh` |
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
1. Install `sox` and `Hammerspoon` via Homebrew
2. Clone `whisper.cpp` into `~/whisper.cpp`
3. Compile it with Metal + Accelerate acceleration
4. Download the `ggml-large-v3.bin` model (~3 GB, first run only)
5. Verify the binary and model are in place

> The first run takes 5–15 minutes depending on your connection and machine.

### 3. Set up Hammerspoon config

```bash
cp hammerspoon-init.lua ~/.hammerspoon/init.lua
```

Open Hammerspoon (it appears in your menu bar). It will ask to reload — click **Reload**.

### 4. Set up the dictation script

```bash
mkdir -p ~/scripts
cp dictate.sh ~/scripts/dictate.sh
chmod +x ~/scripts/dictate.sh
```

### 5. Grant permissions

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
Hammerspoon stores focused window → starts sox (rec)
     │
     ▼
sox records 16kHz mono WAV → /tmp/dictation.wav
     │
     ▼
⌥⌘L pressed again (or Enter)
     │
     ▼
whisper.cpp transcribes with large-v3 + Metal GPU (batch mode)
     │
     ▼
Result → clipboard → Hammerspoon focuses original window → ⌘V paste
```

State is managed via `/tmp/dictation.*` files (`.wav`, `.txt`, `.result`, `.state`, `.pid`).

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

Edit `~/scripts/dictate.sh`, line ~21:

```bash
THREADS=4   -- increase for M2/M3/M4 Pro/Max chips
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Nothing happens on shortcut | Check Hammerspoon has Accessibility permission |
| "whisper binary not found" | Re-run `install.sh`; check `~/whisper.cpp/build/bin/` |
| Microphone not recording | Check Microphone permission for Hammerspoon in System Settings |
| Very slow transcription | Ensure Metal is enabled; check `~/whisper.cpp/build/bin/whisper-cli --help` |
| Text pasted to wrong window | Click your target window before pressing ⌥⌘L |

## License

MIT — Copyright 2026 João Gonçalo Dias
