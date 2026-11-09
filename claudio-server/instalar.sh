#!/usr/bin/env bash
# =====================================================================
#  Claudio - instalador del server propio (xiaozhi-esp32-server)
#  Para una VM Ubuntu 22.04/24.04 (ARM o x86), por ejemplo Oracle Cloud.
#
#  Uso (en la consola de la VM):
#    curl -fsSL https://raw.githubusercontent.com/malditocreww/xiaozhi-esp32/claudio/claudio-server/instalar.sh -o instalar.sh
#    bash instalar.sh
#
#  Pide dos claves:
#    - Claude API key (console.anthropic.com > API Keys)   -> el cerebro
#    - Groq API key   (console.groq.com/keys, gratis)       -> reconocimiento de voz
#  La voz (Edge TTS, es-AR) no necesita clave.
# =====================================================================
set -euo pipefail

DIR="$HOME/claudio-server"
IMAGE="ghcr.io/xinnan-tech/xiaozhi-esp32-server:server_latest"
MODEL_CLAUDE="${MODEL_CLAUDE:-claude-haiku-5-5}"
VOZ="${VOZ:-es-AR-TomasNeural}"   # o es-AR-ElenaNeural (voz femenina)

echo "== Claudio: instalando server en $DIR =="

# ---------- 1. Claves ----------
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  read -rsp "Pegá tu Claude API key (sk-ant-...): " ANTHROPIC_API_KEY; echo
fi
if [ -z "${GROQ_API_KEY:-}" ]; then
  read -rsp "Pegá tu Groq API key (gsk_...): " GROQ_API_KEY; echo
fi
[ -n "$ANTHROPIC_API_KEY" ] || { echo "Falta la Claude API key"; exit 1; }
[ -n "$GROQ_API_KEY" ] || { echo "Falta la Groq API key"; exit 1; }

# ---------- 2. Docker ----------
if ! command -v docker >/dev/null 2>&1; then
  echo "== Instalando Docker =="
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER" || true
fi
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then DOCKER="sudo docker"; fi

# ---------- 3. Firewall de la VM (Oracle trae iptables cerrado) ----------
echo "== Abriendo puertos 8000 y 8003 en la VM =="
for P in 8000 8003; do
  if ! sudo iptables -C INPUT -p tcp --dport "$P" -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT 6 -p tcp -m state --state NEW --dport "$P" -j ACCEPT 2>/dev/null \
      || sudo iptables -I INPUT -p tcp --dport "$P" -j ACCEPT
  fi
done
if command -v netfilter-persistent >/dev/null 2>&1; then
  sudo netfilter-persistent save >/dev/null 2>&1 || true
else
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 || true
  sudo netfilter-persistent save >/dev/null 2>&1 || true
fi

# ---------- 4. IP publica ----------
IP="$(curl -fsS https://api.ipify.org || curl -fsS https://ifconfig.me)"
echo "== IP publica: $IP =="

# ---------- 5. Archivos ----------
mkdir -p "$DIR/data"
cd "$DIR"

cat > docker-compose.yml <<EOF
services:
  xiaozhi-esp32-server:
    image: $IMAGE
    container_name: xiaozhi-esp32-server
    restart: always
    security_opt:
      - seccomp:unconfined
    environment:
      - TZ=America/Argentina/Buenos_Aires
    ports:
      - "8000:8000"
      - "8003:8003"
    volumes:
      - ./data:/opt/xiaozhi-esp32-server/data
EOF

cat > data/.config.yaml <<EOF
server:
  ip: 0.0.0.0
  port: 8000
  http_port: 8003
  websocket: ws://$IP:8000/xiaozhi/v1/
  vision_explain: http://$IP:8003/mcp/vision/explain
  timezone_offset: -3
  auth:
    enabled: false

log:
  log_level: INFO

# Charla: corta la conexion tras 2 min sin voz (ahorra API)
close_connection_no_voice_time: 120
enable_greeting: true
enable_wakeup_words_response_cache: false

# Lista vacia a proposito: asi el texto que manda el equipo al despertarse
# ("Hola Claudio" del sensor, "Hi ESP" por voz) llega tal cual a Claude
# en vez de reemplazarse por un saludo fijo en chino del server.
wakeup_words:
  - "__ninguna__"

exit_commands:
  - "chau claudio"
  - "hasta luego claudio"

prompt: |
  Sos Claudio, un compañero de charla para personas mayores en Argentina.
  Hablás en español rioplatense, tuteando con "vos", con calidez y mucha paciencia.
  Respondé siempre corto: 1 a 3 oraciones, frases simples, sin palabras técnicas.
  Si no entendiste algo, pedí con amabilidad que te lo repitan.
  Mostrá interés por la persona: preguntale cómo está, qué hizo hoy, cómo durmió.
  Cuando la charla empieza con "Hola Claudio" sin nada más, es porque el sensor
  detectó que la persona acaba de llegar cerca tuyo: saludala con cariño según la
  hora del día y preguntale cómo está. Si empieza con "Hi ESP", te llamaron por voz:
  respondé "Acá estoy, decime".
  Tenés un sensor de presencia (herramienta self.presence.get_status): usalo cuando
  te pregunten si hay alguien, o cuánto hace que no se mueve nadie.
  Si te habla de dolor fuerte, una caída, falta de aire o una emergencia, decile con
  calma que llame ya a un familiar o al 107, y no des diagnósticos.
  Nunca inventes datos de salud ni de medicación.

end_prompt:
  enable: true
  prompt: |
    Despedite de forma breve y cariñosa, en español rioplatense.

system_error_response: "Perdoname, ahora no te pude escuchar bien. ¿Probamos de nuevo en un ratito?"

selected_module:
  VAD: SileroVAD
  ASR: ClaudioASR
  LLM: ClaudioLLM
  VLLM: ChatGLMVLLM
  TTS: ClaudioTTS
  Memory: nomem
  Intent: function_call

Intent:
  function_call:
    type: function_call
    # Sin plugins extra del server (los por defecto son chinos: noticias, clima de Cantón).
    # La salida (handle_exit_intent) y las herramientas del equipo (sensor) se cargan solas.
    functions: []

ASR:
  ClaudioASR:
    type: openai
    api_key: $GROQ_API_KEY
    base_url: https://api.groq.com/openai/v1/audio/transcriptions
    model_name: whisper-large-v3-turbo
    output_dir: tmp/

LLM:
  ClaudioLLM:
    type: openai
    base_url: https://api.anthropic.com/v1/
    model_name: $MODEL_CLAUDE
    api_key: $ANTHROPIC_API_KEY
    max_tokens: 400
    thinking: keep

TTS:
  ClaudioTTS:
    type: edge
    voice: $VOZ
    language: "Español"
    output_dir: tmp/
EOF
chmod 600 data/.config.yaml

# ---------- 6. Arranque ----------
echo "== Bajando y arrancando el server (tarda unos minutos la primera vez) =="
$DOCKER compose pull
$DOCKER compose up -d

echo
echo "====================================================================="
echo " Listo. En la placa, cargá esta direccion OTA:"
echo
echo "     http://$IP:8003/xiaozhi/ota/"
echo
echo " Probá en el navegador de tu PC que responda:  http://$IP:8003/xiaozhi/ota/"
echo " Ver registros:   $DOCKER logs -f xiaozhi-esp32-server"
echo "====================================================================="
