import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'config/constants.dart';
import 'screens/auto_playback_screen.dart';
import 'services/cauce_heartbeat_service.dart';
import 'services/device_authorization.dart';
import 'services/device_identity.dart';
import 'services/playback_socket_service.dart';
import 'services/playback_state.dart';
import 'services/power_executor.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  // Dispositivos con sensor (tablets) rotan solos entre vertical y
  // horizontal: todas las vistas del kiosk se adaptan a la orientación
  // del momento (video/imagen con contain, screensaver con bounds en
  // vivo). Se omite portraitDown (vertical boca abajo): una tablet en
  // soporte no se sostiene invertida; si algún día se monta así, es
  // una línea más. En Android TV no hay sensor y el landscape natural
  // manda; en Windows/Linux la llamada es un no-op.
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  final playbackService = await _startDeviceServices();
  runApp(CauceStreamApp(playbackService: playbackService));
}

/// Arranca los servicios globales del protocolo de dispositivos:
/// heartbeat HTTP (conectividad + `current_media`) y WebSocket de
/// playback (asignación vigente). Ambos comparten el [PlaybackState]
/// del medio confirmado en pantalla. Son globales a la app: viven
/// mientras esté abierta, sin importar la navegación.
///
/// Secuencia coordinada por [DeviceAuthorization] (el heartbeat es la
/// única vía de validación; no existe endpoint de consulta de
/// registro):
/// 1. Configuración (.env) e identidad (`device_uid`).
/// 2. [PlaybackState] + estado de autorización (nace `unknown`).
/// 3. [CauceHeartbeatService.start]: el primer heartbeat viaja de
///    inmediato.
/// 4. Se espera su veredicto ([CauceHeartbeatService.firstHeartbeat]):
///    solo una respuesta 200 marca `registered`. 202 (pendiente de
///    registro), 404 (desconocido), 401/422 (configuración inválida)
///    o un servidor inalcanzable dejan el canal WS deshabilitado.
/// 5. [PlaybackSocketService] arranca con esa puerta: sin
///    `registered` no abre conexión y queda a la escucha de
///    transiciones; el heartbeat sigue latiendo y detectará el
///    registro (o la eliminación) del dispositivo más adelante.
///
/// La pantalla funciona igual con o sin registro: sin canal, el
/// contenido persistido llegará en cuanto el registro se confirme;
/// el corazón de la app nunca depende del WebSocket.
Future<PlaybackSocketService?> _startDeviceServices() async {
  final deviceUid = await DeviceIdentity.resolve();
  debugPrint('[CAUCE] device_uid resuelto: "$deviceUid"');

  final serverUrl = AppConfig.cauceServerUrl;
  if (serverUrl == null) {
    debugPrint(
      '[CAUCE] CAUCE_SERVER_URL no está definida: heartbeats y WS '
      'deshabilitados',
    );
    return null;
  }
  if (deviceUid.isEmpty) {
    debugPrint(
      '[CAUCE] No se pudo resolver el nombre del dispositivo: '
      'heartbeats y WS deshabilitados',
    );
    return null;
  }

  final deviceKey = AppConfig.deviceSecret;
  final playbackState = PlaybackState();

  // Estado de autorización compartido: el heartbeat escribe los
  // veredictos del servidor y el canal WS los lee como puerta.
  final authorization = DeviceAuthorization();

  // Diagnóstico de energía al arranque (NO bloqueante: un canal lento o
  // ausente jamás debe retrasar el heartbeat ni el WebSocket).
  final powerExecutor = const MethodChannelPowerExecutor();
  unawaited(_logPowerCapabilities(powerExecutor));
  // Provisionamiento de tablet (diálogos del sistema, una sola vez por
  // instalación): Device Admin para apagar la pantalla por orden
  // remota y exención de optimización de batería para que en espera el
  // cliente siga alcanzable. En TV Owner ya aprovisionada y en
  // plataformas sin canal, es un no-op silencioso.
  unawaited(_ensurePowerProvisioning(powerExecutor));

  // El heartbeat NO lo sustituye el WS: sigue reportando conectividad
  // y el medio realmente en reproducción. Su primer latido es
  // inmediato y su veredicto (el que sea) es lo único que puede
  // autorizar el canal WS.
  final heartbeat = CauceHeartbeatService(
    baseUrl: serverUrl,
    deviceUid: deviceUid,
    deviceKey: deviceKey,
    playbackState: playbackState,
    authorization: authorization,
  )..start();
  await heartbeat.firstHeartbeat;
  debugPrint(
    '[CAUCE] Veredicto del primer heartbeat: ${authorization.status.name}',
  );

  final playbackService = PlaybackSocketService(
    baseUrl: serverUrl,
    deviceUid: deviceUid,
    deviceKey: deviceKey,
    playbackState: playbackState,
    authorization: authorization,
    powerExecutor: powerExecutor,
  )..start();
  return playbackService;
}

