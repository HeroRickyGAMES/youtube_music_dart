// Motor nativo Linux do tomato_player.
//
// Renderização do libmpv em software (MPV_RENDER_API_TYPE_SW) direto para
// um FlPixelBufferTexture do embedder Flutter — sem OpenGL/FBO. O fluxo:
//
//   mpv (decoder)  ->mpv_render_context_render(SW)-> buffer de pixels (RGBA)
//                 -> swap (thread de render)       -> FlPixelBufferTexture
//                 -> Flutter compõe via copy_pixels (render thread do engine)
//
// Threads:
//   * event_thread - mpv_wait_event/observe_property, empurra estados pro Dart
//   * main (GTK)    - fl_method_channel_invoke_method + render SW em idle +
//                     mark_texture_frame_available (render fora do callback do
//                     mpv: render direto no callback trava o pipeline de video)

#include "include/tomato_player/tomato_player_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <mpv/client.h>
#include <mpv/render.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <clocale>
#include <cstdio>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

#include "tomato_player_plugin_private.h"

#define TOMATO_PLAYER_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), tomato_player_plugin_get_type(), \
                              TomatoPlayerPlugin))

#define CHANNEL_NAME "br.com.tomatos/tomato_player"

// Teto do lado maior do alvo do render por software, em pixels. Acima disso a
// imagem nao melhora e o custo cresce em quadrado.
static const int kMaxRenderLado = 1280;

// Ate este lado (px) o render usa o caminho barato de escala. Serve a
// preview/grade; acima disso (tela cheia) a qualidade volta a ser a de verdade.
static const int kLadoQualidadeReduzida = 700;

// Intervalo minimo entre quadros no alvo reduzido (~12 fps). O custo do render
// e fixo por quadro, entao cortar quadros e o que derruba o CPU.
static const int kMsPorQuadroReducido = 83;

// ---------------------------------------------------------------------------
// Frame buffer RGBA tight (stride = width*4). O Flutter, via copy_pixels,
// assume layout tight RGBA (nao ha informacao de stride), entao qualquer
// padding aqui rasga/desloca a imagem por linha.
// ---------------------------------------------------------------------------
struct FrameBuffer {
  int w = 0;
  int h = 0;
  size_t stride = 0;
  uint8_t* data = nullptr;
  size_t capacity = 0;

  ~FrameBuffer() { std::free(data); }

  void Reserve(size_t nbytes) {
    if (nbytes == 0 || capacity >= nbytes) return;
    uint8_t* nd = nullptr;
    if (posix_memalign((void**)&nd, 64, nbytes) != 0) return;
    std::free(data);
    data = nd;
    capacity = nbytes;
  }

  void Ensure(int nw, int nh) {
    if (nw <= 0 || nh <= 0) return;
    if (nw == w && nh == h && data != nullptr) return;
    size_t nstride = (size_t)nw * 4;
    size_t nbytes = nstride * (size_t)nh;
    Reserve(nbytes);
    if (data == nullptr || capacity < nbytes) return;
    stride = nstride;
    w = nw;
    h = nh;
  }

  void Swap(FrameBuffer& o) {
    std::swap(w, o.w);
    std::swap(h, o.h);
    std::swap(stride, o.stride);
    std::swap(data, o.data);
    std::swap(capacity, o.capacity);
  }
};

// ---------------------------------------------------------------------------
// Motor libmpv.
// ---------------------------------------------------------------------------
class Engine {
 public:
  explicit Engine(TomatoPlayerPlugin* plugin) : plugin_(plugin) {}
  ~Engine() = default;

  bool Init();

  mpv_handle* mpv = nullptr;
  mpv_render_context* render_ctx = nullptr;

  // Buffers de video (double buffering: front lido pelo Flutter, back escrito
  // pelo render thread; swap protegido por frame_mutex).
  std::mutex frame_mutex;
  FrameBuffer front;
  FrameBuffer back;
  uint8_t black[64] = {0};

  // Controle de parada.
  std::atomic<bool> render_stop{false};
  std::thread event_thread;
  std::thread render_thread;

  // Sinaliza para a render thread que o mpv quer um frame novo (notificada do
  // update callback). Render em thread propria = o video NAO depende do quao
  // ocupada esta a main thread do GTK (feeds, proxy, logs e estado disputam
  // ela o tempo todo; render no idle era a fonte do "imagem travando muito").
  std::mutex cv_mutex;
  std::condition_variable render_cv;
  bool pending_render = false;

  // Snapshot atual (protegido por state_mutex).
  std::mutex state_mutex;
  std::string state_str = "idle";  // idle|loading|buffering|playing|paused|ended|error
  int init_error = 0;
  int render_error = 0;
  int64_t position_ms = 0;
  int64_t duration_ms = 0;
  double buffer_pct = 0.0;
  bool completed = false;
  bool file_loaded = false;
  int video_w = 0;
  int video_h = 0;

  // Estado de audio. O app nunca mexeu nisso: o volume vinha so do mpv
  // (100, sem mute) e nao havia como o usuario ver nem corrigir um audio
  // mudo. Agora o estado real volta no snapshot para a UI refletir o que o
  // motor esta fazendo, e 'has_audio' habilita/desabilita o controle.
  double volume = 100.0;
  bool muted = false;
  bool has_audio = false;
  std::string current_ao;
  std::string audio_device;

  // Tamanho maximo do alvo do render (0 = tamanho nativo do video). O render e
  // por software, entao renderizar um 4K num widget de 640x360 faz o mpv
  // converter 8 megapixels para mostrar 0,2. Como o custo e fixo por quadro e
  // proporcional a fonte, avisar o tamanho real economiza trabalho de graca.
  int output_w = 0;
  int output_h = 0;

  // Comeca em true porque o Init() ja configurou o caminho barato de escala.
  bool qualidade_reduzida = true;

  // Ultimo quadro publicado, para limitar a taxa de atualizacao da textura.
  std::chrono::steady_clock::time_point ultimo_quadro{};
  std::string error;
  std::string error_code;

  // Notificações adiadas para a main thread do GTK.
  std::atomic<bool> pending_state{false};
  std::atomic<bool> present_scheduled{false};

  // Últimas mensagens de log do mpv (buffer circular) para diagnosticar
  // "audio toca, video não": expostas no BuildSnapshot (o stderr do app não
  // passa pelo harness do flutter test).
  std::vector<std::string> log_lines;
  void AddLogLine(const char* prefix, const char* text);

