package br.com.tomatos.tomato_player

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.Surface

import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory

import io.flutter.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry

/**
 * Engine Android do tomato_player (Media3 ExoPlayer + SurfaceTexture).
 *
 * Contrato (mesmo do desktop): canal único `br.com.tomatos/tomato_player`,
 * com métodos create/open/play/pause/seek/setProperty/disposePlayer e o nativo
 * empurrando snapshots `state` (invokeMethod) no mesmo canal.
 */
@OptIn(UnstableApi::class)
class TomatoPlayerPlugin : FlutterPlugin, MethodCallHandler {

    private var channel: MethodChannel? = null
    private var textureRegistry: TextureRegistry? = null
    private var context: Context? = null

    private var player: ExoPlayer? = null
    // SurfaceProducer (e nao SurfaceTextureEntry): e a unica das duas APIs que
    // expoe setSize, que e o que permite a textura ficar na proporcao do VIDEO
    // (ver [syncSurfaceSize]).
    private var producer: TextureRegistry.SurfaceProducer? = null
    private var surface: Surface? = null
    private var streamName = "Tomato"
    private var volumePercent = 100.0
    private var muted = false

    // Ultimo tamanho aplicado na textura (ver [syncSurfaceSize]).
    private var textureW = 0
    private var textureH = 0

    // Polling leve de posição (o ExoPlayer não notifica change de time-pos).
    private val ticker = Handler(Looper.getMainLooper())
    private val tickerRunnable = object : Runnable {
        override fun run() {
            pushState()
            if (player != null) ticker.postDelayed(this, 250)
        }
    }

