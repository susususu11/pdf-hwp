package app.easydoc.easy_doc_viewer

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.DataInputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.security.DigestInputStream
import java.security.MessageDigest
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var pendingPick: MethodChannel.Result? = null
    private var initialUri: Uri? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initialUri = documentUri(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDocument" -> pickDocument(result)
                "takeInitialDocument" -> {
                    val uri = initialUri
                    initialUri = null
                    if (uri == null) result.success(null) else importInto(uri, result)
                }
                "readText" -> readText(call.argument<String>("path"), result)
                "isSelfTest" -> result.success(intent?.getBooleanExtra("selftest", false) ?: false)
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val uri = documentUri(intent) ?: return
        importDocument(uri) { document, _ ->
            if (document != null) channel?.invokeMethod("documentOpened", document)
        }
    }

    private fun documentUri(source: Intent?): Uri? {
        val incoming = source ?: return null
        return when (incoming.action) {
            Intent.ACTION_VIEW -> incoming.data
            Intent.ACTION_SEND ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    incoming.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    @Suppress("DEPRECATION")
                    incoming.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                }
            else -> null
        }
    }

    private fun pickDocument(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "이미 파일을 고르는 중입니다", null)
            return
        }
        pendingPick = result
        val pick = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
        startActivityForResult(pick, PICK_REQUEST)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_REQUEST) return
        val result = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode == Activity.RESULT_OK && uri != null) importInto(uri, result) else result.success(null)
    }

    private fun importInto(uri: Uri, result: MethodChannel.Result) {
        importDocument(uri) { document, error ->
            if (error != null) result.error("import_failed", error.message, null) else result.success(document)
        }
    }

    /** 다른 앱의 파일은 권한이 곧 사라지므로 앱 저장공간으로 복사한다. */
    private fun importDocument(uri: Uri, done: (Map<String, String>?, Exception?) -> Unit) {
        executor.execute {
            try {
                val document = copyToStorage(uri)
                mainHandler.post { done(document, null) }
            } catch (error: Exception) {
                mainHandler.post { done(null, error) }
            }
        }
    }

    private fun copyToStorage(uri: Uri): Map<String, String> {
        val directory = File(filesDir, "documents").apply { mkdirs() }
        val temp = File.createTempFile("incoming", null, directory)
        val digest = MessageDigest.getInstance("SHA-256")
        val input = contentResolver.openInputStream(uri) ?: throw IllegalStateException("파일을 열 수 없습니다")
        input.use { source ->
            DigestInputStream(source, digest).use { hashed ->
                temp.outputStream().use { hashed.copyTo(it) }
            }
        }
        val hash = digest.digest().joinToString("") { "%02x".format(it) }
        val target = File(directory, hash)
        if (target.exists()) temp.delete() else temp.renameTo(target)
        return mapOf("path" to target.path, "name" to displayName(uri), "hash" to hash)
    }

    private fun readText(path: String?, result: MethodChannel.Result) {
        if (path == null) {
            result.error("bad_args", "파일 경로가 없습니다", null)
            return
        }
        executor.execute {
            try {
                val text = decodeText(File(path))
                mainHandler.post { result.success(text) }
            } catch (error: Exception) {
                mainHandler.post { result.error("read_failed", error.message, null) }
            }
        }
    }

    /** 한국 PC에서 만든 메모장 파일은 UTF-8이 아닌 경우가 많아 인코딩을 판별해 읽는다. */
    private fun decodeText(file: File): Map<String, Any> {
        val length = minOf(file.length(), MAX_TEXT_BYTES).toInt()
        val bytes = ByteArray(length)
        DataInputStream(file.inputStream()).use { it.readFully(bytes) }
        fun starts(vararg mark: Int): Boolean =
            length >= mark.size && mark.indices.all { (bytes[it].toInt() and 0xFF) == mark[it] }
        val text = when {
            starts(0xEF, 0xBB, 0xBF) -> String(bytes, 3, length - 3, Charsets.UTF_8)
            starts(0xFF, 0xFE) -> String(bytes, 2, length - 2, Charsets.UTF_16LE)
            starts(0xFE, 0xFF) -> String(bytes, 2, length - 2, Charsets.UTF_16BE)
            isUtf8(bytes) -> String(bytes, Charsets.UTF_8)
            else -> String(bytes, koreanCharset())
        }
        return mapOf("text" to text, "truncated" to (file.length() > MAX_TEXT_BYTES))
    }

    /** 잘린 파일의 끝에 걸린 미완성 글자는 오류로 치지 않는다. */
    private fun isUtf8(bytes: ByteArray): Boolean {
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        val output = CharBuffer.allocate(bytes.size + 1)
        return !decoder.decode(ByteBuffer.wrap(bytes), output, false).isError
    }

    private fun koreanCharset(): Charset =
        listOf("MS949", "windows-949", "EUC-KR").firstOrNull { Charset.isSupported(it) }?.let { Charset.forName(it) }
            ?: Charsets.UTF_8

    private fun displayName(uri: Uri): String {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val name = cursor.getString(0)
                if (!name.isNullOrBlank()) return name
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "문서"
    }

    private companion object {
        const val CHANNEL = "easy_doc_viewer/files"
        const val PICK_REQUEST = 4101
        const val MAX_TEXT_BYTES = 2L * 1024 * 1024
    }
}
