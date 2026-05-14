#!/usr/bin/env bash
set -euo pipefail

# Garantir que Homebrew está no PATH (Hammerspoon usa PATH mínimo)
export PATH="/opt/homebrew/bin:$PATH"
# Garantir UTF-8 (Hammerspoon não herda locale do shell)
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# === Configuração ===
# Transcrição corre no Mac Mini M4 via SSH (alias "macmini" em ~/.ssh/config com
# ControlMaster). O MacBook deixou de ter whisper.cpp local.
REMOTE_HOST="macmini"
REMOTE_WHISPER="/opt/homebrew/bin/whisper-cli"
REMOTE_MODEL="/Users/zion/whisper.cpp/models/ggml-large-v3.bin"
REMOTE_VAD_MODEL="/Users/zion/whisper.cpp/models/ggml-silero-v5.1.2.bin"
REMOTE_TMP="/tmp"
AUDIO_FILE="/tmp/dictation.wav"
TRANSCRIPT_FILE="/tmp/dictation.txt"
THREADS=8  # Mac Mini M4 tem mais cores que o MacBook

# Anti-hallucination whisper flags:
#   --vad + Silero VAD model → skips silent regions (the #1 cause of hallucinated
#     "Obrigado por verem"/"Subscribe"/etc. on quiet chunks).
#   -sns (suppress non-speech tokens), -tp 0.0 (deterministic), -nf (no temp
#     fallback — reject low-confidence segments instead of guessing).
WHISPER_FLAGS=(
    -t "$THREADS"
    -l auto
    --no-timestamps
    -otxt
    --vad
    --vad-model "$REMOTE_VAD_MODEL"
    -vt 0.35
    -sns
    -tp 0.0
    -nf
)

# Post-filter: phrases that whisper-large-v3 emits on silence/music/noise even
# with VAD on. Stripped from final text. Anchored to whole-utterance matches.
strip_hallucinations() {
    # Reads stdin, writes filtered stdout. Each pattern is a Perl regex.
    perl -CSDA -pe '
        s/\bObrigad[oa]s? por (?:verem|assistirem|terem assistido)[^.!?\n]*[.!?]?//gi;
        s/\bLegendas?(?:\s+(?:e\s+)?revis[ãa]o)?\s+(?:feitas?\s+)?por[^.!?\n]*[.!?]?//gi;
        s/\bSubtitles?\s+(?:by|provided\s+by)[^.!?\n]*[.!?]?//gi;
        s/\bThanks?\s+for\s+watching[^.!?\n]*[.!?]?//gi;
        s/\bSubscribe(?:\s+to[^.!?\n]+)?[.!?]?//gi;
        s/\bAmara\.org[^.!?\n]*//gi;
        s/\s+/ /g;
        s/^\s+|\s+$//g;
    '
}

# === Funções ===
start_recording() {
    # Gravar 16kHz mono WAV (formato que whisper espera)
    # -d trim silence no início, -q quiet
    rec -r 16000 -c 1 -b 16 "$AUDIO_FILE" &
    REC_PID=$!
    echo "$REC_PID" > /tmp/dictation.pid
    echo "recording" > /tmp/dictation.state
}

stop_recording() {
    if [ -f /tmp/dictation.pid ]; then
        PID=$(cat /tmp/dictation.pid)
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID" 2>/dev/null
            wait "$PID" 2>/dev/null || true
        fi
        rm -f /tmp/dictation.pid
    fi
    echo "stopped" > /tmp/dictation.state
}

