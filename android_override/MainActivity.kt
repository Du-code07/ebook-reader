package com.freader.my_ebook_reader

import android.app.Activity
import android.content.ClipData
import android.content.ContentProvider
import android.content.Context
import android.content.ContentValues
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.view.WindowManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.view.View
import android.webkit.WebView
import android.webkit.WebViewClient
import android.graphics.Bitmap
import android.graphics.Typeface
import android.graphics.BitmapFactory
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
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
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
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
    private var lastVolKeyDownTime = 0L
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

    private val CAMERA_SCAN_REQUEST_CODE = 9481
    private var pendingCameraResult: MethodChannel.Result? = null
    private var pendingCameraRawFile: File? = null
    private val autoHideStatusBarRunnable = Runnable { hideSystemStatusBar() }

    private fun scheduleAutoHideStatusBar(delayMs: Long = 1500L) {
        mainHandler.removeCallbacks(autoHideStatusBarRunnable)
        mainHandler.postDelayed(autoHideStatusBarRunnable, delayMs)
    }

    // 2 & 3. 태블릿(OneUI / Android 12L~16 대화면 모드)에서 상태표시줄을 숨기고, 손으로 끌어내렸을 때도 자동으로 다시 올라가게 처리
    private fun hideSystemStatusBar() {
        try {
            window.clearFlags(WindowManager.LayoutParams.FLAG_FORCE_NOT_FULLSCREEN)
            window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val lp = window.attributes
                lp.layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                } else {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
                window.attributes = lp
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                window.setDecorFitsSystemWindows(false)
                window.insetsController?.let { controller ->
                    controller.systemBarsBehavior =
                        android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    controller.hide(
                        android.view.WindowInsets.Type.statusBars() or
                            android.view.WindowInsets.Type.navigationBars()
                    )
                }
            }

            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                View.SYSTEM_UI_FLAG_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                    or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                    or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            )
        } catch (_: Exception) {}
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        try {
            WebView.enableSlowWholeDocumentDraw()
        } catch (_: Exception) {}
        super.onCreate(savedInstanceState)
        hideSystemStatusBar()

        // Android 11~16 태블릿에서 상단 상태표시줄을 손으로 내려서 나타났을 때 자동으로 다시 올라가도록 WindowInsets 감지
        window.decorView.setOnApplyWindowInsetsListener { v, insets ->
            val statusBarVisible = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                insets.isVisible(android.view.WindowInsets.Type.statusBars())
            } else {
                @Suppress("DEPRECATION")
                insets.systemWindowInsetTop > 0
            }
            if (statusBarVisible) {
                scheduleAutoHideStatusBar(1500L)
                mainHandler.postDelayed({ hideSystemStatusBar() }, 2800L)
            }
            v.onApplyWindowInsets(insets)
        }

        @Suppress("DEPRECATION")
        window.decorView.setOnSystemUiVisibilityChangeListener { visibility ->
            if ((visibility and View.SYSTEM_UI_FLAG_FULLSCREEN) == 0) {
                scheduleAutoHideStatusBar(1200L)
            }
        }
    }

    override fun onPostResume() {
        super.onPostResume()
        hideSystemStatusBar()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        hideSystemStatusBar()
        mainHandler.postDelayed({ hideSystemStatusBar() }, 150L)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            hideSystemStatusBar()
            mainHandler.postDelayed({ hideSystemStatusBar() }, 100L)
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
                } else if (call.method == "setScreenOrientation") {
                    val mode = call.argument<String>("mode") ?: "unspecified"
                    runOnUiThread {
                        requestedOrientation = when (mode) {
                            "landscape" -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                            "portrait" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                            else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                        }
                        result.success(true)
                    }
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
                if (call.method == "captureAndScanDocumentPage") {
                    if (pendingCameraResult != null) {
                        result.error("BUSY", "Camera scan already in progress", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val scanDir = File(cacheDir, "camera_scans")
                        if (!scanDir.exists()) scanDir.mkdirs()
                        val rawFile = File(scanDir, "raw_capture_${System.currentTimeMillis()}.jpg")
                        pendingCameraRawFile = rawFile
                        pendingCameraResult = result

                        val authority = "${applicationContext.packageName}.scanprovider"
                        val contentUri = Uri.parse("content://$authority/${rawFile.name}")

                        val cameraIntent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
                            putExtra(MediaStore.EXTRA_OUTPUT, contentUri)
                            clipData = ClipData.newRawUri("", contentUri)
                            addFlags(
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                            )
                        }
                        startActivityForResult(cameraIntent, CAMERA_SCAN_REQUEST_CODE)
                    } catch (e: Exception) {
                        pendingCameraResult = null
                        pendingCameraRawFile = null
                        result.error("CAMERA_ERR", e.message, null)
                    }
                } else if (call.method == "processScannedPageWithTextIsolation") {
                    val imagePath = call.argument<String>("imagePath")
                    val filterMode = call.argument<String>("filterMode") ?: "text_only_zero_margin"
                    val rawBoxes = call.argument<List<Map<String, Any>>>("textBoxes")
                    if (imagePath == null || !File(imagePath).exists()) {
                        result.error("INVALID_ARGS", "Missing imagePath", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val srcFile = File(imagePath)
                            val srcBmp = decodeAndOrientCameraBitmap(srcFile)
                            if (srcBmp == null) {
                                runOnUiThread { result.success(imagePath) }
                                return@Thread
                            }
                            val boxes = ArrayList<Rect>()
                            if (rawBoxes != null) {
                                for (b in rawBoxes) {
                                    val l = (b["left"] as? Number)?.toInt() ?: 0
                                    val t = (b["top"] as? Number)?.toInt() ?: 0
                                    val r = (b["right"] as? Number)?.toInt() ?: 0
                                    val bot = (b["bottom"] as? Number)?.toInt() ?: 0
                                    if (r > l && bot > t) {
                                        boxes.add(Rect(l, t, r, bot))
                                    }
                                }
                            }
                            val processedBmp = extractPureTextOnBlankPage(srcBmp, boxes, filterMode)
                            if (processedBmp !== srcBmp) {
                                srcBmp.recycle()
                            }
                            val scanDir = File(cacheDir, "camera_scans")
                            if (!scanDir.exists()) scanDir.mkdirs()
                            val outFile = File(scanDir, "pure_scan_${System.currentTimeMillis()}.jpg")
                            FileOutputStream(outFile).use { out ->
                                processedBmp.compress(Bitmap.CompressFormat.JPEG, 95, out)
                            }
                            processedBmp.recycle()
                            runOnUiThread { result.success(outFile.absolutePath) }
                        } catch (e: Exception) {
                            runOnUiThread { result.success(imagePath) }
                        }
                    }.start()
                } else if (call.method == "rotateScannedPageImage") {
                    val imagePath = call.argument<String>("imagePath")
                    if (imagePath == null || !File(imagePath).exists()) {
                        result.success(imagePath)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val f = File(imagePath)
                            val bmp = BitmapFactory.decodeFile(f.absolutePath)
                            if (bmp == null) {
                                runOnUiThread { result.success(imagePath) }
                                return@Thread
                            }
                            val matrix = Matrix().apply { postRotate(90f) }
                            val rotated = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, matrix, true)
                            if (rotated !== bmp) bmp.recycle()
                            val outFile = File(f.parentFile, "rot_${System.currentTimeMillis()}.jpg")
                            FileOutputStream(outFile).use { out ->
                                rotated.compress(Bitmap.CompressFormat.JPEG, 95, out)
                            }
                            rotated.recycle()
                            try { f.delete() } catch (_: Exception) {}
                            runOnUiThread { result.success(outFile.absolutePath) }
                        } catch (e: Exception) {
                            runOnUiThread { result.success(imagePath) }
                        }
                    }.start()
                } else if (call.method == "createScannedPdfFromImages") {
                    val imagePaths = call.argument<List<String>>("imagePaths")
                    val outputPath = call.argument<String>("outputPath")
                    if (imagePaths.isNullOrEmpty() || outputPath == null) {
                        result.error("INVALID_ARGS", "Missing imagePaths or outputPath", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val pdfDoc = PdfDocument()
                        try {
                            var pageNum = 1
                            for (imgPath in imagePaths) {
                                val f = File(imgPath)
                                if (!f.exists()) continue
                                val bmp = BitmapFactory.decodeFile(f.absolutePath) ?: continue
                                // 스캔본의 글만 인식해서 빈 종이에 여백 없이(0px margin) 꽉 차게 배치!
                                val pageW = 1240
                                val aspect = bmp.height.toFloat() / bmp.width.toFloat().coerceAtLeast(1f)
                                val pageH = (pageW * aspect).toInt().coerceIn(360, 3400)

                                val pageInfo = PdfDocument.PageInfo.Builder(pageW, pageH, pageNum++).create()
                                val page = pdfDoc.startPage(pageInfo)
                                page.canvas.drawColor(Color.WHITE)
                                val dstRect = RectF(0f, 0f, pageW.toFloat(), pageH.toFloat())
                                val paint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
                                page.canvas.drawBitmap(bmp, null, dstRect, paint)
                                pdfDoc.finishPage(page)
                                bmp.recycle()
                            }
                            val outFile = File(outputPath)
                            outFile.parentFile?.mkdirs()
                            FileOutputStream(outFile).use { out ->
                                pdfDoc.writeTo(out)
                            }
                            pdfDoc.close()
                            runOnUiThread { result.success(outFile.absolutePath) }
                        } catch (e: Exception) {
                            try { pdfDoc.close() } catch (_: Exception) {}
                            runOnUiThread { result.error("CREATE_SCAN_PDF_ERR", e.message, null) }
                        }
                    }.start()
                } else if (call.method == "renderPdfFirstPageThumbnail") {
                    val pdfPath = call.argument<String>("pdfPath") ?: call.argument<String>("filePath")
                    val thumbPath = call.argument<String>("thumbPath") ?: call.argument<String>("outPath")
                    if (pdfPath == null || thumbPath == null) {
                        result.error("INVALID_ARGS", "Missing paths", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val thumbFile = File(thumbPath)
                            if (thumbFile.exists() && thumbFile.length() > 100L) {
                                runOnUiThread { result.success(thumbFile.absolutePath) }
                                return@Thread
                            }
                            thumbFile.parentFile?.mkdirs()
                            val pdfFile = File(pdfPath)
                            if (!pdfFile.exists()) {
                                runOnUiThread { result.success(null) }
                                return@Thread
                            }
                            val pfd = ParcelFileDescriptor.open(pdfFile, ParcelFileDescriptor.MODE_READ_ONLY)
                            val renderer = PdfRenderer(pfd)
                            if (renderer.pageCount > 0) {
                                val page = renderer.openPage(0)
                                val requestedW = call.argument<Int>("maxWidth") ?: 1080
                                val targetW = requestedW.coerceIn(720, 1440)
                                val scale = targetW.toFloat() / page.width.toFloat().coerceAtLeast(1f)
                                val w = targetW
                                val h = (page.height * scale).toInt().coerceIn(640, 2048)
                                val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                                bitmap.eraseColor(Color.WHITE)
                                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                page.close()
                                FileOutputStream(thumbFile).use { out ->
                                    bitmap.compress(Bitmap.CompressFormat.JPEG, 95, out)
                                }
                                bitmap.recycle()
                            }
                            renderer.close()
                            pfd.close()
                            runOnUiThread {
                                result.success(if (thumbFile.exists()) thumbFile.absolutePath else null)
                            }
                        } catch (e: Exception) {
                            runOnUiThread { result.success(null) }
                        }
                    }.start()
                } else if (call.method == "decodeTextBytes") {
                    val rawBytes = call.argument<ByteArray>("bytes")
                    if (rawBytes == null || rawBytes.isEmpty()) {
                        result.success("")
                        return@setMethodCallHandler
                    }
                    try {
                        val decoded = decodeKoreanTextBytesSmart(rawBytes)
                        result.success(decoded)
                    } catch (e: Exception) {
                        result.success(String(rawBytes, Charsets.UTF_8))
                    }
                } else if (call.method == "renderPdfToImages") {
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
                } else if (call.method == "renderStructuredDocToPdf") {
                    val outputPath = call.argument<String>("outputPath")
                    val rawBlocks = call.argument<List<Map<String, Any?>>>("blocks")
                    if (outputPath == null || rawBlocks == null) {
                        result.error("INVALID_ARGS", "Missing outputPath or blocks", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        val pdfDoc = PdfDocument()
                        try {
                            val pageWidth = 1240
                            val pageHeight = 1754
                            val marginX = 76f
                            val marginY = 84f
                            val contentWidth = (pageWidth - 2 * marginX).toInt()
                            val maxBottomY = pageHeight - marginY
                            val ptScale = 2.25f // 10pt -> 22.5px on 1240px A4 width

                            var pageNumber = 1
                            var currentPage: PdfDocument.Page? = null
                            var currentY = marginY

                            fun startNewPage(): android.graphics.Canvas {
                                currentPage?.let { pdfDoc.finishPage(it) }
                                val pageInfo = PdfDocument.PageInfo.Builder(pageWidth, pageHeight, pageNumber++).create()
                                val page = pdfDoc.startPage(pageInfo)
                                currentPage = page
                                page.canvas.drawColor(Color.WHITE)
                                currentY = marginY
                                return page.canvas
                            }

                            var canvas = startNewPage()

                            fun buildTextPaint(
                                fontSizePt: Float,
                                bold: Boolean,
                                italic: Boolean,
                                underline: Boolean,
                                serif: Boolean,
                                colorInt: Int
                            ): TextPaint {
                                val tfStyle = when {
                                    bold && italic -> Typeface.BOLD_ITALIC
                                    bold -> Typeface.BOLD
                                    italic -> Typeface.ITALIC
                                    else -> Typeface.NORMAL
                                }
                                val baseTf = if (serif) Typeface.SERIF else Typeface.SANS_SERIF
                                return TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
                                    typeface = Typeface.create(baseTf, tfStyle)
                                    isFakeBoldText = bold
                                    isUnderlineText = underline
                                    color = colorInt
                                    textSize = (fontSizePt * ptScale).coerceIn(15f, 76f)
                                }
                            }

                            fun parseLayoutAlign(alignStr: String?): Layout.Alignment {
                                return when (alignStr?.lowercase()) {
                                    "center" -> Layout.Alignment.ALIGN_CENTER
                                    "right" -> Layout.Alignment.ALIGN_OPPOSITE
                                    else -> Layout.Alignment.ALIGN_NORMAL
                                }
                            }

                            val tableBorderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                                color = Color.rgb(71, 85, 105)
                                style = Paint.Style.STROKE
                                strokeWidth = 1.8f
                            }
                            val cellFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                                style = Paint.Style.FILL
                            }

                            for (block in rawBlocks) {
                                val bType = block["type"] as? String ?: "paragraph"
                                if (bType == "paragraph") {
                                    val text = (block["text"] as? String ?: "").trimEnd()
                                    val fontSizePt = (block["fontSizePt"] as? Number)?.toFloat() ?: 10.5f
                                    val bold = (block["bold"] as? Boolean) ?: false
                                    val italic = (block["italic"] as? Boolean) ?: false
                                    val underline = (block["underline"] as? Boolean) ?: false
                                    val serif = (block["serif"] as? Boolean) ?: false
                                    val alignStr = block["align"] as? String ?: "left"
                                    val colorInt = (block["textColor"] as? Number)?.toInt() ?: Color.rgb(20, 20, 20)
                                    val leftIndentPt = (block["leftIndentPt"] as? Number)?.toFloat() ?: 0f
                                    val spaceBeforePt = (block["spaceBeforePt"] as? Number)?.toFloat() ?: 0f
                                    val spaceAfterPt = (block["spaceAfterPt"] as? Number)?.toFloat() ?: 4f

                                    if (spaceBeforePt > 0f) {
                                        currentY += spaceBeforePt * ptScale * 0.6f
                                    }

                                    if (text.isEmpty()) {
                                        currentY += (fontSizePt * ptScale * 0.85f).coerceAtLeast(16f)
                                        if (currentY > maxBottomY) {
                                            canvas = startNewPage()
                                        }
                                        continue
                                    }

                                    val indentPx = (leftIndentPt * ptScale).coerceIn(0f, contentWidth * 0.45f)
                                    val availW = (contentWidth - indentPx.toInt()).coerceAtLeast(120)
                                    val tPaint = buildTextPaint(fontSizePt, bold, italic, underline, serif, colorInt)
                                    val layoutAlign = parseLayoutAlign(alignStr)

                                    val layout = StaticLayout.Builder.obtain(text, 0, text.length, tPaint, availW)
                                        .setAlignment(layoutAlign)
                                        .setLineSpacing(0f, 1.35f)
                                        .setIncludePad(false)
                                        .build()

                                    val totalH = layout.height.toFloat()
                                    if (currentY + totalH <= maxBottomY) {
                                        canvas.save()
                                        canvas.translate(marginX + indentPx, currentY)
                                        layout.draw(canvas)
                                        canvas.restore()
                                        currentY += totalH + (spaceAfterPt * ptScale * 0.55f).coerceAtLeast(8f)
                                    } else {
                                        for (lineIdx in 0 until layout.lineCount) {
                                            val lineTop = layout.getLineTop(lineIdx).toFloat()
                                            val lineBottom = layout.getLineBottom(lineIdx).toFloat()
                                            val lineH = (lineBottom - lineTop).coerceAtLeast(22f)
                                            if (currentY + lineH > maxBottomY && currentY > marginY + 1f) {
                                                canvas = startNewPage()
                                            }
                                            canvas.save()
                                            canvas.clipRect(
                                                marginX + indentPx,
                                                currentY,
                                                marginX + indentPx + availW,
                                                currentY + lineH + 4f
                                            )
                                            canvas.translate(marginX + indentPx, currentY - lineTop)
                                            layout.draw(canvas)
                                            canvas.restore()
                                            currentY += lineH
                                        }
                                        currentY += (spaceAfterPt * ptScale * 0.55f).coerceAtLeast(8f)
                                    }
                                } else if (bType == "table") {
                                    @Suppress("UNCHECKED_CAST")
                                    val rawCells = block["cells"] as? List<Map<String, Any?>>
                                    if (rawCells != null && rawCells.isNotEmpty()) {
                                        val numRows = ((block["numRows"] as? Number)?.toInt() ?: 1).coerceAtLeast(1)
                                        val numCols = ((block["numCols"] as? Number)?.toInt() ?: 1).coerceAtLeast(1)
                                        @Suppress("UNCHECKED_CAST")
                                        val rawColWidths = block["colWidths"] as? List<Number>
                                        val colW = FloatArray(numCols)
                                        if (rawColWidths != null && rawColWidths.size == numCols) {
                                            var sumW = 0f
                                            for (n in rawColWidths) sumW += n.toFloat().coerceAtLeast(1f)
                                            if (sumW <= 0f) sumW = numCols.toFloat()
                                            for (c in 0 until numCols) {
                                                colW[c] = (rawColWidths[c].toFloat().coerceAtLeast(1f) / sumW) * contentWidth.toFloat()
                                            }
                                        } else {
                                            val eqW = contentWidth.toFloat() / numCols.toFloat()
                                            for (c in 0 until numCols) colW[c] = eqW
                                        }

                                        val colLeft = FloatArray(numCols + 1)
                                        colLeft[0] = marginX
                                        for (c in 0 until numCols) {
                                            colLeft[c + 1] = colLeft[c] + colW[c]
                                        }

                                        val cellPadX = 10f
                                        val cellPadY = 9f

                                        class PreparedCell(
                                            val row: Int,
                                            val col: Int,
                                            val rowSpan: Int,
                                            val colSpan: Int,
                                            val layout: StaticLayout,
                                            val vAlign: String,
                                            val bgColor: Int?,
                                            val minHeightPx: Float,
                                            val cellBitmap: Bitmap?,
                                            val imgDrawW: Float,
                                            val imgDrawH: Float
                                        )

                                        val preparedCells = ArrayList<PreparedCell>(rawCells.size)
                                        val rowHeights = FloatArray(numRows) { 38f }

                                        for (rc in rawCells) {
                                            val r = ((rc["row"] as? Number)?.toInt() ?: 0).coerceIn(0, numRows - 1)
                                            val c = ((rc["col"] as? Number)?.toInt() ?: 0).coerceIn(0, numCols - 1)
                                            val rSpan = ((rc["rowSpan"] as? Number)?.toInt() ?: 1).coerceIn(1, numRows - r)
                                            val cSpan = ((rc["colSpan"] as? Number)?.toInt() ?: 1).coerceIn(1, numCols - c)
                                            val cellText = (rc["text"] as? String ?: "").trim()
                                            val alignStr = rc["align"] as? String ?: "left"
                                            val vAlignStr = rc["vAlign"] as? String ?: "middle"
                                            val bold = (rc["bold"] as? Boolean) ?: false
                                            val serif = (rc["serif"] as? Boolean) ?: false
                                            val fontSizePt = (rc["fontSizePt"] as? Number)?.toFloat() ?: 9.5f
                                            val textColor = (rc["textColor"] as? Number)?.toInt() ?: Color.rgb(20, 20, 20)
                                            val bgColor = (rc["bgColor"] as? Number)?.toInt()
                                            val minHeightPt = (rc["minHeightPt"] as? Number)?.toFloat() ?: 0f
                                            val minHeightPx = (minHeightPt * ptScale * 0.75f).coerceIn(34f, 450f)

                                            val spanW = colLeft[c + cSpan] - colLeft[c]
                                            val innerW = (spanW - 2 * cellPadX).toInt().coerceAtLeast(28)
                                            val cPaint = buildTextPaint(fontSizePt, bold, false, false, serif, textColor)
                                            val sl = StaticLayout.Builder.obtain(cellText, 0, cellText.length, cPaint, innerW)
                                                .setAlignment(parseLayoutAlign(alignStr))
                                                .setLineSpacing(0f, 1.22f)
                                                .setIncludePad(false)
                                                .build()

                                            var bmp: Bitmap? = null
                                            var iW = 0f
                                            var iH = 0f
                                            val imgBytes = rc["imageBytes"] as? ByteArray
                                            if (imgBytes != null && imgBytes.isNotEmpty()) {
                                                bmp = BitmapFactory.decodeByteArray(imgBytes, 0, imgBytes.size)
                                                if (bmp != null && bmp.width > 0 && bmp.height > 0) {
                                                    val maxW = innerW.toFloat()
                                                    val maxH = 260f
                                                    var sc = maxW / bmp.width.toFloat()
                                                    if (sc > 1.8f) sc = 1.8f
                                                    if (bmp.height * sc > maxH) sc = maxH / bmp.height.toFloat()
                                                    iW = (bmp.width * sc).coerceAtLeast(1f)
                                                    iH = (bmp.height * sc).coerceAtLeast(1f)
                                                }
                                            }

                                            val neededH = (if (cellText.isNotEmpty()) sl.height.toFloat() else 0f) +
                                                (if (iH > 0f) iH + 6f else 0f) + 2 * cellPadY
                                            val totalCellH = maxOf(neededH, minHeightPx)

                                            if (rSpan == 1) {
                                                if (totalCellH > rowHeights[r]) {
                                                    rowHeights[r] = totalCellH.coerceAtMost(pageHeight - 2 * marginY - 30f)
                                                }
                                            }

                                            preparedCells.add(
                                                PreparedCell(
                                                    r, c, rSpan, cSpan, sl, vAlignStr, bgColor, totalCellH, bmp, iW, iH
                                                )
                                            )
                                        }

                                        // Pass 2: distribute height for rowSpan > 1 cells
                                        for (pc in preparedCells) {
                                            if (pc.rowSpan > 1) {
                                                var curSum = 0f
                                                for (rr in pc.row until (pc.row + pc.rowSpan)) {
                                                    curSum += rowHeights[rr]
                                                }
                                                if (pc.minHeightPx > curSum) {
                                                    val extraPerRow = (pc.minHeightPx - curSum) / pc.rowSpan.toFloat()
                                                    for (rr in pc.row until (pc.row + pc.rowSpan)) {
                                                        rowHeights[rr] += extraPerRow
                                                    }
                                                }
                                            }
                                        }

                                        currentY += 6f
                                        // Render row-by-row (or chunk of rows per page)
                                        var rowStart = 0
                                        while (rowStart < numRows) {
                                            if (currentY + rowHeights[rowStart] > maxBottomY && currentY > marginY + 1f) {
                                                canvas = startNewPage()
                                            }
                                            var rowEnd = rowStart
                                            var chunkH = 0f
                                            while (rowEnd < numRows) {
                                                val rh = rowHeights[rowEnd]
                                                if (rowEnd > rowStart && currentY + chunkH + rh > maxBottomY) {
                                                    break
                                                }
                                                chunkH += rh
                                                rowEnd++
                                            }

                                            val rowTopY = FloatArray(numRows + 1)
                                            rowTopY[rowStart] = currentY
                                            for (rr in rowStart until rowEnd) {
                                                rowTopY[rr + 1] = rowTopY[rr] + rowHeights[rr]
                                            }

                                            for (pc in preparedCells) {
                                                val cellEndRow = pc.row + pc.rowSpan
                                                if (cellEndRow <= rowStart || pc.row >= rowEnd) continue
                                                val drawR0 = maxOf(pc.row, rowStart)
                                                val drawR1 = minOf(cellEndRow, rowEnd)
                                                val left = colLeft[pc.col]
                                                val right = colLeft[pc.col + pc.colSpan]
                                                val top = rowTopY[drawR0]
                                                val bottom = rowTopY[drawR1]
                                                val rect = RectF(left, top, right, bottom)

                                                if (pc.bgColor != null) {
                                                    cellFillPaint.color = pc.bgColor
                                                    canvas.drawRect(rect, cellFillPaint)
                                                }
                                                canvas.drawRect(rect, tableBorderPaint)

                                                if (pc.row == drawR0) {
                                                    val boxH = bottom - top
                                                    val contentH = (if (pc.layout.text.isNotEmpty()) pc.layout.height.toFloat() else 0f) +
                                                        (if (pc.imgDrawH > 0f) pc.imgDrawH + 4f else 0f)
                                                    val offsetY = when (pc.vAlign.lowercase()) {
                                                        "bottom" -> maxOf(cellPadY, boxH - contentH - cellPadY)
                                                        "middle", "center" -> maxOf(cellPadY, (boxH - contentH) / 2f)
                                                        else -> cellPadY
                                                    }
                                                    canvas.save()
                                                    canvas.clipRect(left + 2f, top + 2f, right - 2f, bottom - 2f)
                                                    var curCellY = top + offsetY
                                                    if (pc.cellBitmap != null && pc.imgDrawW > 0f && pc.imgDrawH > 0f) {
                                                        val imgLeft = left + ((right - left) - pc.imgDrawW) / 2f
                                                        val imgRect = RectF(imgLeft, curCellY, imgLeft + pc.imgDrawW, curCellY + pc.imgDrawH)
                                                        canvas.drawBitmap(pc.cellBitmap, null, imgRect, Paint(Paint.FILTER_BITMAP_FLAG))
                                                        curCellY += pc.imgDrawH + 4f
                                                    }
                                                    if (pc.layout.text.isNotEmpty()) {
                                                        canvas.translate(left + cellPadX, curCellY)
                                                        pc.layout.draw(canvas)
                                                    }
                                                    canvas.restore()
                                                }
                                            }

                                            currentY += chunkH
                                            rowStart = rowEnd
                                        }

                                        for (pc in preparedCells) {
                                            pc.cellBitmap?.recycle()
                                        }
                                        currentY += 16f
                                    } else {
                                        @Suppress("UNCHECKED_CAST")
                                        val rows = block["rows"] as? List<List<String>> ?: emptyList()
                                        if (rows.isEmpty()) continue
                                        var numCols = 1
                                        for (r in rows) {
                                            if (r.size > numCols) numCols = r.size
                                        }
                                        val colW = contentWidth.toFloat() / numCols.toFloat()
                                        val cellPadX = 10f
                                        val cellPadY = 10f
                                        val cellTextW = (colW - 2 * cellPadX).toInt().coerceAtLeast(32)
                                        val cellPaint = buildTextPaint(9.5f, false, false, false, false, Color.rgb(20, 20, 20))

                                        currentY += 6f
                                        for (row in rows) {
                                            val cellLayouts = ArrayList<StaticLayout>(numCols)
                                            var maxCellH = 32f
                                            for (cIdx in 0 until numCols) {
                                                val cellText = if (cIdx < row.size) row[cIdx].trim() else ""
                                                val sl = StaticLayout.Builder.obtain(cellText, 0, cellText.length, cellPaint, cellTextW)
                                                    .setAlignment(Layout.Alignment.ALIGN_NORMAL)
                                                    .setLineSpacing(0f, 1.22f)
                                                    .setIncludePad(false)
                                                    .build()
                                                cellLayouts.add(sl)
                                                val h = sl.height.toFloat()
                                                if (h > maxCellH) maxCellH = h
                                            }
                                            val rowH = (maxCellH + 2 * cellPadY).coerceAtMost(pageHeight - 2 * marginY - 20f)
                                            if (currentY + rowH > maxBottomY && currentY > marginY + 1f) {
                                                canvas = startNewPage()
                                            }
                                            for (cIdx in 0 until numCols) {
                                                val left = marginX + cIdx * colW
                                                val top = currentY
                                                val right = left + colW
                                                val bottom = top + rowH
                                                val rect = RectF(left, top, right, bottom)
                                                canvas.drawRect(rect, tableBorderPaint)
                                                canvas.save()
                                                canvas.clipRect(left + 2f, top + 2f, right - 2f, bottom - 2f)
                                                canvas.translate(left + cellPadX, top + cellPadY)
                                                cellLayouts[cIdx].draw(canvas)
                                                canvas.restore()
                                            }
                                            currentY += rowH
                                        }
                                        currentY += 16f
                                    }
                                } else if (bType == "image") {
                                    val imgBytes = block["bytes"] as? ByteArray
                                    if (imgBytes != null && imgBytes.isNotEmpty()) {
                                        val bmp = BitmapFactory.decodeByteArray(imgBytes, 0, imgBytes.size)
                                        if (bmp != null && bmp.width > 0 && bmp.height > 0) {
                                            val maxImgW = contentWidth.toFloat()
                                            val maxImgH = (pageHeight - 2 * marginY) * 0.72f
                                            var scale = maxImgW / bmp.width.toFloat()
                                            if (scale > 2.2f) scale = 2.2f
                                            if (bmp.height * scale > maxImgH) {
                                                scale = maxImgH / bmp.height.toFloat()
                                            }
                                            val drawW = (bmp.width * scale).coerceAtLeast(1f)
                                            val drawH = (bmp.height * scale).coerceAtLeast(1f)
                                            if (currentY + drawH + 16f > maxBottomY && currentY > marginY + 1f) {
                                                canvas = startNewPage()
                                            }
                                            val left = marginX + (contentWidth - drawW) / 2f
                                            val dstRect = RectF(left, currentY + 8f, left + drawW, currentY + 8f + drawH)
                                            canvas.drawBitmap(bmp, null, dstRect, Paint(Paint.FILTER_BITMAP_FLAG))
                                            bmp.recycle()
                                            currentY += drawH + 24f
                                        }
                                    }
                                }
                            }

                            currentPage?.let { pdfDoc.finishPage(it) }
                            val outFile = File(outputPath)
                            outFile.parentFile?.mkdirs()
                            FileOutputStream(outFile).use { outStream ->
                                pdfDoc.writeTo(outStream)
                            }
                            pdfDoc.close()
                            runOnUiThread { result.success(outFile.absolutePath) }
                        } catch (e: Exception) {
                            try { pdfDoc.close() } catch (_: Exception) {}
                            runOnUiThread { result.error("DOC_PDF_ERR", e.message, null) }
                        }
                    }.start()
                } else if (call.method == "setScreenOrientation") {
                    val mode = call.argument<String>("mode") ?: "unspecified"
                    runOnUiThread {
                        requestedOrientation = when (mode) {
                            "landscape" -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                            "portrait" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                            else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                        }
                        result.success(true)
                    }
                } else if (call.method == "saveFileToDownloads") {
                    val sourcePath = call.argument<String>("sourcePath")
                    val fileName = call.argument<String>("fileName") ?: "FReader_Export.pdf"
                    if (sourcePath == null || !File(sourcePath).exists()) {
                        result.error("INVALID_SOURCE", "Source file does not exist", null)
                        return@setMethodCallHandler
                    }
                    Thread {
                        try {
                            val srcFile = File(sourcePath)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                val values = ContentValues().apply {
                                    put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                                    put(MediaStore.Downloads.MIME_TYPE, "application/pdf")
                                    put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                                    put(MediaStore.Downloads.IS_PENDING, 1)
                                }
                                val resolver = applicationContext.contentResolver
                                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                                if (uri != null) {
                                    resolver.openOutputStream(uri)?.use { outStream ->
                                        srcFile.inputStream().use { inStream ->
                                            inStream.copyTo(outStream)
                                        }
                                    }
                                    values.clear()
                                    values.put(MediaStore.Downloads.IS_PENDING, 0)
                                    resolver.update(uri, values, null, null)
                                }
                            } else {
                                @Suppress("DEPRECATION")
                                val dlDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                                if (!dlDir.exists()) dlDir.mkdirs()
                                val dstFile = File(dlDir, fileName)
                                srcFile.copyTo(dstFile, overwrite = true)
                            }
                            runOnUiThread { result.success(fileName) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("DOWNLOAD_SAVE_ERR", e.message, null) }
                        }
                    }.start()
                } else if (call.method == "scanHtmlToPdf") {
                    val htmlContent = call.argument<String>("htmlContent")
                    val outputPath = call.argument<String>("outputPath")
                    if (htmlContent == null || outputPath == null) {
                        result.error("INVALID_ARGS", "Missing htmlContent or outputPath", null)
                        return@setMethodCallHandler
                    }
                    runOnUiThread {
                        try {
                            val pageWidth = 1240
                            val pageHeight = 1754
                            val marginY = 64
                            val printableHeight = pageHeight - marginY * 2

                            val webView = WebView(this@MainActivity)
                            webView.setLayerType(View.LAYER_TYPE_SOFTWARE, null)
                            webView.setBackgroundColor(Color.WHITE)
                            webView.settings.apply {
                                javaScriptEnabled = false
                                loadsImagesAutomatically = true
                                useWideViewPort = false
                                loadWithOverviewMode = false
                                defaultTextEncodingName = "utf-8"
                                builtInZoomControls = false
                                displayZoomControls = false
                            }

                            val widthSpec = View.MeasureSpec.makeMeasureSpec(pageWidth, View.MeasureSpec.EXACTLY)
                            val heightSpec = View.MeasureSpec.makeMeasureSpec(pageHeight, View.MeasureSpec.EXACTLY)
                            webView.measure(widthSpec, heightSpec)
                            webView.layout(0, 0, pageWidth, pageHeight)

                            var finished = false
                            webView.webViewClient = object : WebViewClient() {
                                override fun onPageFinished(view: WebView?, url: String?) {
                                    if (finished) return
                                    finished = true
                                    mainHandler.postDelayed({
                                        try {
                                            val wSpec = View.MeasureSpec.makeMeasureSpec(pageWidth, View.MeasureSpec.EXACTLY)
                                            val hSpec = View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
                                            webView.measure(wSpec, hSpec)
                                            val rawH = maxOf(
                                                webView.measuredHeight,
                                                (webView.contentHeight * webView.scale).toInt()
                                            ).coerceAtLeast(printableHeight)
                                            val totalH = rawH.coerceAtMost(printableHeight * 120)
                                            webView.layout(0, 0, pageWidth, totalH)

                                            mainHandler.postDelayed({
                                                Thread {
                                                    val pdfDoc = PdfDocument()
                                                    try {
                                                        // WebView 전체 또는 슬라이스를 고해상도 비트맵으로 스캔하여 줄 잘림 없이 페이지 분할
                                                        var curY = 0
                                                        var pageNum = 1
                                                        val sliceBmp = Bitmap.createBitmap(pageWidth, printableHeight, Bitmap.Config.ARGB_8888)
                                                        val sliceCanvas = android.graphics.Canvas(sliceBmp)
                                                        val rowPixels = IntArray(pageWidth)

                                                        while (curY < totalH) {
                                                            val remaining = totalH - curY
                                                            var cutH = minOf(printableHeight, remaining)

                                                            runOnUiThread {
                                                                sliceBmp.eraseColor(Color.WHITE)
                                                                sliceCanvas.save()
                                                                sliceCanvas.translate(0f, -curY.toFloat())
                                                                webView.draw(sliceCanvas)
                                                                sliceCanvas.restore()
                                                            }
                                                            // UI 스레드 드로잉 완료 대기
                                                            val latch = java.util.concurrent.CountDownLatch(1)
                                                            runOnUiThread { latch.countDown() }
                                                            latch.await()

                                                            // 페이지 하단에서 글자나 표 테두리가 반으로 잘리지 않도록 하단 여백 행 탐색
                                                            if (remaining > printableHeight) {
                                                                val searchStart = printableHeight - 10
                                                                val searchEnd = (printableHeight - 150).coerceAtLeast(200)
                                                                for (y in searchStart downTo searchEnd) {
                                                                    sliceBmp.getPixels(rowPixels, 0, pageWidth, 0, y, pageWidth, 1)
                                                                    var allWhite = true
                                                                    for (x in 40 until (pageWidth - 40) step 4) {
                                                                        val px = rowPixels[x]
                                                                        val r = (px shr 16) and 0xFF
                                                                        val g = (px shr 8) and 0xFF
                                                                        val b = px and 0xFF
                                                                        if (r < 245 || g < 245 || b < 245) {
                                                                            allWhite = false
                                                                            break
                                                                        }
                                                                    }
                                                                    if (allWhite) {
                                                                        cutH = y
                                                                        break
                                                                    }
                                                                }
                                                            }

                                                            val pageInfo = PdfDocument.PageInfo.Builder(pageWidth, pageHeight, pageNum++).create()
                                                            val page = pdfDoc.startPage(pageInfo)
                                                            page.canvas.drawColor(Color.WHITE)
                                                            val srcRect = Rect(0, 0, pageWidth, cutH)
                                                            val dstRect = Rect(0, marginY, pageWidth, marginY + cutH)
                                                            page.canvas.drawBitmap(sliceBmp, srcRect, dstRect, null)
                                                            pdfDoc.finishPage(page)

                                                            curY += cutH.coerceAtLeast(100)
                                                        }

                                                        sliceBmp.recycle()
                                                        val outFile = File(outputPath)
                                                        outFile.parentFile?.mkdirs()
                                                        FileOutputStream(outFile).use { outStream ->
                                                            pdfDoc.writeTo(outStream)
                                                        }
                                                        pdfDoc.close()
                                                        runOnUiThread {
                                                            try { webView.destroy() } catch (_: Exception) {}
                                                            result.success(outFile.absolutePath)
                                                        }
                                                    } catch (e: Exception) {
                                                        try { pdfDoc.close() } catch (_: Exception) {}
                                                        runOnUiThread {
                                                            try { webView.destroy() } catch (_: Exception) {}
                                                            result.error("SCAN_PDF_ERR", e.message, null)
                                                        }
                                                    }
                                                }.start()
                                            }, 180L)
                                        } catch (e: Exception) {
                                            result.error("WEBVIEW_MEASURE_ERR", e.message, null)
                                        }
                                    }, 320L)
                                }
                            }

                            webView.loadDataWithBaseURL(
                                "https://local.freader.doc/",
                                htmlContent,
                                "text/html",
                                "utf-8",
                                null
                            )
                        } catch (e: Exception) {
                            result.error("WEBVIEW_INIT_ERR", e.message, null)
                        }
                    }
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
        hideSystemStatusBar()
        mainHandler.postDelayed({ hideSystemStatusBar() }, 120L)
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
        if (ev != null && (ev.actionMasked == MotionEvent.ACTION_DOWN || ev.actionMasked == MotionEvent.ACTION_UP)) {
            hideSystemStatusBar()
            scheduleAutoHideStatusBar(1200L)
        }
        if (isVolumeInterceptEnabled) {
            checkStylusButtonEvent(ev)
        }
        return super.dispatchTouchEvent(ev)
    }

    private fun decodeKoreanTextBytesSmart(bytes: ByteArray): String {
        // 1. UTF-8 / UTF-16 BOM 체크
        if (bytes.size >= 3 &&
            (bytes[0].toInt() and 0xFF) == 0xEF &&
            (bytes[1].toInt() and 0xFF) == 0xBB &&
            (bytes[2].toInt() and 0xFF) == 0xBF
        ) {
            return String(bytes, 3, bytes.size - 3, Charsets.UTF_8)
        }
        if (bytes.size >= 2 &&
            (bytes[0].toInt() and 0xFF) == 0xFF &&
            (bytes[1].toInt() and 0xFF) == 0xFE
        ) {
            return String(bytes, 2, bytes.size - 2, Charsets.UTF_16LE)
        }
        if (bytes.size >= 2 &&
            (bytes[0].toInt() and 0xFF) == 0xFE &&
            (bytes[1].toInt() and 0xFF) == 0xFF
        ) {
            return String(bytes, 2, bytes.size - 2, Charsets.UTF_16BE)
        }

        // 2. 엄격한 UTF-8 디코딩 시도 (에러 발생 시 Windows 메모장 한글 인코딩인 MS949/CP949로 즉시 전환!)
        try {
            val utf8Decoder = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            return utf8Decoder.decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: CharacterCodingException) {}

        // 3. 한국어 Windows 메모장 기본 ANSI 인코딩(MS949 / CP949 / EUC-KR) 디코딩
        for (csName in listOf("MS949", "CP949", "EUC-KR", "x-windows-949")) {
            try {
                if (Charset.isSupported(csName)) {
                    return String(bytes, Charset.forName(csName))
                }
            } catch (_: Exception) {}
        }

        return String(bytes, Charsets.UTF_8)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (isVolumeInterceptEnabled &&
            (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)
        ) {
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (isVolumeInterceptEnabled &&
            (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)
        ) {
            return true
        }
        return super.onKeyUp(keyCode, event)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val keyCode = event.keyCode
        val action = event.action

        if (isVolumeInterceptEnabled) {
            val now = SystemClock.uptimeMillis()
            // 만약 이전 키 이벤트에서 ACTION_UP이 누락되어 상태가 남았을 경우 450ms 경과 시 자동 초기화
            if (action == KeyEvent.ACTION_DOWN && event.repeatCount == 0 && (now - lastVolKeyDownTime > 450L)) {
                isVolUpPressed = false
                isVolDownPressed = false
                comboTriggered = false
            }

            if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
                if (action == KeyEvent.ACTION_DOWN) {
                    lastVolKeyDownTime = now
                    if (event.repeatCount == 0) {
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
                        mainHandler.postDelayed(r, 70L)
                    }
                } else if (action == KeyEvent.ACTION_UP) {
                    isVolUpPressed = false
                    if (!isVolDownPressed) comboTriggered = false
                }
                return true
            }

            if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
                if (action == KeyEvent.ACTION_DOWN) {
                    lastVolKeyDownTime = now
                    if (event.repeatCount == 0) {
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
                        mainHandler.postDelayed(r, 70L)
                    }
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

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        hideSystemStatusBar()
        if (requestCode == CAMERA_SCAN_REQUEST_CODE) {
            val callback = pendingCameraResult
            val rawFile = pendingCameraRawFile
            pendingCameraResult = null
            pendingCameraRawFile = null

            if (callback == null) return
            if (resultCode != Activity.RESULT_OK) {
                callback.success(null)
                return
            }

            Thread {
                try {
                    var srcBitmap: Bitmap? = null
                    if (rawFile != null && rawFile.exists() && rawFile.length() > 128L) {
                        srcBitmap = decodeAndOrientCameraBitmap(rawFile)
                    }
                    if (srcBitmap == null && data != null) {
                        @Suppress("DEPRECATION")
                        srcBitmap = data.extras?.get("data") as? Bitmap
                    }
                    if (srcBitmap == null) {
                        runOnUiThread { callback.success(null) }
                        return@Thread
                    }

                    // 먼저 종이 영역 자동 감지 및 회전 보정된 이미지를 저장하여 ML Kit 텍스트 영역 인식 후 순수 글자 추출 수행
                    val croppedPaper = cropToDetectedPaperRegion(srcBitmap)
                    if (croppedPaper !== srcBitmap) {
                        srcBitmap.recycle()
                    }

                    val scanDir = File(cacheDir, "camera_scans")
                    if (!scanDir.exists()) scanDir.mkdirs()
                    val cleanFile = File(scanDir, "scanned_raw_${System.currentTimeMillis()}.jpg")
                    FileOutputStream(cleanFile).use { out ->
                        croppedPaper.compress(Bitmap.CompressFormat.JPEG, 95, out)
                    }
                    croppedPaper.recycle()
                    try {
                        if (rawFile != null && rawFile.exists()) rawFile.delete()
                    } catch (_: Exception) {}

                    runOnUiThread {
                        hideSystemStatusBar()
                        callback.success(cleanFile.absolutePath)
                    }
                } catch (e: Exception) {
                    runOnUiThread {
                        hideSystemStatusBar()
                        callback.error("SCAN_PROCESS_ERR", e.message, null)
                    }
                }
            }.start()
        }
    }

    private fun decodeAndOrientCameraBitmap(file: File): Bitmap? {
        val boundsOpts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, boundsOpts)
        val maxDim = 2200
        var sampleSize = 1
        while (boundsOpts.outWidth / sampleSize > maxDim || boundsOpts.outHeight / sampleSize > maxDim) {
            sampleSize *= 2
        }
        val decodeOpts = BitmapFactory.Options().apply {
            inSampleSize = sampleSize
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        val raw = BitmapFactory.decodeFile(file.absolutePath, decodeOpts) ?: return null

        var rotateDeg = 0f
        try {
            val exif = ExifInterface(file.absolutePath)
            when (exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                ExifInterface.ORIENTATION_ROTATE_90 -> rotateDeg = 90f
                ExifInterface.ORIENTATION_ROTATE_180 -> rotateDeg = 180f
                ExifInterface.ORIENTATION_ROTATE_270 -> rotateDeg = 270f
            }
        } catch (_: Exception) {}

        if (rotateDeg == 0f) return raw
        val matrix = Matrix().apply { postRotate(rotateDeg) }
        val rotated = Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, matrix, true)
        if (rotated !== raw) raw.recycle()
        return rotated
    }

    /**
     * 1. 다른 전문 문서 스캔 앱(CamScanner / Adobe Scan 등)처럼 촬영된 책이나 종이 문서의
     * 그림자·조명 얼룩을 제거해 배경을 깨끗한 흰색으로 정돈하고 글자 획을 또렷하게 보정하는 필터
     */
    /**
     * OSS-DocumentScanner & Simple Scan 스타일:
     * 1단계 - 어두운 책상/배경 테두리를 자동으로 감지하여 실제 종이(문서) 영역만 추출
     */
    private fun cropToDetectedPaperRegion(src: Bitmap): Bitmap {
        val w = src.width
        val h = src.height
        if (w < 120 || h < 120) return src

        val step = 4
        val sw = w / step
        val sh = h / step
        val smallLum = IntArray(sw * sh)
        val rowBuf = IntArray(w)
        val hist = IntArray(256)

        for (sy in 0 until sh) {
            src.getPixels(rowBuf, 0, w, 0, sy * step, w, 1)
            for (sx in 0 until sw) {
                val px = rowBuf[sx * step]
                val r = (px shr 16) and 0xFF
                val g = (px shr 8) and 0xFF
                val b = px and 0xFF
                val l = (r * 77 + g * 150 + b * 29) shr 8
                smallLum[sy * sw + sx] = l
                hist[l]++
            }
        }

        // 중앙부(25%~75%)의 밝기를 기준으로 종이 밝기 문턱값 계산
        var centerSum = 0L
        var centerCnt = 0
        for (sy in (sh / 4) until (sh * 3 / 4)) {
            for (sx in (sw / 4) until (sw * 3 / 4)) {
                centerSum += smallLum[sy * sw + sx]
                centerCnt++
            }
        }
        val centerMean = if (centerCnt > 0) (centerSum / centerCnt).toInt() else 170
        val paperThresh = (centerMean * 0.68).toInt().coerceIn(75, 185)

        val rowBrightRatio = FloatArray(sh)
        val colBrightRatio = FloatArray(sw)
        for (sy in 0 until sh) {
            var bright = 0
            for (sx in 0 until sw) {
                if (smallLum[sy * sw + sx] >= paperThresh) bright++
            }
            rowBrightRatio[sy] = bright.toFloat() / sw.toFloat()
        }
        for (sx in 0 until sw) {
            var bright = 0
            for (sy in 0 until sh) {
                if (smallLum[sy * sw + sx] >= paperThresh) bright++
            }
            colBrightRatio[sx] = bright.toFloat() / sh.toFloat()
        }

        var topSy = 0
        while (topSy < sh / 3 && rowBrightRatio[topSy] < 0.38f) topSy++
        var botSy = sh - 1
        while (botSy > (sh * 2) / 3 && rowBrightRatio[botSy] < 0.38f) botSy--
        var leftSx = 0
        while (leftSx < sw / 3 && colBrightRatio[leftSx] < 0.38f) leftSx++
        var rightSx = sw - 1
        while (rightSx > (sw * 2) / 3 && colBrightRatio[rightSx] < 0.38f) rightSx--

        val cropL = (leftSx * step).coerceIn(0, w / 3)
        val cropT = (topSy * step).coerceIn(0, h / 3)
        val cropR = (rightSx * step).coerceIn((w * 2) / 3, w)
        val cropB = (botSy * step).coerceIn((h * 2) / 3, h)

        val cw = cropR - cropL
        val ch = cropB - cropT
        if (cw <= w * 0.45 || ch <= h * 0.45 || (cw >= w - 16 && ch >= h - 16)) {
            return src
        }
        return Bitmap.createBitmap(src, cropL, cropT, cw, ch)
    }

    /**
     * OSS-DocumentScanner & Simple Scan 스타일 핵심 엔진:
     * 2단계 - 적분 영상(Integral Image) 기반 Sauvola 적응형 이진화 + ML Kit 글자 영역 마스킹 + 여백 제로(Zero-Margin) 타이트 크롭
     * -> 스캔본의 글자/표만 선명한 흑색 잉크로 인식해 순백색(#FFFFFF) 빈 종이에 여백 없이 꽉 채워 배치!
     */
    private fun extractPureTextOnBlankPage(
        src: Bitmap,
        ocrBoxes: List<Rect>,
        filterMode: String
    ): Bitmap {
        if (filterMode == "magic_color") {
            return enhanceScannedDocumentBitmap(src)
        }

        val w = src.width
        val h = src.height
        if (w < 32 || h < 32) return src

        val pixels = IntArray(w * h)
        src.getPixels(pixels, 0, w, 0, 0, w, h)

        val lum = IntArray(w * h)
        for (i in pixels.indices) {
            val px = pixels[i]
            val r = (px shr 16) and 0xFF
            val g = (px shr 8) and 0xFF
            val b = px and 0xFF
            lum[i] = (r * 77 + g * 150 + b * 29) shr 8
        }

        // 적분 영상 (Integral Image & Squared Integral Image) 생성 -> O(1) 로컬 평균 및 표준편차 계산
        val stride = w + 1
        val intSum = IntArray(stride * (h + 1))
        val intSqSum = LongArray(stride * (h + 1))

        for (y in 1..h) {
            var rowSum = 0
            var rowSqSum = 0L
            val srcRowOff = (y - 1) * w
            val curIntOff = y * stride
            val prevIntOff = (y - 1) * stride
            for (x in 1..w) {
                val v = lum[srcRowOff + (x - 1)]
                rowSum += v
                rowSqSum += (v * v).toLong()
                intSum[curIntOff + x] = intSum[prevIntOff + x] + rowSum
                intSqSum[curIntOff + x] = intSqSum[prevIntOff + x] + rowSqSum
            }
        }

        // ML Kit OCR 텍스트 박스들을 약간 확장하여 글자 보호 마스크 구성
        val hasOcr = ocrBoxes.isNotEmpty()
        val padX = (w * 0.022f).toInt().coerceAtLeast(12)
        val padY = (h * 0.014f).toInt().coerceAtLeast(10)
        val expandedBoxes = ArrayList<Rect>(ocrBoxes.size)
        var ocrUnionLeft = w
        var ocrUnionTop = h
        var ocrUnionRight = 0
        var ocrUnionBottom = 0

        for (b in ocrBoxes) {
            // 테두리 1% 이내의 카메라 노이즈 오인식 박스는 제외
            if (b.width() < 4 || b.height() < 4) continue
            val el = (b.left - padX).coerceIn(0, w - 1)
            val et = (b.top - padY).coerceIn(0, h - 1)
            val er = (b.right + padX).coerceIn(1, w)
            val eb = (b.bottom + padY).coerceIn(1, h)
            expandedBoxes.add(Rect(el, et, er, eb))
            if (el < ocrUnionLeft) ocrUnionLeft = el
            if (et < ocrUnionTop) ocrUnionTop = et
            if (er > ocrUnionRight) ocrUnionRight = er
            if (eb > ocrUnionBottom) ocrUnionBottom = eb
        }

        // 픽셀별 텍스트 마스크 배열 (OCR 박스가 있으면 해당 영역을 1로 표시)
        val inOcrRegion = BooleanArray(w * h)
        if (expandedBoxes.isNotEmpty()) {
            for (eb in expandedBoxes) {
                for (y in eb.top until eb.bottom) {
                    val ro = y * w
                    for (x in eb.left until eb.right) {
                        inOcrRegion[ro + x] = true
                    }
                }
            }
        }

        val winRadius = (minOf(w, h) / 38).coerceIn(14, 42)
        // 가장자리 2% 영역은 손가락/책 모서리 그림자가 자주 찍히므로 OCR 박스가 아닌 경우 자동 마스킹
        val borderMarginX = (w * 0.02f).toInt().coerceAtLeast(6)
        val borderMarginY = (h * 0.02f).toInt().coerceAtLeast(6)

        val inkGray = IntArray(w * h) { 255 }

        for (y in 0 until h) {
            val y0 = (y - winRadius).coerceAtLeast(0)
            val y1 = (y + winRadius + 1).coerceAtMost(h)
            val rowOff = y * w
            val y0Off = y0 * stride
            val y1Off = y1 * stride
            val isBorderY = (y < borderMarginY || y >= h - borderMarginY)

            for (x in 0 until w) {
                val idx = rowOff + x
                val isOcrPx = inOcrRegion[idx]

                if (!isOcrPx && (isBorderY || x < borderMarginX || x >= w - borderMarginX)) {
                    inkGray[idx] = 255
                    continue
                }

                // OCR이 글자를 찾은 페이지에서 OCR 전체 범위 바깥쪽 여백에 있는 잡티/배경은 순백색(#FFFFFF)으로 즉시 제거
                if (expandedBoxes.isNotEmpty() && !isOcrPx) {
                    if (x < ocrUnionLeft - padX * 2 ||
                        x > ocrUnionRight + padX * 2 ||
                        y < ocrUnionTop - padY * 2 ||
                        y > ocrUnionBottom + padY * 2
                    ) {
                        inkGray[idx] = 255
                        continue
                    }
                }

                val x0 = (x - winRadius).coerceAtLeast(0)
                val x1 = (x + winRadius + 1).coerceAtMost(w)
                val area = (x1 - x0) * (y1 - y0)

                val sum = intSum[y1Off + x1] - intSum[y0Off + x1] - intSum[y1Off + x0] + intSum[y0Off + x0]
                val sqSum = intSqSum[y1Off + x1] - intSqSum[y0Off + x1] - intSqSum[y1Off + x0] + intSqSum[y0Off + x0]

                val mean = sum.toDouble() / area.toDouble()
                val variance = (sqSum.toDouble() / area.toDouble()) - (mean * mean)
                val std = sqrt(variance.coerceAtLeast(0.0))

                // Sauvola 적응형 문턱값: 글자 영역 내부는 세밀한 획까지 보존하고, 비글자 영역은 강한 대비의 표/선만 보존
                val minStd = if (isOcrPx) 6.5 else 13.5
                if (std < minStd) {
                    inkGray[idx] = 255
                    continue
                }

                val k = if (isOcrPx) 0.105 else 0.165
                val threshold = mean * (1.0 - k * (1.0 - (std / 128.0).coerceIn(0.0, 0.85)))
                val v = lum[idx].toDouble()

                if (v >= threshold) {
                    inkGray[idx] = 255
                } else {
                    // 글자 획 내부는 진한 흑색(#0A0A0A)으로, 경계 1px은 부드럽게 안티앨리어싱하여 인쇄본처럼 정돈
                    val depth = (threshold - v) / (threshold * 0.26).coerceAtLeast(7.0)
                    val gVal = (255.0 * (1.0 - depth.coerceIn(0.0, 1.0) * 0.95)).toInt().coerceIn(8, 255)
                    inkGray[idx] = if (gVal > 225) 255 else gVal
                }
            }
        }

        // 3x3 고립 점 노이즈 제거 (Despeckle: 종이 위 미세 먼지/카메라 센서 노이즈 완벽 제거)
        val outPixels = IntArray(w * h) { Color.WHITE }
        var inkMinX = w
        var inkMinY = h
        var inkMaxX = 0
        var inkMaxY = 0
        var totalInkPixels = 0

        for (y in 1 until (h - 1)) {
            val ro = y * w
            for (x in 1 until (w - 1)) {
                val idx = ro + x
                val g = inkGray[idx]
                if (g == 255) continue

                var darkNeighbors = 0
                if (inkGray[idx - 1] < 220) darkNeighbors++
                if (inkGray[idx + 1] < 220) darkNeighbors++
                if (inkGray[idx - w] < 220) darkNeighbors++
                if (inkGray[idx + w] < 220) darkNeighbors++
                if (inkGray[idx - w - 1] < 220) darkNeighbors++
                if (inkGray[idx - w + 1] < 220) darkNeighbors++
                if (inkGray[idx + w - 1] < 220) darkNeighbors++
                if (inkGray[idx + w + 1] < 220) darkNeighbors++

                if (darkNeighbors >= 2) {
                    outPixels[idx] = (0xFF shl 24) or (g shl 16) or (g shl 8) or g
                    totalInkPixels++
                    if (x < inkMinX) inkMinX = x
                    if (x > inkMaxX) inkMaxX = x
                    if (y < inkMinY) inkMinY = y
                    if (y > inkMaxY) inkMaxY = y
                }
            }
        }

        val fullWhiteBmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        fullWhiteBmp.setPixels(outPixels, 0, w, 0, 0, w, h)

        if (filterMode != "text_only_zero_margin") {
            return fullWhiteBmp
        }

        // 3단계: 인식된 글자 영역에 맞춰 빈 여백을 완전히 제거(Zero-Margin Crop)하여 빈 종이에 글자만 꽉 차게 배치!
        var cropL: Int
        var cropT: Int
        var cropR: Int
        var cropB: Int

        if (expandedBoxes.isNotEmpty() && ocrUnionRight > ocrUnionLeft && ocrUnionBottom > ocrUnionTop) {
            cropL = minOf(ocrUnionLeft, if (totalInkPixels > 100) inkMinX else ocrUnionLeft)
            cropT = minOf(ocrUnionTop, if (totalInkPixels > 100) inkMinY else ocrUnionTop)
            cropR = maxOf(ocrUnionRight, if (totalInkPixels > 100) inkMaxX else ocrUnionRight)
            cropB = maxOf(ocrUnionBottom, if (totalInkPixels > 100) inkMaxY else ocrUnionBottom)
        } else if (totalInkPixels > 80 && inkMaxX > inkMinX && inkMaxY > inkMinY) {
            cropL = inkMinX
            cropT = inkMinY
            cropR = inkMaxX
            cropB = inkMaxY
        } else {
            return fullWhiteBmp
        }

        // 첫 글자/마지막 글자 획이 잘리지 않도록 최소 6px 보호 간격만 적용 (여백 제로 느낌)
        val safePad = 6
        cropL = (cropL - safePad).coerceIn(0, w - 1)
        cropT = (cropT - safePad).coerceIn(0, h - 1)
        cropR = (cropR + safePad).coerceIn(cropL + 1, w)
        cropB = (cropB + safePad).coerceIn(cropT + 1, h)

        val cw = cropR - cropL
        val ch = cropB - cropT
        if (cw < 64 || ch < 64) {
            return fullWhiteBmp
        }

        val cropped = Bitmap.createBitmap(fullWhiteBmp, cropL, cropT, cw, ch)
        if (cropped !== fullWhiteBmp) {
            fullWhiteBmp.recycle()
        }
        return cropped
    }

    private fun enhanceScannedDocumentBitmap(src: Bitmap): Bitmap {
        val w = src.width
        val h = src.height
        if (w <= 16 || h <= 16) return src

        val pixels = IntArray(w * h)
        src.getPixels(pixels, 0, w, 0, 0, w, h)

        val lum = IntArray(w * h)
        for (i in pixels.indices) {
            val px = pixels[i]
            val r = (px shr 16) and 0xFF
            val g = (px shr 8) and 0xFF
            val b = px and 0xFF
            lum[i] = (r * 77 + g * 150 + b * 29) shr 8
        }

        // 2D 로컬 배경 조명(종이 밝기) 추정 격자 (조명 그라데이션 및 책 가운데 그림자 완벽 제거)
        val gridCols = 16
        val gridRows = 20
        val bgGrid = IntArray(gridCols * gridRows)
        val hist = IntArray(256)

        for (gy in 0 until gridRows) {
            val y0 = (gy * h) / gridRows
            val y1 = ((gy + 1) * h) / gridRows
            for (gx in 0 until gridCols) {
                val x0 = (gx * w) / gridCols
                val x1 = ((gx + 1) * w) / gridCols
                java.util.Arrays.fill(hist, 0)
                var count = 0
                var y = y0
                while (y < y1) {
                    val rowOff = y * w
                    var x = x0
                    while (x < x1) {
                        hist[lum[rowOff + x]]++
                        count++
                        x += 2
                    }
                    y += 2
                }
                // 상위 15%(85th percentile) 밝기를 해당 영역의 종이 배경 밝기로 채택
                val targetRank = (count * 85) / 100
                var acc = 0
                var bgVal = 210
                for (v in 0..255) {
                    acc += hist[v]
                    if (acc >= targetRank) {
                        bgVal = v.coerceAtLeast(75)
                        break
                    }
                }
                bgGrid[gy * gridCols + gx] = bgVal
            }
        }

        // 격자 스무딩 (3x3 평균 필터로 블록 경계 현상 제거)
        val smoothGrid = IntArray(gridCols * gridRows)
        for (gy in 0 until gridRows) {
            for (gx in 0 until gridCols) {
                var sum = 0
                var cnt = 0
                for (dy in -1..1) {
                    val ny = (gy + dy).coerceIn(0, gridRows - 1)
                    for (dx in -1..1) {
                        val nx = (gx + dx).coerceIn(0, gridCols - 1)
                        sum += bgGrid[ny * gridCols + nx]
                        cnt++
                    }
                }
                smoothGrid[gy * gridCols + gx] = sum / cnt
            }
        }

        // 픽셀별 배경 조명 정규화 + S-커브 대비 강화 (종이는 순백색으로, 글씨는 진하고 선명하게)
        val normLum = IntArray(w * h)
        for (y in 0 until h) {
            val fy = (y.toFloat() / h.toFloat()) * (gridRows - 1)
            val gy0 = fy.toInt().coerceIn(0, gridRows - 1)
            val gy1 = (gy0 + 1).coerceIn(0, gridRows - 1)
            val ty = fy - gy0
            val rowOff = y * w

            for (x in 0 until w) {
                val fx = (x.toFloat() / w.toFloat()) * (gridCols - 1)
                val gx0 = fx.toInt().coerceIn(0, gridCols - 1)
                val gx1 = (gx0 + 1).coerceIn(0, gridCols - 1)
                val tx = fx - gx0

                val b00 = smoothGrid[gy0 * gridCols + gx0]
                val b10 = smoothGrid[gy0 * gridCols + gx1]
                val b01 = smoothGrid[gy1 * gridCols + gx0]
                val b11 = smoothGrid[gy1 * gridCols + gx1]

                val topBg = b00 + (b10 - b00) * tx
                val botBg = b01 + (b11 - b01) * tx
                val localBg = (topBg + (botBg - topBg) * ty).toInt().coerceAtLeast(65)

                val idx = rowOff + x
                val rawL = lum[idx]
                val rel = ((rawL * 255) / localBg).coerceIn(0, 255)

                // 종이 배경(rel >= 208)은 깨끗한 흰색(255)으로, 글씨(rel < 208)는 선명하게 다크닝
                val enhanced = if (rel >= 210) {
                    255
                } else if (rel <= 95) {
                    ((rel * 35) / 95).coerceIn(0, 255)
                } else {
                    val t = (rel - 95).toFloat() / (210f - 95f)
                    val sCurve = t * t * (3f - 2f * t)
                    (35f + sCurve * 220f).toInt().coerceIn(0, 255)
                }
                normLum[idx] = enhanced
            }
        }

        // 글자 윤곽선 샤프닝(Unsharp Mask) 및 컬러 잉크 보존 합성
        val outPixels = IntArray(w * h)
        for (y in 0 until h) {
            val rowOff = y * w
            val isEdgeY = (y == 0 || y == h - 1)
            for (x in 0 until w) {
                val idx = rowOff + x
                val center = normLum[idx]
                val sharpL = if (isEdgeY || x == 0 || x == w - 1 || center == 255) {
                    center
                } else {
                    val neighbors = (
                        normLum[idx - 1] +
                            normLum[idx + 1] +
                            normLum[idx - w] +
                            normLum[idx + w]
                        ) shr 2
                    (center + ((center - neighbors) * 3) / 4).coerceIn(0, 255)
                }

                if (sharpL >= 246) {
                    outPixels[idx] = Color.WHITE
                } else {
                    val px = pixels[idx]
                    val r = (px shr 16) and 0xFF
                    val g = (px shr 8) and 0xFF
                    val b = px and 0xFF
                    val maxC = maxOf(r, g, b)
                    val minC = minOf(r, g, b)
                    // 무채색(검은 글씨/연필/표)은 깔끔한 모노톤 잉크로, 컬러 형광펜/도표는 색감 유지
                    if (maxC - minC < 38) {
                        outPixels[idx] = (0xFF shl 24) or (sharpL shl 16) or (sharpL shl 8) or sharpL
                    } else {
                        val origL = lum[idx].coerceAtLeast(1)
                        val nr = ((r * sharpL) / origL).coerceIn(0, 255)
                        val ng = ((g * sharpL) / origL).coerceIn(0, 255)
                        val nb = ((b * sharpL) / origL).coerceIn(0, 255)
                        outPixels[idx] = (0xFF shl 24) or (nr shl 16) or (ng shl 8) or nb
                    }
                }
            }
        }

        val outBmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        outBmp.setPixels(outPixels, 0, w, 0, 0, w, h)
        return outBmp
    }
}

class ScanFileProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        val ctx = context ?: return null
        val fileName = uri.lastPathSegment ?: return null
        val scanDir = File(ctx.cacheDir, "camera_scans")
        if (!scanDir.exists()) scanDir.mkdirs()
        val targetFile = File(scanDir, fileName)
        if (!targetFile.exists()) {
            targetFile.createNewFile()
        }
        val pfdMode = if (mode.contains("w")) {
            ParcelFileDescriptor.MODE_READ_WRITE or
                ParcelFileDescriptor.MODE_CREATE or
                ParcelFileDescriptor.MODE_TRUNCATE
        } else {
            ParcelFileDescriptor.MODE_READ_ONLY
        }
        return ParcelFileDescriptor.open(targetFile, pfdMode)
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor {
        val name = uri.lastPathSegment ?: "scan.jpg"
        val cols = projection ?: arrayOf("_display_name", "_size")
        val cursor = MatrixCursor(cols, 1)
        val row = Array<Any?>(cols.size) { i ->
            when (cols[i]) {
                "_display_name" -> name
                "_size" -> 0L
                else -> null
            }
        }
        cursor.addRow(row)
        return cursor
    }

    override fun getType(uri: Uri): String = "image/jpeg"
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
