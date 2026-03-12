#!/usr/bin/env bash
set -euo pipefail

# === Configuração ===
WHISPER_DIR="$HOME/whisper.cpp"
MODEL="$WHISPER_DIR/models/ggml-large-v3.bin"
AUDIO_FILE="/tmp/dictation.wav"
TRANSCRIPT_FILE="/tmp/dictation.txt"

# Detectar binário (nome mudou entre versões)
if [ -f "$WHISPER_DIR/build/bin/whisper-cli" ]; then
    WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-cli"
elif [ -f "$WHISPER_DIR/build/bin/main" ]; then
    WHISPER_BIN="$WHISPER_DIR/build/bin/main"
else
    echo "Erro: binário whisper não encontrado" >&2
    exit 1
fi

# Threads para M1 (4 performance cores)
THREADS=4

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

    # Verificar duração mínima (evitar transcrições vazias)
    DURATION=$(sox "$AUDIO_FILE" -n stat 2>&1 | grep "Length" | awk '{print $3}' | cut -d. -f1)
    if [ "${DURATION:-0}" -lt 1 ]; then
        echo "Gravação muito curta, ignorada." >&2
        rm -f "$AUDIO_FILE"
        echo "idle" > /tmp/dictation.state
        exit 0
    fi

    echo "transcribing" > /tmp/dictation.state

    # Transcrever — language=auto detecta PT/EN automaticamente
    "$WHISPER_BIN" \
        -m "$MODEL" \
        -f "$AUDIO_FILE" \
        -t "$THREADS" \
        -l auto \
        --no-timestamps \
        -otxt \
        -of /tmp/dictation \
        2>/dev/null

    # Ler texto, limpar espaços extra
    if [ -f "$TRANSCRIPT_FILE" ]; then
        TEXT=$(cat "$TRANSCRIPT_FILE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '\n' ' ' | sed 's/  */ /g')

        if [ -n "$TEXT" ] && [ "$TEXT" != "[BLANK_AUDIO]" ]; then
            # Guardar resultado para Hammerspoon ler
            printf "%s" "$TEXT" > /tmp/dictation.result
            # Copiar para clipboard e colar
            printf "%s" "$TEXT" | pbcopy
            osascript -e 'tell application "System Events" to keystroke "v" using command down'
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
    *)
        echo "Uso: $0 {start|stop|cancel|stop-transcribe-only}"
        exit 1
        ;;
esac
