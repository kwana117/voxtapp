#!/usr/bin/env bash
set -euo pipefail

# Garantir que Homebrew está no PATH (Hammerspoon usa PATH mínimo)
export PATH="/opt/homebrew/bin:$PATH"
# Garantir UTF-8 (Hammerspoon não herda locale do shell)
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# === Configuração ===
# Por omissão a transcrição corre localmente nesta máquina, usando o
# whisper.cpp que o install.sh compila em ~/whisper.cpp. Para transcrever
# num Mac remoto mais rápido (ex.: um Mac Mini na mesma rede via SSH),
# criar ~/.voxtapp.env com pelo menos VOXT_REMOTE_HOST definido:
#
#   VOXT_REMOTE_HOST="macmini"
#   VOXT_REMOTE_WHISPER="/opt/homebrew/bin/whisper-cli"
#   VOXT_REMOTE_MODEL="/Users/outro-user/whisper.cpp/models/ggml-large-v3.bin"
#   VOXT_REMOTE_VAD_MODEL="/Users/outro-user/whisper.cpp/models/ggml-silero-v5.1.2.bin"
#   VOXT_REMOTE_TMP="/tmp"
#   VOXT_REMOTE_THREADS=8
#
# Requer SSH sem password (ControlMaster/chave) para o host. Sem esse
# ficheiro, ou sem VOXT_REMOTE_HOST definido, corre sempre local.
VOXT_REMOTE_HOST=""
VOXT_REMOTE_WHISPER="/opt/homebrew/bin/whisper-cli"
VOXT_REMOTE_MODEL="$HOME/whisper.cpp/models/ggml-large-v3.bin"
VOXT_REMOTE_VAD_MODEL="$HOME/whisper.cpp/models/ggml-silero-v5.1.2.bin"
VOXT_REMOTE_TMP="/tmp"
VOXT_REMOTE_THREADS=8
[ -f "$HOME/.voxtapp.env" ] && source "$HOME/.voxtapp.env"

WHISPER_DIR="$HOME/whisper.cpp"
LOCAL_MODEL="$WHISPER_DIR/models/ggml-large-v3.bin"
LOCAL_VAD_MODEL="$WHISPER_DIR/models/ggml-silero-v5.1.2.bin"
if [ -f "$WHISPER_DIR/build/bin/whisper-cli" ]; then
    LOCAL_WHISPER="$WHISPER_DIR/build/bin/whisper-cli"
elif [ -f "$WHISPER_DIR/build/bin/main" ]; then
    LOCAL_WHISPER="$WHISPER_DIR/build/bin/main"
else
    LOCAL_WHISPER=""
fi
LOCAL_THREADS="${VOXT_LOCAL_THREADS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

AUDIO_FILE="/tmp/dictation.wav"
TRANSCRIPT_FILE="/tmp/dictation.txt"

require_local_whisper() {
    if [ -z "$LOCAL_WHISPER" ]; then
        echo "Erro: whisper-cli não encontrado em $WHISPER_DIR/build/bin. Corre ./install.sh." >&2
        exit 1
    fi
}

# Anti-hallucination whisper flags:
#   --vad + Silero VAD model → skips silent regions (the #1 cause of hallucinated
#     "Obrigado por verem"/"Subscribe"/etc. on quiet chunks).
#   -sns (suppress non-speech tokens), -tp 0.0 (deterministic), -nf (no temp
#     fallback — reject low-confidence segments instead of guessing).
# Preenche o array global WHISPER_FLAGS para o modelo VAD e nº de threads dados.
build_flags() {
    local vad_model="$1" threads="$2"
    WHISPER_FLAGS=(
        -t "$threads"
        -l auto
        --no-timestamps
        -otxt
        --vad
        --vad-model "$vad_model"
        -vt 0.35
        -sns
        -tp 0.0
        -nf
        # -mc 0: do NOT carry decoder context across VAD segments. Without this,
        # short recordings split by VAD produce repeat hallucinations
        # ("Alô 1 2 3 4 5 6. Alô 1 2 3 4 5 6.") because the decoder re-emits the
        # previous segment's tokens when it sees similar acoustic features.
        -mc 0
    )
}

