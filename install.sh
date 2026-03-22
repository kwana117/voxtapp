#!/usr/bin/env bash
set -euo pipefail

echo "=== Instalação: Whisper.cpp Dictation (macOS Apple Silicon) ==="

# 1. Dependências via Homebrew
echo "[1/6] A instalar dependências (sox, hammerspoon)..."
brew install sox
brew install --cask hammerspoon

# 2. Hammerspoon config + sons
echo "[2/6] A instalar config do Hammerspoon e sons..."
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.hammerspoon/sounds"
cp "$REPO_DIR/hammerspoon-init.lua" "$HOME/.hammerspoon/init.lua"
cp "$REPO_DIR/sounds/"*.mp3 "$HOME/.hammerspoon/sounds/"
echo "✓ Config e sons copiados para ~/.hammerspoon/"

# 3. Clonar whisper.cpp
WHISPER_DIR="$HOME/whisper.cpp"
if [ -d "$WHISPER_DIR" ]; then
    echo "[3/6] whisper.cpp já existe em $WHISPER_DIR, a fazer pull..."
    cd "$WHISPER_DIR" && git pull
else
    echo "[3/6] A clonar whisper.cpp..."
    git clone https://github.com/ggerganov/whisper.cpp.git "$WHISPER_DIR"
fi

# 3. Compilar com aceleração Metal (CoreML + Accelerate)
echo "[4/6] A compilar whisper.cpp com Metal/Accelerate..."
cd "$WHISPER_DIR"
cmake -B build -DWHISPER_METAL=ON -DWHISPER_ACCELERATE=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(sysctl -n hw.ncpu)

# 4. Descarregar modelo large-v3
echo "[5/6] A descarregar modelo large-v3 (pode demorar ~3GB)..."
MODEL_DIR="$WHISPER_DIR/models"
MODEL_FILE="$MODEL_DIR/ggml-large-v3.bin"
if [ -f "$MODEL_FILE" ]; then
    echo "  Modelo já existe, a saltar download."
else
    bash "$WHISPER_DIR/models/download-ggml-model.sh" large-v3
fi

# 5. Verificar
echo "[6/6] A verificar instalação..."
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
    echo "✗ Modelo não encontrado"
    exit 1
fi

echo ""
echo "=== Instalação concluída! ==="
echo "Próximo passo: executar ~/scripts/dictate.sh para testar"
echo "Depois: abrir Hammerspoon e carregar a config"
