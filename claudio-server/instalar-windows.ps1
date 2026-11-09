# =====================================================================
#  Claudio - server propio en una PC con Windows (sin Docker)
#
#  Corre xiaozhi-esp32-server en modo Python y lo publica en internet con
#  Tailscale Funnel (direccion fija, gratis, sin dominio propio).
#
#  Uso (PowerShell, en la PC que hace de server):
#    powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/malditocreww/xiaozhi-esp32/claudio/claudio-server/instalar-windows.ps1 -OutFile $env:TEMP\claudio.ps1; & $env:TEMP\claudio.ps1"
#
#  Pide:
#    - Claude API key (console.anthropic.com > API Keys)  -> cerebro
#    - Groq API key   (console.groq.com/keys, gratis)      -> reconocimiento de voz
# =====================================================================
$ErrorActionPreference = "Stop"

$Dir        = "C:\claudio-server"
$EnvDir     = "$Dir\env"
$App        = "$Dir\xiaozhi-server"
$WsPort     = 8100   # puertos locales (evita choques con otros proyectos en 8000)
$HttpPort   = 8103
$Model      = "claude-haiku-5-5"
$Voz        = "es-AR-TomasNeural"   # o es-AR-ElenaNeural
$RepoZip    = "https://github.com/xinnan-tech/xiaozhi-esp32-server/archive/refs/heads/main.zip"

function Paso($t) { Write-Host "`n== $t ==" -ForegroundColor Cyan }

# ---------- 1. Claves ----------
Paso "Claves"
if (-not $env:ANTHROPIC_API_KEY) { $env:ANTHROPIC_API_KEY = Read-Host "Pega tu Claude API key (sk-ant-...)" }
if (-not $env:GROQ_API_KEY)      { $env:GROQ_API_KEY      = Read-Host "Pega tu Groq API key (gsk_...)" }
if (-not $env:ANTHROPIC_API_KEY -or -not $env:GROQ_API_KEY) { throw "Faltan claves" }

# ---------- 2. Tailscale ----------
Paso "Tailscale"
$ts = "C:\Program Files\Tailscale\tailscale.exe"
if (-not (Test-Path $ts)) {
    winget install --id Tailscale.Tailscale -e --accept-source-agreements --accept-package-agreements
    Write-Host "Inicia sesion en Tailscale (icono al lado del reloj) y volve a correr este script." -ForegroundColor Yellow
    exit 1
}
$status = & $ts status --json | ConvertFrom-Json
$TsHost = $status.Self.DNSName.TrimEnd('.')
if (-not $TsHost) { throw "Tailscale no tiene sesion iniciada en esta PC" }
Write-Host "Nombre Tailscale: $TsHost"

# ---------- 3. Miniconda ----------
Paso "Miniconda (Python 3.10 + opus + ffmpeg)"
$Conda = "$env:USERPROFILE\miniconda3\Scripts\conda.exe"
if (-not (Test-Path $Conda)) {
    winget install --id Anaconda.Miniconda3 -e --accept-source-agreements --accept-package-agreements
}
if (-not (Test-Path $Conda)) { throw "No encuentro conda en $Conda" }
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
if (-not (Test-Path "$EnvDir\python.exe")) {
    & $Conda create -p $EnvDir python=3.10 -y
}
& $Conda install -p $EnvDir -c conda-forge libopus ffmpeg -y

# ---------- 4. Codigo del server ----------
Paso "Bajando xiaozhi-esp32-server"
$zip = "$env:TEMP\xiaozhi-server.zip"
Invoke-WebRequest $RepoZip -OutFile $zip
$tmp = "$env:TEMP\xiaozhi-server-src"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Expand-Archive $zip $tmp
$src = Get-ChildItem $tmp | Select-Object -First 1
$dataBackup = $null
if (Test-Path "$App\data") { $dataBackup = "$env:TEMP\claudio-data"; Copy-Item "$App\data" $dataBackup -Recurse -Force }
if (Test-Path $App) { Remove-Item $App -Recurse -Force }
Copy-Item "$($src.FullName)\main\xiaozhi-server" $App -Recurse
New-Item -ItemType Directory -Force -Path "$App\data" | Out-Null

Paso "Instalando dependencias de Python (tarda, baja ~2 GB)"
$env:PATH = "$EnvDir;$EnvDir\Library\bin;$EnvDir\Scripts;$env:PATH"
& "$EnvDir\python.exe" -m pip install --upgrade pip
& "$EnvDir\python.exe" -m pip install -r "$App\requirements.txt"

# ---------- 5. Configuracion ----------
Paso "Configuracion de Claudio"
$cfg = @"
server:
  ip: 0.0.0.0
  port: $WsPort
  http_port: $HttpPort
  websocket: wss://${TsHost}:8443/xiaozhi/v1/
  vision_explain: https://$TsHost/mcp/vision/explain
  timezone_offset: -3
  auth:
    enabled: false

log:
  log_level: INFO

close_connection_no_voice_time: 120
enable_greeting: true
enable_wakeup_words_response_cache: false

# Vacia a proposito: el texto que manda el equipo al despertarse
# ("Hola Claudio" del sensor) llega tal cual a Claude.
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
    functions: []

ASR:
  ClaudioASR:
    type: openai
    api_key: $($env:GROQ_API_KEY)
    base_url: https://api.groq.com/openai/v1/audio/transcriptions
    model_name: whisper-large-v3-turbo
    output_dir: tmp/

LLM:
  ClaudioLLM:
    type: openai
    base_url: https://api.anthropic.com/v1/
    model_name: $Model
    api_key: $($env:ANTHROPIC_API_KEY)
    max_tokens: 400
    thinking: keep

TTS:
  ClaudioTTS:
    type: edge
    voice: $Voz
    language: "Español"
    output_dir: tmp/
"@
[IO.File]::WriteAllText("$App\data\.config.yaml", $cfg, (New-Object Text.UTF8Encoding($false)))

# ---------- 6. Script de arranque + inicio automatico ----------
Paso "Arranque automatico"
$bat = @"
@echo off
title Claudio server
set PATH=$EnvDir;$EnvDir\Library\bin;$EnvDir\Scripts;%PATH%
set PYTHONIOENCODING=utf-8
cd /d $App
:loop
"$EnvDir\python.exe" app.py >> "$Dir\server.log" 2>&1
echo El server se detuvo, reinicio en 5 segundos... >> "$Dir\server.log"
timeout /t 5 /nobreak >nul
goto loop
"@
[IO.File]::WriteAllText("$Dir\iniciar.bat", $bat, (New-Object Text.ASCIIEncoding))

$action  = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$Dir\iniciar.bat`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0
Register-ScheduledTask -TaskName "Claudio server" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

Get-Process python -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$EnvDir*" } | Stop-Process -Force
Start-ScheduledTask -TaskName "Claudio server"

# ---------- 7. Publicar con Tailscale Funnel ----------
Paso "Publicando en internet con Tailscale Funnel"
& $ts funnel --bg --https=443  "http://127.0.0.1:$HttpPort"
& $ts funnel --bg --https=8443 "http://127.0.0.1:$WsPort"
& $ts funnel status

Write-Host ""
Write-Host "=====================================================================" -ForegroundColor Green
Write-Host " Listo. En la placa (pestana Advanced), carga esta direccion OTA:"
Write-Host ""
Write-Host "     https://$TsHost/xiaozhi/ota/" -ForegroundColor Yellow
Write-Host ""
Write-Host " Proba en el navegador que responda esa misma direccion."
Write-Host " Registros del server: $Dir\server.log"
Write-Host "=====================================================================" -ForegroundColor Green