transcribe() {
    if [ ! -f "$AUDIO_FILE" ]; then
        echo "Erro: ficheiro de áudio não encontrado" >&2
        exit 1
    fi

    # Belt-and-suspenders against the "missing tail" bug:
    # Wait until the WAV file size has been stable for two consecutive 50ms
    # samples before transcribing. Hammerspoon already waits for `rec` to exit
    # via the hs.task callback, but if anything ever bypasses that, this guard
    # ensures we never read a half-flushed WAV (which causes whisper to silently
    # truncate long recordings because the WAV header lies about the length).
    prev_size=-1
    stable=0
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        curr_size=$(stat -f%z "$AUDIO_FILE" 2>/dev/null || echo 0)
        if [ "$curr_size" -eq "$prev_size" ] && [ "$curr_size" -gt 1024 ]; then
            stable=$((stable + 1))
            [ "$stable" -ge 2 ] && break
        else
            stable=0
        fi
        prev_size=$curr_size
        sleep 0.05
    done

    # Verificar duração mínima (evitar transcrições vazias)
    DURATION=$(sox "$AUDIO_FILE" -n stat 2>&1 | grep "Length" | awk '{print $3}' | cut -d. -f1)
    if [ "${DURATION:-0}" -lt 1 ]; then
        echo "Gravação muito curta, ignorada." >&2
        rm -f "$AUDIO_FILE"
        echo "idle" > /tmp/dictation.state
        exit 0
    fi

    echo "transcribing" > /tmp/dictation.state

    # Transcrever no Mac Mini via SSH. Pipe áudio por stdin, capturamos texto por stdout.
    REMOTE_BASENAME="voxt_dictation_$$"
    cat "$AUDIO_FILE" | ssh -o BatchMode=yes "$REMOTE_HOST" "
        set -e
        cat > $REMOTE_TMP/$REMOTE_BASENAME.wav
        $REMOTE_WHISPER -m $REMOTE_MODEL -f $REMOTE_TMP/$REMOTE_BASENAME.wav \
            ${WHISPER_FLAGS[*]} \
            -of $REMOTE_TMP/$REMOTE_BASENAME 2>/dev/null
        cat $REMOTE_TMP/$REMOTE_BASENAME.txt 2>/dev/null || true
        rm -f $REMOTE_TMP/$REMOTE_BASENAME.wav $REMOTE_TMP/$REMOTE_BASENAME.txt
    " > "$TRANSCRIPT_FILE" 2>/dev/null

    # Ler texto, limpar espaços extra, remover frases-fantasma do whisper.
    if [ -f "$TRANSCRIPT_FILE" ]; then
        TEXT=$(cat "$TRANSCRIPT_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '\n' ' ' | sed 's/  */ /g' | strip_hallucinations)

        if [ -n "$TEXT" ] && [ "$TEXT" != "[BLANK_AUDIO]" ]; then
            # Guardar resultado para Hammerspoon ler
            printf "%s" "$TEXT" > /tmp/dictation.result
            # Copiar para clipboard (paste é feito pelo Hammerspoon após focar janela original)
            printf "%s" "$TEXT" | pbcopy
            echo "done" > /tmp/dictation.state
        else
            echo "" > /tmp/dictation.result
            echo "idle" > /tmp/dictation.state
        fi
    else
        echo "Erro: ficheiro de transcrição não gerado" >&2
    fi

    # Limpar
    rm -f "$AUDIO_FILE" "$TRANSCRIPT_FILE"
    echo "idle" > /tmp/dictation.state
}

# === Main ===
case "${1:-}" in
    start)
        stop_recording 2>/dev/null || true
        start_recording
        ;;
    stop)
        stop_recording
        transcribe
        ;;
    cancel)
        stop_recording
        rm -f "$AUDIO_FILE"
        echo "idle" > /tmp/dictation.state
        echo "Gravação cancelada."
        ;;
    stop-transcribe-only)
        # Hammerspoon already killed rec, just transcribe
        transcribe
        ;;
    transcribe-chunk)
        # Used by chunked-mode pipeline. Transcribes a single chunk WAV file
        # to a chosen output basename, without touching /tmp/dictation.* state.
        # Args: $2 = input WAV path, $3 = output basename (no extension)
        INPUT_FILE="${2:?path to chunk WAV required}"
        OUT_BASE="${3:?output basename required}"
        if [ ! -f "$INPUT_FILE" ]; then
            echo "Erro: chunk não encontrado: $INPUT_FILE" >&2
            exit 1
        fi
        # Belt-and-suspenders: wait for the chunk file size to stabilise before
        # reading. Hammerspoon already coordinates this via process exit, but
        # this guard catches any edge case.
        prev_size=-1
        stable=0
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            curr_size=$(stat -f%z "$INPUT_FILE" 2>/dev/null || echo 0)
            if [ "$curr_size" -eq "$prev_size" ] && [ "$curr_size" -gt 1024 ]; then
                stable=$((stable + 1))
                [ "$stable" -ge 2 ] && break
            else
                stable=0
            fi
            prev_size=$curr_size
            sleep 0.05
        done
        # Peak-normalize quiet chunks to -3 dBFS before whisper. Without this,
        # a quiet mic (low input gain, AirPods at distance, etc.) produces
        # audio whisper-large-v3 silently drops as "no speech", and the user
        # sees "(no text detected)" with no clue why. The gain stage gives
        # whisper a fighting chance; the VAD downstream still filters
        # actual silence/noise so we don't amplify junk into hallucinations.
        SEND_FILE="$INPUT_FILE"
        MAX_AMP=$(/opt/homebrew/bin/sox "$INPUT_FILE" -n stat 2>&1 | awk '/Maximum amplitude/ {print $NF}')
        if awk "BEGIN {exit !(${MAX_AMP:-0} > 0.005 && ${MAX_AMP:-0} < 0.5)}"; then
            NORM_FILE="${INPUT_FILE%.wav}_norm.wav"
            /opt/homebrew/bin/sox "$INPUT_FILE" "$NORM_FILE" gain -n -3 2>/dev/null && SEND_FILE="$NORM_FILE"
        fi
        # Transcrição corre no Mac Mini. Pipe da chunk via stdin, recebe texto via stdout.
        REMOTE_BASENAME="voxt_$(basename "$OUT_BASE")_$$"
        cat "$SEND_FILE" | ssh -o BatchMode=yes "$REMOTE_HOST" "
            set -e
            cat > $REMOTE_TMP/$REMOTE_BASENAME.wav
            $REMOTE_WHISPER -m $REMOTE_MODEL -f $REMOTE_TMP/$REMOTE_BASENAME.wav \
                ${WHISPER_FLAGS[*]} \
                -of $REMOTE_TMP/$REMOTE_BASENAME 2>/dev/null
            cat $REMOTE_TMP/$REMOTE_BASENAME.txt 2>/dev/null || true
            rm -f $REMOTE_TMP/$REMOTE_BASENAME.wav $REMOTE_TMP/$REMOTE_BASENAME.txt
        " 2>/dev/null | strip_hallucinations > "$OUT_BASE.txt"
        [ -n "${NORM_FILE:-}" ] && [ -f "$NORM_FILE" ] && rm -f "$NORM_FILE"
        ;;
    *)
        echo "Uso: $0 {start|stop|cancel|stop-transcribe-only|transcribe-chunk <input> <out_base>}"
        exit 1
        ;;
esac
