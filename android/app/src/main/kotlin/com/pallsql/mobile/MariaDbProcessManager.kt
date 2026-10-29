package com.pallsql.mobile

import android.content.Context
import android.os.Build
import android.system.Os
import android.system.OsConstants
import android.util.Log
import java.io.File
import java.io.IOException

/**
 * Owns the native MariaDB server process.
 *
 * PALLSQL ships a `mariadbd` that was cross compiled for Android (arm64-v8a and
 * armeabi-v7a) and packaged as `libmariadbd.so` so that Android extracts it into
 * `nativeLibraryDir`. This class is the only place that exec()s it:
 *
 *  * [runtimeInfo]  - which binaries are actually packaged for this ABI;
 *  * [initialize]   - one time `--bootstrap` of an empty data directory;
 *  * [start]        - exec mariadbd and return the real pid;
 *  * [stop]         - SIGTERM, wait, then SIGKILL;
 *  * [processStatus]- is the process from the pid file still alive;
 *  * [killStale]    - clean up a server that outlived the app process.
 *
 * Nothing here is mocked: when the binary is missing, [runtimeInfo] reports it
 * with the exact path that was checked and the app shows `Not installed`.
 */
class MariaDbProcessManager(private val context: Context) {

    companion object {
        private const val TAG = "PallsqlMariaDB"

        /** Server binary inside the APK. */
        private const val SERVER_LIB = "libmariadbd.so"

        /** Optional helpers packaged as libraries so Android extracts them. */
        private val SUPPORT_LIBS = listOf(
            "libmariadb-admin.so",
            "libmariadb-install-db.so",
            "libmariadbd-script.so",
        )

        /** Bootstrap SQL shipped as assets, applied in this order. */
        private val BOOTSTRAP_ASSETS = listOf(
            "mariadb/mysql_system_tables.sql",
            "mariadb/mysql_system_tables_data.sql",
            "mariadb/mysql_test_data_timezone.sql",
            "mariadb/fill_help_tables.sql",
        )
    }

    private var process: Process? = null

    /** Last pid we started or found, used by [stop] and [processStatus]. */
    private var lastPid: Int = 0

    private fun nativeDir(): File = File(context.applicationInfo.nativeLibraryDir)

    private fun binaryPath(name: String): File = File(nativeDir(), name)

    /** Directory that holds share/ (errmsg.sys, charsets) extracted from assets. */
    private fun supportDir(): File =
        File(context.filesDir, "mariadb/base").apply { mkdirs() }

    private fun dataDirOf(requested: String?): File {
        // Prefer the app private directory: Android does not allow executing a
        // server that writes into shared storage without scoped access.
        val base = File(context.filesDir, "mariadb")
        base.mkdirs()
        val fallback = File(base, "data")
        if (requested.isNullOrBlank()) {
            return fallback
        }
        val wanted = File(requested)
        return if (canUseDirectory(wanted)) wanted else fallback
    }

    private fun canUseDirectory(directory: File): Boolean {
        return try {
            directory.mkdirs()
            val probe = File(directory, ".pallsql-write-test")
            probe.writeText("ok")
            probe.delete()
            true
        } catch (error: IOException) {
            false
        }
    }

    // ------------------------------------------------------------------
    // Runtime discovery
    // ------------------------------------------------------------------

