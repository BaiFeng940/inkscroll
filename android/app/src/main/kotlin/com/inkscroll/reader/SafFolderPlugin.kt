package com.inkscroll.reader

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * SAF（Storage Access Framework）文件夹导入。
 *
 * ## 为什么必须自己写这一层
 *
 * `file_picker.getDirectoryPath()` 在 **Android 11+ 上不可用**，原因有两层：
 *
 * 1. **系统限制**：Android 11 起，`ACTION_OPEN_DOCUMENT_TREE` **不允许**把
 *    存储根目录、`Download` 等受保护目录授权给应用，界面上直接显示
 *    "Can't use this folder / To protect your privacy, choose another folder"。
 *
 * 2. **插件实现限制**：`file_picker` 的 `getFullPathFromTreeUri()` 里
 *    Downloads provider 的路径转换被 `if (Build.VERSION.SDK_INT < R)` 包住 ——
 *    也就是**只在 Android 11 以下生效**。Android 11+ 从"下载"快捷入口进的目录
 *    拿不到真实路径，插件最终返回 null（或抛 `unknown_path`）。
 *
 * 结果就是"选了文件夹但什么都没发生"。
 *
 * ## 这里怎么做
 *
 * 不试图把 `content://` 转成文件路径（那本来就不可靠），而是**通过 SAF
 * 直接读文件内容**：枚举 tree URI 下的所有子文档，把每个文件用
 * `ContentResolver.openInputStream` 复制进应用私有目录。
 *
 * 这也顺带解决了阅读性能问题：复制完成后所有页都是本地文件，
 * 读取不再经过 SAF 的 Binder 往返（那是很慢的）。
 */