  // Telemetria do caminho de render (para diagnosticar "audio toca, video
  // preto"): quantas vezes o mpv pediu um frame (update_calls), quantos frames
  // realmente foram renderizados/swappados (frames_rendered) e quantas vezes o
  // Flutter consumiu o buffer (copy_calls). Se frames_rendered == 0 o mpv nao
  // esta entregando quadro; se copy_calls > 0 e mesmo assim imagem preta, o
  // problema esta no upload/composicao do Flutter (Impeller/Wayland).
  std::atomic<uint32_t> update_calls{0};
  std::atomic<uint32_t> frames_rendered{0};
  std::atomic<uint32_t> copy_calls{0};

  void EventLoop();
  void RenderThreadFn();
  void RenderFrame();
  void GetVideoSize(int out[2]);
  void HandleProperty(mpv_event_property* prop);
  void PushState(bool force);
  void SchedulePresent();
  void Stop();

  FlValue* BuildSnapshot();

 private:
  static void OnRenderUpdate(void* cb_ctx);
  static gboolean OnPresent(gpointer user_data);
  TomatoPlayerPlugin* plugin_;
};

// ---------------------------------------------------------------------------
// Textura de pixel buffer (FlPixelBufferTexture).
// ---------------------------------------------------------------------------
struct TomatoTexture {
  FlPixelBufferTexture parent_instance;
  TomatoPlayerPlugin* plugin;  // fraco; limpo no dispose.
  GMutex plugin_mutex;
};
#define TOMATO_TEXTURE(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), tomato_texture_get_type(), TomatoTexture))

typedef struct {
  FlPixelBufferTextureClass parent_class;
} TomatoTextureClass;

G_DEFINE_TYPE(TomatoTexture, tomato_texture, fl_pixel_buffer_texture_get_type())

// ---------------------------------------------------------------------------
// Plugin.
// ---------------------------------------------------------------------------
struct _TomatoPlayerPlugin {
  GObject parent_instance;

  Engine* engine;
  FlMethodChannel* channel;
  FlTextureRegistrar* texture_registrar;
  TomatoTexture* texture;
  int64_t texture_id;
  gboolean has_texture;
};

G_DEFINE_TYPE(TomatoPlayerPlugin, tomato_player_plugin, g_object_get_type())

static void tomato_texture_finalize(GObject* object);

static void tomato_texture_class_init(TomatoTextureClass* klass) {
  G_OBJECT_CLASS(klass)->finalize = tomato_texture_finalize;
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      [](FlPixelBufferTexture* texture, const uint8_t** out_buffer,
         uint32_t* width, uint32_t* height, GError** error) -> gboolean {
    TomatoTexture* self = TOMATO_TEXTURE(texture);
    // O dispose do plugin espera este mutex antes de soltar a textura e o
    // motor. Sem ele, copy_pixels podia devolver um ponteiro de um buffer
    // liberado por stop_engine durante a troca de tela.
    g_mutex_lock(&self->plugin_mutex);
    TomatoPlayerPlugin* plugin = self->plugin;
    // O motor do Flutter chama copy_pixels já no registro, para descobrir o
    // tamanho da textura. Devolver TRUE sem preencher width/height deixa o
    // motor com lixo (às vezes 0) e ele divide por isso. Todos os caminhos
    // preenchem os três ponteiros, e nenhum devolve dimensão zero.
    if (plugin == nullptr || plugin->engine == nullptr) {
      *out_buffer = nullptr;
      *width = 0;
      *height = 0;
      g_mutex_unlock(&self->plugin_mutex);
      return FALSE;
    }
    Engine* engine = plugin->engine;
    {
      std::lock_guard<std::mutex> lock(engine->frame_mutex);
      engine->copy_calls.fetch_add(1, std::memory_order_relaxed);
      if (engine->front.data != nullptr && engine->front.w > 0 &&
          engine->front.h > 0) {
        *out_buffer = engine->front.data;
        *width = (uint32_t)engine->front.w;
        *height = (uint32_t)engine->front.h;
      } else {
        *out_buffer = engine->black;
        *width = 4;
        *height = 4;
      }
    }
    g_mutex_unlock(&self->plugin_mutex);
    return TRUE;
  };
}

static void tomato_texture_init(TomatoTexture* self) {
  self->plugin = nullptr;
  g_mutex_init(&self->plugin_mutex);
}

static void tomato_texture_finalize(GObject* object) {
  TomatoTexture* self = TOMATO_TEXTURE(object);
  g_mutex_clear(&self->plugin_mutex);
  G_OBJECT_CLASS(tomato_texture_parent_class)->finalize(object);
}

static TomatoTexture* tomato_texture_new(TomatoPlayerPlugin* plugin) {
  TomatoTexture* self = TOMATO_TEXTURE(g_object_new(tomato_texture_get_type(), nullptr));
  self->plugin = plugin;
  return self;
}

