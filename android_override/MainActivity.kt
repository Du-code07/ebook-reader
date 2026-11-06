package com.example.my_ebook_reader

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfDocument
import android.graphics.pdf.PdfRenderer
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.TranslatorOptions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kr.dogfoot.hwplib.reader.HWPReader
import kr.dogfoot.hwplib.tool.textextractor.TextExtractMethod
import kr.dogfoot.hwplib.tool.textextractor.TextExtractor
import java.io.File
import kr.dogfoot.hwplib.reader.HWPReader
import kr.dogfoot.hwplib.tool.textextractor.TextExtractMethod
import kr.dogfoot.hwplib.tool.textextractor.TextExtractor
import java.io.FileOutputStream
import kotlin.math.sqrt

class MainActivity : FlutterActivity(), SensorEventListener {
    private val METHOD_CHANNEL = "ebook_reader/volume_control"
    private val EVENT_CHANNEL = "ebook_reader/volume_events"
    private val PDF_CHANNEL = "ebook_reader/pdf_renderer"
    private val TRANSLATE_CHANNEL = "ebook_reader/mlkit_translate"

    private var isVolumeInterceptEnabled = false
    private var eventSink: EventChannel.EventSink? = null

    private var isVolUpPressed = false
    private var isVolDownPressed = false
    private var comboTriggered = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingVolUpRunnable: Runnable? = null
    private var pendingVolDownRunnable: Runnable? = null

    private var lastSpenSingleTime = 0L
    private var wasStylusButtonPressed = false
    private var mediaSession: MediaSession? = null

    // 3. 흔들어서 화면 잠그고 끄기(Shake to Lock/Unlock)용 가속도 센서
    private var sensorManager: SensorManager? = null
    private var accelerometer: Sensor? = null
    private var lastShakeTimestamp = 0L
    private var shakeCount = 0
    private var firstShakeTime = 0L

