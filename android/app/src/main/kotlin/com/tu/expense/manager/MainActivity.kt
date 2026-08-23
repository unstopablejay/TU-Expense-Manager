package com.tu.expense.manager

import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val tag = "TuExpenseTelephony"
    private val channelName = "com.tu.expense.manager/telephony"
    private var channel: MethodChannel? = null
    private var mmsObserver: ContentObserver? = null
    private val emittedSignatures = mutableSetOf<String>()
    private val backgroundExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "readInbox" -> {
                    val since = (call.argument<Number>("since"))?.toLong()
                    backgroundExecutor.execute {
                        try {
                            val messages = readAllMessages(since)
                            Log.d(tag, "readInbox returned ${messages.size} messages (since: $since)")
                            mainHandler.post {
                                result.success(messages)
                            }
                        } catch (e: Exception) {
                            Log.e(tag, "readInbox error: ${e.message}", e)
                            mainHandler.post {
                                result.error("INBOX_ERROR", e.message, null)
                            }
                        }
                    }
                }
                "startListening" -> {
                    startListening()
                    result.success(true)
                }
                "stopListening" -> {
                    stopListening()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun readAllMessages(sinceMillis: Long?): List<Map<String, Any>> {
        val list = mutableListOf<Map<String, Any>>()
        list.addAll(readSms(sinceMillis))
        list.addAll(readMms(sinceMillis))
        list.sortBy { (it["date"] as? Long) ?: 0L }
        return list
    }

    private fun readSms(sinceMillis: Long?): List<Map<String, Any>> {
        val results = mutableListOf<Map<String, Any>>()
        val seen = mutableSetOf<String>()
        val uris = listOf(
            Uri.parse("content://sms/inbox"),
            Uri.parse("content://sms")
        )

        for (uri in uris) {
            val projection = arrayOf("_id", "body", "date")
            val isInboxUri = uri.toString().endsWith("/inbox")
            val selection = if (sinceMillis != null && sinceMillis > 0) {
                if (isInboxUri) "date > ?" else "date > ? AND (type = 1 OR type IS NULL)"
            } else {
                if (isInboxUri) null else "type = 1 OR type IS NULL"
            }
            val selectionArgs = if (sinceMillis != null && sinceMillis > 0) {
                arrayOf(sinceMillis.toString())
            } else {
                null
            }

            try {
                contentResolver.query(uri, projection, selection, selectionArgs, "date ASC")?.use { cursor ->
                    val bodyIndex = cursor.getColumnIndex("body")
                    val dateIndex = cursor.getColumnIndex("date")
                    while (cursor.moveToNext()) {
                        val body = if (bodyIndex >= 0) cursor.getString(bodyIndex) else null
                        val date = if (dateIndex >= 0) cursor.getLong(dateIndex) else null
                        if (!body.isNullOrBlank() && date != null) {
                            val key = "$date:$body"
                            if (seen.add(key)) {
                                results.add(mapOf("body" to body, "date" to date))
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(tag, "readSms failed for $uri: ${e.message}")
            }

            if (results.isNotEmpty()) {
                break
            }
        }
        return results
    }

    private fun readMms(sinceMillis: Long?): List<Map<String, Any>> {
        val results = mutableListOf<Map<String, Any>>()
        val mmsUri = Uri.parse("content://mms")
        val projection = arrayOf("_id", "date")
        val selection = if (sinceMillis != null && sinceMillis > 0) {
            "date >= ?"
        } else {
            null
        }
        val selectionArgs = if (sinceMillis != null && sinceMillis > 0) {
            arrayOf((sinceMillis / 1000L).toString())
        } else {
            null
        }

        try {
            // 1. Fetch text parts efficiently in batch
            val textByMmsId = mutableMapOf<Long, String>()
            val partUri = Uri.parse("content://mms/part")
            val partProjection = arrayOf("_id", "mid", "ct", "text")
            val partSelection = "ct = ?"
            val partSelectionArgs = arrayOf("text/plain")

            try {
                contentResolver.query(partUri, partProjection, partSelection, partSelectionArgs, null)?.use { partCursor ->
                    val midIndex = partCursor.getColumnIndex("mid")
                    val textIndex = partCursor.getColumnIndex("text")
                    val idIndex = partCursor.getColumnIndex("_id")

                    while (partCursor.moveToNext()) {
                        val mid = if (midIndex >= 0) partCursor.getLong(midIndex) else continue
                        val text = if (textIndex >= 0) partCursor.getString(textIndex) else null
                        if (!text.isNullOrBlank()) {
                            textByMmsId[mid] = text
                        } else {
                            val partId = if (idIndex >= 0) partCursor.getLong(idIndex) else -1L
                            if (partId >= 0 && !textByMmsId.containsKey(mid)) {
                                try {
                                    contentResolver.openInputStream(Uri.parse("content://mms/part/$partId"))?.use { stream ->
                                        val streamText = String(stream.readBytes(), Charsets.UTF_8)
                                        if (streamText.isNotBlank()) {
                                            textByMmsId[mid] = streamText
                                        }
                                    }
                                } catch (_: Exception) {}
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(tag, "batch mms part query failed: ${e.message}")
            }

            // 2. Match text parts with MMS dates
            contentResolver.query(mmsUri, projection, selection, selectionArgs, "date ASC")?.use { cursor ->
                val idIndex = cursor.getColumnIndex("_id")
                val dateIndex = cursor.getColumnIndex("date")

                while (cursor.moveToNext()) {
                    val mmsId = if (idIndex >= 0) cursor.getLong(idIndex) else continue
                    val dateSeconds = if (dateIndex >= 0) cursor.getLong(dateIndex) else continue
                    val dateMillis = dateSeconds * 1000L

                    val body = textByMmsId[mmsId]
                    if (!body.isNullOrBlank()) {
                        results.add(mapOf("body" to body, "date" to dateMillis))
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(tag, "readMms failed: ${e.message}")
        }
        return results
    }

    private fun startListening() {
        if (mmsObserver != null) return
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                super.onChange(selfChange, uri)
                backgroundExecutor.execute {
                    handleContentChange()
                }
            }
        }
        mmsObserver = observer
        try {
            contentResolver.registerContentObserver(Uri.parse("content://mms-sms/"), true, observer)
            contentResolver.registerContentObserver(Uri.parse("content://mms"), true, observer)
            contentResolver.registerContentObserver(Uri.parse("content://sms"), true, observer)
            Log.d(tag, "ContentObserver registered")
        } catch (e: Exception) {
            Log.e(tag, "Failed to register observer: ${e.message}")
        }
    }

    private fun handleContentChange() {
        val now = System.currentTimeMillis()
        val cutoff = now - 300_000L // 5-minute window for carrier timestamp tolerance
        val recent = readAllMessages(cutoff)
        for (msg in recent) {
            val body = msg["body"] as? String ?: continue
            val date = msg["date"] as? Long ?: continue
            val sig = "$date:$body"
            if (emittedSignatures.add(sig)) {
                if (emittedSignatures.size > 500) {
                    val toRemove = emittedSignatures.take(250).toSet()
                    emittedSignatures.removeAll(toRemove)
                }
                Log.d(tag, "Emitting real-time message: $body")
                mainHandler.post {
                    channel?.invokeMethod("onIncomingMessage", mapOf("body" to body, "date" to date))
                }
            }
        }
    }

    private fun stopListening() {
        mmsObserver?.let {
            contentResolver.unregisterContentObserver(it)
            mmsObserver = null
            Log.d(tag, "ContentObserver unregistered")
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        stopListening()
        channel?.setMethodCallHandler(null)
        channel = null
        backgroundExecutor.shutdown()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