// ---------------------------------------------------------------------------
// Engine.
// ---------------------------------------------------------------------------
bool Engine::Init() {
  // Aloca o teto do render uma unica vez. O buffer nunca e liberado durante
  // um resize (o Flutter pode estar lendo o frame anterior em copy_pixels).
  const size_t max_frame_bytes =
      (size_t)kMaxRenderLado * (size_t)kMaxRenderLado * 4;
  front.Reserve(max_frame_bytes);
  back.Reserve(max_frame_bytes);

  // O libmpv exige LC_NUMERIC "C" ou "C.UTF-8": quem inicializa o GTK (setlocale)
  // muda para o locale do usuário (ex.: pt_BR.UTF-8) e o mpv_create() passa a
  // retornar NULL. Chamamos sempre antes de criar (mesmo requerimento do mpv).
  setlocale(LC_NUMERIC, "C");

  mpv = mpv_create();
  if (mpv == nullptr) {
    init_error = -1000;
    return false;
  }

  mpv_set_option_string(mpv, "vo", "libmpv");
  // Audio: usa o backend do PULSE, e nao o AO nativo "pipewire" do mpv.
  //
  // Medido neste PC (Pop!_OS 24.04, pipewire 1.6.8, libmpv 0.37): com o AO
  // nativo o mpv anunciava "AO: [pipewire] ... 2ch floatp" — ou seja, ACHAVA
  // que estava tocando — mas o stream nunca aparecia no grafico (pactl nao
  // via nenhum sink-input) e o usuario nao ouvia nada. O AO "pulse" fala com o
  // pipewire-pulse, que e o caminho que o resto do sistema usa, e e o mesmo
  // que o usuario ja valida todo dia no Chrome.
  mpv_set_option_string(mpv, "ao", "pulse");
  mpv_set_option_string(mpv, "osc", "no");
  mpv_set_option_string(mpv, "keep-open", "yes");
  mpv_set_option_string(mpv, "terminal", "no");
  // Timeouts tolerantes (o media_kit usava 5s, demais para rede lenta).
  mpv_set_option_string(mpv, "network-timeout", "30");
  // Buffers: o default anterior (250 MB) era exagerado, mas este app é um
  // player de streaming e precisa de folga de cache para não travar na
  // reprodução. Valor intermediário: bem abaixo dos 250 MB, bem acima do
  // mínimo de CCTV.
  mpv_set_option_string(mpv, "demuxer-max-bytes", "262144000");    // 250 MB
  mpv_set_option_string(mpv, "demuxer-max-back-bytes", "67108864");  // 64 MB
  mpv_set_option_string(mpv, "demuxer-readahead-secs", "30");
  mpv_set_option_string(mpv, "stream-buffer-size", "33554432");    // 32 MB
  mpv_set_option_string(mpv, "cache-on-disk", "no");
  mpv_set_option_string(mpv, "hwdec", "no");

  // Scripts Lua padrão do mpv (ytdl_hook, stats, console) criam uma thread
  // cada e não servem para nada fora de uso desktop. "no" tira essas 3.
  mpv_set_option_string(mpv, "load-scripts", "no");
  // O app entrega URLs diretas do googlevideo (já resolvidas pelo Dart).
  // Sem isso o hook ytdl do mpv tenta reextrair a URL e falha com
  // "youtube-dl failed".
  mpv_set_option_string(mpv, "ytdl", "no");
  // O app desenha o próprio overlay e não tem interação de teclado com o
  // motor; nada de OSD nem console.
  mpv_set_option_string(mpv, "osd-level", "0");
  mpv_set_option_string(mpv, "input-terminal", "no");
  // Qualidade primeiro: este é um player de vídeo, não uma grade de vigilância.
  // O caminho barato de escala (sws-fast/bilinear/sem dithering) continua
  // existindo, mas é aplicado por setOutputSize SÓ quando o alvo é pequeno
  // (<= 700px, preview/janela reduzida). Em tela cheia o filtro de verdade
  // está ativo. dithering fica ligado por padrão porque em anime — que tem
  // muito degradê — ele evita banding visível.
  mpv_set_option_string(mpv, "sws-fast", "no");
  mpv_set_option_string(mpv, "dither", "fruit");
  mpv_set_option_string(mpv, "dscale", "hermite");
  mpv_set_option_string(mpv, "cscale", "");

  int init_err = mpv_initialize(mpv);
  if (init_err < 0) {
    init_error = init_err;
    return false;
  }

  mpv_render_param create_params[] = {
      {MPV_RENDER_PARAM_API_TYPE, (void*)MPV_RENDER_API_TYPE_SW},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  int rc_err = mpv_render_context_create(&render_ctx, mpv, create_params);
  if (rc_err < 0) {
    render_error = rc_err;
    return false;
  }
  // IMPORTANTE (libmpv render): o update callback deve ser consumido o mais
  // rapido possivel (update() + render()) na main thread, senao o mpv trava o
  // pipeline de video e nenhum frame chega ao buffer (audio toca, video preto).
  // Reproduzimos exatamente o fluxo comprovado do media_kit nesse caso.
  mpv_render_context_set_update_callback(render_ctx, &Engine::OnRenderUpdate,
                                         this);

  // "v" (verbose) fazia o mpv emitir um MPV_EVENT_LOG_MESSAGE por mensagem, e
  // o event loop transformava cada uma em linha de log + um snapshot pro Dart.
  // "warn" é o nível útil e não gera esse volume.
  mpv_request_log_messages(mpv, "warn");
  mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE);
  mpv_observe_property(mpv, 1, "duration", MPV_FORMAT_DOUBLE);
  mpv_observe_property(mpv, 2, "pause", MPV_FORMAT_FLAG);
  mpv_observe_property(mpv, 3, "paused-for-cache", MPV_FORMAT_FLAG);
  mpv_observe_property(mpv, 4, "cache-buffering-state", MPV_FORMAT_INT64);
  mpv_observe_property(mpv, 5, "video-params", MPV_FORMAT_NODE);
  mpv_observe_property(mpv, 6, "current-ao", MPV_FORMAT_STRING);
  mpv_observe_property(mpv, 7, "aid", MPV_FORMAT_STRING);
  mpv_observe_property(mpv, 8, "track-list", MPV_FORMAT_NODE);
  mpv_observe_property(mpv, 9, "volume", MPV_FORMAT_DOUBLE);
  mpv_observe_property(mpv, 10, "mute", MPV_FORMAT_FLAG);
  mpv_observe_property(mpv, 11, "audio-device", MPV_FORMAT_STRING);
  // keep-open=yes pauses at EOF instead of ending the file, so END_FILE is
  // never emitted. `eof-reached` is the reliable "track finished" signal.
  mpv_observe_property(mpv, 12, "eof-reached", MPV_FORMAT_FLAG);

  try {
    event_thread = std::thread(&Engine::EventLoop, this);
    render_thread = std::thread(&Engine::RenderThreadFn, this);
  } catch (const std::system_error& e) {
    init_error = -1001;
    return false;
  }
  return true;
}

void Engine::OnRenderUpdate(void* cb_ctx) {
  // Chamado por uma thread interna do mpv quando um novo frame precisa ser
  // renderizado. NAO render aqui: transcodificar/decode no meio deste callback
  // trava o core do mpv. Apenas acorda a render thread dedicada, que consome
  // o update() + render() num loop proprio (nao depende da main thread).
  Engine* engine = static_cast<Engine*>(cb_ctx);
  engine->update_calls.fetch_add(1, std::memory_order_relaxed);
  {
    std::lock_guard<std::mutex> lk(engine->cv_mutex);
    engine->pending_render = true;
  }
  engine->render_cv.notify_one();
}

