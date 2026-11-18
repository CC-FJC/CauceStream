/// Pruebas del estado de autorización del dispositivo y de la
/// coordinación heartbeat → canal WS: el heartbeat es la única
/// fuente de veredictos (200/202/404 y fallos) y solo `registered`
/// habilita la conexión WebSocket, sin importar cuándo llegue la
/// transición.
library;

import 'dart:async';
import 'dart:convert';

import 'package:cauce_stream/services/cauce_heartbeat_service.dart';
import 'package:cauce_stream/services/device_authorization.dart';
import 'package:cauce_stream/services/playback_socket_service.dart';
import 'package:cauce_stream/services/playback_state.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Socket falso mínimo: solo interesa si el servicio llegó a abrir el
/// canal, cuándo y si lo cerró por revocación.
class CountingSocket implements CauceSocket {
  final StreamController<dynamic> _incoming = StreamController<dynamic>();

  bool closed = false;
  final List<String> sent = <String>[];

  @override
  Stream get stream => _incoming.stream;

  @override
  void add(String data) => sent.add(data);

  @override
  Future<void> close() async {
    closed = true;
    await _incoming.close();
  }
}

http.Response registeredResponse() => http.Response(
      jsonEncode({
        'device_uid': 'SALA 1',
        'status': 'online',
        'device_state': 'active',
        'current_media': 'unknown',
        'payload': {},
        'last_seen': '2026-10-19T12:00:00Z',
      }),
      200,
    );

http.Response pendingResponse() => http.Response(
      jsonEncode({
        'device_uid': 'SALA 1',
        'status': 'pending_registration',
        'last_seen': '2026-10-19T12:00:00Z',
      }),
      202,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Los logs del servicio son útiles en producción; en pruebas, silencio.
    debugPrint = (String? message, {int? wrapWidth}) {};
  });

  group('DeviceAuthorization (estado puro)', () {
    test('nace unknown y sin autorización', () {
      final authorization = DeviceAuthorization();

      expect(authorization.status, DeviceAuthorizationStatus.unknown);
      expect(authorization.isAuthorized, isFalse);
    });

    test('solo registered autoriza y se notifica únicamente en las '
        'transiciones reales', () {
      final authorization = DeviceAuthorization();
      final transitions = <DeviceAuthorizationStatus>[];
      authorization.addListener(transitions.add);

      authorization.update(DeviceAuthorizationStatus.pending);
      authorization.update(DeviceAuthorizationStatus.pending); // sin cambio
      expect(transitions, [DeviceAuthorizationStatus.pending]);
      expect(authorization.isAuthorized, isFalse);

      authorization.update(DeviceAuthorizationStatus.registered);
      expect(
        transitions,
        [DeviceAuthorizationStatus.pending, DeviceAuthorizationStatus.registered],
      );
      expect(authorization.isAuthorized, isTrue);

      authorization.update(DeviceAuthorizationStatus.unknown);
      expect(authorization.isAuthorized, isFalse);
    });

    test('removeListener detiene las notificaciones', () {
      final authorization = DeviceAuthorization();
      final transitions = <DeviceAuthorizationStatus>[];
      void listener(DeviceAuthorizationStatus status) =>
          transitions.add(status);
      authorization.addListener(listener);

      authorization.update(DeviceAuthorizationStatus.registered);
      authorization.removeListener(listener);
      authorization.update(DeviceAuthorizationStatus.unknown);

      expect(transitions, [DeviceAuthorizationStatus.registered]);
    });
  });

  test('flujo completo: el canal WS solo abre cuando el heartbeat '
      'confirma el registro (y se cierra al revocarlo)', () {
    fakeAsync((async) {
      var beat = 0;
      final heartbeatTimes = <int>[];
      final client = MockClient((request) async {
        beat++;
        heartbeatTimes.add(async.elapsed.inMilliseconds);
        // 404 (desconocido) → 202 (pendiente por autoconfig) → 200
        // (registrado) → 404 (eliminado mientras estaba encendido).
        if (beat == 1) return http.Response('{}', 404);
        if (beat == 2) return pendingResponse();
        if (beat == 3) return registeredResponse();
        return http.Response('{}', 404);
      });

      final wsAttempts = <int>[];
      final sockets = <CountingSocket>[];

      Future<CauceSocket> connector(Uri uri, Map<String, String> headers) async {
        wsAttempts.add(async.elapsed.inMilliseconds);
        final socket = CountingSocket();
        sockets.add(socket);
        return socket;
      }

      final authorization = DeviceAuthorization();
      final heartbeat = CauceHeartbeatService(
        baseUrl: 'http://server:8000',
        deviceUid: 'SALA 1',
        client: client,
        authorization: authorization,
        interval: const Duration(seconds: 10),
        resolveIpAddress: () async => '10.15.1.99',
      )..start();

      final playback = PlaybackSocketService(
        baseUrl: 'http://server:8000',
        deviceUid: 'SALA 1',
        playbackState: PlaybackState(),
        authorization: authorization,
        connector: connector,
        wait: (delay) async {},
      )..start();

      // 1) El primer heartbeat viaja inmediatamente (t≈0, veredicto
      //    404): nunca hay intento WS anterior a él.
      async.elapse(const Duration(milliseconds: 150));
      expect(heartbeatTimes, hasLength(1));
      expect(wsAttempts, isEmpty, reason: 'sin 200 no hay intento WS');
      expect(authorization.status, DeviceAuthorizationStatus.unknown);

      // 2) Segundo latido (≈10 s): 202 → pendiente; canal bloqueado.
      async.elapse(const Duration(seconds: 11));
      expect(authorization.status, DeviceAuthorizationStatus.pending);
      expect(wsAttempts, isEmpty);

      // 3) Tercer latido (≈25 s): 200 → registrado → el canal abre,
      //    aunque la app jamás fue reiniciada.
      async.elapse(const Duration(seconds: 16));
      expect(authorization.status, DeviceAuthorizationStatus.registered);
      async.elapse(const Duration(milliseconds: 200));
      expect(wsAttempts, hasLength(1));

      // 4) Cuarto latido (≈35 s): 404 → eliminado → canal revocado.
      async.elapse(const Duration(seconds: 12));
      expect(authorization.status, DeviceAuthorizationStatus.unknown);
      async.elapse(const Duration(milliseconds: 200));
      expect(sockets.single.closed, isTrue, reason: 'la revocación cerró el canal');

      // 5) Aunque pase el tiempo no hay ciclo de reconexión: los
      //    reintentos quedaron cancelados por la revocación.
      final attemptsAfterRevoke = wsAttempts.length;
      async.elapse(const Duration(seconds: 40));
      expect(wsAttempts.length, attemptsAfterRevoke,
          reason: 'sin autorización el ciclo de reconexión no existe');

      heartbeat.dispose();
      playback.dispose();
    });
  });
}
