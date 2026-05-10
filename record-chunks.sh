#!/usr/bin/env bash
# Records audio and writes timed WAV segments to a chunk dir.
# Hammerspoon sends SIGTERM to stop; the trap finalises the last chunk cleanly.
#
# Pipeline: rec → FIFO → ffmpeg segment muxer
# Using raw PCM through the FIFO avoids the streaming-WAV header issue that
# caused the original "missing tail" bug.

set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

CHUNK_DIR="${1:-/tmp/voxt-chunks}"
SEGMENT_TIME="${2:-18}"

# Fresh dir every run — no leftovers from previous sessions.
rm -rf "$CHUNK_DIR"
mkdir -p "$CHUNK_DIR"

FIFO="$CHUNK_DIR/_audio.fifo"
mkfifo "$FIFO"

# Start ffmpeg first (consumer), then rec (producer).
# - segment_time: target chunk length in seconds
# - reset_timestamps: each segment starts at 0 (whisper-friendly)
# - pcm_s16le: same format as input — zero-cost passthrough
ffmpeg -hide_banner -loglevel error \
    -f s16le -ar 16000 -ac 1 -i "$FIFO" \
    -f segment -segment_time "$SEGMENT_TIME" -reset_timestamps 1 \
    -c:a pcm_s16le \
    "$CHUNK_DIR/chunk_%03d.wav" &
FFMPEG_PID=$!

rec -q -r 16000 -c 1 -b 16 -t raw - 2>/dev/null > "$FIFO" &
REC_PID=$!

cleanup() {
    # Kill rec → FIFO closes → ffmpeg gets EOF and finalises the last segment.
    if kill -0 "$REC_PID" 2>/dev/null; then
        kill -TERM "$REC_PID" 2>/dev/null || true
    fi
    # Wait for ffmpeg to flush the last segment before exiting.
    wait "$FFMPEG_PID" 2>/dev/null || true
    rm -f "$FIFO"
}
trap cleanup EXIT INT TERM

# Wait for rec; if Hammerspoon kills us, the trap handles the rest.
wait "$REC_PID" 2>/dev/null || true
wait "$FFMPEG_PID" 2>/dev/null || true
rm -f "$FIFO"
