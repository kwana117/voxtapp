# VoxTapp

Global push-to-talk voice dictation for macOS using [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with Metal acceleration.

Press a shortcut, speak, press again — your speech is transcribed and pasted wherever your cursor is. Works in any app.

![macOS](https://img.shields.io/badge/macOS-Apple%20Silicon-black)
![whisper.cpp](https://img.shields.io/badge/whisper.cpp-large--v3-blue)

## Features

- **Global shortcut** (⌥⌘L) — works in any app (terminal, browser, editor, etc.)
- **Status bar** — visual recording/transcribing indicator at the top of the screen
- **Auto language detection** — speaks Portuguese, English, or any mix
- **Metal acceleration** — fast inference on Apple Silicon
- **Auto-paste** — transcribed text is pasted where your cursor is

## Requirements

- macOS on Apple Silicon (M1/M2/M3/M4)
- [Homebrew](https://brew.sh)

## Install

```bash
git clone https://github.com/kwana117/voxtapp.git
cd voxtapp
chmod +x install.sh
./install.sh
```

This will:
1. Install `sox` and `Hammerspoon` via Homebrew
2. Clone and compile `whisper.cpp` with Metal support
3. Download the `large-v3` model (~3GB)

### Setup Hammerspoon

Copy the Hammerspoon config:

```bash
cp hammerspoon-init.lua ~/.hammerspoon/init.lua
```

Then open Hammerspoon and grant the required permissions:
- **Accessibility** — System Settings → Privacy & Security → Accessibility → enable Hammerspoon
- **Microphone** — will prompt on first recording

### Setup dictation script

```bash
mkdir -p ~/scripts
cp dictate.sh ~/scripts/dictate.sh
chmod +x ~/scripts/dictate.sh
```

## Usage

| Shortcut | Action |
|---|---|
| **⌥⌘L** | Toggle: start recording / stop & transcribe |

1. Press **⌥⌘L** — a dark bar appears at the top showing "Recording..."
2. Speak (any language — auto-detected)
3. Press **⌥⌘L** again — bar changes to "Transcribing..."
4. Text is pasted where your cursor is, bar shows the result in green

## How it works

1. **Hammerspoon** listens for the global shortcut and manages the UI
2. **sox** (`rec`) records audio from the microphone at 16kHz mono
3. **whisper.cpp** transcribes the audio using the large-v3 model with Metal
4. The transcribed text is copied to clipboard and pasted via simulated ⌘V

## Customization

Edit `hammerspoon-init.lua` to change the shortcut. The key detection uses `hs.eventtap` for reliability across all apps. Look for `keyCode == 37` (L key) and modify the flags/keyCode as needed.

## License

MIT