    private fun mapMlKitLangCode(code: String): String {
        val lower = code.trim().lowercase()
        return when {
            lower.startsWith("ja") -> TranslateLanguage.JAPANESE
            lower.startsWith("zh") -> TranslateLanguage.CHINESE
            lower.startsWith("ko") -> TranslateLanguage.KOREAN
            lower.startsWith("en") -> TranslateLanguage.ENGLISH
            else -> TranslateLanguage.KOREAN
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        setupSpenMediaSession()
        setupShakeSensor()

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

        // 1. Google ML Kit 공식 온디바이스 번역 채널 (Japanese, Chinese, Korean, English -> 설정 언어)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TRANSLATE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "translateText") {
                    val text = call.argument<String>("text") ?: ""
                    val sourceLang = call.argument<String>("sourceLang") ?: "ja"
                    val targetLang = call.argument<String>("targetLang") ?: "ko"
                    if (text.isBlank()) {
                        result.success("")
                        return@setMethodCallHandler
                    }
                    val srcCode = mapMlKitLangCode(sourceLang)
                    val tgtCode = mapMlKitLangCode(targetLang)
                    if (srcCode == tgtCode) {
                        result.success(text)
                        return@setMethodCallHandler
                    }
                    val options = TranslatorOptions.Builder()
                        .setSourceLanguage(srcCode)
                        .setTargetLanguage(tgtCode)
                        .build()
                    val translator = Translation.getClient(options)
                    val conditions = DownloadConditions.Builder().build()
                    translator.downloadModelIfNeeded(conditions)
                        .addOnSuccessListener {
                            translator.translate(text)
                                .addOnSuccessListener { translated ->
                                    translator.close()
                                    result.success(translated)
                                }
                                .addOnFailureListener { e ->
                                    translator.close()
                                    result.error("TRANSLATE_ERR", e.message, null)
                                }
                        }
                        .addOnFailureListener { e ->
                            translator.close()
                            result.error("MODEL_DOWNLOAD_ERR", e.message, null)
                        }
                } else if (call.method == "translateBatch") {
                    val texts = call.argument<List<String>>("texts") ?: emptyList()
                    val sourceLang = call.argument<String>("sourceLang") ?: "ja"
                    val targetLang = call.argument<String>("targetLang") ?: "ko"
                    if (texts.isEmpty()) {
                        result.success(emptyList<String>())
                        return@setMethodCallHandler
                    }
                    val srcCode = mapMlKitLangCode(sourceLang)
                    val tgtCode = mapMlKitLangCode(targetLang)
                    if (srcCode == tgtCode) {
                        result.success(texts)
                        return@setMethodCallHandler
                    }
                    val options = TranslatorOptions.Builder()
                        .setSourceLanguage(srcCode)
                        .setTargetLanguage(tgtCode)
                        .build()
                    val translator = Translation.getClient(options)
                    val conditions = DownloadConditions.Builder().build()
                    translator.downloadModelIfNeeded(conditions)
                        .addOnSuccessListener {
                            val translatedList = MutableList(texts.size) { "" }
                            var remaining = texts.size
                            for (index in texts.indices) {
                                val item = texts[index]
                                if (item.isBlank()) {
                                    translatedList[index] = ""
                                    remaining--
                                    if (remaining == 0) {
                                        translator.close()
                                        result.success(translatedList)
                                    }
                                } else {
                                    translator.translate(item)
                                        .addOnSuccessListener { res ->
                                            translatedList[index] = res
                                            remaining--
                                            if (remaining == 0) {
                                                translator.close()
                                                result.success(translatedList)
                                            }
                                        }
                                        .addOnFailureListener {
                                            translatedList[index] = item
                                            remaining--
                                            if (remaining == 0) {
                                                translator.close()
                                                result.success(translatedList)
                                            }
                                        }
                                }
                            }
                        }
                        .addOnFailureListener { e ->
                            translator.close()
                            result.error("MODEL_DOWNLOAD_ERR", e.message, null)
                        }
                } else {
                    result.notImplemented()
                }
            }

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
                                val pageFile = File(outDir, "page_${String.format("%04d", i)}.jpg")
                                if (!pageFile.exists() || pageFile.length() == 0L) {
                                    val page = renderer.openPage(i)
                                    val scale = (1440f / page.width.toFloat().coerceAtLeast(1f)).coerceIn(1.5f, 2.5f)
                                    val width = (page.width * scale).toInt().coerceAtLeast(720)
                                    val height = (page.height * scale).toInt().coerceAtLeast(960)
                                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                                    bitmap.eraseColor(Color.WHITE)
                                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                    page.close()
                                    FileOutputStream(pageFile).use { out ->
                                        bitmap.compress(Bitmap.CompressFormat.JPEG, 90, out)
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
                } else if (call.method == "mergePdfs") {
                    val inputPaths = call.argument<List<String>>("inputPaths")
                    val outputPath = call.argument<String>("outputPath")
                    if (inputPaths == null || inputPaths.isEmpty() || outputPath == null) {
                        result.error("INVALID_ARGS", "Missing inputPaths or outputPath", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val outPdf = PdfDocument()
                        try {
                            var globalPageNumber = 1
                            for (path in inputPaths) {
                                val f = File(path)
                                if (!f.exists()) continue
                                val pfd = ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
                                val renderer = PdfRenderer(pfd)
                                for (i in 0 until renderer.pageCount) {
                                    val srcPage = renderer.openPage(i)
                                    val scale = (1440f / srcPage.width.toFloat().coerceAtLeast(1f)).coerceIn(1.5f, 2.2f)
                                    val w = (srcPage.width * scale).toInt().coerceAtLeast(720)
                                    val h = (srcPage.height * scale).toInt().coerceAtLeast(960)
                                    val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                                    bitmap.eraseColor(Color.WHITE)
                                    srcPage.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                    srcPage.close()

                                    val pageInfo = PdfDocument.PageInfo.Builder(w, h, globalPageNumber++).create()
                                    val destPage = outPdf.startPage(pageInfo)
                                    destPage.canvas.drawBitmap(bitmap, 0f, 0f, null)
                                    outPdf.finishPage(destPage)
                                    bitmap.recycle()
                                }
                                renderer.close()
                                pfd.close()
                            }
                            val outFile = File(outputPath)
                            outFile.parentFile?.mkdirs()
                            FileOutputStream(outFile).use { outStream ->
                                outPdf.writeTo(outStream)
                            }
                            outPdf.close()
                            runOnUiThread { result.success(outFile.absolutePath) }
                        } catch (e: Exception) {
                            try { outPdf.close() } catch (_: Exception) {}
                            runOnUiThread { result.error("MERGE_PDF_ERR", e.message, null) }
                        }
                    }.start()
                } else if (call.method == "extractHwpText") {
                    val hwpPath = call.argument<String>("hwpPath")
                    if (hwpPath == null) {
                        result.error("INVALID_ARGS", "Missing hwpPath", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val hwpFile = HWPReader.fromFile(hwpPath)
                            val extractedText = TextExtractor.extract(
                                hwpFile,
                                TextExtractMethod.InsertControlTextBetweenParagraphText
                            )
                            runOnUiThread { result.success(extractedText ?: "") }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("HWP_ERR", e.message, null) }
                        }
                    }.start()
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun setupShakeSensor() {
        try {
            sensorManager = getSystemService(Context.SENSOR_SERVICE) as? SensorManager
            accelerometer = sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        } catch (_: Exception) {}
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (event == null || !isVolumeInterceptEnabled) return
        if (event.sensor.type == Sensor.TYPE_ACCELEROMETER) {
            val x = event.values[0]
            val y = event.values[1]
            val z = event.values[2]
            val gX = x / SensorManager.GRAVITY_EARTH
            val gY = y / SensorManager.GRAVITY_EARTH
            val gZ = z / SensorManager.GRAVITY_EARTH
            val gForce = sqrt(gX * gX + gY * gY + gZ * gZ)

            if (gForce > 2.25f) {
                val now = SystemClock.uptimeMillis()
                if (now - lastShakeTimestamp < 900L) return
                if (now - firstShakeTime > 650L) {
                    shakeCount = 1
                    firstShakeTime = now
                } else {
                    shakeCount++
                    if (shakeCount >= 2) {
                        shakeCount = 0
                        lastShakeTimestamp = now
                        eventSink?.success("SHAKE_TOGGLE")
                    }
                }
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private fun handleInstantSpenClick() {
        val now = SystemClock.uptimeMillis()
        if (now - lastSpenSingleTime <= 480L) {
            lastSpenSingleTime = 0L
            eventSink?.success("SPEN_DOUBLE_REVERT")
        } else {
            lastSpenSingleTime = now
            eventSink?.success("SPEN_SINGLE")
        }
    }

    private fun handleDirectSpenDouble() {
        lastSpenSingleTime = 0L
        eventSink?.success("SPEN_DOUBLE")
    }

    private fun setupSpenMediaSession() {
        try {
            mediaSession = MediaSession(this, "FReaderSpenSession").apply {
                setCallback(object : MediaSession.Callback() {
                    override fun onMediaButtonEvent(mediaButtonIntent: android.content.Intent): Boolean {
                        @Suppress("DEPRECATION")
                        val ke = mediaButtonIntent.getParcelableExtra<KeyEvent>(android.content.Intent.EXTRA_KEY_EVENT)
                        if (ke != null && isVolumeInterceptEnabled) {
                            if (ke.action == KeyEvent.ACTION_DOWN && ke.repeatCount == 0) {
                                when (ke.keyCode) {
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
                val numSamples = sampleRate / 20
                val generatedSnd = ByteArray(2 * numSamples)
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
                    .setBufferSizeInBytes(generatedSnd.size)
                    .setTransferMode(AudioTrack.MODE_STATIC)
                    .build()
                audioTrack.write(generatedSnd, 0, generatedSnd.size)
                audioTrack.play()
                Thread.sleep(60)
                audioTrack.stop()
                audioTrack.release()
            } catch (_: Exception) {}
        }.start()
    }

    private fun updateMediaSessionState(enabled: Boolean) {
        try {
            mediaSession?.let { session ->
                if (enabled) {
                    val state = PlaybackState.Builder()
                        .setActions(
                            PlaybackState.ACTION_PLAY or
                            PlaybackState.ACTION_PAUSE or
                            PlaybackState.ACTION_PLAY_PAUSE or
                            PlaybackState.ACTION_SKIP_TO_NEXT or
                            PlaybackState.ACTION_SKIP_TO_PREVIOUS
                        )
                        .setState(PlaybackState.STATE_PLAYING, 1L, 1.0f)
                        .build()
                    session.setPlaybackState(state)
                    session.isActive = true
                    playSilentAudioPulse()
                } else {
                    val state = PlaybackState.Builder()
                        .setState(PlaybackState.STATE_PAUSED, 1L, 0.0f)
                        .build()
                    session.setPlaybackState(state)
                    session.isActive = false
                }
            }
        } catch (_: Exception) {}
    }

    override fun onResume() {
        super.onResume()
        try {
            accelerometer?.let {
                sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_UI)
            }
        } catch (_: Exception) {}
        if (isVolumeInterceptEnabled) {
            updateMediaSessionState(true)
        }
    }

    override fun onPause() {
        try {
            sensorManager?.unregisterListener(this)
        } catch (_: Exception) {}
        super.onPause()
    }

    override fun onDestroy() {
        try {
            sensorManager?.unregisterListener(this)
            mediaSession?.isActive = false
            mediaSession?.release()
        } catch (_: Exception) {}
        super.onDestroy()
    }

    private fun checkStylusButtonEvent(ev: MotionEvent?): Boolean {
        if (ev == null) return false
        var isStylus = ev.isFromSource(InputDevice.SOURCE_STYLUS)
        if (!isStylus && ev.pointerCount > 0) {
            val toolType = ev.getToolType(0)
            isStylus = toolType == MotionEvent.TOOL_TYPE_STYLUS || toolType == MotionEvent.TOOL_TYPE_ERASER
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
        val keyCode = event.keyCode
        val action = event.action

        if (isVolumeInterceptEnabled) {
            // 1. 음량 버튼 동시 입력 시 화면 잠금 토글(VOL_BOTH_UNLOCK) 및 단독 입력 시 페이지 넘김
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

            if (keyCode == KeyEvent.KEYCODE_PAGE_DOWN ||
                keyCode == KeyEvent.KEYCODE_DPAD_RIGHT ||
                keyCode == KeyEvent.KEYCODE_DPAD_DOWN ||
                keyCode == KeyEvent.KEYCODE_SPACE ||
                keyCode == KeyEvent.KEYCODE_ENTER ||
                keyCode == KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE ||
                keyCode == KeyEvent.KEYCODE_MEDIA_PLAY ||
                keyCode == KeyEvent.KEYCODE_MEDIA_PAUSE ||
                keyCode == KeyEvent.KEYCODE_CAMERA ||
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