void Engine::AddLogLine(const char* prefix, const char* text) {
  std::lock_guard<std::mutex> lk(state_mutex);
  std::string line = prefix;
  line += " ";
  line += text;
  // Remove quebras de linha no fim.
  while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) {
    line.pop_back();
  }
  log_lines.push_back(line);
  if (log_lines.size() > 120) log_lines.erase(log_lines.begin());
}

// Thread dedicada de render: consome o sinal do mpv (update callback) e
// renderiza o frame mais recente para o buffer SW, num loop proprio.
//
// Por que thread propria e nao o idle da main: a main thread do GTK e usada
// por fedes, proxy, logs e estado do app — quando ela fica ocupada, o g_idle_add
// do render era postergado/atrasado e o video travava (imagem congelada/
// stuttering enquanto o app processava feeds). Aqui o video nao depende do quao
// ocupada a main thread esta: o mpv acorda esta thread via CV quando tem frame.
//
// Loop (padrao mpv render multi-thread): espera update -> drena via
// mpv_render_context_update() -> render(). O update callback volta a disparar
// se houver mais frames pendentes, então a thread drena ate o mpv ficar quieto.
void Engine::RenderThreadFn() {
  for (;;) {
    {
      std::unique_lock<std::mutex> lk(cv_mutex);
      // Timeout de seguranca (16ms) tambem roda se o mpv pedir update sem
      // notify (alguns vo nao chamam o callback para TODA repaint).
      render_cv.wait_for(lk, std::chrono::milliseconds(16), [this]() {
        return render_stop.load() || pending_render;
      });
      if (render_stop.load()) break;
      pending_render = false;
    }
    if (render_ctx == nullptr) continue;
    RenderFrame();
  }
}

