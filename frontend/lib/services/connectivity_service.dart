/// Comprobacion de conectividad con el servidor Cauce.
///
/// Una unica peticion HTTP al endpoint de salud del backend
/// (`GET /api/health`, respuesta `{"status": "ok"}`): la API
/// respondiendo es la prueba real de que el servidor esta vivo.
/// Nunca se usa ping ICMP: no garantiza que la API este operativa
/// y el firewall puede bloquearlo. Toda la configuracion (URL
/// activa y timeout) vive en [ApiConfig].
///
/// El resultado distingue tres estados: la API responde
/// ([ServerHealth.active]), la red local llega pero el servidor no
/// responde ([ServerHealth.off], apagado) y la red misma no
/// responde ([ServerHealth.unreachable], sin ruta ni DNS).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/config/api_config.dart';

/// Resultado de una comprobacion de salud del servidor Cauce.
enum ServerHealth {
  /// El backend respondio HTTP 200 con el contrato (`status: ok`).
  active,

  /// Hay red local, pero el servidor no responde: la maquina esta
  /// apagada (timeout), el puerto esta cerrado (connection refused)
  /// o respondio algo distinto del contrato de salud.
  off,

  /// Ni siquiera hay ruta hacia la red: fallo de DNS, "network is
  /// unreachable" o "no route to host". Sin LAN no hay nada que
  /// sondear.
  unreachable,
}

class ConnectivityService {
  ConnectivityService({
    http.Client? client,
    String? serverUrl,
    Duration? timeout,
  }) : _client = client ?? http.Client(),
       timeout = timeout ?? ApiConfig.connectivityTimeout,
       healthUrl =
           '${serverUrl ?? ApiConfig.activeServerUrl}/api${ApiConfig.healthPath}';

  final http.Client _client;

  /// Endpoint de salud contra el que se comprueba el servidor.
  final String healthUrl;

  /// Espera maxima por comprobacion.
  final Duration timeout;

  /// Sonda el endpoint de salud y clasifica el resultado en
  /// [ServerHealth]. Nunca lanza: cualquier fallo se traduce a un
  /// estado. Si el primer intento no da [ServerHealth.active] se
  /// reintenta una sola vez antes de declarar el fallo: en redes de
  /// sala con perdida de paquetes, un sondeo perdido o lento no debe
  /// voltear la pastilla a "Apagado"/"Inaccesible" por si solo. Con
  /// dos intentos el peor caso son 2x[timeout] (10s por defecto,
  /// dentro del intervalo de sondeo de 15s).
  Future<ServerHealth> check() async {
    final first = await _probe();
    if (first == ServerHealth.active) return first;
    return _probe();
  }

  Future<ServerHealth> _probe() async {
    try {
      final response = await _client.get(Uri.parse(healthUrl)).timeout(timeout);
      if (response.statusCode != 200) {
        // Algo respondio en el puerto pero no es la API de Cauce.
        debugPrint(
          '[Cauce] health $healthUrl respondio HTTP ${response.statusCode}',
        );
        return ServerHealth.off;
      }
      final dynamic body;
      try {
        body = jsonDecode(response.body);
      } catch (_) {
        debugPrint('[Cauce] health $healthUrl body no-JSON: ${response.body}');
        return ServerHealth.off;
      }
      if (body is Map && body['status'] == 'ok') {
        return ServerHealth.active;
      }
      debugPrint(
        '[Cauce] health $healthUrl contrato incumplido: ${response.body}',
      );
      return ServerHealth.off;
    } on TimeoutException {
      // Dentro de la LAN, un SYN sin respuesta significa que la
      // maquina del servidor esta apagada.
      debugPrint('[Cauce] health $healthUrl timeout tras $timeout');
      return ServerHealth.off;
    } on SocketException catch (e) {
      // El motivo del fallo queda en el log (adb logcat / flutter
      // logs) junto con la clasificacion elegida.
      final health = _classifySocket(e);
      debugPrint('[Cauce] health $healthUrl fallo de red [$health]: $e');
      return health;
    } catch (e) {
      // HandshakeException y otros: se llego a algo que no es la API
      // de Cauce -> el servidor de sala esta caido.
      debugPrint('[Cauce] health $healthUrl fallo inesperado: $e');
      return ServerHealth.off;
    }
  }

  /// Clasifica un [SocketException] entre "servidor apagado" y "red
  /// inaccesible" usando el codigo del SO y, como respaldo, el
  /// mensaje (los codigos varian entre Android, Linux y Windows).
  static ServerHealth _classifySocket(SocketException e) {
    final code = e.osError?.errorCode;
    final message = '${e.message} ${e.osError?.message}'.toLowerCase();
    switch (code) {
      // Puerto cerrado o conexion interrumpida: la maquina respondio.
      case 111: // ECONNREFUSED
      case 10061: // WSAECONNREFUSED
      case 104: // ECONNRESET
      case 10054: // WSAECONNRESET
      // Sin respuesta del host: dentro de la LAN, maquina apagada.
      case 110: // ETIMEDOUT
      case 10060: // WSAETIMEDOUT
      case 112: // EHOSTDOWN
      case 10064: // WSAEHOSTDOWN
        return ServerHealth.off;
      // Sin ruta hacia la red o hacia el host, o DNS caido.
      case 101: // ENETUNREACH
      case 10051: // WSAENETUNREACH
      case 113: // EHOSTUNREACH
      case 10065: // WSAEHOSTUNREACH
      case -2: // EAI_NONAME (DNS)
      case 8: // EAI_AGAIN (DNS temporal)
      case 11001: // WSAHOST_NOT_FOUND
        return ServerHealth.unreachable;
    }
    if (message.contains('refused') ||
        message.contains('reset') ||
        message.contains('timed out') ||
        message.contains('timeout') ||
        message.contains('host is down')) {
      return ServerHealth.off;
    }
    if (message.contains('unreachable') ||
        message.contains('no route') ||
        message.contains('host lookup') ||
        message.contains('no such host') ||
        message.contains('name or service not known')) {
      return ServerHealth.unreachable;
    }
    // Codigo desconocido: se asume que la red local sigue viva y que
    // fue el servidor el que no contesto.
    return ServerHealth.off;
  }
}
