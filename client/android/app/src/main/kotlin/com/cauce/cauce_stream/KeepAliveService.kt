package com.cauce.cauce_stream

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder

/**
 * Servicio en primer plano que evita que Android congele al cliente
 * en background mientras una web externa (Custom Tab de Chrome, p. ej.
 * la webAR con cámara de la sala) está abierta encima del kiosk.
 *
 * Sin él, el congelador de apps en caché detiene los timers y la red
 * del proceso: el heartbeat falla, el propio cliente revoca el canal
 * WS por "unreachable" y el servidor pierde el control del
 * dispositivo hasta que alguien cierra la web a mano.
 *
 * Lo arranca/detiene el cliente (canal `cauce_stream/device`):
 * arranca al abrir el Custom Tab, se detiene al cerrarlo (cambio de
 * medio o gesto atrás del mediador).
 */
class KeepAliveService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification(this))
        // START_STICKY: si el sistema lo mata, se reintenta mientras el
        // cliente siga esperando que la web esté abierta (el stop
        // explícito del canal lo apaga de verdad).
        return START_STICKY
    }

    companion object {
        private const val CHANNEL_ID = "cauce_external_url_keepalive"
        private const val NOTIFICATION_ID = 0x4B41

        fun start(context: Context) {
            context.startForegroundService(
                Intent(context, KeepAliveService::class.java)
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, KeepAliveService::class.java))
        }

        private fun buildNotification(context: Context): Notification {
            val manager =
                context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Contenido externo en pantalla",
                    NotificationManager.IMPORTANCE_MIN,
                ).apply {
                    description =
                        "Mantiene el canal de control activo mientras la " +
                            "experiencia web externa está abierta."
                }
            )
            return Notification.Builder(context, CHANNEL_ID)
                .setContentTitle("CAUCE Stream")
                .setContentText("Experiencia web externa en pantalla")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setOngoing(true)
                .build()
        }
    }
}
