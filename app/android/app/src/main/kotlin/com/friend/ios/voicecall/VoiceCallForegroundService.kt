package com.friend.ios.voicecall

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Foreground service (type `phoneCall`) carrying the ongoing-call notification
 * for the voice-mode session: CallStyle on API 31+ (the same treatment the
 * Claude app's voice mode gets — visible on the lock screen, red hang-up), a
 * plain ongoing notification with a hang-up action below that.
 *
 * Lifecycle is owned by [VoiceCallController]: started when the Connection
 * goes active, stopped on teardown. The hang-up action routes back through
 * this service (ACTION_HANGUP) purely because a PendingIntent needs a target;
 * the actual teardown decision is the controller's.
 */
class VoiceCallForegroundService : Service() {

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_HANGUP) {
            Log.i(TAG, "hang-up from notification")
            if (VoiceCallController.isInitialized) {
                VoiceCallController.instance.onHangUpFromNotification()
            } else {
                stopSelf()
            }
            return START_NOT_STICKY
        }
        createChannel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createChannel() {
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(CHANNEL_ID, "Voice conversation", NotificationManager.IMPORTANCE_DEFAULT).apply {
            setSound(null, null)
            enableVibration(false)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val hangUp = PendingIntent.getService(
            this,
            0,
            Intent(this, VoiceCallForegroundService::class.java).setAction(ACTION_HANGUP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val contentIntent = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE)
        }
        val builder = Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("Omi")
            .setContentText("Voice conversation")
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_CALL)
        contentIntent?.let { builder.setContentIntent(it) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val person = Person.Builder().setName("Omi").setImportant(true).build()
            builder.style = Notification.CallStyle.forOngoingCall(person, hangUp)
        } else {
            builder.addAction(Notification.Action.Builder(null, "Hang up", hangUp).build())
        }
        return builder.build()
    }

    companion object {
        private const val TAG = "VoiceCallFgs"
        private const val CHANNEL_ID = "omi_voice_call"
        private const val NOTIFICATION_ID = 41043
        private const val ACTION_HANGUP = "com.friend.ios.voicecall.HANGUP"

        fun start(context: Context) {
            context.startForegroundService(Intent(context, VoiceCallForegroundService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, VoiceCallForegroundService::class.java))
        }
    }
}
