package com.freader.my_ebook_reader

import android.content.Context
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import android.content.ContentValues
import android.os.Environment
import android.provider.MediaStore
import android.view.ViewGroup
import android.webkit.WebView
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
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import kotlin.math.sqrt

class MainActivity : FlutterActivity(), SensorEventListener {
    private val METHOD_CHANNEL = "ebook_reader/volume_control"
    private val EVENT_CHANNEL = "ebook_reader/volume_events"
    private val PDF_CHANNEL = "ebook_reader/pdf_renderer"

    private var isVolumeInterceptEnabled = false
    private var eventSink: EventChannel.EventSink? = null
    private var pdfMethodChannel: MethodChannel? = null

    private var isVolUpPressed = false
    private var isVolDownPressed = false
    private var comboTriggered = false
    private var lastVolUpDownTime = 0L
    private var lastVolDownDownTime = 0L
    private var lastVolUpEventTime = 0L
    private var lastVolDownEventTime = 0L
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingVolUpRunnable: Runnable? = null
    private var pendingVolDownRunnable: Runnable? = null

    private var lastSpenSingleTime = 0L
    private var wasStylusButtonPressed = false
    private var mediaSession: MediaSession? = null

    private var sensorManager: SensorManager? = null
    private var accelerometer: Sensor? = null
    private var accelCurrent = SensorManager.GRAVITY_EARTH
    private var accelLast = SensorManager.GRAVITY_EARTH
    private var shakeAccel = 0.0f
    private var lastShakeTimestamp = 0L
    private var lastShakePeakTime = 0L
    private var shakeCount = 0
    private var firstShakeTime = 0L
    private val thumbExecutor = Executors.newFixedThreadPool(4)

    // 상단 상태표시줄을 한번 내렸을 때 약 1.5초 후 다시 숨김.
    // 예전처럼 0.75초마다 계속 확인하는 반복 작업은 배터리를 소모하므로, 상태표시줄이 나타날 때(창 인셋 변경)만 처리
    private var isActivityResumed = false
    private val reHideStatusBarRunnable = Runnable {
        if (isActivityResumed && isStatusBarCurrentlyVisible()) hideSystemStatusBar()
    }

    private fun scheduleStatusBarReHide() {
        mainHandler.removeCallbacks(reHideStatusBarRunnable)
        mainHandler.postDelayed(reHideStatusBarRunnable, 1500L)
    }

    // 흔들기(화면 잠금 해제)용 가속도 센서는 뷰어에서 '화면 잠금'이 켜져 있을 때만 켠다
    private var shakeListeningRequested = false

    private fun isStatusBarCurrentlyVisible(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val rootInsets = window?.decorView?.rootWindowInsets
                rootInsets?.isVisible(WindowInsets.Type.statusBars()) == true
            } else {
                @Suppress("DEPRECATION")
                (window.decorView.systemUiVisibility and View.SYSTEM_UI_FLAG_FULLSCREEN) == 0
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun hideSystemStatusBar(alsoHideNavBar: Boolean = false) {
        try {
            window.clearFlags(WindowManager.LayoutParams.FLAG_FORCE_NOT_FULLSCREEN)
            window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val lp = window.attributes
                val desiredCutout = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                } else {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
                if (lp.layoutInDisplayCutoutMode != desiredCutout) {
                    lp.layoutInDisplayCutoutMode = desiredCutout
                    window.attributes = lp
                }
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                window.setDecorFitsSystemWindows(false)
                window.insetsController?.let { controller ->
                    controller.systemBarsBehavior =
                        WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    // 중요: 태블릿 OneUI에서 navigationBars()와 statusBars()를 묶어서 호출하면 태스크바 때문에 상태표시줄 숨김 애니메이션이 취소되므로 반드시 분리!
                    controller.hide(WindowInsets.Type.statusBars())
                    if (alsoHideNavBar) {
                        try {
                            controller.hide(WindowInsets.Type.navigationBars())
                        } catch (_: Exception) {}
                    }
                }
            } else {
                @Suppress("DEPRECATION")
                window.decorView.systemUiVisibility = (
                    View.SYSTEM_UI_FLAG_FULLSCREEN
                        or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                        or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                        or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                        or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        or View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                )
            }
        } catch (_: Exception) {}
    }

