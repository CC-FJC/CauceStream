import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'device_authorization.dart';
import 'device_identity.dart';
import 'playback_state.dart';

/// Envía heartbeats periódicos al servidor Cauce (protocolo de
/// dispositivos, sin autenticación de usuario).
///
/// El device_uid es el nombre del dispositivo tal como lo expone el SO,
/// sin normalizar; va URL-encoded en la ruta. El device_state se deriva
/// (en Android) del estado real de la PANTALLA (`isInteractive`): una
/// app pausada porque una web externa está encima sigue `active`
/// (pantalla y experiencia corriendo); solo pantalla apagada es
/// `idle`. En plataformas sin el canal nativo (desktop, tests) cae al
/// ciclo de vida de la app (resumed -> active; resto -> idle). El
/// `status` (conectividad) NUNCA se reporta: lo determina el servidor.
///
/// El medio en reproducción se reporta en `payload.current_media`
/// (Media.id entero), leído del [PlaybackState] compartido: solo el
/// reproductor confirma qué está realmente en pantalla. Sin medio
/// confirmado el campo se OMITE y el servidor guarda "unknown".
/// El retirado `current_application` ya no se envía: el backend lo
/// trató siempre como atributo inerte.
///
/// Autorización del canal WS: cada veredicto del servidor (200, 202,
/// 404, 401, 422 o fallo de red) se traduce, cuando se inyecta
/// [authorization], al estado compartido [DeviceAuthorization]. Solo
/// la respuesta 200 confirma el registro y habilita la conexión
/// WebSocket de playback. El primer heartbeat sale inmediatamente al
/// arrancar el servicio y [firstHeartbeat] completa con ese veredicto:
/// el arranque lo espera antes de armar el canal. Los dispositivos
/// aún no registrados (202/404) latirán de forma progresiva
/// (intervalo base → 1.5x → 2x) sin superar el TTL de descubrimiento
/// del servidor (30 s), conservando el autodescubrimiento.
class CauceHeartbeatService with WidgetsBindingObserver {
  CauceHeartbeatService({
    required this.baseUrl,
    required this.deviceUid,
    this.deviceKey,
    this.playbackState,
    this.authorization,
    http.Client? client,
    Duration interval = const Duration(seconds: 10),
    Duration timeout = const Duration(seconds: 5),
    Future<String> Function()? resolveIpAddress,
    Future<String?> Function()? resolveMacAddress,
    Future<bool?> Function()? resolveIsInteractive,
    Future<Map<String, Object?>?> Function()? resolvePowerCaps,
  })  : _client = client ?? http.Client(),
        _interval = interval,
        _timeout = timeout,
        _resolveIpAddress = resolveIpAddress ?? _localIPv4Address,
        _resolveMacAddress = resolveMacAddress ?? DeviceIdentity.resolveMacAddress,
        _resolveIsInteractive =
            resolveIsInteractive ?? DeviceIdentity.resolveIsInteractive,
        _resolvePowerCaps = resolvePowerCaps;

  /// URL base del servidor (p. ej. http://10.15.1.150:8000).
  final String baseUrl;

  /// Nombre del dispositivo tal como lo expone el SO (sin normalizar).
  final String deviceUid;

  /// Secreto compartido con el servidor (X-Device-Key). null cuando el
  /// servidor no lo exige (modo transición).
  final String? deviceKey;

  /// Fuente compartida del medio confirmado en pantalla. null en
  /// pruebas aisladas del heartbeat.
  final PlaybackState? playbackState;

  /// Estado de autorización compartido con el canal WS (null en
  /// pruebas aisladas): cada veredicto del heartbeat se escribe aquí
  /// y solo `registered` habilita la conexión de playback.
  final DeviceAuthorization? authorization;

  final http.Client _client;
  final Duration _interval;
  final Duration _timeout;
  final Future<String> Function() _resolveIpAddress;
  final Future<String?> Function() _resolveMacAddress;
  final Future<bool?> Function() _resolveIsInteractive;

  /// Capacidades de energía de la plataforma (PowerExecutor). null en
  /// plataformas sin canal nativo: la clave simplemente no se envía.
  final Future<Map<String, Object?>?> Function()? _resolvePowerCaps;

  /// MAC resuelta una sola vez (la interfaz no cambia en operación);
  /// null si no se pudo determinar: entonces simplemente no se envía.
  String? _macAddress;
  bool _macResolved = false;

  Timer? _timer;
  bool _sending = false;
  bool _disposed = false;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  /// Grado del intervalo progresivo entre heartbeats de dispositivos
  /// aún no registrados (202/404): número de veredictos consecutivos
  /// sin registro. Cualquier otro veredicto lo reinicia.
  int _unregisteredStep = 0;

  /// Último veredicto aplicado (arranque: unknown). Se rastrea aquí
  /// además de en [authorization] para que el intervalo progresivo
  /// también funcione sin coordinación inyectada (pruebas aisladas).
  DeviceAuthorizationStatus _verdict = DeviceAuthorizationStatus.unknown;

