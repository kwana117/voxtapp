#!/usr/bin/env bash
set -euo pipefail

echo "=== Instalação: Whisper.cpp Dictation (macOS Apple Silicon) ==="

# 1. Dependências via Homebrew
echo "[1/7] A instalar dependências (sox, ffmpeg, hammerspoon)..."
brew install sox ffmpeg
brew install --cask hammerspoon

# 2. Hammerspoon config + sons
echo "[2/7] A instalar config do Hammerspoon e sons..."
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.hammerspoon/sounds"
cp "$REPO_DIR/hammerspoon-init.lua" "$HOME/.hammerspoon/init.lua"
cp "$REPO_DIR/sounds/"*.mp3 "$HOME/.hammerspoon/sounds/"
echo "✓ Config e sons copiados para ~/.hammerspoon/"

# 3. Scripts de gravação/transcrição
echo "[3/7] A instalar scripts em ~/scripts/..."
mkdir -p "$HOME/scripts"
cp "$REPO_DIR/dictate.sh" "$HOME/scripts/dictate.sh"
cp "$REPO_DIR/record-chunks.sh" "$HOME/scripts/record-chunks.sh"
chmod +x "$HOME/scripts/dictate.sh" "$HOME/scripts/record-chunks.sh"
echo "✓ Scripts copiados para ~/scripts/"

# 4. Clonar whisper.cpp
WHISPER_DIR="$HOME/whisper.cpp"
if [ -d "$WHISPER_DIR" ]; then
    echo "[4/7] whisper.cpp já existe em $WHISPER_DIR, a fazer pull..."
    cd "$WHISPER_DIR" && git pull
else
    echo "[4/7] A clonar whisper.cpp..."
    git clone https://github.com/ggerganov/whisper.cpp.git "$WHISPER_DIR"
fi

# 5. Compilar com aceleração Metal (CoreML + Accelerate)
echo "[5/7] A compilar whisper.cpp com Metal/Accelerate..."
cd "$WHISPER_DIR"
cmake -B build -DWHISPER_METAL=ON -DWHISPER_ACCELERATE=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(sysctl -n hw.ncpu)

# 6. Descarregar modelos (transcrição large-v3 + VAD para anti-alucinação)
echo "[6/7] A descarregar modelos (large-v3 ~3GB + VAD)..."
MODEL_DIR="$WHISPER_DIR/models"
MODEL_FILE="$MODEL_DIR/ggml-large-v3.bin"
VAD_MODEL_FILE="$MODEL_DIR/ggml-silero-v5.1.2.bin"
if [ -f "$MODEL_FILE" ]; then
    echo "  Modelo large-v3 já existe, a saltar download."
else
    bash "$WHISPER_DIR/models/download-ggml-model.sh" large-v3
fi
if [ -f "$VAD_MODEL_FILE" ]; then
    echo "  Modelo VAD já existe, a saltar download."
else
    bash "$WHISPER_DIR/models/download-vad-model.sh" silero-v5.1.2
fi

# 7. Verificar
echo "[7/7] A verificar instalação..."
if [ -f "$WHISPER_DIR/build/bin/whisper-cli" ]; then
    echo "✓ whisper-cli compilado com sucesso"
elif [ -f "$WHISPER_DIR/build/bin/main" ]; then
    echo "✓ main compilado com sucesso (versão mais antiga)"
else
    echo "✗ Erro: binário não encontrado em build/bin/"
    exit 1
fi

if [ -f "$MODEL_FILE" ]; then
    echo "✓ Modelo large-v3 disponível"
else
    echo "✗ Modelo large-v3 não encontrado"
    exit 1
fi

if [ -f "$VAD_MODEL_FILE" ]; then
    echo "✓ Modelo VAD disponível"
else
    echo "✗ Modelo VAD não encontrado"
    exit 1
fi

echo ""
echo "=== Instalação concluída! ==="
echo "Próximo passo: abrir Hammerspoon (menu bar) → Reload Config"
echo "Depois: dar permissão de Accessibility ao Hammerspoon em System Settings → Privacy & Security, e testar ⌥⌘L"
