package com.example.my_ebook_reader

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "setIntercept") {
                    isVolumeInterceptEnabled = call.argument<Boolean>("enabled") ?: false
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
            mainHandler.postDelayed(r, 320L)
        }
    }

    // 갤럭시 S펜 호버 상태에서 펜 옆면 버튼을 누를 때 발생하는 스타일러스 버튼 이벤트 감지
    private var wasStylusButtonPressed = false
    override fun dispatchGenericMotionEvent(ev: MotionEvent?): Boolean {
        if (ev != null && (ev.isFromSource(InputDevice.SOURCE_STYLUS) || ev.getToolType(0) == MotionEvent.TOOL_TYPE_STYLUS)) {
            val isPressed = (ev.buttonState and MotionEvent.BUTTON_STYLUS_PRIMARY) != 0 ||
                            (ev.buttonState and MotionEvent.BUTTON_SECONDARY) != 0
            if (isPressed && !wasStylusButtonPressed) {
                wasStylusButtonPressed = true
                triggerSpenButtonPress()
                return true
            } else if (!isPressed) {
                wasStylusButtonPressed = false
            }
        }
        return super.dispatchGenericMotionEvent(ev)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (isVolumeInterceptEnabled) {
            if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
                if (event?.repeatCount == 0) {
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
                    mainHandler.postDelayed(r, 95L)
                }
                return true
            }
            if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
                if (event?.repeatCount == 0) {
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
                    mainHandler.postDelayed(r, 95L)
                }
                return true
            }

            // 갤럭시 태블릿 S펜 에어 액션(Air Actions) 원격 버튼 키코드 지원 (1번 클릭 / 2번 클릭)
            if (keyCode == KeyEvent.KEYCODE_PAGE_DOWN ||
                keyCode == KeyEvent.KEYCODE_DPAD_RIGHT ||
                keyCode == KeyEvent.KEYCODE_DPAD_DOWN ||
                keyCode == KeyEvent.KEYCODE_SPACE ||
                keyCode == KeyEvent.KEYCODE_ENTER ||
                keyCode == KeyEvent.KEYCODE_MEDIA_NEXT) {
                if (event?.repeatCount == 0) {
                    triggerSpenButtonPress()
                }
                return true
            }
            if (keyCode == KeyEvent.KEYCODE_PAGE_UP ||
                keyCode == KeyEvent.KEYCODE_DPAD_LEFT ||
                keyCode == KeyEvent.KEYCODE_DPAD_UP ||
                keyCode == KeyEvent.KEYCODE_MEDIA_PREVIOUS) {
                if (event?.repeatCount == 0) {
                    eventSink?.success("SPEN_DOUBLE")
                }
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (isVolumeInterceptEnabled) {
            if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
                isVolUpPressed = false
                if (!isVolDownPressed) comboTriggered = false
                return true
            }
            if (keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
                isVolDownPressed = false
                if (!isVolUpPressed) comboTriggered = false
                return true
            }
            if (keyCode == KeyEvent.KEYCODE_PAGE_DOWN ||
                keyCode == KeyEvent.KEYCODE_PAGE_UP ||
                keyCode == KeyEvent.KEYCODE_DPAD_RIGHT ||
                keyCode == KeyEvent.KEYCODE_DPAD_LEFT ||
                keyCode == KeyEvent.KEYCODE_DPAD_DOWN ||
                keyCode == KeyEvent.KEYCODE_DPAD_UP ||
                keyCode == KeyEvent.KEYCODE_SPACE ||
                keyCode == KeyEvent.KEYCODE_ENTER) {
                return true
            }
        }
        return super.onKeyUp(keyCode, event)
    }
}
