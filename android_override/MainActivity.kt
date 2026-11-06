package com.example.my_ebook_reader

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
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

    // 갤럭시 S펜 버튼 1번 클릭(다음 페이지) / 2번 연속 클릭(이전 페이지) 감지용 상태
    private var spenClickCount = 0
    private var pendingSpenRunnable: Runnable? = null
    private var wasStylusButtonPressed = false

    // 핵심: 삼성 One UI의 S펜 에어 액션(Air Actions)이 별도 설정 없이도 즉시 버튼 클릭 신호를 보내도록 만드는 MediaSession!
    // 삼성 공식 문서(S Pen Remote FAQ Q3): 앱이 활성 MediaSession을 가지면 S펜 버튼 1번/2번 클릭이 즉시 MediaSession으로 전달됩니다.
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
                                    KeyEvent.KEYCODE_MEDIA_NEXT -> {
                                        // 삼성 에어 액션에서 2번 클릭을 MEDIA_NEXT로 보낼 때와 1번 클릭(PLAY_PAUSE)을 모두 통합 처리
                                        triggerSpenButtonPress()
                                        return true
                                    }
                                    KeyEvent.KEYCODE_MEDIA_PREVIOUS -> {
                                        eventSink?.success("SPEN_DOUBLE")
                                        return true
                                    }
                                    KeyEvent.KEYCODE_MEDIA_PLAY,
                                    KeyEvent.KEYCODE_MEDIA_PAUSE,
                                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                                    KeyEvent.KEYCODE_HEADSETHOOK -> {
                                        triggerSpenButtonPress()
                                        return true
                                    }
                                }
                            }
                            return true
                        }
                        return super.onMediaButtonEvent(mediaButtonIntent)
                    }

                    override fun onPlay() {
                        if (isVolumeInterceptEnabled) triggerSpenButtonPress()
                    }

                    override fun onPause() {
                        if (isVolumeInterceptEnabled) triggerSpenButtonPress()
                    }

                    override fun onSkipToNext() {
                        if (isVolumeInterceptEnabled) eventSink?.success("SPEN_DOUBLE")
                    }

                    override fun onSkipToPrevious() {
                        if (isVolumeInterceptEnabled) eventSink?.success("SPEN_DOUBLE")
                    }
                })
                @Suppress("DEPRECATION")
                setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
            }
        } catch (_: Exception) {}
    }

    private fun playSilentAudioPulse() {
        // Android OS가 이 앱의 MediaSession을 최우선 활성 세션으로 등록하도록 0.05초 무음 오디오 펄스 재생
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

    private fun triggerSpenButtonPress() {
        spenClickCount++
        pendingSpenRunnable?.let { mainHandler.removeCallbacks(it) }
        if (spenClickCount >= 2) {
            spenClickCount = 0
            eventSink?.success("SPEN_DOUBLE")
        } else {
            val r = Runnable {
                if (spenClickCount == 1) {
                    eventSink?.success("SPEN_SINGLE")
                }
                spenClickCount = 0
            }
            pendingSpenRunnable = r
            mainHandler.postDelayed(r, 380L)
        }
    }

    // 갤럭시 S펜 호버 및 터치 상태에서 펜 옆면 버튼을 누를 때 발생하는 모든 스타일러스 버튼 이벤트 감지
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
                triggerSpenButtonPress()
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
                    mainHandler.postDelayed(r, 110L)
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
                    mainHandler.postDelayed(r, 110L)
                } else if (action == KeyEvent.ACTION_UP) {
                    isVolDownPressed = false
                    if (!isVolUpPressed) comboTriggered = false
                }
                return true
            }

            // 2. 삼성 S펜 RemoteActions(remote_action.xml) 및 블루투스 리모컨 키 감지
            // PAGE_UP / DPAD_LEFT / MEDIA_PREVIOUS가 직접 오면 즉시 이전 페이지(SPEN_DOUBLE)
            if (keyCode == KeyEvent.KEYCODE_PAGE_UP ||
                keyCode == KeyEvent.KEYCODE_DPAD_LEFT ||
                keyCode == KeyEvent.KEYCODE_DPAD_UP ||
                keyCode == KeyEvent.KEYCODE_MEDIA_PREVIOUS) {
                if (action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    eventSink?.success("SPEN_DOUBLE")
                }
                return true
            }

            // PAGE_DOWN / DPAD_RIGHT / SPACE / ENTER / MEDIA_PLAY_PAUSE 등은 1번 클릭 시 다음 페이지, 2번 연속 클릭 시 이전 페이지
            if (keyCode == KeyEvent.KEYCODE_PAGE_DOWN ||
                keyCode == KeyEvent.KEYCODE_DPAD_RIGHT ||
                keyCode == KeyEvent.KEYCODE_DPAD_DOWN ||
                keyCode == KeyEvent.KEYCODE_SPACE ||
                keyCode == KeyEvent.KEYCODE_ENTER ||
                keyCode == KeyEvent.KEYCODE_MEDIA_NEXT ||
                keyCode == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE ||
                keyCode == KeyEvent.KEYCODE_MEDIA_PLAY ||
                keyCode == KeyEvent.KEYCODE_MEDIA_PAUSE ||
                keyCode == KeyEvent.KEYCODE_HEADSETHOOK ||
                keyCode == KeyEvent.KEYCODE_F1 ||
                keyCode == KeyEvent.KEYCODE_F2) {
                if (action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    triggerSpenButtonPress()
                }
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }
}