  /// Completa cuando termina el PRIMER heartbeat (con éxito o sin
  /// él): el arranque esperará ese veredicto antes de armar el canal
  /// WS. Se completa también al disponer el servicio para que nadie
  /// quede colgado esperando.
  Completer<void>? _firstHeartbeat;

  Future<void> get firstHeartbeat =>
      _firstHeartbeat?.future ?? Future<void>.value();

  // Log de advertencias de solo una vez hasta que un heartbeat tenga
  // éxito, para no spamear mientras el servidor está caído.
  bool _warnedUnregistered = false;
  bool _warnedPendingRegistration = false;
  bool _warnedFailure = false;

  bool get isRunning => _timer != null;

  /// `active` con la app en primer plano; `idle` en cualquier otro
  /// estado del ciclo de vida (sigue enviando heartbeats: es estado
  /// operativo, no conectividad).
  String get deviceState =>
      _lifecycle == AppLifecycleState.resumed ? 'active' : 'idle';

  /// Estado operativo REAL reportado al servidor. En Android manda el
  /// estado de la pantalla (`isInteractive`): el kiosk pausado por una
  /// web externa encima sigue estando `active` (la experiencia corre);
  /// solo una pantalla apagada es `idle`. Sin el canal nativo (desktop,
  /// tests) decae al ciclo de vida.
  Future<String> _deviceState() async {
    final interactive = await _resolveIsInteractive();
    if (interactive != null) return interactive ? 'active' : 'idle';
    return deviceState;
  }

  void start() {
    if (_disposed || isRunning) return;
    debugPrint(
      '[CAUCE] Heartbeat iniciado (device_uid="$deviceUid", '
      'server=$baseUrl, cada ${_interval.inSeconds}s)',
    );
    WidgetsBinding.instance.addObserver(this);
    // Primer heartbeat inmediato (sin esperar el intervalo): su
    // veredicto es la primera palabra del servidor sobre el registro
    // y el arranque del canal WS lo espera.
    _firstHeartbeat ??= Completer<void>();
    unawaited(sendHeartbeat());
    _scheduleNext();
  }

