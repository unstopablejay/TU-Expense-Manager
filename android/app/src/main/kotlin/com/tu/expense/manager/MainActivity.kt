package com.tu.expense.manager

import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val tag = "TuExpenseTelephony"
    private val channelName = "com.tu.expense.manager/telephony"
    private var channel: MethodChannel? = null
    private var mmsObserver: ContentObserver? = null
    private val emittedSignatures = mutableSetOf<String>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "readInbox" -> {
                    val since = (call.argument<Number>("since"))?.toLong()
                    try {
                        val messages = readAllMessages(since)
                        Log.d(tag, "readInbox returned ${messages.size} messages (since: $since)")
                        result.success(messages)
                    } catch (e: Exception) {
                        Log.e(tag, "readInbox error: ${e.message}", e)
                        result.error("INBOX_ERROR", e.message, null)
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
        val uri = Uri.parse("content://sms/inbox")
        val projection = arrayOf("_id", "body", "date")
        val selection = if (sinceMillis != null && sinceMillis > 0) "date > ?" else null
        val selectionArgs = if (sinceMillis != null && sinceMillis > 0) arrayOf(sinceMillis.toString()) else null

        try {
            contentResolver.query(uri, projection, selection, selectionArgs, "date ASC")?.use { cursor ->
                val bodyIndex = cursor.getColumnIndex("body")
                val dateIndex = cursor.getColumnIndex("date")
                while (cursor.moveToNext()) {
                    val body = if (bodyIndex >= 0) cursor.getString(bodyIndex) else null
                    val date = if (dateIndex >= 0) cursor.getLong(dateIndex) else null
                    if (!body.isNullOrBlank() && date != null) {
                        results.add(mapOf("body" to body, "date" to date))
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(tag, "readSms failed: ${e.message}")
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
            contentResolver.query(mmsUri, projection, selection, selectionArgs, "date ASC")?.use { cursor ->
                val idIndex = cursor.getColumnIndex("_id")
                val dateIndex = cursor.getColumnIndex("date")

                while (cursor.moveToNext()) {
                    val mmsId = if (idIndex >= 0) cursor.getLong(idIndex) else continue
                    val dateSeconds = if (dateIndex >= 0) cursor.getLong(dateIndex) else continue
                    val dateMillis = dateSeconds * 1000L

                    val body = getMmsText(mmsId)
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

    private fun getMmsText(mmsId: Long): String? {
        val partUri = Uri.parse("content://mms/part")
        val projection = arrayOf("_id", "mid", "ct", "text")
        val selection = "mid = ?"
        val selectionArgs = arrayOf(mmsId.toString())

        try {
            contentResolver.query(partUri, projection, selection, selectionArgs, null)?.use { cursor ->
                val idIndex = cursor.getColumnIndex("_id")
                val ctIndex = cursor.getColumnIndex("ct")
                val textIndex = cursor.getColumnIndex("text")

                while (cursor.moveToNext()) {
                    val ct = if (ctIndex >= 0) cursor.getString(ctIndex) else null
                    if (ct == "text/plain") {
                        val text = if (textIndex >= 0) cursor.getString(textIndex) else null
                        if (!text.isNullOrBlank()) {
                            return text
                        }
                        val partId = if (idIndex >= 0) cursor.getLong(idIndex) else -1L
                        if (partId >= 0) {
                            try {
                                contentResolver.openInputStream(Uri.parse("content://mms/part/$partId"))?.use { stream ->
                                    val streamText = String(stream.readBytes(), Charsets.UTF_8)
                                    if (streamText.isNotBlank()) {
                                        return streamText
                                    }
                                }
                            } catch (_: Exception) {}
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(tag, "getMmsText failed for mid=$mmsId: ${e.message}")
        }
        return null
    }

    private fun startListening() {
        if (mmsObserver != null) return
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                super.onChange(selfChange, uri)
                handleContentChange()
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
        val cutoff = now - 60_000L
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
                channel?.invokeMethod("onIncomingMessage", mapOf("body" to body, "date" to date))
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
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
