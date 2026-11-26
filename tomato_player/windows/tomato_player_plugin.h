#ifndef FLUTTER_PLUGIN_TOMATO_PLAYER_PLUGIN_H_
#define FLUTTER_PLUGIN_TOMATO_PLAYER_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/texture_registrar.h>
#include <mpv/client.h>
#include <mpv/render.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <memory>
#include <chrono>
#include <mutex>
#include <string>
#include <thread>

namespace tomato_player {

// Teto do lado maior do alvo do render por software, em pixels.
static const int kMaxRenderLado = 1280;
// Ate este lado (px) o render usa o caminho barato de escala e a taxa limitada.
static const int kLadoQualidadeReduzida = 700;
// Intervalo minimo entre quadros no alvo reduzido (~12 fps).
static const int kMsPorQuadroReducido = 83;

class Engine;

class TomatoPlayerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  TomatoPlayerPlugin(flutter::TextureRegistrar* texture_registrar);

  virtual ~TomatoPlayerPlugin();

  TomatoPlayerPlugin(const TomatoPlayerPlugin&) = delete;
  TomatoPlayerPlugin& operator=(const TomatoPlayerPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  flutter::TextureRegistrar* texture_registrar() { return texture_registrar_; }

  // Regista a textura de pixel buffer no engine e devolve o id (ou -1).
  int64_t RegisterPixelTexture();
  void UnregisterPixelTexture();

  // O Engine (nativo) consulta/corre o estado do plugin ao publicar frames e
  // estados; por isso enxerga os membros privados.
  friend class Engine;

 private:
  flutter::TextureRegistrar* texture_registrar_;
  std::unique_ptr<Engine> engine_;
  // Mantém a textura viva enquanto registrada.
  std::shared_ptr<flutter::TextureVariant> texture_;
  int64_t texture_id_ = -1;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  FlutterDesktopPixelBuffer black_pixel_buffer_;
};

// =============================================================================
// Engine (libmpv, render SW "rgb0" -> FlutterDesktopPixelBuffer).
// =============================================================================
struct FrameBuffer {
  uint8_t* data = nullptr;
  int w = 0;
  int h = 0;
  size_t stride = 0;
  size_t bytes = 0;

  void Ensure(int nw, int nh) {
    if (nw <= 0 || nh <= 0) return;
    if (nw == w && nh == h && data != nullptr) return;
    size_t nstride = (size_t)nw * 4;  // Windows espera linhas contíguas (sem padding).
    size_t nbytes = nstride * (size_t)nh;
    uint8_t* nd = (uint8_t*)malloc(nbytes);
    if (nd == nullptr) return;
    free(data);
    data = nd;
    stride = nstride;
    bytes = nbytes;
    w = nw;
    h = nh;
  }

  void Swap(FrameBuffer& o) {
    std::swap(w, o.w);
    std::swap(h, o.h);
    std::swap(stride, o.stride);
    std::swap(bytes, o.bytes);
    std::swap(data, o.data);
  }
};

class Engine {
 public:
  explicit Engine(TomatoPlayerPlugin* plugin) : plugin_(plugin) {}
  ~Engine() = default;

  bool Init();

  // CopyPixelBuffer (thread de raster do Flutter): devolve o frame atual.
  const FlutterDesktopPixelBuffer* CopyPixelBuffer(size_t, size_t);

  void Stop();

  mpv_handle* mpv = nullptr;
  mpv_render_context* render_ctx = nullptr;

  std::mutex frame_mutex;
  FrameBuffer front;
  FrameBuffer back;
  uint8_t black[64] = {0};
  int video_w = 0;
  // Tamanho maximo do alvo do render (0 = tamanho nativo do video). Ver o
  // comentario da versao Linux: o render e por software e o custo e fixo por
  // quadro, entao renderizar 4K num widget de 640x360 e desperdicio puro.
  int output_w = 0;
  int output_h = 0;
  // Comeca em true porque o Init() ja configurou o caminho barato de escala.
  bool qualidade_reduzida = true;
  // Ultimo quadro publicado, para limitar a taxa de atualizacao da textura.
  std::chrono::steady_clock::time_point ultimo_quadro{};
  int video_h = 0;

  // Snapshot (protegido por state_mutex).
  std::mutex state_mutex;
  std::string state_str = "idle";
  int64_t position_ms = 0;
  int64_t duration_ms = 0;
  double buffer_pct = 0.0;
  bool completed = false;
  bool file_loaded = false;
  std::string error;
  std::string error_code;

  std::mutex render_mutex;
  std::condition_variable render_cv;
  std::atomic<bool> render_stop{false};
  std::atomic<bool> need_frame{false};
  std::thread render_thread;
  std::thread event_thread;

  void EventLoop();
  void RenderLoop();
  void RenderFrame();
  void GetVideoSize(int out[2]);
  void HandleProperty(mpv_event_property* prop);
  void PushState(bool force);

  FlutterDesktopPixelBuffer pixel_buffer_ = {};

 private:
  static void OnRenderUpdate(void* cb_ctx);
  TomatoPlayerPlugin* plugin_;
};

}  // namespace tomato_player

#endif  // FLUTTER_PLUGIN_TOMATO_PLAYER_PLUGIN_H_