  /// Detiene el temporizador pero permite reiniciar (p. ej. tras un 422
  /// se detiene para no reintentar en bucle con el mismo payload).
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    WidgetsBinding.instance.removeObserver(this);
    // Nadie debe quedar esperando un primer veredicto que no llegará.
    _completeFirstHeartbeat();
    _client.close();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    // Al volver a primer plano se envía de inmediato para que el
    // servidor detecte la recuperación rápido (offline -> online).
    if (state == AppLifecycleState.resumed && isRunning) {
      unawaited(sendHeartbeat());
    }
  }

  void _scheduleNext() {
    if (_disposed) return;
    _timer = Timer(_nextInterval() + _jitter(), _tick);
  }

  /// Intervalo del siguiente heartbeat según el último veredicto:
  /// confirmado o inalcanzable → intervalo base (detección rápida de
  /// cambios y de recuperación de red); pendiente/desconocido →
  /// progresivo (1x, 1x, 1.5x, 2x tope) para no sondear de forma
  /// agresiva a un equipo que el administrador todavía no registra.
  /// El tope queda por debajo del TTL de los pendientes del servidor
  /// (30 s): el autodescubrimiento nunca pierde al dispositivo por
  /// ralentizarse.
  Duration _nextInterval() {
    final unregistered = _verdict == DeviceAuthorizationStatus.pending ||
        _verdict == DeviceAuthorizationStatus.unknown;
    if (!unregistered) return _interval;
    switch (_unregisteredStep) {
      case 0:
      case 1:
        return _interval; // primer sondeo consecutivo sin registro: base
      case 2:
        return _interval * 1.5;
      default:
        return _interval * 2; // tope por debajo del TTL (30 s)
    }
  }

  Duration _jitter() =>
      Duration(milliseconds: Random().nextInt(2000) - 1000);

  Future<void> _tick() async {
    if (_disposed || !isRunning) return;
    await sendHeartbeat();
    // sendHeartbeat puede llamar a stop() (422): no reprogramar en ese caso.
    if (_disposed || !isRunning) return;
    _scheduleNext();
  }

  /// Envía un heartbeat individual. Nunca lanza: los fallos se loguean
  /// y el siguiente ciclo reintenta.
  Future<void> sendHeartbeat() async {
    if (_disposed || _sending) return;
    _sending = true;
    try {
      final ipAddress = await _resolveIpAddress();
      // La MAC se resuelve una sola vez y se reporta como campo general
      // (igual que la IP): el servidor la usa para Wake-on-LAN.
      if (!_macResolved) {
        _macAddress = await _resolveMacAddress();
        _macResolved = true;
      }
      final macAddress = _macAddress;
      // `current_media` solo va cuando el reproductor confirmó el
      // medio: el Media.id entero del contrato. Sin medio confirmado
      // se omite y el servidor guarda "unknown".
      final mediaId = playbackState?.currentMediaId;
      // `power_caps` (can_standby/can_wake por Device Admin/Owner) le
      // dice al servidor que este dispositivo puede ejecutar power por
      // su propio canal WS. Se resuelve en cada latido (los diálogos
      // de aprovisionamiento lo cambian a mitad de arranque); un
      // proveedor roto jamás rompe el heartbeat.
      Map<String, Object?>? powerCaps;
      try {
        powerCaps = await _resolvePowerCaps?.call();
      } catch (_) {
        powerCaps = null;
      }
      final body = jsonEncode({
        'ip_address': ipAddress,
        if (macAddress != null) 'mac_address': macAddress,
        'device_state': await _deviceState(),
        'payload': {
          if (mediaId != null) 'current_media': mediaId,
          if (powerCaps != null) 'power_caps': powerCaps,
        },
      });
      final uri = Uri.parse(
        '$baseUrl/api/devices/${Uri.encodeComponent(deviceUid)}/heartbeat',
      );
      final key = deviceKey;
      final response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              if (key != null) 'X-Device-Key': key,
            },
            body: body,
          )
          .timeout(_timeout);

      if (response.statusCode == 200) {
        _warnedUnregistered = false;
        _warnedPendingRegistration = false;
        _warnedFailure = false;
        _applyVerdict(DeviceAuthorizationStatus.registered);
      } else if (response.statusCode == 202) {
        // Autoconfig activo: aceptado como descubrimiento pendiente de
        // registro; se sigue latiendo con normalidad.
        if (!_warnedPendingRegistration) {
          _warnedPendingRegistration = true;
          debugPrint(
            '[CAUCE] Heartbeat 202: "$deviceUid" aceptado en espera de '
            'registro (autoconfig activo en el servidor)',
          );
        }
        _applyVerdict(DeviceAuthorizationStatus.pending);
      } else if (response.statusCode == 404) {
        if (!_warnedUnregistered) {
          _warnedUnregistered = true;
          debugPrint(
            '[CAUCE] Heartbeat 404: "$deviceUid" aún no está registrado '
            'en el servidor (autoconfig pendiente); se reintenta de '
            'forma progresiva',
          );
        }
        _applyVerdict(DeviceAuthorizationStatus.unknown);
      } else if (response.statusCode == 401) {
        // Clave de dispositivo rechazada (X-Device-Key): configuración
        // incompatible, no un rechazo de registro ni un fallo de red.
        // Se sigue consultando por si la configuración del servidor
        // cambia; el canal WS permanece bloqueado.
        debugPrint(
          '[CAUCE] Heartbeat 401: el servidor rechazó la clave de '
          'dispositivo (X-Device-Key); revisa CAUCE_DEVICE_SECRET',
        );
        _applyVerdict(DeviceAuthorizationStatus.invalid);
      } else if (response.statusCode == 422) {
        debugPrint(
          '[CAUCE] Heartbeat 422: payload rechazado por el servidor, se '
          'detiene el servicio hasta corregir: ${response.body}',
        );
        _applyVerdict(DeviceAuthorizationStatus.invalid);
        stop();
      } else {
        _warnFailure('HTTP ${response.statusCode}: ${response.body}');
        _applyVerdict(DeviceAuthorizationStatus.unreachable);
      }
    } catch (e) {
      _warnFailure('$e');
      // Fallo de red/servidor: no es un rechazo de registro. Mantiene
      // el canal bloqueado hasta recuperar la confirmación, sin
      // confundirlo con un 404.
      _applyVerdict(DeviceAuthorizationStatus.unreachable);
    } finally {
      _sending = false;
      _completeFirstHeartbeat();
    }
  }

  /// Traduce el veredicto al estado de autorización compartido y
  /// avanza (o reinicia) el intervalo progresivo de los dispositivos
  /// reconocidos como no registrados (202/404).
  void _applyVerdict(DeviceAuthorizationStatus verdict) {
    _verdict = verdict;
    final unregistered = verdict == DeviceAuthorizationStatus.pending ||
        verdict == DeviceAuthorizationStatus.unknown;
    _unregisteredStep = unregistered ? _unregisteredStep + 1 : 0;
    authorization?.update(verdict);
  }

  void _completeFirstHeartbeat() {
    final completer = _firstHeartbeat;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _warnFailure(String detail) {
    if (!_warnedFailure) {
      _warnedFailure = true;
      debugPrint(
        '[CAUCE] Heartbeat falló (servidor no disponible), se reintenta '
        'cada ${_interval.inSeconds}s: $detail',
      );
    }
  }

  /// IP LAN propia del dispositivo (IPv4 no loopback). La IP no es la
  /// identidad: solo información de conexión que el dispositivo declara.
  static Future<String> _localIPv4Address() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (!address.isLoopback) return address.address;
        }
      }
      // Fallback documentado: sin IPv4 LAN, loopback como último recurso.
      return InternetAddress.loopbackIPv4.address;
    } catch (e) {
      debugPrint('[CAUCE] No se pudo determinar la IP local: $e');
      return InternetAddress.loopbackIPv4.address;
    }
  }
}
