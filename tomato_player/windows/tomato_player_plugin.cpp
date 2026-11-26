#include "tomato_player_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <clocale>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <chrono>
#include <memory>
#include <string>
#include <utility>

namespace tomato_player {

namespace {

std::string StrFrom(const flutter::EncodableValue* v) {
  if (v == nullptr) return "";
  if (std::holds_alternative<std::string>(*v)) {
    return std::get<std::string>(*v);
  }
  return "";
}

int64_t IntFrom(const flutter::EncodableValue* v) {
  if (v == nullptr) return 0;
  if (std::holds_alternative<int32_t>(*v)) return std::get<int32_t>(*v);
  if (std::holds_alternative<int64_t>(*v)) return std::get<int64_t>(*v);
  if (std::holds_alternative<double>(*v)) return (int64_t)std::get<double>(*v);
  if (std::holds_alternative<bool>(*v)) return std::get<bool>(*v) ? 1 : 0;
  return 0;
}

}  // namespace

// static
void TomatoPlayerPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "br.com.tomatos/tomato_player",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<TomatoPlayerPlugin>(
      registrar->texture_registrar());
  plugin->channel_ = std::move(channel);

  plugin->channel_->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

TomatoPlayerPlugin::TomatoPlayerPlugin(
    flutter::TextureRegistrar* texture_registrar)
    : texture_registrar_(texture_registrar) {}

TomatoPlayerPlugin::~TomatoPlayerPlugin() {
  if (engine_) {
    engine_->Stop();
    UnregisterPixelTexture();
    engine_.reset();
  }
}

int64_t TomatoPlayerPlugin::RegisterPixelTexture() {
  if (texture_ != nullptr && texture_id_ >= 0) return texture_id_;
  auto buffer_texture = std::make_unique<flutter::PixelBufferTexture>(
      [this](size_t width, size_t height) {
        if (engine_) return engine_->CopyPixelBuffer(width, height);
        return static_cast<const FlutterDesktopPixelBuffer*>(
            &black_pixel_buffer_);
      });
  texture_ =
      std::make_shared<flutter::TextureVariant>(std::move(*buffer_texture));
  texture_id_ = texture_registrar_->RegisterTexture(texture_.get());
  return texture_id_;
}

void TomatoPlayerPlugin::UnregisterPixelTexture() {
  if (texture_id_ >= 0 && texture_registrar_ != nullptr) {
    texture_registrar_->UnregisterTexture(texture_id_);
  }
  texture_id_ = -1;
  texture_.reset();
}

// ---------------------------------------------------------------------------
// Engine.
// ---------------------------------------------------------------------------
bool Engine::Init() {
  // O libmpv exige LC_NUMERIC "C"/"C.UTF-8" (mpv_create retorna NULL caso o
  // app configure locale). Inofensivo no Windows; mantém paridade com o Linux.
  setlocale(LC_NUMERIC, "C");

  mpv = mpv_create();
  if (mpv == nullptr) return false;

  mpv_set_option_string(mpv, "vo", "libmpv");
  mpv_set_option_string(mpv, "osc", "no");
  mpv_set_option_string(mpv, "keep-open", "yes");
  mpv_set_option_string(mpv, "terminal", "no");
  // Configuração tolerante a CDN lenta (igual ao Linux).
  mpv_set_option_string(mpv, "network-timeout", "30");
  // Buffers de LIVE, nao de VOD (o default de 250 MB veio do caso de VOD).
  mpv_set_option_string(mpv, "demuxer-max-bytes", "262144000");    // 250 MB
  mpv_set_option_string(mpv, "demuxer-max-back-bytes", "67108864");  // 64 MB
  mpv_set_option_string(mpv, "demuxer-readahead-secs", "30");
  mpv_set_option_string(mpv, "stream-buffer-size", "33554432");  // 32 MB
  mpv_set_option_string(mpv, "cache-on-disk", "no");
  mpv_set_option_string(mpv, "hwdec", "no");
  // Scripts Lua padrao do mpv (ytdl_hook, stats, console) criam uma thread cada
  // e nao servem para nada fora de uso desktop.
  mpv_set_option_string(mpv, "load-scripts", "no");
  // O app desenha o proprio overlay e nao tem interacao de teclado com o motor.
  mpv_set_option_string(mpv, "osd-level", "0");
  mpv_set_option_string(mpv, "input-terminal", "no");
  // Qualidade primeiro: este e um player de video, nao uma grade de vigilancia.
  // O caminho barato de escala existe, mas so entra quando o alvo e pequeno
  // (<= 700px). dithering fica ligado porque anime tem muito degrade e dither
  // evita banding visivel.
  mpv_set_option_string(mpv, "sws-fast", "no");
  mpv_set_option_string(mpv, "dither", "fruit");
  mpv_set_option_string(mpv, "dscale", "hermite");
  mpv_set_option_string(mpv, "cscale", "");

  if (mpv_initialize(mpv) < 0) return false;

  mpv_render_param create_params[] = {
      {MPV_RENDER_PARAM_API_TYPE, (void*)MPV_RENDER_API_TYPE_SW},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  if (mpv_render_context_create(&render_ctx, mpv, create_params) < 0) {
    return false;
  }
  mpv_render_context_set_update_callback(render_ctx, &Engine::OnRenderUpdate,
                                         this);

  mpv_request_log_messages(mpv, "warn");
  mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE);
  mpv_observe_property(mpv, 1, "duration", MPV_FORMAT_DOUBLE);
  mpv_observe_property(mpv, 2, "pause", MPV_FORMAT_FLAG);
  mpv_observe_property(mpv, 3, "paused-for-cache", MPV_FORMAT_FLAG);
  mpv_observe_property(mpv, 4, "cache-buffering-state", MPV_FORMAT_INT64);
  mpv_observe_property(mpv, 5, "video-params", MPV_FORMAT_NODE);

  render_thread = std::thread(&Engine::RenderLoop, this);
  event_thread = std::thread(&Engine::EventLoop, this);
  return true;
}

void Engine::OnRenderUpdate(void* cb_ctx) {
  Engine* engine = static_cast<Engine*>(cb_ctx);
  engine->need_frame.store(true);
  engine->render_cv.notify_one();
}

void Engine::PushState(bool force) {
  (void)force;
  auto* plugin = plugin_;
  if (plugin == nullptr || plugin->engine_ == nullptr) return;
  flutter::EncodableMap map;
  {
    std::lock_guard<std::mutex> lk(state_mutex);
    map[flutter::EncodableValue("state")] = flutter::EncodableValue(state_str);
    map[flutter::EncodableValue("positionMs")] =
        flutter::EncodableValue((int64_t)position_ms);
    map[flutter::EncodableValue("durationMs")] =
        flutter::EncodableValue((int64_t)duration_ms);
    map[flutter::EncodableValue("bufferingPercentage")] =
        flutter::EncodableValue((int64_t)buffer_pct);
    map[flutter::EncodableValue("completed")] =
        flutter::EncodableValue(completed);
    if (!error.empty()) {
      map[flutter::EncodableValue("error")] =
          flutter::EncodableValue(error);
      map[flutter::EncodableValue("errorCode")] =
          flutter::EncodableValue(error_code);
    }
  }
  {
    std::lock_guard<std::mutex> lk(frame_mutex);
    map[flutter::EncodableValue("videoWidth")] = flutter::EncodableValue(video_w);
    map[flutter::EncodableValue("videoHeight")] =
        flutter::EncodableValue(video_h);
  }
  if (plugin->channel_ != nullptr) {
    plugin->channel_->InvokeMethod(
        "state", std::make_unique<flutter::EncodableValue>(std::move(map)),
        nullptr);
  }
}

void Engine::HandleProperty(mpv_event_property* prop) {
  if (prop->format == MPV_FORMAT_NONE) return;
  std::lock_guard<std::mutex> lk(state_mutex);

  if (strcmp(prop->name, "time-pos") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
    double v = *(double*)prop->data;
    position_ms = v >= 0 ? (int64_t)(v * 1000.0) : 0;
  } else if (strcmp(prop->name, "duration") == 0 &&
             prop->format == MPV_FORMAT_DOUBLE) {
    double v = *(double*)prop->data;
    duration_ms = v > 0 ? (int64_t)(v * 1000.0) : 0;
  } else if (strcmp(prop->name, "pause") == 0 &&
             prop->format == MPV_FORMAT_FLAG) {
    bool paused = *(int*)prop->data != 0;
    if (paused) {
      if (state_str == "playing" || state_str == "buffering") state_str = "paused";
    } else if (file_loaded) {
      if (state_str == "paused" || state_str == "idle") state_str = "playing";
    }
  } else if (strcmp(prop->name, "paused-for-cache") == 0 &&
             prop->format == MPV_FORMAT_FLAG) {
    bool buffering = *(int*)prop->data != 0;
    if (buffering && (state_str == "playing" || state_str == "buffering")) {
      state_str = "buffering";
    } else if (!buffering && state_str == "buffering") {
      state_str = "playing";
    }
  } else if (strcmp(prop->name, "cache-buffering-state") == 0 &&
             prop->format == MPV_FORMAT_INT64) {
    buffer_pct = (double)*(int64_t*)prop->data;
  } else if (strcmp(prop->name, "video-params") == 0 &&
             prop->format == MPV_FORMAT_NODE) {
    mpv_node* node = (mpv_node*)prop->data;
    if (node->format == MPV_FORMAT_NODE_MAP && node->u.list != nullptr) {
      int64_t w = 0, h = 0;
      for (int i = 0; i < node->u.list->num; i++) {
        const char* key = node->u.list->keys[i];
        mpv_node* val = &node->u.list->values[i];
        int64_t iv = 0;
        if (val->format == MPV_FORMAT_INT64) iv = val->u.int64;
        else if (val->format == MPV_FORMAT_DOUBLE) iv = (int64_t)val->u.double_;
        if (strcmp(key, "w") == 0) w = iv;
        else if (strcmp(key, "h") == 0) h = iv;
      }
      if (w > 0 && h > 0) {
        video_w = (int)w;
        video_h = (int)h;
      }
    }
  }
}

void Engine::EventLoop() {
  for (;;) {
    mpv_event* event = mpv_wait_event(mpv, -1.0);
    if (event == nullptr) continue;
    if (event->event_id == MPV_EVENT_NONE) {
      if (render_stop.load()) break;
      continue;
    }
    if (render_stop.load()) break;

    bool force_push = false;
    switch (event->event_id) {
      case MPV_EVENT_START_FILE: {
        std::lock_guard<std::mutex> lk(state_mutex);
        state_str = "loading";
        file_loaded = false;
        force_push = true;
        break;
      }
      case MPV_EVENT_FILE_LOADED: {
        std::lock_guard<std::mutex> lk(state_mutex);
        file_loaded = true;
        if (state_str != "buffering") state_str = "playing";
        force_push = true;
        break;
      }
      case MPV_EVENT_END_FILE: {
        mpv_event_end_file* end = (mpv_event_end_file*)event->data;
        {
          std::lock_guard<std::mutex> lk(state_mutex);
          file_loaded = false;
          if (end->reason == MPV_END_FILE_REASON_EOF) {
            state_str = "ended";
            completed = true;
          } else if (end->reason == MPV_END_FILE_REASON_ERROR) {
            state_str = "error";
            completed = false;
            error = mpv_error_string(end->error);
            error_code = "end_file";
          } else {
            state_str = "idle";
            completed = false;
          }
          force_push = true;
        }
        break;
      }
      case MPV_EVENT_LOG_MESSAGE: {
        mpv_event_log_message* msg = (mpv_event_log_message*)event->data;
        if (strcmp(msg->level, "error") == 0) {
          std::lock_guard<std::mutex> lk(state_mutex);
          error = msg->text;
          error_code = "log";
        }
        break;
      }
      case MPV_EVENT_PROPERTY_CHANGE: {
        mpv_event_property* prop = (mpv_event_property*)event->data;
        HandleProperty(prop);
        break;
      }
      default:
        break;
    }
    PushState(force_push);
  }
}

// Thread dedicada de render: consome o sinal do mpv (update callback) e
// renderiza o frame mais recente para o buffer SW, num loop proprio (mesmo
// contrato do Linux).
void Engine::RenderLoop() {
  for (;;) {
    {
      std::unique_lock<std::mutex> lk(render_mutex);
      // Timeout de segurança (16ms) roda mesmo se o mpv não notificar (alguns
      // vo não chamam o update callback para TODA repaint).
      render_cv.wait_for(lk, std::chrono::milliseconds(16), [this] {
        return render_stop.load() || need_frame.load();
      });
      if (render_stop.load()) break;
      need_frame.store(false);
    }
    RenderFrame();
  }
}

void Engine::RenderFrame() {
  if (render_ctx == nullptr) return;
  if (render_stop.load()) return;

  // Consumir o sinal de update. OBRIGATORIO: enquanto o render context nao
  // acknowledgar, o mpv bloqueia o pipeline de video (audio toca, video fica
  // preto).
  uint64_t flags = mpv_render_context_update(render_ctx);
  if ((flags & MPV_RENDER_UPDATE_FRAME) == 0) return;

  // Dimensoes a partir das propriedades observadas (video-params) ou do
  // video-out-params (fallback). NAO usar mpv_render_context_get_info com
  // MPV_RENDER_PARAM_SW_SIZE: o get_info so suporta NEXT_FRAME_INFO e retorna
  // MPV_ERROR_NOT_IMPLEMENTED — era o motivo do video nunca aparecer no
  // Windows (RenderFrame abortava sempre no get_info).
  int size[2] = {0, 0};
  int max_out[2] = {0, 0};
  {
    std::lock_guard<std::mutex> lk(state_mutex);
    size[0] = video_w;
    size[1] = video_h;
    max_out[0] = output_w;
    max_out[1] = output_h;
  }
  if (size[0] <= 0 || size[1] <= 0) {
    GetVideoSize(size);
  }
  if (size[0] <= 0 || size[1] <= 0) return;
  if (size[0] > 8192 || size[1] > 8192) return;

  // Limita o alvo ao tamanho que o widget ocupa, sem distorcer (escala pelo
  // menor lado e mantem o aspecto), com teto final para nao crescer em
  // quadrado numa tela grande.
  if (max_out[0] > 0 && max_out[1] > 0) {
    double escala = (std::min)(static_cast<double>(max_out[0]) / size[0],
                               static_cast<double>(max_out[1]) / size[1]);
    if (escala > 1.0) {
      const double teto = (std::min)(
          static_cast<double>(kMaxRenderLado) / size[0],
          static_cast<double>(kMaxRenderLado) / size[1]);
      if (teto < 1.0) escala = teto;
    }
    if (escala < 1.0) {
      int w = static_cast<int>(size[0] * escala + 0.5);
      int h = static_cast<int>(size[1] * escala + 0.5);
      if (w < 16) w = 16;
      if (h < 16) h = 16;
      size[0] = w;
      size[1] = h;
    }
  }

  // Limite de taxa no alvo reduzido: o custo e fixo por quadro, entao cortar
  // quadros e o que derruba o CPU. Tela cheia nao e limitada.
  if (max_out[0] > 0 && max_out[1] > 0) {
    const int64_t lado =
        (int64_t)(max_out[0] > max_out[1] ? max_out[0] : max_out[1]);
    if (lado <= kLadoQualidadeReduzida) {
      auto agora = std::chrono::steady_clock::now();
      if (!ultimo_quadro.time_since_epoch().count()) {
        ultimo_quadro = agora;
      } else {
        auto decorrido = std::chrono::duration_cast<std::chrono::milliseconds>(
                             agora - ultimo_quadro).count();
        if (decorrido < kMsPorQuadroReducido) return;
        ultimo_quadro = agora;
      }
    } else {
      ultimo_quadro = std::chrono::steady_clock::now();
    }
  }

  back.Ensure(size[0], size[1]);
  if (back.data == nullptr) return;
  // Alvo degenerado nao serve para nada e o scaler do mpv nao gosta disso.
  if (size[0] < 32 || size[1] < 32) return;

  // "rgb0" (R no offset 0): o embedder Windows sobe o FlutterDesktopPixelBuffer
  // como GL_RGBA via glTexImage2D. "bgr0" reverteria R/B (e o A=0 some).
  const char* fmt = "rgb0";
  size_t stride = back.stride;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_SW_SIZE, size},
      {MPV_RENDER_PARAM_SW_FORMAT, (void*)fmt},
      {MPV_RENDER_PARAM_SW_STRIDE, &stride},
      {MPV_RENDER_PARAM_SW_POINTER, back.data},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  if (mpv_render_context_render(render_ctx, params) != MPV_ERROR_SUCCESS) return;