class SafFolderPlugin(
    private val activity: Activity,
    private val messenger: io.flutter.plugin.common.BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "inkscroll/saf"
        private const val REQ_TREE = 4210
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private var pendingResult: MethodChannel.Result? = null
    private var pendingDestDir: String? = null
    private var pendingExtensions: List<String> = emptyList()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // 用系统默认浏览器打开一个外部链接（设置里的「帮助文档」）。
            //
            // 为什么不引入 url_launcher：这里只需要"打开一个 URL"这一个动作，
            // 为它加一个第三方依赖（连带版本解析与新平台实现）不划算。
            // ★ 必须判断 resolveActivity —— 某些精简 ROM 上没有浏览器时，
            //   直接 startActivity 会抛 ActivityNotFoundException 把应用带崩。
            "openUrl" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrEmpty()) {
                    result.error("bad_args", "url 不能为空", null)
                    return
                }
                try {
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    if (intent.resolveActivity(activity.packageManager) == null) {
                        result.error("no_handler", "没有可打开该链接的应用", null)
                        return
                    }
                    activity.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("open_failed", e.message ?: "$e", null)
                }
            }
            "pickAndCopy" -> {
                if (pendingResult != null) {
                    result.error("busy", "已有一次选择正在进行", null)
                    return
                }
                val destDir = call.argument<String>("destDir")
                if (destDir.isNullOrEmpty()) {
                    result.error("bad_args", "destDir 不能为空", null)
                    return
                }
                pendingResult = result
                pendingDestDir = destDir
                pendingExtensions = call.argument<List<String>>("extensions") ?: emptyList()

                // 从"最近使用的位置"开始，用户可以自己导航
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                    addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                            Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
                    )
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        putExtra(DocumentsContract.EXTRA_INITIAL_URI, null as Uri?)
                    }
                }
                try {
                    activity.startActivityForResult(intent, REQ_TREE)
                } catch (e: Exception) {
                    finishWithError("no_picker", "系统没有可用的文件夹选择器：${e.message}")
                }
            }
            else -> result.notImplemented()
        }
    }

    /** @return true 表示这次结果由本插件消费 */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_TREE) return false
        val result = pendingResult ?: return true
        val destDir = pendingDestDir

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pendingResult = null
            pendingDestDir = null
            result.success(
                mapOf(
                    "cancelled" to true,
                    "copied" to 0,
                    "total" to 0,
                    "skipped" to 0,
                )
            )
            return true
        }

        val treeUri = data.data!!
        pendingResult = null
        pendingDestDir = null

        // 后台线程做 IO，别卡 UI
        Thread {
            try {
                val cr = activity.contentResolver
                try {
                    cr.takePersistableUriPermission(
                        treeUri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                } catch (_: Exception) {
                    // 拿不到持久权限不影响本次复制
                }

                val outcome = copyTree(cr, treeUri, File(destDir!!), pendingExtensions)
                activity.runOnUiThread {
                    result.success(
                        mapOf(
                            "cancelled" to false,
                            "copied" to outcome.copied,
                            "total" to outcome.total,
                            "skipped" to outcome.skipped,
                            "folderName" to outcome.folderName,
                        )
                    )
                }
            } catch (e: Exception) {
                activity.runOnUiThread {
                    result.error("copy_failed", e.message ?: e.toString(), null)
                }
            }
        }.start()

        return true
    }

    private class Outcome(
        var copied: Int = 0,
        var total: Int = 0,
        var skipped: Int = 0,
        var folderName: String = "",
    )

    private fun copyTree(
        cr: ContentResolver,
        treeUri: Uri,
        destDir: File,
        allowedExtensions: List<String>,
    ): Outcome {
        val out = Outcome()
        if (!destDir.exists()) destDir.mkdirs()

        val rootDocId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (e: Exception) {
            throw IllegalStateException("无法解析文件夹标识：${e.message}")
        }

        // 取文件夹显示名（不引入 androidx.documentfile 依赖，直接 query）
        try {
            val rootUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootDocId)
            cr.query(
                rootUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null, null, null
            )?.use { c ->
                if (c.moveToFirst()) {
                    out.folderName = c.getString(0) ?: ""
                }
            }
        } catch (_: Exception) {
            // 取名失败不影响导入
        }

        // 广度优先遍历（用显式栈，避免深目录递归爆栈）
        val stack = ArrayDeque<Pair<String, String>>() // docId to relativePath
        stack.addLast(rootDocId to "")

        val used = HashSet<String>()

        while (stack.isNotEmpty()) {
            val (docId, relPath) = stack.removeLast()
            val childrenUri = try {
                DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
            } catch (_: Exception) {
                continue
            }

            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            )

            val cursor = try {
                cr.query(childrenUri, projection, null, null, null)
            } catch (_: Exception) {
                null
            } ?: continue

            cursor.use { c ->
                val idIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                if (idIdx < 0 || nameIdx < 0) return@use

                while (c.moveToNext()) {
                    val childId = c.getString(idIdx) ?: continue
                    val name = c.getString(nameIdx) ?: continue
                    val mime = if (mimeIdx >= 0) c.getString(mimeIdx) else null

                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        stack.addLast(childId to if (relPath.isEmpty()) name else "$relPath/$name")
                        continue
                    }

                    out.total++

                    // 扩展名过滤（Dart 侧已经把允许列表准备好）
                    if (allowedExtensions.isNotEmpty()) {
                        val dot = name.lastIndexOf('.')
                        val ext = if (dot >= 0) name.substring(dot).lowercase() else ""
                        if (ext.isEmpty() || !allowedExtensions.contains(ext)) {
                            out.skipped++
                            continue
                        }
                    }

                    val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, childId)
                    try {
                        // 扁平存放 + 原名；重名时加后缀，避免互相覆盖。
                        // 之所以扁平化：文档模型里书内路径用 '/' 分类，
                        // 而这里保持"一本 = 一层目录"更简单，顺序由文件名保证。
                        var target = File(destDir, name)
                        if (used.contains(name)) {
                            var n = 2
                            val dot = name.lastIndexOf('.')
                            val base = if (dot > 0) name.substring(0, dot) else name
                            val suffix = if (dot > 0) name.substring(dot) else ""
                            while (true) {
                                val candidate = "${base}_$n$suffix"
                                if (!used.contains(candidate) && !File(destDir, candidate).exists()) {
                                    target = File(destDir, candidate)
                                    break
                                }
                                n++
                            }
                        }
                        cr.openInputStream(docUri)?.use { input ->
                            target.outputStream().use { output -> input.copyTo(output, 64 * 1024) }
                        } ?: run {
                            out.skipped++
                            continue
                        }
                        used.add(target.name)
                        out.copied++
                    } catch (_: Exception) {
                        out.skipped++
                    }
                }
            }
        }

        return out
    }

    private fun finishWithError(code: String, message: String) {
        val result = pendingResult ?: return
        pendingResult = null
        pendingDestDir = null
        result.error(code, message, null)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
