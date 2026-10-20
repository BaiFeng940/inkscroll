package com.inkscroll.reader

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener

class MainActivity : FlutterActivity() {

    private var safPlugin: SafFolderPlugin? = null
    private var refreshRate: RefreshRateController? = null
    private var pdfPlugin: PdfPlugin? = null
    private var surfaceRateApplied = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        safPlugin = SafFolderPlugin(this, flutterEngine.dartExecutor.binaryMessenger)
        refreshRate = RefreshRateController(this)
        pdfPlugin = PdfPlugin(flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // ★ 高刷新率适配（第一层）：切窗口显示模式。
        //   这一步不需要 Surface，越早做越好 —— 否则启动后会先在 60Hz
        //   下渲染一段再升上去，观感上就是"开头卡一下"。
        refreshRate?.applyWindowMode()

        // ★ 第二层：首帧渲染之后 Surface 才有效，这时才能真正声明帧率。
        //   用 Flutter 官方提供的 listener，比轮询 / postDelayed 可靠。
        val flutterView = findViewById<FlutterView>(FlutterActivity.FLUTTER_VIEW_ID)
        flutterView?.addOnFirstFrameRenderedListener(object : FlutterUiDisplayListener {
            override fun onFlutterUiDisplayed() {
                surfaceRateApplied = true
                refreshRate?.applySurfaceFrameRate()
            }

            override fun onFlutterUiNoLongerDisplayed() {
                // 不需要处理
            }
        })
    }

    override fun onResume() {
        super.onResume()
        // 从后台回来 / 息屏唤醒后，显示模式可能被系统改回去了，需要重设。
        refreshRate?.applyWindowMode()
        if (surfaceRateApplied) {
            refreshRate?.applySurfaceFrameRate()
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // 部分 ROM 要到窗口重新获得焦点时才应用显示模式，这里再补一次。
        if (hasFocus) {
            refreshRate?.applyWindowMode()
            refreshRate?.applySurfaceFrameRate()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // 交给 SAF 插件优先处理；它只消费自己发起的那个 requestCode
        if (safPlugin?.onActivityResult(requestCode, resultCode, data) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        pdfPlugin?.dispose()
        pdfPlugin = null
        safPlugin?.dispose()
        safPlugin = null
        refreshRate = null
        super.onDestroy()
    }
}