  {
    std::lock_guard<std::mutex> lk(frame_mutex);
    front.Swap(back);
    video_w = front.w;
    video_h = front.h;
  }
  // MarkTextureFrameAvailable é thread-safe (documentado no
  // flutter_texture_registrar.h); chamamos direto aqui.
  auto* plugin = plugin_;
  if (plugin != nullptr && plugin->texture_id_ >= 0) {
    plugin->texture_registrar_->MarkTextureFrameAvailable(
        plugin->texture_id_);
  }
}

// Dimensões de saída do vídeo via video-out-params (dw/dh) + rotação. Mesmo
// conceito do Linux: não depende do render já ter acontecido.
void Engine::GetVideoSize(int out[2]) {
  out[0] = out[1] = 0;
  if (mpv == nullptr) return;
  mpv_node params;
  if (mpv_get_property(mpv, "video-out-params", MPV_FORMAT_NODE, &params) !=
      MPV_ERROR_SUCCESS) {
    return;
  }
  int64_t dw = 0, dh = 0, rotate = 0;
  if (params.format == MPV_FORMAT_NODE_MAP && params.u.list != nullptr) {
    for (int i = 0; i < params.u.list->num; i++) {
      const char* key = params.u.list->keys[i];
      mpv_node* v = &params.u.list->values[i];
      if (v->format != MPV_FORMAT_INT64) continue;
      if (strcmp(key, "dw") == 0) dw = v->u.int64;
      if (strcmp(key, "dh") == 0) dh = v->u.int64;
      if (strcmp(key, "rotate") == 0) rotate = v->u.int64;
    }
  }
  mpv_free_node_contents(&params);
  if (dw <= 0 || dh <= 0) return;
  if (rotate == 0 || rotate == 180) {
    out[0] = (int)dw;
    out[1] = (int)dh;
  } else {
    out[0] = (int)dh;
    out[1] = (int)dw;
  }
}

