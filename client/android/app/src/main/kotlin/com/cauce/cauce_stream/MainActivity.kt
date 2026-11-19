package com.cauce.cauce_stream

import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import java.net.NetworkInterface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "cauce_stream/device"
    private val powerChannelName = "cauce.power/power"

    /// Receptor de encendido/apagado de pantalla: una pantalla apagada
    /// (standby manual o power.command) activa el guardián que mantiene
    /// al cliente latiendo en espera; al encender, si no hay web
    /// externa encima el servicio se apaga.
    private var screenReceiver: BroadcastReceiver? = null
    private var screenReceiverRegistered = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        registerScreenStateReceiver()
    }

    override fun onDestroy() {
        unregisterScreenStateReceiver()
        super.onDestroy()
    }

    private fun registerScreenStateReceiver() {
        if (screenReceiverRegistered) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    Intent.ACTION_SCREEN_OFF ->
                        KeepAliveService.noteScreen(context, true)
                    Intent.ACTION_SCREEN_ON ->
                        KeepAliveService.noteScreen(context, false)
                }
            }
        }
        registerReceiver(
            receiver,
            IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
            },
        )
        screenReceiver = receiver
        screenReceiverRegistered = true
        // Sincroniza el estado de pantalla desde el arranque (p. ej.
        // el kiosk abre con la pantalla ya apagada tras un reinicio).
        KeepAliveService.noteScreen(this, !isInteractive())
    }

    private fun unregisterScreenStateReceiver() {
        val receiver = screenReceiver ?: return
        try {
            unregisterReceiver(receiver)
        } catch (e: Exception) {
            // Ya desregitrado por el sistema: no rompe nada.
        }
        screenReceiver = null
        screenReceiverRegistered = false
    }

    private val adminComponent: ComponentName
        get() = ComponentName(this, CauceDeviceAdminReceiver::class.java)

    private fun devicePolicyManager(): DevicePolicyManager =
        getSystemService(DEVICE_POLICY_SERVICE) as DevicePolicyManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getDeviceName" -> {
                        // Nombre configurado del dispositivo, tal cual lo
                        // expone el SO; en TV boxes suele venir vacío y se
                        // usa el modelo como fallback.
                        val name = Settings.Global.getString(
                            contentResolver,
                            "device_name"
                        ) ?: Build.MODEL
                        result.success(name)
                    }
                    "getMacAddress" -> {
                        // MAC real de la interfaz activa para Wake-on-LAN
                        // del lado del servidor. WifiManager devuelve
                        // 02:00:00:00:00:00 desde Android 6 (privacidad),
                        // así que no se usa; se lee de NetworkInterface.
                        result.success(activeMacAddress())
                    }
                    "startKeepAlive" -> {
                        // Motivo "web externa abierta": el Custom Tab
                        // cubre el kiosk y Android congelaría al cliente
                        // en background: sin esto los heartbeats caen y
                        // el propio cliente revoca el WS.
                        try {
                            KeepAliveService.holdWeb(this, true)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "stopKeepAlive" -> {
                        // Suelta el motivo web: si la pantalla sigue
                        // encendida, el servicio se apaga de verdad;
                        // si está apagada, el guardián de pantalla lo
                        // mantiene.
                        KeepAliveService.holdWeb(this, false)
                        result.success(true)
                    }
                    "isInteractive" -> {
                        // Pantalla encendida: la fuente del device_state
                        // real del heartbeat (una web externa encima
                        // pausa la app, pero la pantalla sigue activa).
                        result.success(isInteractive())
                    }
                    "reorderKioskToFront" -> {
                        // Trae la activity del kiosk al frente cuando
                        // el Custom Tab cerrado en espera quedó "zombie"
                        // encima al encender la pantalla.
                        try {
                            startActivity(Intent(this, MainActivity::class.java).apply {
                                addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
                                    or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                            })
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, powerChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "wakeScreen" -> {
                        // Encender la pantalla (action "on"). La app sigue
                        // ejecutándose con la pantalla en espera (los
                        // heartbeats siguen llegando), así que el canal
                        // atiende el comando aunque la activity esté
                        // pausada. Idempotente: pantalla ya encendida es
                        // éxito.
                        wakeScreen()
                        result.success(true)
                    }
                    "enterStandby" -> {
                        // Apagar la pantalla (action "off") vía el
                        // DevicePolicyManager.goToSleep() oculto del
                        // framework (por reflexión) cuando la app está
                        // aprovisionada como Device Owner / Device Admin;
                        // si no, false y el cliente responde
                        // power.error/standby_denied.
                        result.success(enterStandby())
                    }
                    "getPowerCapabilities" -> {
                        result.success(powerCapabilities())
                    }
                    "requestDeviceAdmin" -> {
                        result.success(requestDeviceAdmin())
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        result.success(requestIgnoreBatteryOptimizations())
                    }
                    "requestNotifications" -> {
                        result.success(requestNotifications())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Apagar la pantalla (action "off").
    ///
    /// Android NO ofrece API pública compilable para que una app ponga la
    /// pantalla en espera: DevicePolicyManager.goToSleep(long) es @hide en
    /// el SDK público (no resuelve contra android.jar), pero existe en el
    /// framework y se invoca por reflexión. El chequeo de permisos del
    /// servicio pasa solo cuando la app es Device Owner (aprovisionamiento
    /// por ADB/QR; ver client/docs/device_owner_setup.md) o, en la mayoría
    /// de los OEM, con Device Admin activo. Sin aprovisionamiento (o si el
    /// OEM retiró el método oculto) devuelve false: el cliente responde
    /// power.error/standby_denied. Sin workarounds (overlay negro).
    private fun enterStandby(): Boolean {
        val dpm = devicePolicyManager()
        val owner = dpm.isDeviceOwnerApp(packageName)
        val adminActive = dpm.isAdminActive(adminComponent)
        if (!owner && !adminActive) return false
        // 1) Ruta ideal: goToSleep() duerme la pantalla SIN bloquear el
        //    dispositivo (time = 0: hasta el próximo evento de wake —
        //    power.command "on" con wake lock, IR del control, toque).
        try {
            val goToSleep = DevicePolicyManager::class.java
                .getMethod("goToSleep", Long::class.javaPrimitiveType)
            goToSleep.invoke(dpm, 0L)
            return true
        } catch (e: Exception) {
            // NoSuchMethodException (OEM sin el método oculto),
            // SecurityException (el servicio lo rechazó): cae al plan B.
        }
        // 2) Plan B: lockNow() (API pública del Device Admin clásico)
        //    bloquea el dispositivo y apaga la pantalla. El kiosk no
        //    define lockscreen: al despertar queda como estaba.
        if (adminActive) {
            return try {
                dpm.lockNow()
                true
            } catch (e: Exception) {
                false
            }
        }
        return false
    }

    /// Pantalla encendida (interactive): la fuente del `device_state`
    /// del heartbeat. Con una web externa encima la app está pausada,
    /// pero la pantalla (y la experiencia) siguen activas: eso es
    /// `active`, no "en espera".
    private fun isInteractive(): Boolean =
        (getSystemService(POWER_SERVICE) as PowerManager).isInteractive

    /// Diálogo único del sistema para eximir la app de la optimización
    /// de batería: con la pantalla en espera (Doze) el cliente conserva
    /// red y timers — el servidor puede seguir mandándole órdenes.
    /// true si ya estaba eximida o si el diálogo se lanzó.
    private fun requestIgnoreBatteryOptimizations(): Boolean {
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        if (pm.isIgnoringBatteryOptimizations(packageName)) return true
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                )
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    /// Capacidades reales de energía, para diagnóstico y para que la app
    /// sepa qué le falta aprovisionar antes de poder apagar la pantalla.
    private fun powerCapabilities(): Map<String, Any> {
        val dpm = devicePolicyManager()
        val owner = dpm.isDeviceOwnerApp(packageName)
        val adminActive = dpm.isAdminActive(adminComponent)
        return mapOf(
            // Wake lock con ACQUIRE_CAUSES_WAKEUP es API pública: encender
            // la pantalla siempre está soportado.
            "can_wake" to true,
            "can_standby" to (owner || adminActive),
            "device_owner" to owner,
            "admin_active" to adminActive,
        )
    }

    /// Lanza el diálogo del sistema para activar la app como Device Admin
    /// clásico (ACTION_ADD_DEVICE_ADMIN). Devuelve true si ya estaba activo
    /// o si el flujo se lanzó. Ojo: esto da Device Admin, no Device Owner;
    /// para Owner hace falta aprovisionamiento por ADB/QR (ver doc).
    private fun requestDeviceAdmin(): Boolean {
        val dpm = devicePolicyManager()
        if (dpm.isDeviceOwnerApp(packageName) || dpm.isAdminActive(adminComponent)) {
            return true
        }
        return try {
            startActivity(
                Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
                    putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, adminComponent)
                    putExtra(
                        DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                        "Cauce Stream necesita administración del dispositivo para " +
                            "poder apagar la pantalla de forma remota."
                    )
                }
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    /// MAC (upper-case, con ':') de la primera interfaz activa no
    /// loopback; null si ninguna tiene hardware address.
    private fun activeMacAddress(): String? {
        return try {
            val interfaces = NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
            for (iface in interfaces) {
                if (!iface.isUp || iface.isLoopback) continue
                val hw = iface.hardwareAddress
                if (hw != null && hw.isNotEmpty()) {
                    return hw.joinToString(":") { "%02X".format(it) }
                }
            }
            null
        } catch (e: Exception) {
            null
        }
    }

    /// Notificaciones habilitadas — requisito de ENCENDER en One UI:
    /// Samsung cancela el encendido de pantalla de apps sin
    /// notificaciones ("Screen__On : Cancel (notifications are
    /// disabled)"). true si ya están habilitadas o el diálogo del
    /// permiso de turno (API 33+) se lanzó.
    private fun requestNotifications(): Boolean {
        val nm = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        if (nm.areNotificationsEnabled()) return true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return try {
                requestPermissions(
                    arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                    0x4E01,
                )
                true
            } catch (e: Exception) {
                false
            }
        }
        // Pre-13: no hay diálogo; se habilitan a mano en Ajustes.
        return false
    }

    /// Enciende la pantalla desde código. La receta clásica (wake lock
    /// FULL_WAKE_LOCK | ACQUIRE_CAUSES_WAKEUP) la ignora Android 14+
    /// para apps con targetSdk 34+: la vía pública es lanzar una
    /// activity con setTurnScreenOn(true) — el sistema despierta la
    /// pantalla para crearla (el patrón de las alarmas). WakeActivity
    /// no pinta nada y termina al instante: el kiosk (o la web
    /// externa) queda debajo con la pantalla ya encendida. El wake
    /// lock se mantiene para targets viejos y como refuerzo.
    private fun wakeScreen() {
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        val alreadyInteractive = powerManager.isInteractive

        if (!alreadyInteractive) {
            @Suppress("DEPRECATION")
            val wakeLock = powerManager.newWakeLock(
                PowerManager.FULL_WAKE_LOCK
                    or PowerManager.ACQUIRE_CAUSES_WAKEUP
                    or PowerManager.ON_AFTER_RELEASE,
                "cauce:power:wake"
            )
            // Solo enciende, no se retiene: se libera por timeout.
            wakeLock.acquire(3_000L)
        }

        runOnUiThread {
            // Flags de la activity actual: si algo más la reanuda, que
            // sea verla y sin lockscreen.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setTurnScreenOn(true)
                setShowWhenLocked(true)
            } else {
                @Suppress("DEPRECATION")
                window.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED
                        or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                )
            }
            if (!alreadyInteractive) {
                startActivity(Intent(this, WakeActivity::class.java))
            }
        }
    }
}