// Consome um sinal de update e renderiza UM frame (SW) para o buffer back, com
// swap para o front que o Flutter consome via copy_pixels.
//
// CRITICO: mpv_render_context_update() DEVE ser chamada SEMPRE que o update
// callback dispara — mesmo sem renderizar — para consumir o sinal. Sem isso o
// mpv trava o pipeline de vídeo inteiro (core bloqueado esperando o render
// consumir o frame → audio toca mas vídeo nunca aparece).
void Engine::RenderFrame() {
  if (render_ctx == nullptr) return;
  if (render_stop.load()) return;

  // 1) Consumir o sinal de update. OBRIGATORIO — sem isso o mpv bloqueia
  //    esperando o render context acknowledgar.
  uint64_t flags = mpv_render_context_update(render_ctx);

  // 2) Dimensoes: video-params (observado) → video-out-params (fallback).
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

  // 2b) Limita o alvo do render ao tamanho que o widget realmente ocupa, sem
  // distorcer: escala pelo menor dos dois lados e mantem o aspecto do video.
  // Como o mpv converte YUV->RGB de qualquer jeito, escalar durante a conversao
  // e praticamente de graca — o que economiza e toda a leitura da fonte em
  // resolucao nativa. O teto final evita que uma tela grande mande o player
  // renderizar 1 megapixel por pixel de video sem ganho visivel.
  if (max_out[0] > 0 && max_out[1] > 0) {
    double escala = std::min(static_cast<double>(max_out[0]) / size[0],
                             static_cast<double>(max_out[1]) / size[1]);
    if (escala > 1.0) {
      const double teto = std::min(
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

  // 3) So renderiza se ha um frame novo (MPV_RENDER_UPDATE_FRAME) ou se o
  //    tamanho mudou (primeira vez). Ignorar MPV_ERROR_UNINITIALIZED (sem
  //    frame novo) e OK.
  if ((flags & MPV_RENDER_UPDATE_FRAME) == 0) return;

  // Limite de taxa. O custo do render por software e FIXO por quadro e
  // proporcional a fonte, entao o que pesa e quantos quadros sao produzidos. Em
  // 25 fps sao ~25 uploads de textura por segundo so neste player, e cada um
  // acorda a thread de raster do Flutter. Num alvo reduzido, 12 fps e
  // imperceptivel; em tela cheia a fluidez e o que o usuario avalia, entao nao
  // e limitado.
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

  // Alvo degenerado nao serve para nada e o scaler do mpv nao gosta de
  // dimensao minuscula.
  if (size[0] < 32 || size[1] < 32) return;

  const char* fmt = "rgb0";
  int pitch = 4 * size[0];
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_SW_SIZE, size},
      {MPV_RENDER_PARAM_SW_FORMAT, (void*)fmt},
      {MPV_RENDER_PARAM_SW_STRIDE, &pitch},
      {MPV_RENDER_PARAM_SW_POINTER, back.data},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  int rc = mpv_render_context_render(render_ctx, params);
  if (rc != MPV_ERROR_SUCCESS && rc != MPV_ERROR_UNINITIALIZED) {
    g_printerr("[tomato] render rc=%d (%s)\n", rc, mpv_error_string(rc));
    return;
  }

  {
    std::lock_guard<std::mutex> lk(frame_mutex);
    front.Swap(back);
    frames_rendered.fetch_add(1, std::memory_order_relaxed);
  }
  // fl_texture_registrar_mark_texture_frame_available e thread-safe no
  // flutter_linux (posta pro raster thread); pode chamar daqui.
  if (plugin_->texture != nullptr) {
    fl_texture_registrar_mark_texture_frame_available(
        plugin_->texture_registrar, FL_TEXTURE(plugin_->texture));
  }
}

// Dimensoes de saida do video via video-out-params (dw/dh) + rotacao. Mesmo
// conceito do media_kit: nao depende do render ja ter acontecido.
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

gboolean Engine::OnPresent(gpointer user_data) {
  TomatoPlayerPlugin* plugin = TOMATO_PLAYER_PLUGIN(user_data);
  Engine* engine = plugin->engine;
  if (engine != nullptr) {
    engine->present_scheduled.store(false);
    // Render NAO acontece aqui: a render thread dedicada cuida do video
    // (RenderThreadFn/RenderFrame). Aqui so entrega o estado pro Dart.
    if (plugin->channel != nullptr && engine->pending_state.exchange(false)) {
      g_autoptr(FlValue) snapshot = engine->BuildSnapshot();
      fl_method_channel_invoke_method(plugin->channel, "state", snapshot, nullptr,
                                      nullptr, nullptr);
    }
  }
  g_object_unref(plugin);
  return G_SOURCE_REMOVE;
}

void Engine::SchedulePresent() {
  if (present_scheduled.exchange(true)) return;
  g_object_ref(plugin_);
  g_idle_add(&Engine::OnPresent, plugin_);
}

void Engine::PushState(bool force) {
  (void)force;
  pending_state.store(true);
  SchedulePresent();
}

// Sanitiza texto vindo do motor antes de mandar pelo MethodChannel.
//
// O StandardMessageCodec do Flutter decodifica string como UTF-8 e LANCA
// FormatException ("Unexpected extension byte") se um byte nao-continuacao
// aparecer. Texto de log do mpv (nivel info) e rotulo de codec chegam Crus do
// decoder e nao tem garantia de UTF-8; um unico byte ruim em dbgLogs quebrava
// o snapshot INTEIRO a cada estado (600+ FormatException por sessao), com o
// player congelando. Aqui qualquer byte invalido vira '?', e o canal nunca
// mais quebra por texto do motor.
static FlValue* fl_value_new_utf8_safe(const char* text) {
  if (text == nullptr) return fl_value_new_string("");
  std::string s(text);
  size_t i = 0;
  while (i < s.size()) {
    unsigned char c = (unsigned char)s[i];
    size_t len = 0;
    if (c < 0x80) {
      len = 1;
    } else if ((c & 0xE0) == 0xC0) {
      len = 2;
    } else if ((c & 0xF0) == 0xE0) {
      len = 3;
    } else if ((c & 0xF8) == 0xF0) {
      len = 4;
    } else {
      s[i] = '?';
      i += 1;
      continue;
    }
    if (i + len > s.size()) {
      s[i] = '?';
      i += 1;
      continue;
    }
    bool ok = true;
    for (size_t j = 1; j < len; j++) {
      if (((unsigned char)s[i + j] & 0xC0) != 0x80) {
        ok = false;
        break;
      }
    }
    if (!ok) {
      s[i] = '?';
      i += 1;
      continue;
    }
    i += len;
  }
  return fl_value_new_string(s.c_str());
}

FlValue* Engine::BuildSnapshot() {
  FlValue* map = fl_value_new_map();
  {
    std::lock_guard<std::mutex> lk(state_mutex);
    fl_value_set_string_take(map, "state", fl_value_new_utf8_safe(state_str.c_str()));
    fl_value_set_string_take(map, "positionMs", fl_value_new_int(position_ms));
    fl_value_set_string_take(map, "durationMs", fl_value_new_int(duration_ms));
    fl_value_set_string_take(map, "bufferingPercentage",
                             fl_value_new_float(buffer_pct));
    fl_value_set_string_take(map, "completed", fl_value_new_bool(completed));
    // Estado real de audio: o controle de volume so faz sentido com faixa de
    // audio presente, entao isso viaja junto para a UI desabilitar o controle.
    fl_value_set_string_take(map, "volume", fl_value_new_float(volume));
    fl_value_set_string_take(map, "muted", fl_value_new_bool(muted));
    fl_value_set_string_take(map, "hasAudio", fl_value_new_bool(has_audio));
    fl_value_set_string_take(map, "currentAo",
                             fl_value_new_utf8_safe(current_ao.c_str()));
    fl_value_set_string_take(map, "audioDevice",
                             fl_value_new_utf8_safe(audio_device.c_str()));
    if (!error.empty()) {
      fl_value_set_string_take(map, "error",
                               fl_value_new_utf8_safe(error.c_str()));
      fl_value_set_string_take(map, "errorCode",
                               fl_value_new_utf8_safe(error_code.c_str()));
    }
  }
  {
    std::lock_guard<std::mutex> lk(frame_mutex);
    fl_value_set_string_take(map, "videoWidth", fl_value_new_int(video_w));
    fl_value_set_string_take(map, "videoHeight", fl_value_new_int(video_h));
  }
  fl_value_set_string_take(map, "dbgFrames",
                           fl_value_new_int(frames_rendered.load()));
  fl_value_set_string_take(map, "dbgCopies", fl_value_new_int(copy_calls.load()));
  fl_value_set_string_take(map, "dbgUpdates",
                           fl_value_new_int(update_calls.load()));
  {
    std::lock_guard<std::mutex> lk(state_mutex);
    FlValue* logs = fl_value_new_list();
    for (const std::string& l : log_lines) {
      fl_value_append_take(logs, fl_value_new_utf8_safe(l.c_str()));
    }
    fl_value_set_string_take(map, "dbgLogs", logs);
  }
  return map;
}

void Engine::HandleProperty(mpv_event_property* prop) {
  if (prop->format == MPV_FORMAT_NONE) return;  // valor ainda não disponível
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
  } else if (strcmp(prop->name, "eof-reached") == 0 &&
             prop->format == MPV_FORMAT_FLAG) {
    if (*(int*)prop->data != 0) {
      state_str = "ended";
      completed = true;
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
  } else if (strcmp(prop->name, "current-ao") == 0 ||
             strcmp(prop->name, "aid") == 0 ||
             strcmp(prop->name, "audio-device") == 0) {
    // NAO leia prop->data para estes: mpv_observe_property com MPV_FORMAT_STRING
    // entrega ponteiro JA LIBERADO (medido: aid veio '`bzV', audio-device veio
    // '0czV' — lixo de heap). Esse valor ia para o snapshot e quebrava a
    // decodificacao UTF-8 do canal, derrubando o estado a cada push. O evento
    // serve so de AVISO de mudanca; o valor vem de mpv_get_property, que
    // entrega a string correta.
    const char* nome = prop->name;
    char* v = nullptr;
    if (mpv_get_property(mpv, nome, MPV_FORMAT_STRING, &v) >= 0) {
      if (strcmp(nome, "current-ao") == 0) {
        current_ao = v ? v : "";
        // AO aberto = existe saida de audio de fato. E o sinal mais forte,
        // porque vem do motor depois de ele abrir o dispositivo.
        if (!current_ao.empty()) has_audio = true;
      } else if (strcmp(nome, "audio-device") == 0) {
        audio_device = v ? v : "";
      } else if (strcmp(nome, "aid") == 0) {
        // aid == "no" => sem faixa de audio habilitada.
        has_audio = v != nullptr && v[0] != '\0' && strcmp(v, "no") != 0;
      }
      if (v != nullptr) mpv_free(v);
    }
  } else if (strcmp(prop->name, "volume") == 0 &&
             prop->format == MPV_FORMAT_DOUBLE) {
    volume = *(double*)prop->data;
  } else if (strcmp(prop->name, "mute") == 0 &&
             prop->format == MPV_FORMAT_FLAG) {
    muted = *(int*)prop->data != 0;
  } else if (strcmp(prop->name, "track-list") == 0 &&
             prop->format == MPV_FORMAT_NODE) {
    mpv_node* node = (mpv_node*)prop->data;
    int ntracks = 0;
    bool saw_audio = false;
    if (node->format == MPV_FORMAT_NODE_ARRAY && node->u.list != nullptr) {
      ntracks = node->u.list->num;
      for (int i = 0; i < node->u.list->num; i++) {
        mpv_node* t = &node->u.list->values[i];
        if (t->format != MPV_FORMAT_NODE_MAP) continue;
        for (int j = 0; j < t->u.list->num; j++) {
          const char* k = t->u.list->keys[j];
          mpv_node* v = &t->u.list->values[j];
          if (!strcmp(k, "codec_type") && v->format == MPV_FORMAT_STRING &&
              !strcmp(v->u.string, "audio")) {
            saw_audio = true;
            break;
          }
        }
      }
    }
    // Nao sobrescreve `has_audio` direto com `saw_audio`: o parse de
    // codec_type do track-list nao se confirma (os dois tracks sairam como
    // audio=-1 mesmo com aid=1 selecionado) e isso zerava o controle de volume
    // com o audio escolhido. Aqui so AFIRMA audio; quem zera, abaixo, e um
    // arquivo de fato sem faixa nenhuma.
    if (saw_audio) has_audio = true;
    else if (ntracks == 0) has_audio = false;
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
        AddLogLine(msg->level, msg->text);
        if (g_strcmp0(msg->level, "error") == 0) {
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

void Engine::Stop() {
  render_stop.store(true);
  if (mpv != nullptr) {
    mpv_wakeup(mpv);  // faz o wait_event(-1) retornar
  }
  {
    // Acorda a render thread para ela perceber o render_stop.
    std::lock_guard<std::mutex> lk(cv_mutex);
    pending_render = true;
  }
  render_cv.notify_one();
  if (event_thread.joinable()) event_thread.join();
  if (render_thread.joinable()) render_thread.join();
}

// ---------------------------------------------------------------------------
// Manipuladores de método.
// ---------------------------------------------------------------------------
static FlMethodResponse* handle_create(TomatoPlayerPlugin* self, FlValue*) {
  if (self->engine == nullptr) {
    Engine* engine = new Engine(self);
    if (!engine->Init()) {
      int derr = engine->init_error;
      int rerr = engine->render_error;
      delete engine;
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "init_failed", derr != 0 ? "falha ao iniciar o libmpv" : "falha no render",
          fl_value_new_int(derr != 0 ? derr : rerr)));
    }
    self->texture = tomato_texture_new(self);
    if (!fl_texture_registrar_register_texture(
            self->texture_registrar, FL_TEXTURE(self->texture))) {
      g_object_unref(self->texture);
      self->texture = nullptr;
      engine->Stop();
      delete engine;
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "texture_failed", "falha ao registrar a textura", nullptr));
    }
    self->texture_id = fl_texture_get_id(FL_TEXTURE(self->texture));
    self->has_texture = TRUE;
    self->engine = engine;
  }

  g_autoptr(FlValue) result = fl_value_new_map();
  fl_value_set_string_take(result, "textureId", fl_value_new_int(self->texture_id));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* handle_open(TomatoPlayerPlugin* self, FlValue* args) {
  if (self->engine == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "not_created", "chame create() antes de open()", nullptr));
  }
  Engine* engine = self->engine;

  FlValue* uri_value = fl_value_lookup_string(args, "uri");
  if (uri_value == nullptr || fl_value_get_type(uri_value) != FL_VALUE_TYPE_STRING) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_uri", "uri ausente ou inválida", nullptr));
  }
  const char* uri = fl_value_get_string(uri_value);

  std::string headers;
  FlValue* headers_value = fl_value_lookup_string(args, "httpHeaders");
  if (headers_value != nullptr && fl_value_get_type(headers_value) == FL_VALUE_TYPE_MAP) {
    size_t n = fl_value_get_length(headers_value);
    for (size_t i = 0; i < n; i++) {
      FlValue* key = fl_value_get_map_key(headers_value, i);
      FlValue* val = fl_value_get_map_value(headers_value, i);
      if (key != nullptr && val != nullptr &&
          fl_value_get_type(key) == FL_VALUE_TYPE_STRING &&
          fl_value_get_type(val) == FL_VALUE_TYPE_STRING) {
        if (!headers.empty()) headers += ",";
        headers += fl_value_get_string(key);
        headers += ": ";
        headers += fl_value_get_string(val);
      }
    }
  }
  if (!headers.empty()) {
    mpv_set_property_string(engine->mpv, "http-header-fields", headers.c_str());
  }

  FlValue* options_value = fl_value_lookup_string(args, "options");
  if (options_value != nullptr &&
      fl_value_get_type(options_value) == FL_VALUE_TYPE_MAP) {
    size_t n = fl_value_get_length(options_value);
    for (size_t i = 0; i < n; i++) {
      FlValue* key = fl_value_get_map_key(options_value, i);
      FlValue* val = fl_value_get_map_value(options_value, i);
      if (key != nullptr && val != nullptr &&
          fl_value_get_type(key) == FL_VALUE_TYPE_STRING &&
          fl_value_get_type(val) == FL_VALUE_TYPE_STRING) {
        mpv_set_property_string(engine->mpv, fl_value_get_string(key),
                                fl_value_get_string(val));
      }
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

  const char* cmd[] = {"loadfile", uri, nullptr};
  int lf_rc = mpv_command(engine->mpv, cmd);
  {
    char lbuf[96];
    snprintf(lbuf, sizeof(lbuf), "loadfile rc=%d", lf_rc);
    engine->AddLogLine("open", lbuf);
  }
  engine->PushState(true);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* handle_play(TomatoPlayerPlugin* self, FlValue*) {
  if (self->engine == nullptr || self->engine->mpv == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "not_created", "player não criado", nullptr));
  }
  int flag = 0;
  mpv_set_property(self->engine->mpv, "pause", MPV_FORMAT_FLAG, &flag);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* handle_pause(TomatoPlayerPlugin* self, FlValue*) {
  if (self->engine == nullptr || self->engine->mpv == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "not_created", "player não criado", nullptr));
  }
  int flag = 1;
  mpv_set_property(self->engine->mpv, "pause", MPV_FORMAT_FLAG, &flag);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* handle_seek(TomatoPlayerPlugin* self, FlValue* args) {
  if (self->engine == nullptr || self->engine->mpv == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "not_created", "player não criado", nullptr));
  }
  FlValue* position = fl_value_lookup_string(args, "positionMs");
  if (position == nullptr || fl_value_get_type(position) != FL_VALUE_TYPE_INT) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_position", "positionMs ausente", nullptr));
  }
  int64_t ms = fl_value_get_int(position);
  gchar* secs = g_strdup_printf("%.3f", ms / 1000.0);
  const char* cmd[] = {"seek", secs, "absolute+exact", nullptr};
  mpv_command(self->engine->mpv, cmd);
  g_free(secs);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* handle_set_output_size(TomatoPlayerPlugin* self,
                                                FlValue* args) {
  FlValue* w_value = fl_value_lookup_string(args, "width");
  FlValue* h_value = fl_value_lookup_string(args, "height");
  int w = 0;
  int h = 0;
  if (w_value != nullptr && fl_value_get_type(w_value) == FL_VALUE_TYPE_INT) {
    w = static_cast<int>(fl_value_get_int(w_value));
  }
  if (h_value != nullptr && fl_value_get_type(h_value) == FL_VALUE_TYPE_INT) {
    h = static_cast<int>(fl_value_get_int(h_value));
  }
  if (w < 0) w = 0;
  if (h < 0) h = 0;
  // Teto de seguranca: o alvo do render alimenta um swscale; um valor absurdo
  // aqui viraria um buffer gigante (e um OOM), nao um video melhor.
  if (w > 4096) w = 4096;
  if (h > 4096) h = 4096;

  Engine* engine = self->engine;
  if (engine == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "not_created", "chame create() antes", nullptr));
  }
  {
    std::lock_guard<std::mutex> lk(engine->state_mutex);
    engine->output_w = w;
    engine->output_h = h;
  }

  // A qualidade acompanha o tamanho pedido: alvo pequeno usa o caminho barato
  // de escala, alvo grande volta para o filtro de verdade. Assim a GPU nao e
  // usada para nada aqui, mas o filtro correto e escolhido por contexto.
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
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* handle_debug_frame(TomatoPlayerPlugin* self, FlValue*) {
  if (self->engine == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "not_created", "player não criado", nullptr));
  }
  Engine* engine = self->engine;
  std::lock_guard<std::mutex> lk(engine->frame_mutex);

  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "framesRendered",
                           fl_value_new_int(engine->frames_rendered.load()));
  fl_value_set_string_take(map, "copyCalls",
                           fl_value_new_int(engine->copy_calls.load()));
  fl_value_set_string_take(map, "updateCalls",
                           fl_value_new_int(engine->update_calls.load()));

  {
    std::lock_guard<std::mutex> lk(engine->state_mutex);
    FlValue* logs = fl_value_new_list();
    for (const std::string& l : engine->log_lines) {
      fl_value_append_take(logs, fl_value_new_string(l.c_str()));
    }
    fl_value_set_string_take(map, "logs", logs);
  }

  const FrameBuffer& fb = engine->front;
  if (fb.data == nullptr || fb.w <= 0 || fb.h <= 0) {
    fl_value_set_string_take(map, "w", fl_value_new_int(0));
    fl_value_set_string_take(map, "h", fl_value_new_int(0));
    return FL_METHOD_RESPONSE(fl_method_success_response_new(map));
  }

  fl_value_set_string_take(map, "w", fl_value_new_int(fb.w));
  fl_value_set_string_take(map, "h", fl_value_new_int(fb.h));

  // Amostra ate 512x512 central: verifica se HA pixel nao-preto (video de
  // verdade) ou tudo preto (frame morto). Soma R,G,B e cuenta nao-pretos.
  uint64_t sum = 0;
  uint64_t nonblack = 0;
  int sx = fb.w > 512 ? fb.w / 2 - 256 : 0;
  int sy = fb.h > 512 ? fb.h / 2 - 256 : 0;
  int sw = fb.w > 512 ? 512 : fb.w;
  int sh = fb.h > 512 ? 512 : fb.h;
  for (int y = 0; y < sh; y++) {
    const uint8_t* row = fb.data + ((size_t)(sy + y)) * fb.stride;
    for (int x = 0; x < sw; x++) {
      const uint8_t* p = row + (size_t)(sx + x) * 4;
      uint32_t v = (uint32_t)p[0] + p[1] + p[2];
      sum += v;
      if (v > 30) nonblack++;
    }
  }
  uint64_t n = (uint64_t)sw * sh;
  fl_value_set_string_take(map, "avgRGB",
                           fl_value_new_int((int64_t)(sum / (n > 0 ? n : 1))));
  fl_value_set_string_take(map, "nonBlack",
                           fl_value_new_int((int64_t)nonblack));
  fl_value_set_string_take(map, "sampled",
                           fl_value_new_int((int64_t)n));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(map));
}