const FlutterDesktopPixelBuffer* Engine::CopyPixelBuffer(size_t, size_t) {
  std::lock_guard<std::mutex> lk(frame_mutex);
  if (front.data != nullptr && front.w > 0) {
    pixel_buffer_.buffer = front.data;
    pixel_buffer_.width = front.w;
    pixel_buffer_.height = front.h;
  } else {
    pixel_buffer_.buffer = black;
    pixel_buffer_.width = 4;
    pixel_buffer_.height = 4;
  }
  pixel_buffer_.release_callback = nullptr;
  pixel_buffer_.release_context = nullptr;
  return &pixel_buffer_;
}

void Engine::Stop() {
  render_stop.store(true);
  need_frame.store(true);
  render_cv.notify_all();
  if (mpv != nullptr) {
    mpv_wakeup(mpv);
  }
  if (render_thread.joinable()) render_thread.join();
  if (event_thread.joinable()) event_thread.join();
  if (render_ctx != nullptr) {
    mpv_render_context_free(render_ctx);
    render_ctx = nullptr;
  }
  if (mpv != nullptr) {
    mpv_terminate_destroy(mpv);
    mpv = nullptr;
  }
}

// ---------------------------------------------------------------------------
// Handlers de método (mesmo contrato do Linux).
// ---------------------------------------------------------------------------
void TomatoPlayerPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();
  const auto* args = method_call.arguments();

  if (method == "create") {
    if (engine_ == nullptr) {
      auto engine = std::make_unique<Engine>(this);
      if (!engine->Init()) {
        result->Error("init_failed", "falha ao iniciar o libmpv", nullptr);
        return;
      }
      engine_ = std::move(engine);
      RegisterPixelTexture();
      if (texture_id_ < 0) {
        engine_->Stop();
        engine_.reset();
        result->Error("texture_failed", "falha ao registrar a textura", nullptr);
        return;
      }
    }
    flutter::EncodableMap m;
    m[flutter::EncodableValue("textureId")] =
        flutter::EncodableValue((int64_t)texture_id_);
    result->Success(flutter::EncodableValue(std::move(m)));
    return;
  }

  if (engine_ == nullptr || engine_->mpv == nullptr) {
    result->Error("not_created", "chame create() antes", nullptr);
    return;
  }
  Engine* engine = engine_.get();

  if (method == "open") {
    if (!std::holds_alternative<flutter::EncodableMap>(*args)) {
      result->Error("invalid_args", "argumentos inválidos", nullptr);
      return;
    }
    const auto& call_map = std::get<flutter::EncodableMap>(*args);
    std::string uri;
    auto it = call_map.find(flutter::EncodableValue("uri"));
    if (it != call_map.end()) uri = StrFrom(&it->second);
    if (uri.empty()) {
      result->Error("invalid_uri", "uri ausente ou inválida", nullptr);
      return;
    }

    std::string headers;
    auto hdr_it = call_map.find(flutter::EncodableValue("httpHeaders"));
    if (hdr_it != call_map.end() &&
        std::holds_alternative<flutter::EncodableMap>(hdr_it->second)) {
      const flutter::EncodableMap& hdr_map =
          std::get<flutter::EncodableMap>(hdr_it->second);
      for (const auto& [k, v] : hdr_map) {
        if (!headers.empty()) headers += ",";
        headers += StrFrom(&k) + ": " + StrFrom(&v);
      }
    }
    if (!headers.empty()) {
      mpv_set_property_string(engine->mpv, "http-header-fields", headers.c_str());
    }

    auto opt_it = call_map.find(flutter::EncodableValue("options"));
    if (opt_it != call_map.end() &&
        std::holds_alternative<flutter::EncodableMap>(opt_it->second)) {
      const flutter::EncodableMap& opt_map =
          std::get<flutter::EncodableMap>(opt_it->second);
      for (const auto& [k, v] : opt_map) {
        mpv_set_property_string(engine->mpv, StrFrom(&k).c_str(),
                                StrFrom(&v).c_str());
      }
    }

    {
      std::lock_guard<std::mutex> lk(engine->state_mutex);
      engine->state_str = "loading";
      engine->position_ms = 0;
      engine->duration_ms = 0;
      engine->buffer_pct = 0;
      engine->completed = false;
      engine->file_loaded = false;
      engine->error.clear();
      engine->error_code.clear();
    }

    const char* cmd[] = {"loadfile", uri.c_str(), nullptr};
    mpv_command(engine->mpv, cmd);
    engine->PushState(true);
    result->Success();
    return;
  }

  if (method == "play") {
    int flag = 0;
    mpv_set_property(engine->mpv, "pause", MPV_FORMAT_FLAG, &flag);
    result->Success();
    return;
  }
  if (method == "pause") {
    int flag = 1;
    mpv_set_property(engine->mpv, "pause", MPV_FORMAT_FLAG, &flag);
    result->Success();
    return;
  }
  if (method == "seek") {
    int64_t ms = 0;
    if (std::holds_alternative<flutter::EncodableMap>(*args)) {
      const auto& call_map = std::get<flutter::EncodableMap>(*args);
      auto it = call_map.find(flutter::EncodableValue("positionMs"));
      if (it != call_map.end()) ms = IntFrom(&it->second);
    }
    char secs[32];
    snprintf(secs, sizeof(secs), "%.3f", ms / 1000.0);
    const char* cmd[] = {"seek", secs, "absolute+exact", nullptr};
    mpv_command(engine->mpv, cmd);
    result->Success();
    return;
  }
  if (method == "setOutputSize") {
    int w = 0;
    int h = 0;
    if (std::holds_alternative<flutter::EncodableMap>(*args)) {
      const auto& call_map = std::get<flutter::EncodableMap>(*args);
      auto w_it = call_map.find(flutter::EncodableValue("width"));
      auto h_it = call_map.find(flutter::EncodableValue("height"));
      if (w_it != call_map.end()) w = static_cast<int>(IntFrom(&w_it->second));
      if (h_it != call_map.end()) h = static_cast<int>(IntFrom(&h_it->second));
    }
    if (w < 0) w = 0;
    if (h < 0) h = 0;
    // Teto de seguranca: evita buffer gigante (e OOM) por valor absurdo.
    if (w > 4096) w = 4096;
    if (h > 4096) h = 4096;
    {
      std::lock_guard<std::mutex> lk(engine->state_mutex);
      engine->output_w = w;
      engine->output_h = h;
    }
    // A qualidade acompanha o tamanho pedido: alvo pequeno usa o caminho
    // barato de escala, alvo grande volta para o filtro de verdade.
    {
      int64_t lado = (int64_t)(w > h ? w : h);
      const bool compacto = lado > 0 && lado <= kLadoQualidadeReduzida;
      if (compacto != engine->qualidade_reduzida) {
        engine->qualidade_reduzida = compacto;
        if (compacto) {
          mpv_set_property_string(engine->mpv, "sws-fast", "yes");
          mpv_set_property_string(engine->mpv, "dither", "no");
          mpv_set_property_string(engine->mpv, "dscale", "bilinear");
          mpv_set_property_string(engine->mpv, "cscale", "bilinear");
        } else {
          mpv_set_property_string(engine->mpv, "sws-fast", "no");
          mpv_set_property_string(engine->mpv, "dither", "fruit");
          mpv_set_property_string(engine->mpv, "dscale", "hermite");
          mpv_set_property_string(engine->mpv, "cscale", "");
        }
      }
    }
    result->Success();
    return;
  }
  if (method == "setProperty") {
    if (!std::holds_alternative<flutter::EncodableMap>(*args)) {
      result->Error("invalid_property", "name/value inválidos", nullptr);
      return;
    }
    const auto& call_map = std::get<flutter::EncodableMap>(*args);
    auto name_it = call_map.find(flutter::EncodableValue("name"));
    auto val_it = call_map.find(flutter::EncodableValue("value"));
    if (name_it == call_map.end() || val_it == call_map.end()) {
      result->Error("invalid_property", "name/value inválidos", nullptr);
      return;
    }
    const std::string name = StrFrom(&name_it->second);
    const flutter::EncodableValue& value = val_it->second;
    if (std::holds_alternative<bool>(value)) {
      int flag = std::get<bool>(value) ? 1 : 0;
      mpv_set_property(engine->mpv, name.c_str(), MPV_FORMAT_FLAG, &flag);
    } else if (std::holds_alternative<int32_t>(value) ||
               std::holds_alternative<int64_t>(value)) {
      int64_t v = IntFrom(&value);
      mpv_set_property(engine->mpv, name.c_str(), MPV_FORMAT_INT64, &v);
    } else if (std::holds_alternative<double>(value)) {
      double v = std::get<double>(value);
      mpv_set_property(engine->mpv, name.c_str(), MPV_FORMAT_DOUBLE, &v);
    } else if (std::holds_alternative<std::string>(value)) {
      const std::string& v = std::get<std::string>(value);
      mpv_set_property_string(engine->mpv, name.c_str(), v.c_str());
    } else {
      result->Error("invalid_property", "tipo de valor não suportado", nullptr);
      return;
    }
    result->Success();
    return;
  }
  if (method == "disposePlayer") {
    if (engine_) {
      engine_->Stop();
      UnregisterPixelTexture();
      engine_.reset();
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}

}  // namespace tomato_player