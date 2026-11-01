#include "mmwave_sensor.h"

#include <esp_log.h>
#include <esp_timer.h>

#include <cctype>
#include <cstdlib>
#include <ctime>

#include "application.h"

#define TAG "mmwave"

static constexpr uint8_t kHeader[4] = {0xF4, 0xF3, 0xF2, 0xF1};
static constexpr uint8_t kTail[4] = {0xF8, 0xF7, 0xF6, 0xF5};
static constexpr int64_t kPendingTimeoutMs = 60 * 1000;  // espera maxima a que el equipo este libre
static constexpr int64_t kAliveTimeoutMs = 30 * 1000;

static int64_t NowMs() {
    return esp_timer_get_time() / 1000;
}

MmwaveSensor::MmwaveSensor(const MmwaveConfig& config) : config_(config) {}

MmwaveSensor::~MmwaveSensor() {
    if (task_ != nullptr) {
        vTaskDelete(task_);
    }
    if (started_) {
        uart_driver_delete(config_.uart_num);
    }
}

bool MmwaveSensor::Start() {
    uart_config_t uart_cfg = {};
    uart_cfg.baud_rate = config_.baud_rate;
    uart_cfg.data_bits = UART_DATA_8_BITS;
    uart_cfg.parity = UART_PARITY_DISABLE;
    uart_cfg.stop_bits = UART_STOP_BITS_1;
    uart_cfg.flow_ctrl = UART_HW_FLOWCTRL_DISABLE;
    uart_cfg.source_clk = UART_SCLK_DEFAULT;

    esp_err_t err = uart_driver_install(config_.uart_num, 1024, 0, 0, nullptr, 0);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "No se pudo instalar el driver UART: %s", esp_err_to_name(err));
        return false;
    }
    err = uart_param_config(config_.uart_num, &uart_cfg);
    if (err == ESP_OK) {
        err = uart_set_pin(config_.uart_num, config_.tx_pin, config_.rx_pin,
                           UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE);
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "No se pudo configurar el UART: %s", esp_err_to_name(err));
        uart_driver_delete(config_.uart_num);
        return false;
    }
    started_ = true;

    if (xTaskCreate(TaskEntry, "mmwave", 4096, this, 3, &task_) != pdPASS) {
        ESP_LOGE(TAG, "No se pudo crear la tarea del sensor");
        task_ = nullptr;
        return false;
    }
    ESP_LOGI(TAG, "Sensor mmWave iniciado (TX=%d, RX=%d, %d baudios)",
             config_.tx_pin, config_.rx_pin, config_.baud_rate);
    return true;
}

void MmwaveSensor::TaskEntry(void* arg) {
    static_cast<MmwaveSensor*>(arg)->TaskLoop();
}

void MmwaveSensor::TaskLoop() {
    uint8_t buf[128];
    int64_t last_tick = 0;
    while (true) {
        int n = uart_read_bytes(config_.uart_num, buf, sizeof(buf), pdMS_TO_TICKS(100));
        if (n > 0) {
            last_data_ms_.store(NowMs());
            for (int i = 0; i < n; i++) {
                FeedByte(buf[i]);
            }
        }
        int64_t now = NowMs();
        if (now - last_tick >= 500) {
            last_tick = now;
            Tick();
        }
    }
}

// ---------- Parser ----------

void MmwaveSensor::FeedByte(uint8_t b) {
    // Trama binaria en curso
    if (frame_expected_ > 0) {
        frame_buf_[frame_len_++] = b;
        if (frame_expected_ == 2 && frame_len_ == 2) {
            // Ya tenemos la longitud: calcular el tamano total de la trama
            int payload_len = frame_buf_[0] | (frame_buf_[1] << 8);
            int total = 2 + payload_len + 4;
            if (payload_len < 3 || total > (int)sizeof(frame_buf_)) {
                frame_expected_ = 0;  // longitud invalida, descartar
                frame_len_ = 0;
            } else {
                frame_expected_ = total;
            }
            return;
        }
        if (frame_len_ >= frame_expected_) {
            // frame_buf_: [len_lo len_hi payload... tail(4)]
            int payload_len = frame_buf_[0] | (frame_buf_[1] << 8);
            const uint8_t* tail = &frame_buf_[2 + payload_len];
            bool ok = tail[0] == kTail[0] && tail[1] == kTail[1] &&
                      tail[2] == kTail[2] && tail[3] == kTail[3];
            if (ok) {
                HandleBinaryFrame(&frame_buf_[2], payload_len);
            }
            frame_expected_ = 0;
            frame_len_ = 0;
        }
        return;
    }

    // Busqueda de cabecera binaria
    if (b == kHeader[header_match_]) {
        header_match_++;
        if (header_match_ == 4) {
            header_match_ = 0;
            frame_len_ = 0;
            frame_expected_ = 2;  // primero leemos la longitud
            line_buf_.clear();
        }
        return;
    }
    header_match_ = (b == kHeader[0]) ? 1 : 0;

    // Modo texto
    if (b == '\n' || b == '\r') {
        if (!line_buf_.empty()) {
            HandleTextLine(line_buf_);
            line_buf_.clear();
        }
    } else if (b >= 0x20 && b < 0x7F) {
        if (line_buf_.size() < 64) {
            line_buf_.push_back(static_cast<char>(b));
        } else {
            line_buf_.clear();
        }
    }
}

