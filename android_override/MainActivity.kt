package com.example.my_ebook_reader

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity: FlutterActivity() {
    private val METHOD_CHANNEL = "ebook_reader/volume_control"
    private val EVENT_CHANNEL = "ebook_reader/volume_events"
    private val PDF_CHANNEL = "ebook_reader/pdf_renderer"

    private var eventSink: EventChannel.EventSink? = null
    private var isVolumeInterceptEnabled = false

    // 음량 버튼 2개(UP + DOWN) 동시 누름 감지용 상태
    private var isVolUpPressed = false
    private var isVolDownPressed = false
    private var comboTriggered = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingVolUpRunnable: Runnable? = null
    private var pendingVolDownRunnable: Runnable? = null

    // S펜 호버 버튼 및 에어 액션 초고속 반응 처리용 타임스탬프
    private var lastSpenSingleTime = 0L
    private var wasStylusButtonPressed = false
    private var mediaSession: MediaSession? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupSpenMediaSession()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "setIntercept") {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    isVolumeInterceptEnabled = enabled
                    updateMediaSessionState(enabled)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PDF_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "renderPdfToImages") {
                    val pdfPath = call.argument<String>("pdfPath")
                    val outDirPath = call.argument<String>("outDirPath")
                    if (pdfPath == null || outDirPath == null) {
                        result.error("INVALID_ARGS", "Missing paths", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val outDir = File(outDirPath)
                            if (!outDir.exists()) outDir.mkdirs()
                            val pfd = ParcelFileDescriptor.open(File(pdfPath), ParcelFileDescriptor.MODE_READ_ONLY)
                            val renderer = PdfRenderer(pfd)
                            val pagePaths = ArrayList<String>()

                            for (i in 0 until renderer.pageCount) {
                                val pageFile = File(outDir, "page_${String.format("%04d", i)}.png")
                                if (!pageFile.exists()) {
                                    val page = renderer.openPage(i)
                                    val width = (page.width * 2).coerceAtLeast(1080)
                                    val height = (page.height * 2).coerceAtLeast(1520)
                                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                                    bitmap.eraseColor(Color.WHITE)
                                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                    page.close()
                                    FileOutputStream(pageFile).use { out ->
                                        bitmap.compress(Bitmap.CompressFormat.PNG, 90, out)
                                    }
                                    bitmap.recycle()
                                }
                                pagePaths.add(pageFile.absolutePath)
                            }
                            renderer.close()
                            pfd.close()
                            runOnUiThread { result.success(pagePaths) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("PDF_ERR", e.message, null) }
                        }
                    }.start()
                } else {
                    result.notImplemented()
                }
            }
    }

    // S펜 1번 클릭(다음 페이지) / 2번 연속 클릭(이전 페이지) 딜레이 0초 즉시 반응!
    private fun handleInstantSpenClick() {
        val now = SystemClock.uptimeMillis()
        if (now - lastSpenSingleTime <= 480L) {
            // 0.48초 이내에 두 번째 클릭이 들어오면 즉시 이전 페이지로 복귀(직전 1페이지 전진분 + 1페이지 후진 = 총 2페이지 후진 신호)
            lastSpenSingleTime = 0L
            eventSink?.success("SPEN_DOUBLE_REVERT")
        } else {
            lastSpenSingleTime = now
            eventSink?.success("SPEN_SINGLE")
        }
    }

    // 삼성 One UI가 자체적으로 S펜 2번 클릭을 감지해 보낸 신호(MEDIA_NEXT / SKIP_TO_NEXT / PAGE_UP 등)는 즉시 이전 페이지(SPEN_DOUBLE)로 실행!
    private fun handleDirectSpenDouble() {
        lastSpenSingleTime = 0L
        eventSink?.success("SPEN_DOUBLE")
    }

    private fun setupSpenMediaSession() {
        try {
            mediaSession = MediaSession(this, "FReaderSpenSession").apply {
                setCallback(object : MediaSession.Callback() {
                    override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                        val ke = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT, KeyEvent::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            mediaButtonIntent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
                        }
                        if (ke != null && isVolumeInterceptEnabled) {
                            if (ke.action == KeyEvent.ACTION_DOWN && ke.repeatCount == 0) {
                                when (ke.keyCode) {
                                    // 핵심 수정: 갤럭시 탭에서 S펜 버튼을 2번 누르면 삼성 One UI가 MEDIA_NEXT(다음 곡)를 전송합니다!
                                    // 이를 즉시 이전 페이지(SPEN_DOUBLE)로 매핑하여 S펜 2번 클릭이 100% 작동하도록 수정!
                                    KeyEvent.KEYCODE_MEDIA_NEXT,
                                    KeyEvent.KEYCODE_MEDIA_PREVIOUS -> {
                                        handleDirectSpenDouble()
                                        return true
                                    }
                                    KeyEvent.KEYCODE_MEDIA_PLAY,
                                    KeyEvent.KEYCODE_MEDIA_PAUSE,
                                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                                    KeyEvent.KEYCODE_HEADSETHOOK -> {
                                        handleInstantSpenClick()
                                        return true
                                    }
                                }
                            }
                            return true
                        }
                        return super.onMediaButtonEvent(mediaButtonIntent)
                    }

                    override fun onPlay() {
                        if (isVolumeInterceptEnabled) handleInstantSpenClick()
                    }

                    override fun onPause() {
                        if (isVolumeInterceptEnabled) handleInstantSpenClick()
                    }

                    override fun onSkipToNext() {
                        if (isVolumeInterceptEnabled) handleDirectSpenDouble()
                    }

                    override fun onSkipToPrevious() {
                        if (isVolumeInterceptEnabled) handleDirectSpenDouble()
                    }
                })
                @Suppress("DEPRECATION")
                setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
            }
        } catch (_: Exception) {}
    }

    private fun playSilentAudioPulse() {
        Thread {
            try {
                val sampleRate = 8000
                val bufferSize = AudioTrack.getMinBufferSize(
                    sampleRate,
                    AudioFormat.CHANNEL_OUT_MONO,
                    AudioFormat.ENCODING_PCM_16BIT
                ).coerceAtLeast(800)
                val audioTrack = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(sampleRate)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .build()
                    )
                    .setBufferSizeInBytes(bufferSize)
                    .setTransferMode(AudioTrack.MODE_STATIC)
                    .build()
                val silence = ByteArray(bufferSize)
                audioTrack.write(silence, 0, silence.size)
                audioTrack.play()
                Thread.sleep(60)
                audioTrack.stop()
                audioTrack.release()
            } catch (_: Exception) {}
        }.start()
    }

    private fun updateMediaSessionState(enabled: Boolean) {
        try {
            val session = mediaSession ?: return
            if (enabled) {
                val state = PlaybackState.Builder()
                    .setActions(
                        PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_SKIP_TO_NEXT or
                        PlaybackState.ACTION_SKIP_TO_PREVIOUS
                    )
                    .setState(PlaybackState.STATE_PLAYING, 0L, 1.0f)
                    .build()
                session.setPlaybackState(state)
                session.isActive = true
                playSilentAudioPulse()
            } else {
                val state = PlaybackState.Builder()
                    .setState(PlaybackState.STATE_STOPPED, 0L, 0.0f)
                    .build()
                session.setPlaybackState(state)
                session.isActive = false
            }
        } catch (_: Exception) {}
    }

    override fun onResume() {
        super.onResume()
        if (isVolumeInterceptEnabled) {
            updateMediaSessionState(true)
        }
    }

    override fun onDestroy() {
        try {
            mediaSession?.isActive = false
            mediaSession?.release()
        } catch (_: Exception) {}
        super.onDestroy()
    }

    private fun checkStylusButtonEvent(ev: MotionEvent?): Boolean {
        if (ev == null) return false
        var isStylus = ev.isFromSource(InputDevice.SOURCE_STYLUS)
        if (!isStylus && ev.pointerCount > 0) {
            val tool = ev.getToolType(0)
            isStylus = (tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_ERASER)
        }
        if (isStylus) {
            val isPressed = (ev.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY) != 0 ||
                            (ev.buttonState and MotionEvent.BUTTON_STYLUS_SECONDARY) != 0 ||
                            (ev.buttonState and MotionEvent.BUTTON_SECONDARY) != 0 ||
                            (ev.buttonState and MotionEvent.BUTTON_TERTIARY) != 0
            if (isPressed && !wasStylusButtonPressed) {
                wasStylusButtonPressed = true
                handleInstantSpenClick()
                return true
            } else if (!isPressed) {
                wasStylusButtonPressed = false
            }
        }
        return false
    }

    override fun dispatchGenericMotionEvent(ev: MotionEvent?): Boolean {
        if (isVolumeInterceptEnabled && checkStylusButtonEvent(ev)) {
            return true
        }
        return super.dispatchGenericMotionEvent(ev)
    }

    override fun dispatchTouchEvent(ev: MotionEvent?): Boolean {
        if (isVolumeInterceptEnabled) {
            checkStylusButtonEvent(ev)
        }
        return super.dispatchTouchEvent(ev)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (isVolumeInterceptEnabled) {
            val keyCode = event.keyCode
            val action = event.action

            // 1. 음량 버튼 (단독 누름 시 페이지 이동 / 2개 동시 누름 시 화면 터치 잠금 해제)
            if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
                if (action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    isVolUpPressed = true
                    if (isVolDownPressed) {
                        comboTriggered = true
                        pendingVolDownRunnable?.let { mainHandler.removeCallbacks(it) }
                        pendingVolUpRunnable?.let { mainHandler.removeCallbacks(it) }
                        eventSink?.success("VOL_BOTH_UNLOCK")
                        return true
                    }
                    val r = Runnable {
                        if (!comboTriggered) {
                            eventSink?.success("UP")
                        }
                    }
                    pendingVolUpRunnable = r
                    mainHandler.postDelayed(r, 85L)
                } else if (action == KeyEvent.ACTION_UP) {
                    isVolUpPressed = false
                    if (!isVolDownPressed) comboTriggered = false
                }
                return true
            }

            if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
                if (action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    isVolDownPressed = true
                    if (isVolUpPressed) {
                        comboTriggered = true
                        pendingVolUpRunnable?.let { mainHandler.removeCallbacks(it) }
                        pendingVolDownRunnable?.let { mainHandler.removeCallbacks(it) }
                        eventSink?.success("VOL_BOTH_UNLOCK")
                        return true
                    }
                    val r = Runnable {
                        if (!comboTriggered) {
                            eventSink?.success("DOWN")
                        }
                    }
                    pendingVolDownRunnable = r
                    mainHandler.postDelayed(r, 85L)
                } else if (action == KeyEvent.ACTION_UP) {
                    isVolDownPressed = false
                    if (!isVolUpPressed) comboTriggered = false
                }
                return true
            }

            // 2. 삼성 S펜 2번 클릭 신호(PAGE_UP, MEDIA_NEXT, MEDIA_PREVIOUS, DPAD_LEFT, DPAD_UP) -> 딜레이 없이 즉시 이전 페이지!
            if (keyCode == KeyEvent.KEYCODE_PAGE_UP ||
                keyCode == KeyEvent.KEYCODE_DPAD_LEFT ||
                keyCode == KeyEvent.KEYCODE_DPAD_UP ||
                keyCode == KeyEvent.KEYCODE_MEDIA_NEXT ||
                keyCode == KeyEvent.KEYCODE_MEDIA_PREVIOUS) {
                if (action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    handleDirectSpenDouble()
                }
                return true
            }

            // 3. 삼성 S펜 1번 클릭 신호(PAGE_DOWN, DPAD_RIGHT, SPACE, ENTER, PLAY_PAUSE 등) -> 딜레이 없이 즉시 다음 페이지 (연속 2회 입력 시 즉시 이전 페이지 복귀)!
            if (keyCode == KeyEvent.KEYCODE_PAGE_DOWN ||
                keyCode == KeyEvent.KEYCODE_DPAD_RIGHT ||
                keyCode == KeyEvent.KEYCODE_DPAD_DOWN ||
                keyCode == KeyEvent.KEYCODE_SPACE ||
                keyCode == KeyEvent.KEYCODE_ENTER ||
                keyCode == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE ||
                keyCode == KeyEvent.KEYCODE_MEDIA_PLAY ||
                keyCode == KeyEvent.KEYCODE_MEDIA_PAUSE ||
                keyCode == KeyEvent.KEYCODE_HEADSETHOOK ||
                keyCode == KeyEvent.KEYCODE_F1 ||
                keyCode == KeyEvent.KEYCODE_F2) {
                if (action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    handleInstantSpenClick()
                }
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }
}
