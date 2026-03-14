# VoxTapp — Agent Setup Guide

This document is intended for AI agents performing automated installation and configuration of VoxTapp on a new macOS Apple Silicon machine. Follow each step exactly in order.

---

## Prerequisites check

Before starting, verify the environment:

```bash
# Must be Apple Silicon
uname -m        # must output: arm64

# macOS version
sw_vers -productVersion   # must be 13.0 (Ventura) or later

# Homebrew must be installed
brew --version  # if not found, install: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# git must be available
git --version

# cmake must be available (install if missing)
cmake --version || brew install cmake
```

If `uname -m` returns `x86_64`, **stop** — this app requires Apple Silicon (M1/M2/M3/M4).

---

## Step 1 — Clone the repository

```bash
git clone https://github.com/kwana117/voxtapp.git ~/voxtapp
cd ~/voxtapp
```

---

## Step 2 — Run the installer

```bash
chmod +x install.sh
./install.sh
```

Expected output (in order):
1. `[1/5]` — sox and Hammerspoon installed via Homebrew
2. `[2/5]` — whisper.cpp cloned to `~/whisper.cpp`
3. `[3/5]` — whisper.cpp compiled with Metal + Accelerate (takes 2–10 min)
4. `[4/5]` — `ggml-large-v3.bin` downloaded to `~/whisper.cpp/models/` (~3 GB)
5. `[5/5]` — Verification: both binary and model confirmed present

**Verify manually after install:**

```bash
# Binary must exist (one of these two paths)
ls ~/whisper.cpp/build/bin/whisper-cli 2>/dev/null || ls ~/whisper.cpp/build/bin/main

# Model must exist
ls ~/whisper.cpp/models/ggml-large-v3.bin

# sox must be available
rec --version
```

---

## Step 3 — Install Hammerspoon config

```bash
mkdir -p ~/.hammerspoon
cp ~/voxtapp/hammerspoon-init.lua ~/.hammerspoon/init.lua
```

Open Hammerspoon (it should now be in `/Applications/Hammerspoon.app`):

```bash
open -a Hammerspoon
```

Hammerspoon will appear in the menu bar. It will prompt to reload config — confirm reload.

> **Manual step required:** Hammerspoon needs Accessibility permission. Direct the user to:
> System Settings → Privacy & Security → Accessibility → toggle **Hammerspoon** ON
> Then reload Hammerspoon from its menu bar icon.

---

## Step 4 — Install the dictation script

```bash
mkdir -p ~/scripts
cp ~/voxtapp/dictate.sh ~/scripts/dictate.sh
chmod +x ~/scripts/dictate.sh
```

Verify:

```bash
~/scripts/dictate.sh 2>&1 | head -1
# Expected: "Uso: .../dictate.sh {start|stop|cancel|stop-transcribe-only}"
```

---

## Step 5 — Verify full pipeline (smoke test)

```bash
# Start a 2-second test recording
~/scripts/dictate.sh start
sleep 2
~/scripts/dictate.sh stop

# Check result
cat /tmp/dictation.result 2>/dev/null && echo "(result found)" || echo "(no result — recording may have been too short or silent)"
```

If whisper returns `[BLANK_AUDIO]`, that is expected for a silent test — the pipeline is working.

---

## Configuration defaults

These are the active defaults and where to change them:

| Setting | Default | File | Line |
|---|---|---|---|
| Transcription model | `ggml-large-v3.bin` | `dictate.sh` | `MODEL=` |
| Processing mode | Batch (offline, non-streaming) | `dictate.sh` | `--no-timestamps` flag |
| Language detection | Auto (PT/EN/any) | `dictate.sh` | `-l auto` |
| Threads | 4 | `dictate.sh` | `THREADS=4` |
| Auto-Enter after paste | Enabled | `hammerspoon-init.lua` | `AUTO_ENTER = true` |
| Global shortcut | ⌥⌘L | `hammerspoon-init.lua` | `keyCode == 37` |
| whisper.cpp location | `~/whisper.cpp` | `dictate.sh` | `WHISPER_DIR=` |

> **Batch mode** is the default and recommended mode. Whisper processes the full audio clip after recording stops, which gives the highest accuracy with the large-v3 model.

---

## File locations after setup

```
~/voxtapp/                        ← repo (source of truth)
├── install.sh
├── dictate.sh
├── hammerspoon-init.lua
├── README.md
└── AGENT_SETUP.md

~/scripts/
└── dictate.sh                    ← active copy used at runtime

~/.hammerspoon/
└── init.lua                      ← active Hammerspoon config (copy of hammerspoon-init.lua)

~/whisper.cpp/                    ← whisper.cpp source + build
├── build/bin/whisper-cli         ← compiled binary
└── models/
    └── ggml-large-v3.bin         ← ~3 GB model file
```

---

## Permissions required (must be granted by user)

These cannot be automated — the user must grant them manually:

1. **Accessibility** — required for global hotkey and simulated keystrokes
   - System Settings → Privacy & Security → Accessibility → Hammerspoon → ON
2. **Microphone** — required for audio recording
   - Will prompt automatically on first use; or manually via System Settings → Privacy & Security → Microphone → Hammerspoon → ON

After granting Accessibility, reload Hammerspoon: menu bar icon → Reload Config.

---

## Updating

To update VoxTapp to the latest version:

```bash
cd ~/voxtapp
git pull
cp hammerspoon-init.lua ~/.hammerspoon/init.lua
cp dictate.sh ~/scripts/dictate.sh
# Reload Hammerspoon from menu bar
```

To update whisper.cpp:

```bash
cd ~/whisper.cpp
git pull
cmake --build build -j$(sysctl -n hw.ncpu)
```

---

## Troubleshooting checklist

- [ ] `uname -m` returns `arm64`
- [ ] `~/whisper.cpp/build/bin/whisper-cli` or `main` exists
- [ ] `~/whisper.cpp/models/ggml-large-v3.bin` exists (~3 GB)
- [ ] `~/scripts/dictate.sh` exists and is executable
- [ ] `~/.hammerspoon/init.lua` exists
- [ ] Hammerspoon is running (visible in menu bar)
- [ ] Accessibility permission granted to Hammerspoon
- [ ] Microphone permission granted to Hammerspoon
- [ ] Hammerspoon config reloaded after permissions granted