    private fun applyRequestedScreenOrientation(mode: String) {
        requestedOrientation = when (mode) {
            "landscape" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            "portrait" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
            else -> ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
        hideSystemStatusBar()
        mainHandler.postDelayed({ hideSystemStatusBar() }, 180L)
        mainHandler.postDelayed({ hideSystemStatusBar() }, 450L)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        hideSystemStatusBar(alsoHideNavBar = true)
        mainHandler.postDelayed({ hideSystemStatusBar(alsoHideNavBar = true) }, 250L)
        mainHandler.postDelayed({ hideSystemStatusBar(alsoHideNavBar = true) }, 600L)

        window.decorView.setOnApplyWindowInsetsListener { v, insets ->
            val statusBarVisible = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                insets.isVisible(WindowInsets.Type.statusBars())
            } else {
                @Suppress("DEPRECATION")
                insets.systemWindowInsetTop > 0
            }
            if (statusBarVisible && isActivityResumed) {
                scheduleStatusBarReHide()
            }
            v.onApplyWindowInsets(insets)
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
            mainHandler.postDelayed({ hideSystemStatusBar() }, 120L)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        hideSystemStatusBar()
        mainHandler.postDelayed({ hideSystemStatusBar() }, 200L)
        mainHandler.postDelayed({ hideSystemStatusBar() }, 600L)
        setupSpenMediaSession()
        setupShakeSensor()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "setIntercept") {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    isVolumeInterceptEnabled = enabled
                    if (!enabled) {
                        setShakeListening(false)
                    }
                    updateMediaSessionState(enabled)
                    result.success(null)
                } else if (call.method == "statusBarHeight") {
                    // 상태표시줄 본래 높이(px) — 태블릿에서 상단바를 이만큼 항상 내려 둔다
                    val id = resources.getIdentifier("status_bar_height", "dimen", "android")
                    result.success(if (id > 0) resources.getDimensionPixelSize(id) else 0)
                } else if (call.method == "setShakeListening") {
                    setShakeListening(call.argument<Boolean>("enabled") ?: false)
                    result.success(null)
                } else if (call.method == "setScreenOrientation") {
                    val mode = call.argument<String>("mode") ?: "unspecified"
                    runOnUiThread {
                        applyRequestedScreenOrientation(mode)
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

        val pChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PDF_CHANNEL)
        pdfMethodChannel = pChannel
        pChannel.setMethodCallHandler { call, result ->
            if (call.method == "pdfSearchSupported") {
                result.success(pdfSearchSupported())
            } else if (call.method == "pdfSearch") {
                // 파일 내 단어 검색: 쪽마다 찾은 곳의 사각형(쪽 크기 대비 0~1)을 돌려 준다
                val path = call.argument<String>("path") ?: ""
                val query = call.argument<String>("query") ?: ""
                if (!pdfSearchSupported()) {
                    result.error("UNSUPPORTED", "PDF search needs Android 15 or a recent system update", null)
                    return@setMethodCallHandler
                }
                thumbExecutor.execute {
                    try {
                        val found = searchPdfText(path, query)
                        runOnUiThread { result.success(found) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("SEARCH_ERR", e.message, null) }
                    }
                }
            } else if (call.method == "pdfPageTexts") {
                // 목차용: 쪽마다의 글 [from, to) (지원하지 않는 기기에서는 빈 목록)
                val path = call.argument<String>("path") ?: ""
                val from = call.argument<Int>("from") ?: 0
                val to = call.argument<Int>("to") ?: 0
                if (!pdfSearchSupported()) {
                    result.success(emptyList<String>())
                    return@setMethodCallHandler
                }
                thumbExecutor.execute {
                    try {
                        val texts = pdfPageTexts(path, from, to)
                        runOnUiThread { result.success(texts) }
                    } catch (e: Exception) {
                        runOnUiThread { result.success(emptyList<String>()) }
                    }
                }
            } else if (call.method == "renderPdfFirstPageThumbnail") {
                val pdfPath = call.argument<String>("pdfPath") ?: call.argument<String>("filePath")
                val thumbPath = call.argument<String>("thumbPath") ?: call.argument<String>("outPath")
                val requestedW = call.argument<Int>("maxWidth") ?: 420
                if (pdfPath == null || thumbPath == null) {
                    result.error("INVALID_ARGS", "Missing paths", null)
                    return@setMethodCallHandler
                }
                thumbExecutor.execute {
                    try {
                        val thumbFile = File(thumbPath)
                        if (thumbFile.exists() && thumbFile.length() > 100L) {
                            runOnUiThread { result.success(thumbFile.absolutePath) }
                            return@execute
                        }
                        thumbFile.parentFile?.mkdirs()
                        val pdfFile = File(pdfPath)
                        if (!pdfFile.exists()) {
                            runOnUiThread { result.success(null) }
                            return@execute
                        }
                        val pfd = ParcelFileDescriptor.open(pdfFile, ParcelFileDescriptor.MODE_READ_ONLY)
                        val renderer = PdfRenderer(pfd)
                        if (renderer.pageCount > 0) {
                            val page = renderer.openPage(0)
                            val targetW = requestedW.coerceIn(320, 640)
                            val scale = targetW.toFloat() / page.width.toFloat().coerceAtLeast(1f)
                            val w = targetW
                            val h = (page.height * scale).toInt().coerceIn(320, 960)
                            val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                            bitmap.eraseColor(Color.WHITE)
                            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            page.close()
                            FileOutputStream(thumbFile).use { out ->
                                bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
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
                }
            } else if (call.method == "extractArchiveFirstImageThumbnail") {
                val archivePath = call.argument<String>("filePath")
                val thumbPath = call.argument<String>("outPath")
                val requestedW = call.argument<Int>("maxWidth") ?: 420
                if (archivePath == null || thumbPath == null) {
                    result.error("INVALID_ARGS", "Missing paths", null)
                    return@setMethodCallHandler
                }
                thumbExecutor.execute {
                    try {
                        val thumbFile = File(thumbPath)
                        if (thumbFile.exists() && thumbFile.length() > 100L) {
                            runOnUiThread { result.success(thumbFile.absolutePath) }
                            return@execute
                        }
                        val srcFile = File(archivePath)
                        if (!srcFile.exists()) {
                            runOnUiThread { result.success(null) }
                            return@execute
                        }
                        thumbFile.parentFile?.mkdirs()
                        ZipFile(srcFile).use { zip ->
                            val entries = zip.entries()
                            var bestEntry: ZipEntry? = null
                            var bestName = ""
                            while (entries.hasMoreElements()) {
                                val entry = entries.nextElement()
                                if (entry.isDirectory) continue
                                val lower = entry.name.lowercase()
                                if (lower.contains("__macosx") || lower.substringAfterLast('/').startsWith("._")) continue
                                if (lower.endsWith(".jpg") || lower.endsWith(".jpeg") || lower.endsWith(".png") || lower.endsWith(".webp")) {
                                    if (bestEntry == null || compareNaturalStrings(lower, bestName) < 0) {
                                        bestEntry = entry
                                        bestName = lower
                                    }
                                }
                            }
                            if (bestEntry != null) {
                                val rawBytes = zip.getInputStream(bestEntry).use { it.readBytes() }
                                val boundsOpts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                                BitmapFactory.decodeByteArray(rawBytes, 0, rawBytes.size, boundsOpts)
                                var sampleSize = 1
                                val targetW = requestedW.coerceIn(320, 640)
                                while (boundsOpts.outWidth / (sampleSize * 2) >= targetW) {
                                    sampleSize *= 2
                                }
                                val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sampleSize }
                                val decoded = BitmapFactory.decodeByteArray(rawBytes, 0, rawBytes.size, decodeOpts)
                                if (decoded != null) {
                                    FileOutputStream(thumbFile).use { out ->
                                        decoded.compress(Bitmap.CompressFormat.JPEG, 85, out)
                                    }
                                    decoded.recycle()
                                }
                            }
                        }
                        runOnUiThread {
                            result.success(if (thumbFile.exists() && thumbFile.length() > 64L) thumbFile.absolutePath else null)
                        }
                    } catch (e: Exception) {
                        runOnUiThread { result.success(null) }
                    }
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
            } else if (call.method == "wakeHiddenWebViews") {
                // 서재 표지(첫 페이지) 만들기용 화면 밖 WebView: 숨김 상태면 그리기를 멈추므로
                // 완전히 투명하게 + 화면 밖으로 옮긴 뒤 '보이는' 상태로 둔다 (사용자에게는 안 보임)
                var count = 0
                fun wake(v: View) {
                    if (v is WebView && v.visibility == View.INVISIBLE) {
                        v.alpha = 0f
                        v.translationX = -100000f
                        v.visibility = View.VISIBLE
                        count++
                    }
                    if (v is ViewGroup) {
                        for (i in 0 until v.childCount) wake(v.getChildAt(i))
                    }
                }
                wake(window.decorView)
                result.success(count)
            } else if (call.method == "snapshotWebView") {
                // 위로 밀어 넘길 때 지금 페이지를 잠깐 붙잡아 두는 그림 (JPEG 바이트, 빈 곳은 배경색)
                val webView = findLargestWebView(window.decorView)
                if (webView == null || webView.width <= 0 || webView.height <= 0) {
                    result.error("NO_WEBVIEW", "WebView not found", null)
                    return@setMethodCallHandler
                }
                try {
                    val bg = (call.argument<Number>("background") ?: 0xFF000000L).toLong().toInt()
                    val scale = ((call.argument<Number>("scale") ?: 1.0).toFloat()).coerceIn(0.25f, 1f)
                    val bw = maxOf(1, (webView.width * scale).toInt())
                    val bh = maxOf(1, (webView.height * scale).toInt())
                    val bmp = Bitmap.createBitmap(bw, bh, Bitmap.Config.ARGB_8888)
                    val canvas = Canvas(bmp)
                    canvas.drawColor(bg)
                    canvas.scale(bw.toFloat() / webView.width, bh.toFloat() / webView.height)
                    canvas.translate(-webView.scrollX.toFloat(), -webView.scrollY.toFloat())
                    webView.draw(canvas)
                    val transparent = (bg ushr 24) == 0
                    Thread {
                        try {
                            val out = java.io.ByteArrayOutputStream()
                            // 배경이 투명(종이 질감 위)이면 투명도를 살리는 PNG로
                            if (transparent) bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
                            else bmp.compress(Bitmap.CompressFormat.JPEG, 88, out)
                            bmp.recycle()
                            val bytes = out.toByteArray()
                            runOnUiThread { result.success(bytes) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("CAPTURE_ERR", e.message, null) }
                        }
                    }.start()
                } catch (e: Exception) {
                    result.error("CAPTURE_ERR", e.message, null)
                }
            } else if (call.method == "captureWebView") {
                // EPUB 본문(WebView) 화면을 그림 파일로 저장 (PDF 내보내기용)
                val outPath = call.argument<String>("path")
                val webView = findLargestWebView(window.decorView)
                if (outPath == null || webView == null || webView.width <= 0 || webView.height <= 0) {
                    result.error("NO_WEBVIEW", "WebView not found", null)
                    return@setMethodCallHandler
                }
                try {
                    val bmp = Bitmap.createBitmap(webView.width, webView.height, Bitmap.Config.ARGB_8888)
                    val canvas = Canvas(bmp)
                    canvas.translate(-webView.scrollX.toFloat(), -webView.scrollY.toFloat())
                    webView.draw(canvas)
                    Thread {
                        try {
                            FileOutputStream(File(outPath)).use { out -> bmp.compress(Bitmap.CompressFormat.PNG, 100, out) }
                            bmp.recycle()
                            runOnUiThread { result.success(outPath) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("CAPTURE_ERR", e.message, null) }
                        }
                    }.start()
                } catch (e: Exception) {
                    result.error("CAPTURE_ERR", e.message, null)
                }
            } else if (call.method == "exportPdfWithMemos") {
                // 페이지 그림 + 필기(+텍스트 메모)를 합쳐 PDF로 만들고 다운로드 폴더에 저장
                @Suppress("UNCHECKED_CAST")
                val pages = call.argument<List<Map<String, Any?>>>("pages")
                val fileName = call.argument<String>("fileName") ?: "FReader_export.pdf"
                val fallbackDir = call.argument<String>("fallbackDir")
                if (pages == null || pages.isEmpty()) {
                    result.error("INVALID_ARGS", "No pages", null)
                    return@setMethodCallHandler
                }
                Thread {
                    try {
                        val saved = exportPdfWithMemos(pages, fileName, fallbackDir)
                        runOnUiThread { result.success(saved) }
                    } catch (e: Exception) {
                        runOnUiThread { result.error("EXPORT_ERR", e.message, null) }
                    }
                }.start()
            } else if (call.method == "mergePdfs") {
                val inputPaths = call.argument<List<String>>("inputPaths")
                val outputPath = call.argument<String>("outputPath")
                if (inputPaths == null || outputPath == null || inputPaths.isEmpty()) {
                    result.error("INVALID_ARGS", "Missing inputPaths or outputPath", null)
                    return@setMethodCallHandler
                }
                Thread {
                    val outPdf = PdfDocument()
                    try {
                        var globalPageNum = 1
                        val totalFiles = inputPaths.size
                        for ((fileIdx, path) in inputPaths.withIndex()) {
                            val f = File(path)
                            if (!f.exists()) continue
                            val currentIdx = fileIdx + 1
                            val currentName = f.name
                            mainHandler.post {
                                try {
                                    pdfMethodChannel?.invokeMethod(
                                        "onPdfMergeProgress",
                                        mapOf(
                                            "current" to currentIdx,
                                            "total" to totalFiles,
                                            "fileName" to currentName
                                        )
                                    )
                                } catch (_: Exception) {}
                            }
                            val pfd = ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
                            val renderer = PdfRenderer(pfd)
                            for (i in 0 until renderer.pageCount) {
                                val srcPage = renderer.openPage(i)
                                val scale = (1440f / srcPage.width.toFloat().coerceAtLeast(1f)).coerceIn(1.5f, 2.2f)
                                val w = (srcPage.width * scale).toInt().coerceAtLeast(720)
                                val h = (srcPage.height * scale).toInt().coerceAtLeast(960)
                                val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                                bmp.eraseColor(Color.WHITE)
                                srcPage.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                srcPage.close()

                                val pageInfo = PdfDocument.PageInfo.Builder(w, h, globalPageNum++).create()
                                val dstPage = outPdf.startPage(pageInfo)
                                dstPage.canvas.drawBitmap(bmp, 0f, 0f, null)
                                outPdf.finishPage(dstPage)
                                bmp.recycle()
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
            } else if (call.method == "setScreenOrientation") {
                val mode = call.argument<String>("mode") ?: "unspecified"
                runOnUiThread {
                    applyRequestedScreenOrientation(mode)
                    result.success(true)
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
            accelCurrent = SensorManager.GRAVITY_EARTH
            accelLast = SensorManager.GRAVITY_EARTH
            shakeAccel = 0.0f
        } catch (_: Exception) {}
    }

    private fun setShakeListening(enabled: Boolean) {
        shakeListeningRequested = enabled
        if (enabled && isActivityResumed) {
            registerShakeSensorListener()
        } else if (!enabled) {
            try {
                sensorManager?.unregisterListener(this)
            } catch (_: Exception) {}
            shakeCount = 0
            shakeAccel = 0.0f
        }
    }

    private fun registerShakeSensorListener() {
        try {
            if (sensorManager == null || accelerometer == null) {
                setupShakeSensor()
            }
            accelerometer?.let {
                sensorManager?.unregisterListener(this, it)
                sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
            }
        } catch (_: Exception) {}
    }

    private fun compareNaturalStrings(a: String, b: String): Int {
        val reg = Regex("(\\d+)|(\\D+)")
        val ma = reg.findAll(a).map { it.value }.toList()
        val mb = reg.findAll(b).map { it.value }.toList()
        val len = minOf(ma.size, mb.size)
        for (i in 0 until len) {
            val pa = ma[i]
            val pb = mb[i]
            val na = pa.toBigIntegerOrNull()
            val nb = pb.toBigIntegerOrNull()
            val cmp = if (na != null && nb != null) na.compareTo(nb) else pa.compareTo(pb)
            if (cmp != 0) return cmp
        }
        return ma.size.compareTo(mb.size)
    }

    override fun onSensorChanged(event: SensorEvent?) {
        if (!isVolumeInterceptEnabled || event == null) return
        if (event.sensor.type != Sensor.TYPE_ACCELEROMETER) return

        val x = event.values[0]
        val y = event.values[1]
        val z = event.values[2]
        val magnitude = sqrt((x * x + y * y + z * z).toDouble()).toFloat()
        accelLast = accelCurrent
        accelCurrent = magnitude
        val delta = kotlin.math.abs(accelCurrent - accelLast)
        shakeAccel = shakeAccel * 0.80f + delta
        val gForce = magnitude / SensorManager.GRAVITY_EARTH

        // 일상적인 흔들림이나 손 움직임에서는 반응하지 않도록 임계값을 높이고, 명확하게 2번 흔들었을 때만 해제되도록 설정
        if (gForce > 2.42f && shakeAccel > 11.8f) {
            val now = SystemClock.uptimeMillis()
            if (now - lastShakeTimestamp < 1100L) return
            // 한 번 흔드는 동작의 시작·멈춤이 2번으로 중복 인식되지 않도록 최소 220ms 간격 보장
            if (now - lastShakePeakTime < 220L) return
            lastShakePeakTime = now

            if (now - firstShakeTime > 800L) {
                shakeCount = 1
                firstShakeTime = now
            } else {
                shakeCount++
            }

            if (shakeCount >= 2) {
                shakeCount = 0
                shakeAccel = 0.0f
                lastShakeTimestamp = now
                mainHandler.post {
                    eventSink?.success("SHAKE_TOGGLE")
                }
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    private fun handleInstantSpenClick() {
        val now = SystemClock.uptimeMillis()
        if (now - lastSpenSingleTime in 25L..420L) {
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
                        if (!isVolumeInterceptEnabled) return super.onMediaButtonEvent(mediaButtonIntent)
                        @Suppress("DEPRECATION")
                        val ke = mediaButtonIntent.getParcelableExtra<KeyEvent>(android.content.Intent.EXTRA_KEY_EVENT)
                        if (ke != null && ke.action == KeyEvent.ACTION_DOWN && ke.repeatCount == 0) {
                            when (ke.keyCode) {
                                KeyEvent.KEYCODE_MEDIA_NEXT,
                                KeyEvent.KEYCODE_MEDIA_PREVIOUS -> {
                                    handleDirectSpenDouble()
                                    return true
                                }
                                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                                KeyEvent.KEYCODE_MEDIA_PLAY,
                                KeyEvent.KEYCODE_MEDIA_PAUSE,
                                KeyEvent.KEYCODE_HEADSETHOOK -> {
                                    handleInstantSpenClick()
                                    return true
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

                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
                setPlaybackToLocal(attrs)
            }
        } catch (_: Exception) {}
    }

    private fun playSilentAudioPulseToClaimMediaSession() {
        Thread {
            try {
                val sampleRate = 8000
                val numSamples = sampleRate / 10
                val silentBuf = ByteArray(numSamples * 2)
                val track = AudioTrack.Builder()
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
                    .setBufferSizeInBytes(silentBuf.size)
                    .setTransferMode(AudioTrack.MODE_STATIC)
                    .build()
                track.write(silentBuf, 0, silentBuf.size)
                track.play()
                Thread.sleep(120)
                track.stop()
                track.release()
            } catch (_: Exception) {}
        }.start()
    }

    private fun updateMediaSessionState(active: Boolean) {
        try {
            mediaSession?.let { session ->
                if (active) {
                    val state = PlaybackState.Builder()
                        .setActions(
                            PlaybackState.ACTION_PLAY or
                                PlaybackState.ACTION_PAUSE or
                                PlaybackState.ACTION_PLAY_PAUSE or
                                PlaybackState.ACTION_SKIP_TO_NEXT or
                                PlaybackState.ACTION_SKIP_TO_PREVIOUS
                        )
                        .setState(PlaybackState.STATE_PLAYING, 1L, 1.0f, SystemClock.elapsedRealtime())
                        .build()
                    session.setPlaybackState(state)
                    session.isActive = true
                    playSilentAudioPulseToClaimMediaSession()
                } else {
                    val state = PlaybackState.Builder()
                        .setState(PlaybackState.STATE_STOPPED, 0L, 0.0f, SystemClock.elapsedRealtime())
                        .build()
                    session.setPlaybackState(state)
                    session.isActive = false
                }
            }
        } catch (_: Exception) {}
    }

    override fun onResume() {
        super.onResume()
        isActivityResumed = true
        hideSystemStatusBar(alsoHideNavBar = true)
        mainHandler.postDelayed({ hideSystemStatusBar(alsoHideNavBar = true) }, 250L)
        scheduleStatusBarReHide()
        if (shakeListeningRequested) registerShakeSensorListener()
        if (isVolumeInterceptEnabled) {
            updateMediaSessionState(true)
        }
    }

    override fun onPause() {
        isActivityResumed = false
        mainHandler.removeCallbacks(reHideStatusBarRunnable)
        try {
            sensorManager?.unregisterListener(this)
        } catch (_: Exception) {}
        super.onPause()
    }

    override fun onDestroy() {
        isActivityResumed = false
        mainHandler.removeCallbacks(reHideStatusBarRunnable)
        try {
            sensorManager?.unregisterListener(this)
            mediaSession?.isActive = false
            mediaSession?.release()
        } catch (_: Exception) {}
        super.onDestroy()
    }

    private fun checkStylusButtonEvent(ev: MotionEvent?): Boolean {
        if (!isVolumeInterceptEnabled || ev == null) return false
        val isStylus = ev.isFromSource(InputDevice.SOURCE_STYLUS) ||
            (ev.pointerCount > 0 && (
                ev.getToolType(0) == MotionEvent.TOOL_TYPE_STYLUS ||
                    ev.getToolType(0) == MotionEvent.TOOL_TYPE_ERASER
                ))
        if (!isStylus) return false

        val btnState = ev.buttonState
        val pressed = (btnState and MotionEvent.BUTTON_STYLUS_PRIMARY) != 0 ||
            (btnState and MotionEvent.BUTTON_SECONDARY) != 0

        if (pressed && !wasStylusButtonPressed) {
            wasStylusButtonPressed = true
            handleInstantSpenClick()
            return true
        } else if (!pressed && wasStylusButtonPressed) {
            wasStylusButtonPressed = false
        }
        return false
    }

    override fun dispatchGenericMotionEvent(ev: MotionEvent?): Boolean {
        if (isVolumeInterceptEnabled) {
            checkStylusButtonEvent(ev)
        }
        return super.dispatchGenericMotionEvent(ev)
    }

    override fun dispatchTouchEvent(ev: MotionEvent?): Boolean {
        if (ev != null && (ev.actionMasked == MotionEvent.ACTION_DOWN || ev.actionMasked == MotionEvent.ACTION_UP)) {
            if (isStatusBarCurrentlyVisible()) {
                hideSystemStatusBar()
            }
        }
        if (isVolumeInterceptEnabled) {
            checkStylusButtonEvent(ev)
        }
        return super.dispatchTouchEvent(ev)
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
            if (isVolUpPressed && (now - lastVolUpEventTime > 1800L)) {
                isVolUpPressed = false
            }
            if (isVolDownPressed && (now - lastVolDownEventTime > 1800L)) {
                isVolDownPressed = false
            }
            if (!isVolUpPressed && !isVolDownPressed && (now - lastVolUpDownTime > 500L) && (now - lastVolDownDownTime > 500L)) {
                comboTriggered = false
            }

            if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
                if (action == KeyEvent.ACTION_DOWN) {
                    lastVolUpEventTime = now
                    if (event.repeatCount == 0) {
                        lastVolUpDownTime = now
                        isVolUpPressed = true
                        if (isVolDownPressed || (now - lastVolDownDownTime in 0L..420L)) {
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
                        mainHandler.postDelayed(r, 130L)
                    }
                } else if (action == KeyEvent.ACTION_UP) {
                    isVolUpPressed = false
                    if (!isVolDownPressed) comboTriggered = false
                }
                return true
            }

            if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
                if (action == KeyEvent.ACTION_DOWN) {
                    lastVolDownEventTime = now
                    if (event.repeatCount == 0) {
                        lastVolDownDownTime = now
                        isVolDownPressed = true
                        if (isVolUpPressed || (now - lastVolUpDownTime in 0L..420L)) {
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
                        mainHandler.postDelayed(r, 130L)
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
                keyCode == KeyEvent.KEYCODE_MEDIA_PREVIOUS
            ) {
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
                keyCode == KeyEvent.KEYCODE_F2
            ) {
                if (action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                    handleInstantSpenClick()
                }
                return true
            }
        }

        return super.dispatchKeyEvent(event)
    }

    // ── PDF 내보내기 ──────────────────────────────────────────────────────────

    /** 화면에 보이는 WebView 중 가장 큰 것 (EPUB 본문) */
    private fun findLargestWebView(root: View): WebView? {
        var best: WebView? = null
        fun walk(v: View) {
            // 표지 만들기용 투명 WebView(alpha 0)는 제외
            if (v is WebView && v.isShown && v.alpha > 0f) {
                val b = best
                if (b == null || v.width * v.height > b.width * b.height) best = v
            }
            if (v is ViewGroup) {
                for (i in 0 until v.childCount) walk(v.getChildAt(i))
            }
        }
        walk(root)
        return best
    }

    /** 너무 큰 그림은 메모리를 넘지 않게 줄여서 읽는다 (긴 변 최대 약 3200px) */
    private fun decodePageBitmap(path: String): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 3200) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        return BitmapFactory.decodeFile(path, opts)
    }

    private fun exportPdfWithMemos(pages: List<Map<String, Any?>>, fileName: String, fallbackDir: String?): String {
        val doc = PdfDocument()
        val tmp = File(cacheDir, "export_${System.currentTimeMillis()}.pdf")
        try {
            val total = pages.size
            for ((idx, page) in pages.withIndex()) {
                val imagePath = page["image"] as? String ?: continue
                val bmp = decodePageBitmap(imagePath) ?: continue
                val w = bmp.width
                val h = bmp.height
                val info = PdfDocument.PageInfo.Builder(w, h, idx + 1).create()
                val pdfPage = doc.startPage(info)
                val canvas = pdfPage.canvas
                canvas.drawColor(Color.WHITE)
                canvas.drawBitmap(bmp, 0f, 0f, null)
                bmp.recycle()

                // 화면에서 그린 필기 굵기를 이 그림 크기에 맞게 키운다
                val refWidth = (page["refWidth"] as? Number)?.toFloat() ?: 0f
                val scale = if (refWidth > 1f) w / refWidth else 1f

                @Suppress("UNCHECKED_CAST")
                val strokes = page["strokes"] as? List<Map<String, Any?>> ?: emptyList()
                for (st in strokes) {
                    @Suppress("UNCHECKED_CAST")
                    val xs = (st["x"] as? List<Number>) ?: continue
                    @Suppress("UNCHECKED_CAST")
                    val ys = (st["y"] as? List<Number>) ?: continue
                    if (xs.isEmpty() || xs.size != ys.size) continue
                    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                        style = Paint.Style.STROKE
                        strokeCap = Paint.Cap.ROUND
                        strokeJoin = Paint.Join.ROUND
                        color = ((st["c"] as? Number)?.toLong() ?: 0xFFFFC107L).toInt()
                        strokeWidth = ((st["w"] as? Number)?.toFloat() ?: 2f) * scale
                    }
                    val path = Path()
                    path.moveTo(xs[0].toFloat() * w, ys[0].toFloat() * h)
                    if (xs.size == 1) {
                        path.lineTo(xs[0].toFloat() * w + 0.01f, ys[0].toFloat() * h)
                    } else {
                        for (i in 1 until xs.size) path.lineTo(xs[i].toFloat() * w, ys[i].toFloat() * h)
                    }
                    canvas.drawPath(path, paint)
                }

                // 텍스트 메모: 화면과 같은 노란 메모지 (왼쪽 위)
                val note = (page["note"] as? String)?.trim().orEmpty()
                if (note.isNotEmpty()) drawNoteBox(canvas, note, scale)

                doc.finishPage(pdfPage)
                val cur = idx + 1
                mainHandler.post {
                    try {
                        pdfMethodChannel?.invokeMethod("onPdfExportProgress", mapOf("current" to cur, "total" to total))
                    } catch (_: Exception) {}
                }
            }
            FileOutputStream(tmp).use { doc.writeTo(it) }
        } finally {
            doc.close()
        }
        try {
            return savePdfToDownloads(tmp, fileName, fallbackDir)
        } finally {
            tmp.delete()
        }
    }

    private fun drawNoteBox(canvas: Canvas, note: String, scale: Float) {
        val pad = 12f * scale
        val maxW = 220f * scale
        val tp = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xDD000000.toInt()
            textSize = 12f * scale
        }
        val innerMax = (maxW - 20f * scale).toInt().coerceAtLeast(10)
        val textW = minOf(innerMax.toFloat(), tp.measureText(note.replace('\n', ' '))).toInt().coerceAtLeast(10)
        val layout = StaticLayout.Builder.obtain(note, 0, note.length, tp, textW)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setMaxLines(3)
            .setEllipsize(TextUtils.TruncateAt.END)
            .build()
        val boxW = layout.width + 20f * scale
        val boxH = layout.height + 12f * scale
        val box = RectF(pad, pad, pad + boxW, pad + boxH)
        val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xF2FFE082.toInt() }
        val r = 8f * scale
        canvas.drawRoundRect(box, r, r, bg)
        canvas.save()
        canvas.translate(pad + 10f * scale, pad + 6f * scale)
        layout.draw(canvas)
        canvas.restore()
    }

    /** 다운로드/FReader 폴더에 저장. 안드로이드 10 미만이면 앱 서재 폴더에 저장. 저장 위치를 돌려준다. */
    private fun savePdfToDownloads(src: File, fileName: String, fallbackDir: String?): String {
        val safeName = fileName.replace(Regex("[\\\\/:*?\"<>|]"), "_")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
                put(MediaStore.MediaColumns.MIME_TYPE, "application/pdf")
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/FReader")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("Cannot create file in Downloads")
            resolver.openOutputStream(uri)?.use { out -> src.inputStream().use { it.copyTo(out) } }
                ?: throw IllegalStateException("Cannot write file in Downloads")
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            // 같은 이름이 있으면 시스템이 이름 뒤에 (1) 등을 붙이므로 실제 이름을 다시 읽는다
            var finalName = safeName
            try {
                resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) finalName = c.getString(0) ?: safeName
                }
            } catch (_: Exception) {}
            return Environment.DIRECTORY_DOWNLOADS + "/FReader/" + finalName
        }
        val dir = File(fallbackDir ?: filesDir.absolutePath)
        dir.mkdirs()
        var out = File(dir, safeName)
        var n = 1
        while (out.exists()) {
            out = File(dir, safeName.removeSuffix(".pdf") + " ($n).pdf")
            n++
        }
        src.copyTo(out)
        return out.absolutePath
    }

    // ── PDF 글자 검색 (안드로이드 15+, 또는 시스템 업데이트로 PDF 확장 13 이상인 11~14) ──
    private fun pdfSearchSupported(): Boolean {
        if (Build.VERSION.SDK_INT >= 35) return true
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        return try {
            android.os.ext.SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S) >= 13
        } catch (_: Throwable) {
            false
        }
    }

    @android.annotation.SuppressLint("NewApi")
    private fun searchPdfText(path: String, query: String): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        if (query.isBlank()) return out
        val pfd = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        try {
            if (Build.VERSION.SDK_INT >= 35) {
                PdfRenderer(pfd).use { renderer ->
                    for (i in 0 until renderer.pageCount) {
                        renderer.openPage(i).use { page ->
                            addPdfMatches(out, i, page.width.toFloat(), page.height.toFloat(), page.searchText(query))
                        }
                    }
                }
            } else {
                android.graphics.pdf.PdfRendererPreV(pfd).use { renderer ->
                    for (i in 0 until renderer.pageCount) {
                        renderer.openPage(i).use { page ->
                            addPdfMatches(out, i, page.width.toFloat(), page.height.toFloat(), page.searchText(query))
                        }
                    }
                }
            }
        } finally {
            try { pfd.close() } catch (_: Exception) {}
        }
        return out
    }

    @android.annotation.SuppressLint("NewApi")
    private fun pdfPageTexts(path: String, from: Int, to: Int): List<String> {
        val out = ArrayList<String>()
        val pfd = ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
        try {
            if (Build.VERSION.SDK_INT >= 35) {
                PdfRenderer(pfd).use { renderer ->
                    for (i in maxOf(0, from) until minOf(renderer.pageCount, to)) {
                        renderer.openPage(i).use { page -> out.add(page.textContents.joinToString("\n") { it.text }) }
                    }
                }
            } else {
                android.graphics.pdf.PdfRendererPreV(pfd).use { renderer ->
                    for (i in maxOf(0, from) until minOf(renderer.pageCount, to)) {
                        renderer.openPage(i).use { page -> out.add(page.textContents.joinToString("\n") { it.text }) }
                    }
                }
            }
        } finally {
            try { pfd.close() } catch (_: Exception) {}
        }
        return out
    }

    @android.annotation.SuppressLint("NewApi")
    private fun addPdfMatches(out: ArrayList<Map<String, Any>>, pageIndex: Int, w: Float, h: Float, matches: List<android.graphics.pdf.models.PageMatchBounds>) {
        if (w <= 0f || h <= 0f) return
        for (m in matches) {
            val rects = ArrayList<Double>()
            for (r in m.bounds) {
                rects.add((r.left / w).toDouble()); rects.add((r.top / h).toDouble())
                rects.add((r.right / w).toDouble()); rects.add((r.bottom / h).toDouble())
            }
            if (rects.isNotEmpty()) out.add(mapOf("page" to pageIndex, "rects" to rects))
        }
    }
}