    private val listener = object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) = pushState()

        override fun onIsPlayingChanged(isPlaying: Boolean) = pushState()

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) = pushState()

        override fun onVideoSizeChanged(videoSize: VideoSize) = pushState()

        override fun onPlayerError(error: PlaybackException) = pushState()
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        textureRegistry = binding.textureRegistry
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "br.com.tomatos/tomato_player")
        channel?.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "create" -> handleCreate(result)
            "open" -> handleOpen(call, result)
            "play" -> handlePlay(result)
            "pause" -> handlePause(result)
            "seek" -> handleSeek(call, result)
            "setProperty" -> handleSetProperty(call, result)
            "listAudioDevices" -> handleListAudioDevices(result)
            "disposePlayer" -> handleDispose(result)
            else -> result.notImplemented()
        }
    }

    private fun handleCreate(result: Result) {
        if (player != null && producer != null) {
            result.success(mapOf("textureId" to producer!!.id()))
            return
        }
        val registry = textureRegistry
        val appContext = context
        if (registry == null || appContext == null) {
            result.error("texture_failed", "binding indisponível", null)
            return
        }
        try {
            val prod = registry.createSurfaceProducer()
            surface = prod.surface

            val exoPlayer = ExoPlayer.Builder(appContext)
                .setMediaSourceFactory(
                    DefaultMediaSourceFactory(
                        DefaultHttpDataSource.Factory()
                            .setUserAgent(streamName)
                            .setAllowCrossProtocolRedirects(true)
                            .setDefaultRequestProperties(mapOf("User-Agent" to streamName))
                    )
                )
                .setHandleAudioBecomingNoisy(true)
                .setWakeMode(C.WAKE_MODE_NETWORK)
                .build()
            exoPlayer.addListener(listener)
            exoPlayer.setVideoSurface(surface)
            exoPlayer.setAudioAttributes(
                AudioAttributes.Builder()
                    .setContentType(C.CONTENT_TYPE_MUSIC)
                    .setUsage(C.USAGE_MEDIA)
                    .build(),
                /* handleAudioFocus = */ true,
            )

            producer = prod
            player = exoPlayer
            applyVolume()
            result.success(mapOf("textureId" to prod.id()))
        } catch (e: Exception) {
            Log.e(TAG, "create falhou", e)
            result.error("init_failed", "falha ao criar o player: ${e.message}", null)
        }
    }

    private fun handleOpen(call: MethodCall, result: Result) {
        val exo = player
        if (exo == null) {
            result.error("not_created", "chame create() antes de open()", null)
            return
        }
        val uri = call.argument<String>("uri")
        if (uri == null) {
            result.error("invalid_uri", "uri ausente ou inválida", null)
            return
        }
        val headers = mutableMapOf<String, String>()
        (call.argument<Map<*, *>>("httpHeaders"))?.forEach { (k, v) ->
            if (k != null && v != null) headers[k.toString()] = v.toString()
        }
        headers["User-Agent"]?.let { streamName = it }

        try {
            val factory = DefaultMediaSourceFactory(
                DefaultHttpDataSource.Factory()
                    .setUserAgent(streamName)
                    .setAllowCrossProtocolRedirects(true)
                    .setDefaultRequestProperties(headers)
            )
            exo.setMediaSource(factory.createMediaSource(MediaItem.fromUri(uri)))
            exo.prepare()
            if (!tickerRegistered) {
                ticker.post(tickerRunnable)
                tickerRegistered = true
            }
            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "open falhou", e)
            result.error("open_failed", e.message, null)
        }
    }

    private var tickerRegistered = false

    private fun handlePlay(result: Result) {
        runCatching { player?.play() }
        result.success(null)
    }

    private fun handlePause(result: Result) {
        runCatching { player?.pause() }
        result.success(null)
    }

    private fun handleSeek(call: MethodCall, result: Result) {
        val ms = (call.argument<Number>("positionMs"))?.toLong() ?: 0L
        try {
            player?.seekTo(ms)
        } catch (e: Exception) {
            Log.e(TAG, "seek falhou", e)
        }
        result.success(null)
    }

    private fun handleSetProperty(call: MethodCall, result: Result) {
        val name = call.argument<String>("name")
        if (name == null) {
            result.error("invalid_property", "nome da propriedade ausente", null)
            return
        }
        when (name) {
            "volume" -> runCatching {
                val value = (call.argument<Number>("value"))?.toDouble() ?: 100.0
                volumePercent = value.coerceIn(0.0, 100.0)
                applyVolume()
            }
            "mute" -> runCatching {
                muted = call.argument<Boolean>("value") ?: false
                applyVolume()
            }
            "speed" -> runCatching {
                val s = (call.argument<Number>("value"))?.toFloat() ?: 1f
                player?.setPlaybackSpeed(s)
            }
            // Android routes audio through the system mixer; there is no
            // reliable per-app output device switch here.
            "audio-device" -> Unit
            else -> result.error("unknown_property", "propriedade não suportada: $name", null)
        }
        result.success(null)
    }

    private fun applyVolume() {
        val exo = player ?: return
        exo.volume = if (muted) 0f else (volumePercent / 100.0).toFloat().coerceIn(0f, 1f)
    }

    private fun handleListAudioDevices(result: Result) {
        // Empty list = the UI only offers "Automático" on Android.
        result.success(emptyList<Map<String, String>>())
    }

    private fun handleDispose(result: Result) {
        stopAndRelease()
        result.success(null)
    }

    private fun stopAndRelease() {
        ticker.removeCallbacks(tickerRunnable)
        tickerRegistered = false
        player?.removeListener(listener)
        player?.clearVideoSurface()
        player?.release()
        player = null
        // O SurfaceProducer e o dono do Surface: release() abaixo ja libera
        // ambos. Chamar surface.release() antes causava double-free nativo.
        surface = null
        producer?.let { runCatching { it.release() } }
        producer = null
        textureW = 0
        textureH = 0
    }

    private fun pushState() {
        val exo = player ?: return
        syncSurfaceSize(exo)
        val snapshot = HashMap<String, Any?>()
        snapshot["state"] = stateString(exo)
        snapshot["positionMs"] = exo.currentPosition
        snapshot["durationMs"] = exo.duration.takeIf { it > 0 } ?: 0L
        val bufferedRatio = if (exo.duration > 0) {
            exo.bufferedPosition.toDouble() / exo.duration.toDouble()
        } else 0.0
        snapshot["bufferingPercentage"] =
            (bufferedRatio.coerceIn(0.0, 1.0) * 100.0).toInt()
        snapshot["completed"] = exo.playbackState == Player.STATE_ENDED
        snapshot["videoWidth"] = exo.videoSize.width
        snapshot["videoHeight"] = exo.videoSize.height
        snapshot["volume"] = volumePercent
        snapshot["muted"] = muted
        snapshot["hasAudio"] = runCatching {
            exo.currentTracks.groups.any { it.type == C.TRACK_TYPE_AUDIO && it.isSupported }
        }.getOrDefault(false)
        snapshot["currentAo"] = "android"
        snapshot["audioDevice"] = "auto"
        val error = exo.playerError
        snapshot["error"] = error?.errorCodeName
        snapshot["errorCode"] = error?.errorCode?.toString()
        channel?.invokeMethod("state", snapshot)
    }

    /**
     * Mantem a textura com o tamanho do VIDEO, nunca o do widget.
     *
     * O ExoPlayer desenha o quadro na Surface respeitando a proporcao do
     * video: com a textura no tamanho do widget (que no modo "Expandir
     * AspectRatio" e a tela toda, bem diferente de 16:9), a tarja preta do
     * ExoPlayer ficaria EMBUTIDA no quadro — e nenhum alongamento feito no
     * Flutter surjiria efeito. Era exatamente o bug do mobile: a caixa crescia
     * e a imagem continuava igual.
     *
     * Com a textura na razao real do video nao existe tarja; quem estica a
     * imagem ate a borda passa a ser o Flutter, no `Texture` widget, e o
     * alongamento funciona igual em todas as plataformas.
     */
    private fun syncSurfaceSize(exo: ExoPlayer) {
        val prod = producer ?: return
        val w = exo.videoSize.width
        val h = exo.videoSize.height
        if (w <= 0 || h <= 0) return
        if (w == textureW && h == textureH) return
        textureW = w
        textureH = h
        runCatching { prod.setSize(w, h) }
    }

    private fun stateString(exo: ExoPlayer): String = when {
        exo.playerError != null -> "error"
        exo.playbackState == Player.STATE_IDLE -> "idle"
        exo.playbackState == Player.STATE_BUFFERING -> "buffering"
        exo.playbackState == Player.STATE_READY -> if (exo.isPlaying) "playing" else "paused"
        exo.playbackState == Player.STATE_ENDED -> "ended"
        else -> "loading"
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        stopAndRelease()
        textureRegistry = null
        context = null
    }

    companion object {
        private const val TAG = "TomatoPlayer"
    }
}