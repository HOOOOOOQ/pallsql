package com.pallsql.mobile

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.StatFs
import android.provider.OpenableColumns
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hosts the Flutter engine and exposes the small, explicitly allow-listed
 * native surface used by PALLSQL. No arbitrary command execution happens here.
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.pallsql.mobile/native"
        private const val PICK_FILE_REQUEST = 4201
        private const val NOTIFICATION_PERMISSION_REQUEST = 4202
    }

    private var pendingImportResult: MethodChannel.Result? = null
    private var pendingImportDirectory: String? = null

    /** Created lazily so a build without the runtime still starts. */
    private val mariaDb: MariaDbProcessManager by lazy { MariaDbProcessManager(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> handleCall(call, result) }
        requestNotificationPermissionIfNeeded()
    }

    private fun handleCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getDeviceInfo" -> result.success(deviceInfo())
            "getStorageStats" -> result.success(storageStats())
            "getNativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
            "startForegroundService" -> startServerService(call, result)
            "stopForegroundService" -> {
                stopService(Intent(this, PallsqlForegroundService::class.java))
                result.success(true)
            }
            "pickFile" -> pickFile(call, result)
            "shareFile" -> shareFile(call, result)
            "openUrl" -> openUrl(call, result)

            // MariaDB native runtime. Every call runs on a worker thread because
            // process start/stop blocks, and the UI must stay responsive.
            "mariadbRuntimeInfo" ->
                runOffThread(result) { mariaDb.runtimeInfo() }
            "mariadbInitialize" ->
                runOffThread(result) {
                    mariaDb.initialize(
                        requestedDataDir = call.argument<String>("dataDirectory"),
                        baseDirectory = call.argument<String>("baseDirectory"),
                        force = call.argument<Boolean>("force") == true,
                    )
                }
            "mariadbStart" ->
                runOffThread(result) {
                    mariaDb.start(
                        requestedDataDir = call.argument<String>("dataDirectory"),
                        baseDirectory = call.argument<String>("baseDirectory"),
                        configPath = call.argument<String>("configPath"),
                        port = call.argument<Int>("port") ?: 3306,
                        bindAddress = call.argument<String>("bindAddress")
                            ?: "127.0.0.1",
                        socketPath = call.argument<String>("socketPath"),
                        pidFile = call.argument<String>("pidFile"),
                        errorLogPath = call.argument<String>("errorLogPath"),
                        skipNetworking = call.argument<Boolean>("skipNetworking") == true,
                    )
                }
            "mariadbStop" ->
                runOffThread(result) {
                    mariaDb.stop(
                        requestedPid = call.argument<Int>("pid"),
                        gracefulTimeoutMs = call.argument<Int>("gracefulTimeoutMs")
                            ?: 8000,
                    )
                }
            "mariadbProcessStatus" ->
                runOffThread(result) { mariaDb.processStatus() }
            "mariadbKillStale" ->
                runOffThread(result) { mariaDb.killStale() }

            else -> result.notImplemented()
        }
    }

    /** Runs [block] on a background thread and returns its map to Flutter. */
    private fun runOffThread(
        result: MethodChannel.Result,
        block: () -> Map<String, Any?>,
    ) {
        Thread {
            try {
                val value = block()
                runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                runOnUiThread { result.error("mariadb_native", error.message, null) }
            }
        }.start()
    }

    private fun deviceInfo(): Map<String, Any?> {
        val versionName = try {
            packageManager.getPackageInfo(packageName, 0).versionName ?: "unknown"
        } catch (error: Exception) {
            "unknown"
        }
        return mapOf(
            "androidVersion" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "appVersion" to versionName,
            "packageName" to packageName,
            "appDataDir" to filesDir.parentFile?.absolutePath,
        )
    }

    private fun storageStats(): Map<String, Any?> {
        val stat = StatFs(filesDir.absolutePath)
        return mapOf(
            "appBytes" to (directorySize(filesDir) + directorySize(cacheDir)),
            "freeBytes" to stat.availableBytes,
            "totalBytes" to stat.totalBytes,
        )
    }

    private fun directorySize(directory: File, budget: Int = 20000): Long {
        val files = directory.listFiles() ?: return 0L
        var total = 0L
        var visited = 0
        for (file in files) {
            if (visited++ > budget) {
                break
            }
            total += if (file.isDirectory) directorySize(file, budget) else file.length()
        }
        return total
    }

    private fun startServerService(call: MethodCall, result: MethodChannel.Result) {
        val title = call.argument<String>("title") ?: "PALLSQL server"
        val text = call.argument<String>("text") ?: "Serving the local website"
        val intent = Intent(this, PallsqlForegroundService::class.java).apply {
            putExtra(PallsqlForegroundService.EXTRA_TITLE, title)
            putExtra(PallsqlForegroundService.EXTRA_TEXT, text)
        }
        try {
            ContextCompat.startForegroundService(this, intent)
            result.success(true)
        } catch (error: Exception) {
            result.error("service_failed", error.message, null)
        }
    }

    private fun pickFile(call: MethodCall, result: MethodChannel.Result) {
        val destination = call.argument<String>("destinationDirectory")
        if (destination == null) {
            result.error("invalid_argument", "destinationDirectory is required", null)
            return
        }
        val directory = File(destination).canonicalFile
        val sandbox = filesDir.canonicalFile
        if (!directory.path.startsWith(sandbox.path)) {
            result.error("invalid_path", "Destination must be inside app storage", null)
            return
        }
        if (pendingImportResult != null) {
            result.error("busy", "Another import is already running", null)
            return
        }
        pendingImportResult = result
        pendingImportDirectory = directory.absolutePath
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, PICK_FILE_REQUEST)
        } catch (error: ActivityNotFoundException) {
            pendingImportResult = null
            pendingImportDirectory = null
            result.error("no_picker", "No document picker available", null)
        }
    }

    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_FILE_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingImportResult
        val destination = pendingImportDirectory
        pendingImportResult = null
        pendingImportDirectory = null
        if (result == null) {
            return
        }
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null || destination == null) {
            result.success(null)
            return
        }
        try {
            val name = sanitizeFileName(queryDisplayName(uri))
            val directory = File(destination)
            if (!directory.exists()) {
                directory.mkdirs()
            }
            val target = File(directory, name)
            contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: throw IllegalStateException("Could not read the chosen file")
            result.success(target.absolutePath)
        } catch (error: Exception) {
            result.error("import_failed", error.message, null)
        }
    }

    private fun queryDisplayName(uri: Uri): String {
        val projection = arrayOf(OpenableColumns.DISPLAY_NAME)
        contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) {
                    val value = cursor.getString(index)
                    if (!value.isNullOrBlank()) {
                        return value
                    }
                }
            }
        }
        return "import-${System.currentTimeMillis()}"
    }

    private fun sanitizeFileName(raw: String): String {
        val base = raw.substringAfterLast('/').substringAfterLast('\\')
        val cleaned = base.replace("..", "_").trim()
        return if (cleaned.isEmpty()) {
            "import-${System.currentTimeMillis()}"
        } else {
            cleaned.take(120)
        }
    }

    private fun shareFile(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            result.error("invalid_argument", "path is required", null)
            return
        }
        val file = File(path).canonicalFile
        val sandbox = filesDir.canonicalFile
        if (!file.path.startsWith(sandbox.path) || !file.exists()) {
            result.error("invalid_path", "File is not inside app storage", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val mime = call.argument<String>("mimeType") ?: "application/octet-stream"
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(Intent.createChooser(intent, "Share PALLSQL file"))
            result.success(true)
        } catch (error: Exception) {
            result.error("share_failed", error.message, null)
        }
    }

    private fun openUrl(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url == null) {
            result.error("invalid_argument", "url is required", null)
            return
        }
        val uri = Uri.parse(url)
        val scheme = uri.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") {
            result.error("invalid_scheme", "Only http and https are supported", null)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_VIEW, uri)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            result.success(true)
        } catch (error: ActivityNotFoundException) {
            result.success(false)
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            return
        }
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }
}
