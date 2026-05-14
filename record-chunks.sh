#!/usr/bin/env bash
# Records audio and writes timed WAV segments to a chunk dir.
# Hammerspoon sends SIGTERM to stop; the trap finalises the last chunk cleanly.
#
# Pipeline:
#   ffmpeg(avfoundation, pinned to VOXT_INPUT_DEVICE) → tee → FIFO → ffmpeg(segment muxer)
#                                                              ↘ _raw.pcm (live tap)
#
# Pinning the input device by name (not relying on the macOS default) prevents
# silent-recording failures when another app changes the system default input
# to an aggregate device (e.g. our meeting assistant's "Meeting In" with no
# real audio source).

set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

CHUNK_DIR="${1:-/tmp/voxt-chunks}"
SEGMENT_TIME="${2:-18}"
# Explicit device pinning — overridable via env for users on external mics.
INPUT_DEVICE="${VOXT_INPUT_DEVICE:-MacBook Pro Microphone}"

# Fresh dir every run — no leftovers from previous sessions.
rm -rf "$CHUNK_DIR"
mkdir -p "$CHUNK_DIR"

FIFO="$CHUNK_DIR/_audio.fifo"
TEE_IN="$CHUNK_DIR/_tee_in.fifo"
RAW_COPY="$CHUNK_DIR/_raw.pcm"
mkfifo "$FIFO"
mkfifo "$TEE_IN"

# 1. Segmenter (consumer of FIFO): writes timed WAV chunks.
ffmpeg -hide_banner -loglevel error \
    -f s16le -ar 16000 -ac 1 -i "$FIFO" \
    -f segment -segment_time "$SEGMENT_TIME" -reset_timestamps 1 \
    -c:a pcm_s16le \
    "$CHUNK_DIR/chunk_%03d.wav" &
FFMPEG_SEG_PID=$!

# 2. Tee splits the raw PCM stream: $RAW_COPY for live mic-energy check,
# $FIFO for the segmenter.
tee "$RAW_COPY" < "$TEE_IN" > "$FIFO" &
TEE_PID=$!

# 3. Capture from the pinned input device. sox with coreaudio + explicit
# native rate (48k) starts in ~0.4s — much faster than ffmpeg avfoundation
# (~1s). Output 16 kHz mono s16le raw PCM to stdout.
sox -q -t coreaudio -r 48000 -c 1 "$INPUT_DEVICE" \
    -r 16000 -c 1 -b 16 -t raw - 2>/dev/null > "$TEE_IN" &
REC_PID=$!

cleanup() {
    # Kill capture → tee gets EOF → FIFO closes → segmenter flushes last chunk.
    if kill -0 "$REC_PID" 2>/dev/null; then
        kill -TERM "$REC_PID" 2>/dev/null || true
    fi
    wait "$TEE_PID" 2>/dev/null || true
    wait "$FFMPEG_SEG_PID" 2>/dev/null || true
    rm -f "$FIFO" "$TEE_IN" "$RAW_COPY"
}
trap cleanup EXIT INT TERM

wait "$REC_PID" 2>/dev/null || true
wait "$TEE_PID" 2>/dev/null || true
wait "$FFMPEG_SEG_PID" 2>/dev/null || true
rm -f "$FIFO" "$TEE_IN" "$RAW_COPY"
