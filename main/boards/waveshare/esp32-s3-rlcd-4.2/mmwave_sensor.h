#ifndef _MMWAVE_SENSOR_H_
#define _MMWAVE_SENSOR_H_

// Sensor de presencia Waveshare HMMD mmWave (S3KM1110) por UART.
// Entiende los dos formatos de salida del sensor:
//   - Modo normal (texto): lineas "ON" / "OFF" y "Range N"
//   - Modo reporte (binario): trama F4 F3 F2 F1 ... F8 F7 F6 F5
// Cuando la persona vuelve despues de un rato sin nadie, dispara un saludo
// de Claudio (WakeWordInvoke), respetando enfriamiento y horario nocturno.

#include <driver/gpio.h>
#include <driver/uart.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include <atomic>
#include <cstdint>
#include <string>

struct MmwaveConfig {
    uart_port_t uart_num = UART_NUM_1;
    gpio_num_t tx_pin = GPIO_NUM_43;   // TX de la placa -> RX del sensor
    gpio_num_t rx_pin = GPIO_NUM_44;   // RX de la placa <- TX del sensor
    int baud_rate = 115200;

    // Cuanto tiempo sin detectar a nadie para considerar que "se fue"
    int64_t absence_to_leave_ms = 10LL * 60 * 1000;      // 10 minutos
    // Tiempo minimo entre dos saludos espontaneos
    int64_t greeting_cooldown_ms = 4LL * 60 * 60 * 1000; // 4 horas
    // Maximo de saludos espontaneos por dia (si hay hora valida)
    int max_greetings_per_day = 2;
    // Horario en que NO saluda (si hay hora valida). 22 a 8 = de noche.
    int quiet_start_hour = 22;
    int quiet_end_hour = 8;
    // Texto que se envia al server como si la persona lo hubiera dicho
    std::string greeting_text = "Hola Claudio";
};

class MmwaveSensor {
public:
    explicit MmwaveSensor(const MmwaveConfig& config);
    ~MmwaveSensor();

    bool Start();

    bool IsPresent() const { return present_.load(); }
    int LastDistanceCm() const { return last_distance_cm_.load(); }
    // Minutos desde la ultima deteccion (-1 si nunca detecto)
    int MinutesSinceLastSeen() const;
    bool IsAlive() const;  // el sensor mando datos en los ultimos 30 s
    int GreetingsToday() const { return greetings_today_.load(); }

private:
    static void TaskEntry(void* arg);
    void TaskLoop();

    void FeedByte(uint8_t b);
    void HandleTextLine(const std::string& line);
    void HandleBinaryFrame(const uint8_t* payload, int len);
    void UpdatePresence(bool present, int distance_cm);
    void Tick();  // logica de saludo, se llama periodicamente

    bool InQuietHours(bool& time_valid) const;
    int CurrentDayOfYear(bool& time_valid) const;

    MmwaveConfig config_;
    TaskHandle_t task_ = nullptr;
    bool started_ = false;

    std::atomic<bool> present_{false};
    std::atomic<int> last_distance_cm_{-1};
    std::atomic<int64_t> last_seen_ms_{-1};
    std::atomic<int64_t> last_data_ms_{-1};
    std::atomic<int> greetings_today_{0};

    // Estado de saludo (solo se usa dentro de la tarea del sensor)
    int64_t absent_since_ms_ = -1;
    bool away_long_enough_ = true;  // al encender, la primera llegada saluda
    int64_t last_greeting_ms_ = -1;
    int64_t pending_greeting_since_ms_ = -1;
    int greetings_day_ = -1;

    // Parser de texto
    std::string line_buf_;
    // Parser binario
    uint8_t frame_buf_[96];
    int frame_len_ = 0;
    int frame_expected_ = 0;
    int header_match_ = 0;
};

#endif