static FlMethodResponse* handle_list_audio_devices(TomatoPlayerPlugin* self) {
  if (self->engine == nullptr || self->engine->mpv == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "not_created", "player não criado", nullptr));
  }
  // audio-device-list e um node array de maps {name, description, ...}. O
  // player so precisa de nome + rotulo legivel para o seletor da UI.
  mpv_node* node = nullptr;
  if (mpv_get_property(self->engine->mpv, "audio-device-list", MPV_FORMAT_NODE,
                       &node) < 0 ||
      node == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_list()));
  }
  FlValue* list = fl_value_new_list();
  if (node->format == MPV_FORMAT_NODE_ARRAY && node->u.list != nullptr) {
    for (int i = 0; i < node->u.list->num; i++) {
      mpv_node* t = &node->u.list->values[i];
      if (t->format != MPV_FORMAT_NODE_MAP) continue;
      char* name = nullptr;
      char* desc = nullptr;
      for (int j = 0; j < t->u.list->num; j++) {
        const char* k = t->u.list->keys[j];
        mpv_node* v = &t->u.list->values[j];
        if (v->format != MPV_FORMAT_STRING) continue;
        if (!strcmp(k, "name")) name = v->u.string;
        else if (!strcmp(k, "description")) desc = v->u.string;
      }
      if (name == nullptr) continue;
      FlValue* entry = fl_value_new_map();
      fl_value_set_string_take(entry, "name", fl_value_new_string(name));
      fl_value_set_string_take(entry, "description",
                               fl_value_new_string(desc != nullptr ? desc : name));
      fl_value_append_take(list, entry);
    }
  }
  mpv_free_node_contents(node);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(list));
}

