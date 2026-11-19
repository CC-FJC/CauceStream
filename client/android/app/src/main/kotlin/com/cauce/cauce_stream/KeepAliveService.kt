package com.cauce.cauce_stream

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager

/**
 * Servicio en primer plano que evita que Android congele al cliente
 * en background mientras el kiosk NO es la ventana visible/activa.
 *
 * Lo mantienen encendido dos motivos (basta cualquiera):
 * - `webHold`: una web externa (Custom Tab de Chrome, p. ej. la webAR
 *   con cámara de la sala) está abierta encima del kiosk. Lo arma el
 *   canal `cauce_stream/device` al abrir la web y lo suelta al cerrarla.
 * - `screenOff`: la pantalla está apagada (standby por power.command
 *   o manual). Lo arma/desarma el broadcast de ACTION_SCREEN_OFF/ON:
 *   con cualquier medio (imagen, video, webview) el cliente sigue
 *   latiendo en espera y el servidor puede despertarlo.
 *
 * Sin él, el congelador de apps detiene los timers y la red del
 * proceso: el heartbeat falla, el propio cliente revoca el canal WS
 * por "unreachable" y el dispositivo aparece desconectado en la sala.
 *
 * Además retiene un PARTIAL_WAKE_LOCK (con la exención de
 * optimización de batería pedida al instalar, los timers siguen
 * corriendo en Doze profundo; sin red no hay WS).
 */
class KeepAliveService : Service() {

    private var cpuLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification(this))
        holdCpu()
        // START_STICKY: si el sistema lo mata, se reintenta mientras
        // algún motivo siga vigente (el stop explícito lo apaga de
        // verdad cuando ya no queda ninguno).
        return START_STICKY
    }

    override fun onDestroy() {
        releaseCpu()
        super.onDestroy()
    }

    private fun holdCpu() {
        if (cpuLock?.isHeld == true) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        @Suppress("WakelockTimeout")
        cpuLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "cauce:keepalive:cpu",
        ).apply {
            setReferenceCounted(false)
            acquire() // sin timeout: vive mientras el servicio
        }
    }

    private fun releaseCpu() {
        cpuLock?.let { if (it.isHeld) it.release() }
        cpuLock = null
    }

    companion object {
        private const val CHANNEL_ID = "cauce_keepalive"
        private const val NOTIFICATION_ID = 0x4B41

        @Volatile private var webHold = false
        @Volatile private var screenOff = false

        /** La web externa está abierta encima: mantener vivo el cliente. */
        fun holdWeb(context: Context, hold: Boolean) {
            webHold = hold
            refresh(context)
        }

        /** La pantalla se apagó/encendió: mantener vivo en espera. */
        fun noteScreen(context: Context, off: Boolean) {
            screenOff = off
            refresh(context)
        }

        fun start(context: Context) {
            context.startForegroundService(
                Intent(context, KeepAliveService::class.java)
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, KeepAliveService::class.java))
        }

        /**
         * Enciende el servicio si queda algún motivo; lo apaga de
         * verdad si ya no queda ninguno. El arranque desde broadcast
         * puede ser denegado por las restricciones de FGS en segundo
         * plano (Android 12+): se registra y se reintenta en el
         * siguiente evento; nunca rompe al cliente.
         */
        fun refresh(context: Context) {
            if (webHold || screenOff) {
                try {
                    start(context)
                } catch (e: Exception) {
                    android.util.Log.w(
                        "CAUCE",
                        "KeepAlive no pudo arrancar ahora: ${e.javaClass.simpleName}",
                    )
                }
            } else {
                stop(context)
            }
        }

        private fun buildNotification(context: Context): Notification {
            val manager =
                context.getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Canal de control del kiosk",
                    NotificationManager.IMPORTANCE_MIN,
                ).apply {
                    description =
                        "Mantiene los heartbeats y el WebSocket activos " +
                            "mientras el kiosk está en espera o una web " +
                            "externa está en pantalla."
                }
            )
            return Notification.Builder(context, CHANNEL_ID)
                .setContentTitle("CAUCE Stream")
                .setContentText("Canal de control activo (espera o web externa)")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setOngoing(true)
                .build()
        }
    }
}