void MmwaveSensor::HandleTextLine(const std::string& raw) {
    std::string line;
    for (char c : raw) {
        line.push_back(static_cast<char>(std::toupper(static_cast<unsigned char>(c))));
    }
    if (line == "ON") {
        UpdatePresence(true, -1);
    } else if (line == "OFF") {
        UpdatePresence(false, -1);
    } else if (line.rfind("RANGE", 0) == 0) {
        int dist = std::atoi(line.c_str() + 5);
        UpdatePresence(true, dist);
    }
}

void MmwaveSensor::HandleBinaryFrame(const uint8_t* payload, int len) {
    if (len < 3) {
        return;
    }
    bool present = payload[0] == 0x01;
    int distance = payload[1] | (payload[2] << 8);
    UpdatePresence(present, present ? distance : -1);
}

void MmwaveSensor::UpdatePresence(bool present, int distance_cm) {
    bool was_present = present_.exchange(present);
    if (present) {
        last_seen_ms_.store(NowMs());
        if (distance_cm >= 0) {
            last_distance_cm_.store(distance_cm);
        }
    }
    if (was_present != present) {
        ESP_LOGI(TAG, "Presencia: %s", present ? "HAY ALGUIEN" : "nadie");
    }
}

// ---------- Logica de saludo ----------

bool MmwaveSensor::InQuietHours(bool& time_valid) const {
    time_t now = time(nullptr);
    struct tm t;
    localtime_r(&now, &t);
    time_valid = (t.tm_year + 1900) >= 2025;
    if (!time_valid) {
        return false;
    }
    int h = t.tm_hour;
    if (config_.quiet_start_hour > config_.quiet_end_hour) {
        return h >= config_.quiet_start_hour || h < config_.quiet_end_hour;
    }
    return h >= config_.quiet_start_hour && h < config_.quiet_end_hour;
}

int MmwaveSensor::CurrentDayOfYear(bool& time_valid) const {
    time_t now = time(nullptr);
    struct tm t;
    localtime_r(&now, &t);
    time_valid = (t.tm_year + 1900) >= 2025;
    return time_valid ? (t.tm_year * 1000 + t.tm_yday) : -1;
}

void MmwaveSensor::Tick() {
    int64_t now = NowMs();

    // Reinicio del contador diario
    bool time_valid = false;
    int day = CurrentDayOfYear(time_valid);
    if (time_valid && day != greetings_day_) {
        greetings_day_ = day;
        greetings_today_.store(0);
    }

    if (present_.load()) {
        absent_since_ms_ = -1;
        if (away_long_enough_ && pending_greeting_since_ms_ < 0) {
            pending_greeting_since_ms_ = now;
            ESP_LOGI(TAG, "Llegada detectada, saludo pendiente");
        }
        away_long_enough_ = false;
    } else {
        if (absent_since_ms_ < 0) {
            absent_since_ms_ = now;
        }
        if (!away_long_enough_ && now - absent_since_ms_ >= config_.absence_to_leave_ms) {
            away_long_enough_ = true;
            ESP_LOGI(TAG, "Sin nadie hace %lld min: la proxima llegada saluda",
                     (long long)(config_.absence_to_leave_ms / 60000));
        }
    }

    if (pending_greeting_since_ms_ < 0) {
        return;
    }

    // Condiciones que cancelan el saludo
    bool quiet_valid = false;
    if (InQuietHours(quiet_valid)) {
        ESP_LOGI(TAG, "Horario nocturno: no saludo");
        pending_greeting_since_ms_ = -1;
        return;
    }
    if (last_greeting_ms_ >= 0 && now - last_greeting_ms_ < config_.greeting_cooldown_ms) {
        ESP_LOGI(TAG, "Saludo reciente: espero el enfriamiento");
        pending_greeting_since_ms_ = -1;
        return;
    }
    if (time_valid && greetings_today_.load() >= config_.max_greetings_per_day) {
        ESP_LOGI(TAG, "Ya saludo %d veces hoy", greetings_today_.load());
        pending_greeting_since_ms_ = -1;
        return;
    }
    if (now - pending_greeting_since_ms_ > kPendingTimeoutMs) {
        ESP_LOGI(TAG, "El equipo estuvo ocupado: saludo cancelado");
        pending_greeting_since_ms_ = -1;
        return;
    }

    // Solo saludar si el equipo esta libre (no hablando ni escuchando)
    auto& app = Application::GetInstance();
    if (app.GetDeviceState() != kDeviceStateIdle) {
        return;  // reintenta en el proximo tick
    }

    ESP_LOGI(TAG, "Saludo espontaneo por presencia");
    app.WakeWordInvoke(config_.greeting_text);
    last_greeting_ms_ = now;
    greetings_today_.fetch_add(1);
    pending_greeting_since_ms_ = -1;
}

// ---------- Consultas ----------

int MmwaveSensor::MinutesSinceLastSeen() const {
    int64_t seen = last_seen_ms_.load();
    if (seen < 0) {
        return -1;
    }
    return static_cast<int>((NowMs() - seen) / 60000);
}

bool MmwaveSensor::IsAlive() const {
    int64_t last = last_data_ms_.load();
    return last >= 0 && NowMs() - last < kAliveTimeoutMs;
}
