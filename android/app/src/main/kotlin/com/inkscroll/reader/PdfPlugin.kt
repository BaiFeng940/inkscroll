package com.inkscroll.reader

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * PDF 渲染通道。
 *
 * ## 为什么用系统自带的 PdfRenderer
 *
 * Flutter 生态里常见的做法是引 `pdfx` / `pdf_render`，它们会把整个
 * **pdfium** 打进 APK（约 100 MB）。而我们只需要"按页渲染成位图"，
 * Android 从 5.0 起就自带 `PdfRenderer`（底层同样是 pdfium，但是在系统里），
 * 于是：
 *   · APK 体积零增长
 *   · 不用为三种 ABI 各带一份原生库
 *   · 系统渲染器随 ROM 更新，兼容性由厂商保证
 *
 * ## 关键约束
 *
 * · `PdfRenderer` 同一时刻只允许打开**一个页面**，必须串行使用；
 * · 它持有文件句柄，所以要按文档缓存实例，避免反复开关；
 * · 渲染宽度必须**上限**，否则大页面（A3 扫描件）能瞬间吃掉几百 MB。
 */
class PdfPlugin(
    private val messenger: io.flutter.plugin.common.BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "inkscroll/pdf"

        /** 渲染宽度的硬上限（像素）。1080p 手机一屏约 1080，2 倍余量足够。 */
        private const val MAX_RENDER_WIDTH = 2048
    }

    private val channel = MethodChannel(messenger, CHANNEL)

    /** path -> 打开中的文档。PdfRenderer 内部有句柄，复用能省掉重复解析。 */
    private val openDocs = HashMap<String, Opened>()

    private class Opened(
        val pfd: ParcelFileDescriptor,
        val renderer: PdfRenderer,
    ) {
        /** PdfRenderer 不允许并发，用锁串行化渲染。 */
        val lock = Any()
    }

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // 读取页数与每页尺寸（不渲染）
            "open" -> {
                val path = call.argument<String>("path")
                if (path.isNullOrEmpty()) {
                    result.error("bad_args", "path 不能为空", null)
                    return
                }
                try {
                    val doc = obtain(path)
                    synchronized(doc.lock) {
                        val n = doc.renderer.pageCount
                        val widths = ArrayList<Int>(n)
                        val heights = ArrayList<Int>(n)
                        for (i in 0 until n) {
                            doc.renderer.openPage(i).use { page ->
                                widths.add(page.width)
                                heights.add(page.height)
                            }
                        }
                        result.success(
                            mapOf(
                                "pageCount" to n,
                                "widths" to widths,
                                "heights" to heights,
                            )
                        )
                    }
                } catch (e: Exception) {
                    result.error("pdf_open_failed", e.message ?: "$e", null)
                }
            }

            // 渲染某一页为 PNG 字节
            "render" -> {
                val path = call.argument<String>("path")
                val index = call.argument<Int>("index") ?: -1
                val maxWidth = call.argument<Int>("maxWidth") ?: MAX_RENDER_WIDTH
                if (path.isNullOrEmpty() || index < 0) {
                    result.error("bad_args", "path / index 无效", null)
                    return
                }
                val target = ByteArrayOutputStream()
                try {
                    val doc = obtain(path)
                    synchronized(doc.lock) {
                        if (index >= doc.renderer.pageCount) {
                            result.error("out_of_range", "页码越界", null)
                            return
                        }
                        doc.renderer.openPage(index).use { page ->
                            // 按目标宽度等比缩放；不能超过硬上限
                            val w = minOf(maxWidth, MAX_RENDER_WIDTH)
                                .coerceAtLeast(64)
                            val h = (w.toFloat() * page.height / page.width)
                                .toInt().coerceAtLeast(1)
                            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                            // PDF 没有背景色概念，必须自己铺白，否则透明区域会变黑
                            bmp.eraseColor(Color.WHITE)
                            page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            bmp.compress(Bitmap.CompressFormat.PNG, 100, target)
                            bmp.recycle()
                        }
                    }
                    result.success(target.toByteArray())
                } catch (e: Exception) {
                    result.error("pdf_render_failed", e.message ?: "$e", null)
                }
            }

            "close" -> {
                val path = call.argument<String>("path")
                if (!path.isNullOrEmpty()) closeDoc(path)
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun obtain(path: String): Opened {
        openDocs[path]?.let { return it }
        val file = File(path)
        if (!file.exists()) throw IllegalStateException("文件不存在: $path")
        val pfd = ParcelFileDescriptor.open(
            file,
            ParcelFileDescriptor.MODE_READ_ONLY,
        )
        val renderer = PdfRenderer(pfd)
        return Opened(pfd, renderer).also { openDocs[path] = it }
    }

    private fun closeDoc(path: String) {
        openDocs.remove(path)?.let { doc ->
            try { doc.renderer.close() } catch (_: Exception) {}
            try { doc.pfd.close() } catch (_: Exception) {}
        }
    }

    /** 释放全部句柄。Activity 销毁时调用。 */
    fun dispose() {
        val paths = openDocs.keys.toList()
        paths.forEach { closeDoc(it) }
        channel.setMethodCallHandler(null)
    }
}