static FlMethodResponse* handle_set_property(TomatoPlayerPlugin* self,
                                             FlValue* args) {
  if (self->engine == nullptr || self->engine->mpv == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "not_created", "player não criado", nullptr));
  }
  FlValue* name_value = fl_value_lookup_string(args, "name");
  FlValue* value = fl_value_lookup_string(args, "value");
  if (name_value == nullptr ||
      fl_value_get_type(name_value) != FL_VALUE_TYPE_STRING ||
      value == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_property", "name/value inválidos", nullptr));
  }
  const char* name = fl_value_get_string(name_value);
  switch (fl_value_get_type(value)) {
    case FL_VALUE_TYPE_BOOL: {
      int flag = fl_value_get_bool(value) ? 1 : 0;
      mpv_set_property(self->engine->mpv, name, MPV_FORMAT_FLAG, &flag);
      break;
    }
    case FL_VALUE_TYPE_INT: {
      int64_t v = fl_value_get_int(value);
      mpv_set_property(self->engine->mpv, name, MPV_FORMAT_INT64, &v);
      break;
    }
    case FL_VALUE_TYPE_FLOAT: {
      double v = fl_value_get_float(value);
      mpv_set_property(self->engine->mpv, name, MPV_FORMAT_DOUBLE, &v);
      break;
    }
    case FL_VALUE_TYPE_STRING: {
      const char* v = fl_value_get_string(value);
      mpv_set_property_string(self->engine->mpv, name, v);
      break;
    }
    default:
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "invalid_property", "tipo de valor não suportado", nullptr));
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static gboolean delete_engine_cb(gpointer data) {
  delete static_cast<Engine*>(data);
  return G_SOURCE_REMOVE;
}