    fun runtimeInfo(): Map<String, Any?> {
        val server = binaryPath(SERVER_LIB)
        val support = SUPPORT_LIBS.map { binaryPath(it) }.filter { it.exists() }
        val abis = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            Build.SUPPORTED_ABIS.toList()
        } else {
            listOf(Build.CPU_ABI)
        }
        val installed = server.exists() && server.canExecute()
        val reason = when {
            !server.exists() ->
                "MariaDB server binary not packaged: ${server.absolutePath} " +
                    "does not exist for ABI ${abis.joinToString(", ")}"
            !server.canExecute() ->
                "MariaDB server binary is not executable: ${server.absolutePath}"
            else -> ""
        }
        val version = if (installed) readVersionFile() else null
        return mapOf(
            "installed" to installed,
            "serverBinary" to if (installed) server.absolutePath else null,
            "supportBinaries" to support.map { it.name },
            "abies" to abis,
            "reason" to reason,
            "baseDirectory" to supportDir().absolutePath,
            "version" to version,
            "nativeLibraryDir" to nativeDir().absolutePath,
        )
    }

    /** Reads the version the build pipeline wrote next to the binary. */
    private fun readVersionFile(): String? {
        val marker = File(nativeDir(), "libmariadb-version.so")
        if (marker.exists()) {
            return try {
                marker.readText().trim().takeIf { it.isNotEmpty() }
            } catch (error: IOException) {
                null
            }
        }
        return null
    }

    // ------------------------------------------------------------------
    // Initialisation
    // ------------------------------------------------------------------

    /**
     * Creates the system tables in [requestedDataDir] with `mariadbd --bootstrap`.
     *
     * An existing data directory (one that already has `ibdata1`) is never
     * re-initialised: the server would fail and the user's data would be at
     * risk. The caller gets `alreadyInitialised = true` instead.
     */
    fun initialize(
        requestedDataDir: String?,
        baseDirectory: String?,
        force: Boolean,
    ): Map<String, Any?> {
        val server = binaryPath(SERVER_LIB)
        if (!server.exists()) {
            return fail("MariaDB server binary is not packaged (${server.absolutePath})")
        }
        val dataDir = dataDirOf(requestedDataDir)
        val marker = File(dataDir, "ibdata1")
        if (marker.exists() && !force) {
            return mapOf(
                "ok" to true,
                "alreadyInitialised" to true,
                "dataDirectory" to dataDir.absolutePath,
                "output" to "existing data directory kept",
            )
        }
        val bootstrap = extractBootstrapScript()
            ?: return fail(
                "Bootstrap SQL is missing from the APK assets " +
                    "(assets/mariadb/mysql_system_tables.sql). " +
                    "The native build step has to package it.",
            )
        val base = baseDirectory?.takeIf { it.isNotBlank() }?.let { File(it) }
            ?: supportDir()
        val command = listOf(
            server.absolutePath,
            "--no-defaults",
            "--bootstrap",
            "--skip-grant-tables",
            "--basedir=${base.absolutePath}",
            "--datadir=${dataDir.absolutePath}",
            "--character-sets-dir=${File(base, "share/charsets").absolutePath}",
            "--lc-messages-dir=${File(base, "share/english").absolutePath}",
            "--log-error=${File(context.filesDir, "mariadb/init-error.log").absolutePath}",
        )
        return try {
            val builder = ProcessBuilder(command)
            builder.redirectErrorStream(true)
            val started = builder.start()
            bootstrap.inputStream().use { input ->
                started.outputStream.use { output -> input.copyTo(output) }
            }
            val finishedOk = started.waitFor()
            val output = started.inputStream.bufferedReader().readText()
            if (finishedOk == 0 && File(dataDir, "mysql").exists()) {
                mapOf(
                    "ok" to true,
                    "alreadyInitialised" to false,
                    "dataDirectory" to dataDir.absolutePath,
                    "output" to output.takeLast(4000),
                )
            } else {
                fail(
                    "mariadbd --bootstrap exited with $finishedOk",
                    detail = output.takeLast(4000),
                )
            }
        } catch (error: Exception) {
            fail("mariadbd --bootstrap could not run", detail = error.toString())
        }
    }

    /** Concatenates the bootstrap SQL assets into one temporary file. */
    private fun extractBootstrapScript(): File? {
        val target = File(context.cacheDir, "pallsql-bootstrap.sql")
        var found = false
        try {
            target.outputStream().use { out ->
                out.write("SET sql_mode='';\n".toByteArray())
                for (asset in BOOTSTRAP_ASSETS) {
                    try {
                        context.assets.open(asset).use { input ->
                            input.copyTo(out)
                            found = true
                            out.write('\n'.code)
                        }
                    } catch (missing: IOException) {
                        Log.w(TAG, "bootstrap asset $asset is not packaged")
                    }
                }
            }
        } catch (error: IOException) {
            Log.e(TAG, "could not build the bootstrap script", error)
            return null
        }
        return if (found) target else null
    }

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    fun start(
        requestedDataDir: String?,
        baseDirectory: String?,
        configPath: String?,
        port: Int,
        bindAddress: String,
        socketPath: String?,
        pidFile: String?,
        errorLogPath: String?,
        skipNetworking: Boolean,
    ): Map<String, Any?> {
        val server = binaryPath(SERVER_LIB)
        if (!server.exists()) {
            return fail("MariaDB server binary is not packaged (${server.absolutePath})")
        }
        if (isRunning()) {
            return mapOf(
                "ok" to true,
                "pid" to lastPid,
                "alreadyRunning" to true,
                "output" to "mariadbd is already running",
            )
        }
        val dataDir = dataDirOf(requestedDataDir)
        if (!File(dataDir, "ibdata1").exists()) {
            return fail("The MariaDB data directory was not initialised yet")
        }
        val base = baseDirectory?.takeIf { it.isNotBlank() }?.let { File(it) }
            ?: supportDir()
        val logFile = errorLogPath?.takeIf { it.isNotBlank() }?.let { File(it) }
            ?: File(context.filesDir, "mariadb/mariadb-error.log")
        logFile.parentFile?.mkdirs()

        val command = mutableListOf(
            server.absolutePath,
            "--no-defaults",
            "--basedir=${base.absolutePath}",
            "--datadir=${dataDir.absolutePath}",
            "--character-sets-dir=${File(base, "share/charsets").absolutePath}",
            "--lc-messages-dir=${File(base, "share/english").absolutePath}",
            "--port=$port",
            "--user=",
            "--skip-name-resolve",
            "--skip-host-cache",
            "--default-storage-engine=InnoDB",
        )
        if (skipNetworking) {
            command.add("--skip-networking")
        } else {
            command.add("--bind-address=$bindAddress")
        }
        socketPath?.takeIf { it.isNotBlank() }?.let { command.add("--socket=$it") }
        pidFile?.takeIf { it.isNotBlank() }?.let { command.add("--pid-file=$it") }
        // A dedicated config file would override the flags above, so it is only
        // validated, not applied here; the flags are the single source of truth.
        if (configPath != null && !File(configPath).exists()) {
            Log.w(TAG, "config file $configPath is missing, using flags only")
        }

        return try {
            val builder = ProcessBuilder(command)
            builder.redirectErrorStream(true)
            builder.redirectOutput(ProcessBuilder.Redirect.appendTo(logFile))
            val started = builder.start()
            process = started
            val pid = pidOf(started)
            lastPid = pid
            if (pidFile != null) {
                try {
                    File(pidFile).writeText(pid.toString())
                } catch (error: IOException) {
                    Log.w(TAG, "could not write the pid file", error)
                }
            }
            mapOf(
                "ok" to true,
                "pid" to pid,
                "dataDirectory" to dataDir.absolutePath,
                "logFile" to logFile.absolutePath,
                "command" to command.joinToString(" "),
            )
        } catch (error: Exception) {
            fail("mariadbd could not be started", detail = error.toString())
        }
    }

    fun stop(requestedPid: Int?, gracefulTimeoutMs: Int): Map<String, Any?> {
        val pid = requestedPid?.takeIf { it > 0 } ?: lastPid
        if (pid <= 0) {
            return mapOf("ok" to true, "output" to "no MariaDB process is known")
        }
        val live = process
        var signalled = false
        try {
            Os.kill(pid, OsConstants.SIGTERM)
            signalled = true
        } catch (error: Exception) {
            Log.w(TAG, "SIGTERM to $pid failed: $error")
        }
        if (live != null) {
            live.waitFor(gracefulTimeoutMs.toLong(), java.util.concurrent.TimeUnit.MILLISECONDS)
        } else {
            val deadline = System.currentTimeMillis() + gracefulTimeoutMs
            while (System.currentTimeMillis() < deadline && isPidAlive(pid)) {
                Thread.sleep(150)
            }
        }
        if (isPidAlive(pid)) {
            try {
                Os.kill(pid, OsConstants.SIGKILL)
            } catch (error: Exception) {
                Log.w(TAG, "SIGKILL to $pid failed: $error")
            }
        }
        val alive = isPidAlive(pid)
        if (!alive) {
            process = null
            lastPid = 0
        }
        return mapOf(
            "ok" to !alive,
            "signalled" to signalled,
            "pid" to pid,
            "reason" to if (alive) "mariadbd $pid is still alive" else "",
        )
    }

    fun processStatus(): Map<String, Any?> {
        val live = process?.isAlive == true
        val pid = if (lastPid > 0) lastPid else 0
        return mapOf(
            "running" to (live || (pid > 0 && isPidAlive(pid) && hasMariaDbCmdline(pid))),
            "pid" to pid,
        )
    }

    fun killStale(): Map<String, Any?> {
        if (lastPid <= 0 || !isPidAlive(lastPid)) {
            return mapOf("ok" to true, "output" to "nothing to clean up")
        }
        if (!hasMariaDbCmdline(lastPid)) {
            return mapOf(
                "ok" to false,
                "output" to "pid $lastPid is not mariadbd; left untouched",
            )
        }
        return try {
            Os.kill(lastPid, OsConstants.SIGTERM)
            Thread.sleep(1200)
            if (isPidAlive(lastPid)) {
                Os.kill(lastPid, OsConstants.SIGKILL)
            }
            lastPid = 0
            process = null
            mapOf("ok" to true, "output" to "stale mariadbd terminated")
        } catch (error: Exception) {
            mapOf("ok" to false, "output" to "could not terminate: $error")
        }
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private fun isRunning(): Boolean {
        return process?.isAlive == true || (lastPid > 0 && isPidAlive(lastPid))
    }

    private fun pidOf(started: Process): Int {
        return try {
            val field = started.javaClass.getDeclaredField("pid")
            field.isAccessible = true
            (field.get(started) as? Int) ?: 0
        } catch (error: Exception) {
            0
        }
    }

    private fun isPidAlive(pid: Int): Boolean {
        if (pid <= 0) {
            return false
        }
        val proc = File("/proc/$pid")
        return proc.exists()
    }

    private fun hasMariaDbCmdline(pid: Int): Boolean {
        return try {
            File("/proc/$pid/cmdline").readText().contains("mariadbd")
        } catch (error: Exception) {
            false
        }
    }

    private fun fail(reason: String, detail: String = ""): Map<String, Any?> =
        mapOf(
            "ok" to false,
            "reason" to reason,
            "output" to detail,
        )
}
