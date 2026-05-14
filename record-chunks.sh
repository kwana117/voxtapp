#!/usr/bin/env bash
# Records audio and writes timed WAV segments to a chunk dir.
# Hammerspoon sends SIGTERM to stop; the trap finalises the last chunk cleanly.
#
# Pipeline: rec → tee → FIFO → ffmpeg segment muxer
#                     ↘ _raw.pcm (live tap for mic-energy health check)
# Using raw PCM through the FIFO avoids the streaming-WAV header issue that
# caused the original "missing tail" bug. The _raw.pcm tap lets Hammerspoon
# detect a dead mic within seconds (e.g., wrong input device, muted hardware)
# without waiting for the first chunk to close.

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
TEE_IN="$CHUNK_DIR/_tee_in.fifo"
RAW_COPY="$CHUNK_DIR/_raw.pcm"
mkfifo "$FIFO"
mkfifo "$TEE_IN"

# Start ffmpeg first (consumer of FIFO), then tee (splitter), then rec (producer).
# - segment_time: target chunk length in seconds
# - reset_timestamps: each segment starts at 0 (whisper-friendly)
# - pcm_s16le: same format as input — zero-cost passthrough
ffmpeg -hide_banner -loglevel error \
    -f s16le -ar 16000 -ac 1 -i "$FIFO" \
    -f segment -segment_time "$SEGMENT_TIME" -reset_timestamps 1 \
    -c:a pcm_s16le \
    "$CHUNK_DIR/chunk_%03d.wav" &
FFMPEG_PID=$!

# tee splits raw PCM: $RAW_COPY for live mic-energy check, $FIFO for ffmpeg.
tee "$RAW_COPY" < "$TEE_IN" > "$FIFO" &
TEE_PID=$!

rec -q -r 16000 -c 1 -b 16 -t raw - 2>/dev/null > "$TEE_IN" &
REC_PID=$!

cleanup() {
    # Kill rec → tee gets EOF → FIFO closes → ffmpeg flushes last segment.
    if kill -0 "$REC_PID" 2>/dev/null; then
        kill -TERM "$REC_PID" 2>/dev/null || true
    fi
    wait "$TEE_PID" 2>/dev/null || true
    wait "$FFMPEG_PID" 2>/dev/null || true
    rm -f "$FIFO" "$TEE_IN" "$RAW_COPY"
}
trap cleanup EXIT INT TERM

# Wait for rec; if Hammerspoon kills us, the trap handles the rest.
wait "$REC_PID" 2>/dev/null || true
wait "$TEE_PID" 2>/dev/null || true
wait "$FFMPEG_PID" 2>/dev/null || true
rm -f "$FIFO" "$TEE_IN" "$RAW_COPY"