static gboolean release_texture_cb(gpointer data) {
  g_object_unref(data);
  return G_SOURCE_REMOVE;
}

static void stop_engine(TomatoPlayerPlugin* self) {
  if (self->engine == nullptr) return;
  Engine* engine = self->engine;
  engine->Stop();

  if (self->texture != nullptr) {
    TomatoTexture* texture = self->texture;
    g_mutex_lock(&texture->plugin_mutex);
    texture->plugin = nullptr;
    g_mutex_unlock(&texture->plugin_mutex);
    fl_texture_registrar_unregister_texture(self->texture_registrar,
                                            FL_TEXTURE(texture));
    self->texture = nullptr;
    // copy_pixels pode estar no raster thread; solta a textura depois que o
    // Flutter terminou o ultimo upload, junto com o engine.
    g_timeout_add(100, release_texture_cb, texture);
  }
  self->has_texture = FALSE;
  self->texture_id = 0;

  if (engine->render_ctx != nullptr) {
    mpv_render_context_free(engine->render_ctx);
    engine->render_ctx = nullptr;
  }
  if (engine->mpv != nullptr) {
    mpv_terminate_destroy(engine->mpv);
    engine->mpv = nullptr;
  }
  self->engine = nullptr;
  // copy_pixels roda no raster thread do Flutter e pode ter acabado de
  // devolver o ponteiro do ultimo frame. Destruir o engine aqui liberava esse
  // buffer no meio do upload; um giro do main loop da tempo do Flutter copiar.
  g_timeout_add(100, delete_engine_cb, engine);
}

static FlMethodResponse* handle_dispose(TomatoPlayerPlugin* self, FlValue*) {
  stop_engine(self);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static void tomato_player_plugin_handle_method_call(
    TomatoPlayerPlugin* self, FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  FlMethodResponse* response = nullptr;
  if (strcmp(method, "create") == 0) {
    response = handle_create(self, args);
  } else if (strcmp(method, "open") == 0) {
    response = handle_open(self, args);
  } else if (strcmp(method, "play") == 0) {
    response = handle_play(self, args);
  } else if (strcmp(method, "pause") == 0) {
    response = handle_pause(self, args);
  } else if (strcmp(method, "seek") == 0) {
    response = handle_seek(self, args);
  } else if (strcmp(method, "setOutputSize") == 0) {
    response = handle_set_output_size(self, args);
  } else if (strcmp(method, "setProperty") == 0) {
    response = handle_set_property(self, args);
  } else if (strcmp(method, "listAudioDevices") == 0) {
    response = handle_list_audio_devices(self);
  } else if (strcmp(method, "debugFrame") == 0) {
    response = handle_debug_frame(self, args);
  } else if (strcmp(method, "disposePlayer") == 0) {
    response = handle_dispose(self, args);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(FlMethodResponse) owned = response;
  fl_method_call_respond(method_call, owned, nullptr);
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  TomatoPlayerPlugin* plugin = TOMATO_PLAYER_PLUGIN(user_data);
  tomato_player_plugin_handle_method_call(plugin, method_call);
}

// ---------------------------------------------------------------------------
// GObject plugin.
// ---------------------------------------------------------------------------
static void tomato_player_plugin_dispose(GObject* object) {
  TomatoPlayerPlugin* self = TOMATO_PLAYER_PLUGIN(object);
  stop_engine(self);
  if (self->channel != nullptr) {
    g_object_unref(self->channel);
    self->channel = nullptr;
  }
  G_OBJECT_CLASS(tomato_player_plugin_parent_class)->dispose(object);
}

static void tomato_player_plugin_class_init(TomatoPlayerPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = tomato_player_plugin_dispose;
}

static void tomato_player_plugin_init(TomatoPlayerPlugin* self) {
  self->engine = nullptr;
  self->channel = nullptr;
  self->texture_registrar = nullptr;
  self->texture = nullptr;
  self->texture_id = 0;
  self->has_texture = FALSE;
}

void tomato_player_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  TomatoPlayerPlugin* plugin = TOMATO_PLAYER_PLUGIN(
      g_object_new(tomato_player_plugin_get_type(), nullptr));

  plugin->texture_registrar = fl_plugin_registrar_get_texture_registrar(registrar);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), CHANNEL_NAME,
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(plugin->channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}