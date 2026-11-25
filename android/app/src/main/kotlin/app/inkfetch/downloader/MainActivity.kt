package app.inkfetch.downloader

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "app.inkfetch/native"
        private const val EVENT_CHANNEL = "app.inkfetch/native_events"
        private const val REQUEST_TREE = 4201
        private const val REQUEST_VPN = 4202
    }

    private var pendingResult: MethodChannel.Result? = null
    private var eventSink: EventChannel.EventSink? = null
    private val ioExecutor = Executors.newSingleThreadExecutor()

    /** 等待 VPN 授权期间暂存的启动参数。 */
    private var pendingVpnRequest: Map<String, String>? = null
    private var pendingVpnResult: MethodChannel.Result? = null

    @Volatile
    private var cancelCopy = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "defaultDownloadDir" -> {
                        val dir = getExternalFilesDir(null) ?: filesDir
                        result.success(dir.absolutePath)
                    }
                    "pickDirectory" -> launchDirectoryPicker(result)
                    "saveToDirectory" -> {
                        val src = call.argument<String>("srcPath")
                        val tree = call.argument<String>("treeUri")
                        val name = call.argument<String>("fileName") ?: "download.bin"
                        if (src == null || tree == null) {
                            result.error("bad_args", "缺少保存参数", null)
                        } else {
                            cancelCopy = false
                            ioExecutor.execute {
                                try {
                                    val saved = saveToTree(src, tree, name)
                                    runOnUiThread { result.success(saved) }
                                } catch (cancelled: CopyCancelledException) {
                                    runOnUiThread { result.success(null) }
                                } catch (error: Throwable) {
                                    runOnUiThread {
                                        result.error(
                                            "save_failed",
                                            error.message ?: "保存到文件夹失败",
                                            null
                                        )
                                    }
                                }
                            }
                        }
                    }
                    "cancelCopyToDirectory" -> {
                        cancelCopy = true
                        result.success(true)
                    }
                    "startDownloadService" -> {
                        val title = call.argument<String>("title") ?: "正在下载"
                        DownloadForegroundService.start(this, title)
                        result.success(true)
                    }
                    "stopDownloadService" -> {
                        DownloadForegroundService.stop(this)
                        result.success(true)
                    }
                    "openFile" -> {
                        val uri = call.argument<String>("uri")
                        val path = call.argument<String>("path")
                        result.success(openFile(uri, path))
                    }
                    "openFolder" -> {
                        val tree = call.argument<String>("treeUri")
                        val path = call.argument<String>("path")
                        result.success(openFolder(tree, path))
                    }
                    "accelStart" -> startAccel(call, result)
                    "accelStop" -> {
                        val intent = Intent(this, GithubAccelVpnService::class.java)
                        intent.action = GithubAccelVpnService.ACTION_STOP
                        startService(intent)
                        result.success(true)
                    }
                    "accelStatus" -> {
                        result.success(GithubAccelVpnService.isActive)
                    }
                    else -> result.notImplemented()
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
    }

    private fun emitProgress(done: Long, total: Long) {
        val sink = eventSink ?: return
        runOnUiThread {
            sink.success(
                mapOf(
                    "type" to "copyProgress",
                    "done" to done,
                    "total" to total
                )
            )
        }
    }

    /**
     * 启动 GitHub 加速 VPN。
     *
     * Android 要求使用 VpnService 必须先经用户同意（会弹系统授权框），
     * 所以这里分两步：没授权时先 prepare 拉起授权界面，授权后回到
     * onActivityResult 再真正启动。已经授权过就直接启动。
     */
    private fun startAccel(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val domainIps = HashMap<String, String>()
        @Suppress("UNCHECKED_CAST")
        val raw = call.argument<Map<String, String>>("domainIps")
        raw?.forEach { (k, v) -> domainIps[k] = v }
        if (domainIps.isEmpty()) {
            result.error("no_ips", "没有可用的 IP 列表", null)
            return
        }
        val upstream = call.argument<String>("upstream") ?: "223.5.5.5"

        val intent = android.net.VpnService.prepare(this)
        if (intent != null) {
            // 需要用户先授权；把参数存起来，等 onActivityResult 再启动。
            pendingVpnRequest = domainIps + mapOf(
                GithubAccelVpnService.EXTRA_UPSTREAM to upstream
            )
            pendingVpnResult = result
            try {
                startActivityForResult(intent, REQUEST_VPN)
            } catch (e: Exception) {
                pendingVpnRequest = null
                pendingVpnResult = null
                result.error("vpn_prepare_failed", e.message ?: "无法请求 VPN 权限", null)
            }
            return
        }
        launchVpnService(domainIps, upstream)
        result.success(true)
    }

    private fun launchVpnService(domainIps: HashMap<String, String>, upstream: String) {
        val intent = Intent(this, GithubAccelVpnService::class.java).apply {
            action = GithubAccelVpnService.ACTION_START
            putExtra(GithubAccelVpnService.EXTRA_UPSTREAM, upstream)
            putExtra(GithubAccelVpnService.EXTRA_DOMAIN_IPS, domainIps)
        }
        // 用 startService：本服务不以前台服务方式运行（VPN 的常驻通知
        // 由系统负责），用 startForegroundService 会在 5 秒内因为
        // 没调用 startForeground 而被系统判为 ANR。
        startService(intent)
    }

    private fun launchDirectoryPicker(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "选择器已打开", null)
            return
        }
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
            )
        }
        try {
            startActivityForResult(intent, REQUEST_TREE)
        } catch (error: Throwable) {
            pendingResult = null
            result.error("picker_failed", error.message ?: "无法打开文件夹选择器", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_VPN) {
            val request = pendingVpnRequest
            val vpnResult = pendingVpnResult
            pendingVpnRequest = null
            pendingVpnResult = null
            if (resultCode != Activity.RESULT_OK || request == null) {
                vpnResult?.error("vpn_denied", "用户拒绝了 VPN 授权", null)
                return
            }
            val upstream = request[GithubAccelVpnService.EXTRA_UPSTREAM] ?: "223.5.5.5"
            val domainIps = HashMap<String, String>()
            request.forEach { (k, v) ->
                if (k != GithubAccelVpnService.EXTRA_UPSTREAM) domainIps[k] = v
            }
            try {
                launchVpnService(domainIps, upstream)
                vpnResult?.success(true)
            } catch (e: Exception) {
                vpnResult?.error("vpn_start_failed", e.message ?: "无法启动加速", null)
            }
            return
        }
        if (requestCode != REQUEST_TREE) return
        val result = pendingResult
        pendingResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result?.success(null)
            return
        }
        try {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        } catch (_: Throwable) {
        }
        result?.success(
            mapOf(
                "uri" to uri.toString(),
                "name" to treeDisplayName(uri)
            )
        )
    }

    private fun treeDisplayName(tree: Uri): String {
        return try {
            val docId = DocumentsContract.getTreeDocumentId(tree)
            val docUri = DocumentsContract.buildDocumentUriUsingTree(tree, docId)
            contentResolver.query(
                docUri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            } ?: tree.lastPathSegment ?: "已选文件夹"
        } catch (_: Throwable) {
            tree.lastPathSegment ?: "已选文件夹"
        }
    }

    private fun saveToTree(
        srcPath: String,
        treeUriString: String,
        fileName: String
    ): Map<String, String> {
        val tree = Uri.parse(treeUriString)
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        val directoryUri = DocumentsContract.buildDocumentUriUsingTree(tree, rootId)
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, rootId)

        val existing = HashSet<String>()
        contentResolver.query(
            childrenUri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                cursor.getString(0)?.let { existing.add(it) }
            }
        }

        val extension = fileName.substringAfterLast('.', "")
        val baseName = if (extension.isEmpty()) {
            fileName
        } else {
            fileName.substring(0, fileName.length - extension.length - 1)
        }
        var name = fileName
        var counter = 1
        while (existing.contains(name)) {
            name = if (extension.isEmpty()) {
                "$baseName ($counter)"
            } else {
                "$baseName ($counter).$extension"
            }
            counter++
        }

        val mime = if (extension.isEmpty()) {
            "application/octet-stream"
        } else {
            MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(extension.lowercase())
                ?: "application/octet-stream"
        }

        val documentUri = DocumentsContract.createDocument(
            contentResolver,
            directoryUri,
            mime,
            name
        ) ?: throw IllegalStateException("无法在所选文件夹中创建文件")

        val source = File(srcPath)
        val total = source.length()
        var done = 0L
        emitProgress(0L, total)
        try {
            source.inputStream().use { input ->
                val output = contentResolver.openOutputStream(documentUri)
                    ?: throw IllegalStateException("无法写入所选文件夹")
                output.use { out ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        if (cancelCopy) throw CopyCancelledException()
                        val read = input.read(buffer)
                        if (read <= 0) break
                        out.write(buffer, 0, read)
                        done += read
                        emitProgress(done, total)
                    }
                    out.flush()
                }
            }
        } catch (error: Throwable) {
            // 复制中断时删除半成品，避免在用户文件夹里留下残文件。
            try {
                DocumentsContract.deleteDocument(contentResolver, documentUri)
            } catch (_: Throwable) {
            }
            throw error
        } finally {
            emitProgress(total, total)
        }

        return mapOf(
            "uri" to documentUri.toString(),
            "name" to name
        )
    }

    private fun mimeFor(path: String?, uri: Uri?): String {
        if (uri != null) {
            contentResolver.getType(uri)?.let { return it }
        }
        val extension = path?.substringAfterLast('.', "") ?: ""
        if (extension.isNotEmpty()) {
            MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(extension.lowercase())
                ?.let { return it }
        }
        return "application/octet-stream"
    }

    private fun openFile(uriString: String?, path: String?): Boolean {
        return try {
            val target: Uri = when {
                uriString != null && uriString.isNotEmpty() -> Uri.parse(uriString)
                path != null && path.isNotEmpty() -> {
                    val file = File(path)
                    if (!file.exists()) return false
                    FileProvider.getUriForFile(
                        this,
                        "$packageName.fileprovider",
                        file
                    )
                }
                else -> return false
            }
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(target, mimeFor(path, target))
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_ACTIVITY_NEW_TASK
                )
            }
            startActivity(intent)
            true
        } catch (_: Throwable) {
            false
        }
    }

    private fun openFolder(treeUriString: String?, path: String?): Boolean {
        if (treeUriString != null && treeUriString.isNotEmpty()) {
            val tree = Uri.parse(treeUriString)
            val candidates = mutableListOf<Uri>()
            try {
                val docId = DocumentsContract.getTreeDocumentId(tree)
                candidates.add(DocumentsContract.buildDocumentUriUsingTree(tree, docId))
            } catch (_: Throwable) {
            }
            candidates.add(tree)
            for (candidate in candidates) {
                try {
                    startActivity(
                        Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(
                                candidate,
                                DocumentsContract.Document.MIME_TYPE_DIR
                            )
                            addFlags(
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_ACTIVITY_NEW_TASK
                            )
                        }
                    )
                    return true
                } catch (_: Throwable) {
                }
            }
        }
        val targetPath = path ?: return false
        return try {
            val file = File(targetPath)
            val directory = if (file.isFile) file.parentFile else file
            if (directory == null || !directory.exists()) return false
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                directory
            )
            startActivity(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            )
            true
        } catch (_: Throwable) {
            false
        }
    }
}

class CopyCancelledException : Exception("已取消复制")