/// Loguea las capacidades de energía del dispositivo (si el box está
/// aprovisionado como Device Owner/Admin y puede apagar pantalla).
/// Corre en segundo plano: nunca bloquea el arranque de los servicios.
Future<void> _logPowerCapabilities(PowerExecutor executor) async {
  try {
    final caps = await executor.capabilities();
    debugPrint(
      '[CAUCE] Capacidades de energía: wake=${caps.canWake} '
      'standby=${caps.canStandby} device_owner=${caps.deviceOwner} '
      'admin_active=${caps.adminActive}',
    );
    if (!caps.canStandby) {
      debugPrint(
        '[CAUCE] Apagar pantalla NO disponible por la app: aprovisionar '
        'como Device Owner (client/docs/device_owner_setup.md)',
      );
    }
  } catch (e) {
    debugPrint('[CAUCE] No se pudieron consultar las capacidades de energía: $e');
  }
}

/// Pide al mediador (una vez por instalación, en diálogos del sistema)
/// los permisos que hacen viable el control de pantalla en tablets
/// sin aprovisionarlas como Device Owner:
/// 1. Notificaciones → One UI cancela ENCENDER en apps sin ellas.
/// 2. Device Admin clásico → `enterStandby` (goToSleep/lockNow).
/// 3. Exención de optimización de batería → en espera el cliente no
///    pierde red ni timers: el servidor puede despertarlo.
/// Ya-provisionado (TV Owner) o sin canal (desktop): no-op. Corre en
/// segundo plano: nunca retrasa heartbeats ni WebSocket.
Future<void> _ensurePowerProvisioning(PowerExecutor executor) async {
  try {
    final caps = await executor.capabilities();
    if (caps.deviceOwner) {
      // TV ya aprovisionada como Device Owner: nada que pedir.
      return;
    }
    final notifications = await executor.requestNotifications();
    debugPrint(
      '[CAUCE] Notificaciones ${notifications ? 'habilitadas o '
          'solicitadas' : 'no se pudieron pedir'}: One UI exige '
          'notificaciones activas para ENCENDER la pantalla',
    );
    if (!caps.adminActive) {
      final launched = await executor.requestDeviceAdmin();
      debugPrint(
        '[CAUCE] Device Admin ${launched ? 'pendiente de activar '
            '(diálogo del sistema abierto)': 'no se pudo pedir'}: sin él, '
            'APAGAR PANTALLA quedará denegado en esta tablet',
      );
    }
    final exempt = await executor.requestIgnoreBatteryOptimizations();
    debugPrint(
      '[CAUCE] Exención de optimización de batería '
      '${exempt ? 'activa o solicitada' : 'no se pudo pedir'}: sin ella, '
      'en espera la tablet dejaría de responder al servidor',
    );
  } on PowerExecutorException catch (e) {
    // platformUnsupported (desktop) y derivados: sin canal nativo no
    // hay nada que provisionar en este dispositivo.
    debugPrint('[CAUCE] Provisionamiento de energía no aplica: ${e.code}');
  } catch (e) {
    debugPrint('[CAUCE] No se pudo pedir el provisionamiento de energía: $e');
  }
}

class CauceStreamApp extends StatelessWidget {
  const CauceStreamApp({super.key, this.home, this.playbackService});

  final Widget? home;
  final PlaybackSocketService? playbackService;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
      child: MaterialApp(
        title: 'CAUCE Stream',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0A1628),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF1565C0),
            surface: Color(0xFF0D1D34),
          ),
          useMaterial3: true,
          focusColor: Colors.white,
        ),
        home:
            home ?? AutoPlaybackScreen(playbackService: playbackService),
      ),
    );
  }
}