# Post-filter: strips whisper-large-v3 ghost phrases and collapses consecutive
# duplicate sentences. Whisper emits same-sentence repeats on short or
# ambiguous audio regardless of beam/temperature/VAD flags — needs a textual
# dedupe pass to be reliable.
strip_hallucinations() {
    perl -CSDA -e '
        local $/; my $t = <STDIN>;
        # 1. Strip well-known ghost phrases.
        $t =~ s/\bObrigad[oa]s? por (?:verem|assistirem|terem assistido)[^.!?\n]*[.!?]?//gi;
        $t =~ s/\bLegendas?(?:\s+(?:e\s+)?revis[ãa]o)?\s+(?:feitas?\s+)?por[^.!?\n]*[.!?]?//gi;
        $t =~ s/\bSubtitles?\s+(?:by|provided\s+by)[^.!?\n]*[.!?]?//gi;
        $t =~ s/\bThanks?\s+for\s+watching[^.!?\n]*[.!?]?//gi;
        $t =~ s/\bSubscribe(?:\s+to[^.!?\n]+)?[.!?]?//gi;
        $t =~ s/\bAmara\.org[^.!?\n]*//gi;
        # 2. Collapse consecutive identical sentences ("Alô 1 2 3. Alô 1 2 3.").
        # Split on sentence terminators while keeping them; dedupe via a
        # case- and whitespace-insensitive normalized form.
        my @parts = split /(?<=[.!?])\s+/, $t;
        my @out;
        my $prev = "";
        for my $s (@parts) {
            (my $norm = lc $s) =~ s/\s+/ /g;
            $norm =~ s/^\s+|\s+$//g;
            $norm =~ s/[.!?,;:]+$//;
            next if $norm eq "";
            if ($norm ne $prev) { push @out, $s; $prev = $norm; }
        }
        $t = join(" ", @out);
        # 3. Remove word-level consecutive repeat loops (Whisper looping within a chunk).
        # Finds sequences of ≥5 words that appear twice in a row and removes the second copy.
        # Repeats until no more consecutive duplicates exist (handles chained loops).
        my @words = split /\s+/, $t;
        my $changed = 1;
        while ($changed) {
            $changed = 0;
            my $n = scalar @words;
            OUTER: for my $len (reverse 5 .. int($n / 2)) {
                for my $i (0 .. $n - 2 * $len) {
                    my $match = 1;
                    for my $j (0 .. $len - 1) {
                        my $a = lc($words[$i + $j]         // ""); $a =~ s/\W//g;
                        my $b = lc($words[$i + $len + $j]  // ""); $b =~ s/\W//g;
                        unless ($a eq $b) { $match = 0; last }
                    }
                    if ($match) {
                        splice(@words, $i + $len, $len);
                        $changed = 1;
                        last OUTER;
                    }
                }
            }
        }
        $t = join(" ", @words);
        # 4. Final whitespace cleanup.
        $t =~ s/\s+/ /g;
        $t =~ s/^\s+|\s+$//g;
        print $t;
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

    if [ -n "$VOXT_REMOTE_HOST" ]; then
        # Transcrever num Mac remoto via SSH. Pipe áudio por stdin, capturamos texto por stdout.
        build_flags "$VOXT_REMOTE_VAD_MODEL" "$VOXT_REMOTE_THREADS"
        REMOTE_BASENAME="voxt_dictation_$$"
        cat "$AUDIO_FILE" | ssh -o BatchMode=yes "$VOXT_REMOTE_HOST" "
            set -e
            cat > $VOXT_REMOTE_TMP/$REMOTE_BASENAME.wav
            $VOXT_REMOTE_WHISPER -m $VOXT_REMOTE_MODEL -f $VOXT_REMOTE_TMP/$REMOTE_BASENAME.wav \
                ${WHISPER_FLAGS[*]} \
                -of $VOXT_REMOTE_TMP/$REMOTE_BASENAME 2>/dev/null
            cat $VOXT_REMOTE_TMP/$REMOTE_BASENAME.txt 2>/dev/null || true
            rm -f $VOXT_REMOTE_TMP/$REMOTE_BASENAME.wav $VOXT_REMOTE_TMP/$REMOTE_BASENAME.txt
        " > "$TRANSCRIPT_FILE" 2>/dev/null
    else
        # Transcrever localmente.
        require_local_whisper
        build_flags "$LOCAL_VAD_MODEL" "$LOCAL_THREADS"
        "$LOCAL_WHISPER" -m "$LOCAL_MODEL" -f "$AUDIO_FILE" \
            "${WHISPER_FLAGS[@]}" \
            -of "${TRANSCRIPT_FILE%.txt}" 2>/dev/null || true
    fi

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
        #       $4 = optional prompt text (last N words of previous chunk)
        INPUT_FILE="${2:?path to chunk WAV required}"
        OUT_BASE="${3:?output basename required}"
        PROMPT_TEXT="${4:-}"
        # Base64-encode the prompt so it survives embedding in the SSH command
        # string without quoting issues (base64 output is alphanumeric + +/=).
        PROMPT_B64=""
        if [ -n "$PROMPT_TEXT" ]; then
            PROMPT_B64=$(printf '%s' "$PROMPT_TEXT" | base64 | tr -d '\n')
        fi
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
        if [ -n "$VOXT_REMOTE_HOST" ]; then
            # Transcrição corre no Mac remoto. Pipe da chunk via stdin, recebe texto via stdout.
            build_flags "$VOXT_REMOTE_VAD_MODEL" "$VOXT_REMOTE_THREADS"
            REMOTE_BASENAME="voxt_$(basename "$OUT_BASE")_$$"
            cat "$SEND_FILE" | ssh -o BatchMode=yes "$VOXT_REMOTE_HOST" "
                set -e
                cat > $VOXT_REMOTE_TMP/$REMOTE_BASENAME.wav
                PROMPT_DECODED=
                if [ -n '$PROMPT_B64' ]; then
                    PROMPT_DECODED=\$(printf '%s' '$PROMPT_B64' | base64 -D 2>/dev/null || printf '%s' '$PROMPT_B64' | base64 -d 2>/dev/null || true)
                fi
                $VOXT_REMOTE_WHISPER -m $VOXT_REMOTE_MODEL -f $VOXT_REMOTE_TMP/$REMOTE_BASENAME.wav \
                    ${WHISPER_FLAGS[*]} \
                    \${PROMPT_DECODED:+--prompt} \${PROMPT_DECODED:+\"\$PROMPT_DECODED\"} \
                    -of $VOXT_REMOTE_TMP/$REMOTE_BASENAME 2>/dev/null
                cat $VOXT_REMOTE_TMP/$REMOTE_BASENAME.txt 2>/dev/null || true
                rm -f $VOXT_REMOTE_TMP/$REMOTE_BASENAME.wav $VOXT_REMOTE_TMP/$REMOTE_BASENAME.txt
            " 2>/dev/null | strip_hallucinations > "$OUT_BASE.txt"
        else
            # Transcrição local.
            require_local_whisper
            build_flags "$LOCAL_VAD_MODEL" "$LOCAL_THREADS"
            PROMPT_DECODED=""
            if [ -n "$PROMPT_B64" ]; then
                PROMPT_DECODED=$(printf '%s' "$PROMPT_B64" | base64 -D 2>/dev/null || printf '%s' "$PROMPT_B64" | base64 -d 2>/dev/null || true)
            fi
            LOCAL_BASENAME="${OUT_BASE}_tmp$$"
            if [ -n "$PROMPT_DECODED" ]; then
                "$LOCAL_WHISPER" -m "$LOCAL_MODEL" -f "$SEND_FILE" \
                    "${WHISPER_FLAGS[@]}" --prompt "$PROMPT_DECODED" \
                    -of "$LOCAL_BASENAME" 2>/dev/null || true
            else
                "$LOCAL_WHISPER" -m "$LOCAL_MODEL" -f "$SEND_FILE" \
                    "${WHISPER_FLAGS[@]}" \
                    -of "$LOCAL_BASENAME" 2>/dev/null || true
            fi
            cat "$LOCAL_BASENAME.txt" 2>/dev/null | strip_hallucinations > "$OUT_BASE.txt"
            rm -f "$LOCAL_BASENAME.txt"
        fi
        [ -n "${NORM_FILE:-}" ] && [ -f "$NORM_FILE" ] && rm -f "$NORM_FILE"
        ;;
    *)
        echo "Uso: $0 {start|stop|cancel|stop-transcribe-only|transcribe-chunk <input> <out_base>}"
        exit 1
        ;;
esac
