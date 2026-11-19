import 'dart:convert';
import 'dart:io';

import 'package:cauce_stream/services/cauce_heartbeat_service.dart';
import 'package:cauce_stream/services/device_authorization.dart';
import 'package:cauce_stream/services/playback_state.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  http.Response okResponse() => http.Response(
        jsonEncode({
          'device_uid': 'SALA PANTALLA 1',
          'status': 'online',
          'device_state': 'active',
          'current_media': 'unknown',
          'payload': {},
          'last_seen': '2026-10-19T12:00:00Z',
        }),
        200,
      );

  test('envía el body del contrato y codifica la ruta', () async {
    Uri? capturedUri;
    String? contentType;
    Map<String, dynamic>? capturedBody;
    final client = MockClient((request) async {
      capturedUri = request.url;
      contentType = request.headers['Content-Type'];
      capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
      return okResponse();
    });

    final service = CauceHeartbeatService(
      baseUrl: 'http://10.15.1.150:8000',
      deviceUid: 'SALA PANTALLA 1',
      client: client,
      resolveIpAddress: () async => '10.15.1.99',
      resolveMacAddress: () async => '7C:01:3E:7A:7D:52',
    );

    await service.sendHeartbeat();

    expect(capturedUri!.path, '/api/devices/SALA%20PANTALLA%201/heartbeat');
    expect(contentType, 'application/json');
    expect(capturedBody!['ip_address'], '10.15.1.99');
    // La MAC se reporta como campo general (Wake-on-LAN del servidor),
    // normalizada a mayúsculas por DeviceIdentity.
    expect(capturedBody!['mac_address'], '7C:01:3E:7A:7D:52');
    expect(capturedBody!['device_state'], 'active');
    // Sin medio confirmado: `current_media` se omite (el servidor guarda
    // "unknown") y el retirado `current_application` ya no se envía.
    expect(capturedBody!['payload'], isEmpty);
    expect(
      (capturedBody!['payload'] as Map<String, dynamic>)
          .containsKey('current_application'),
      isFalse,
    );
    // El cliente nunca reporta `status`: lo determina el servidor.
    expect(capturedBody!.containsKey('status'), isFalse);
    service.dispose();
  });

  test('sin MAC resuelta no se envía mac_address', () async {
    Map<String, dynamic>? capturedBody;
    final client = MockClient((request) async {
      capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
      return okResponse();
    });

    final service = CauceHeartbeatService(
      baseUrl: 'http://10.15.1.150:8000',
      deviceUid: 'SALA PANTALLA 1',
      client: client,
      resolveIpAddress: () async => '10.15.1.99',
      resolveMacAddress: () async => null,
    );

    await service.sendHeartbeat();

    expect(capturedBody!.containsKey('mac_address'), isFalse);
    service.dispose();
  });

  test('reporta payload.current_media cuando hay un medio confirmado',
      () async {
    Map<String, dynamic>? capturedBody;
    final client = MockClient((request) async {
      capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
      return okResponse();
    });
    final playbackState = PlaybackState()..setPlaying(5);
    final service = CauceHeartbeatService(
      baseUrl: 'http://10.15.1.150:8000',
      deviceUid: 'SALA 1',
      deviceKey: 'secreto',
      playbackState: playbackState,
      client: client,
      resolveIpAddress: () async => '10.15.1.99',
    );

    await service.sendHeartbeat();

    // Media.id entero, no "unknown" ni nombre de archivo/aplicación.
    expect(capturedBody!['payload'], {'current_media': 5});

    playbackState.clear();
    await service.sendHeartbeat();
    expect(capturedBody!['payload'], isEmpty);
    service.dispose();
  });

  test('404 (dispositivo aún no registrado) no lanza', () async {
    final client = MockClient((request) async => http.Response('{}', 404));
    final service = CauceHeartbeatService(
      baseUrl: 'http://server:8000',
      deviceUid: 'GHOST',
      client: client,
      resolveIpAddress: () async => '10.15.1.99',
    );

    await service.sendHeartbeat(); // debe registrarse el 404, no lanzar

    service.dispose();
  });

  test('envía X-Device-Key cuando está configurado', () async {
    String? receivedKey;
    final client = MockClient((request) async {
      receivedKey = request.headers['x-device-key'];
      return okResponse();
    });
    final service = CauceHeartbeatService(
      baseUrl: 'http://server:8000',
      deviceUid: 'SALA 1',
      deviceKey: 'secreto-compartido',
      client: client,
      resolveIpAddress: () async => '10.15.1.99',
    );

    await service.sendHeartbeat();

    expect(receivedKey, 'secreto-compartido');
    service.dispose();
  });

  test('202 (descubrimiento pendiente por autoconfig) no lanza', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'device_uid': 'GHOST',
          'status': 'pending_registration',
          'last_seen': '2026-10-19T12:00:00Z',
        }),
        202,
      ),
    );
    final service = CauceHeartbeatService(
      baseUrl: 'http://server:8000',
      deviceUid: 'GHOST',
      client: client,
      resolveIpAddress: () async => '10.15.1.99',
    );

    await service.sendHeartbeat(); // aceptado como pendiente, no es fallo

    service.dispose();
  });

  test('un 422 detiene el servicio (no reintenta el mismo payload)',
      () {
    fakeAsync((async) {
      final client =
          MockClient((request) async => http.Response('invalid', 422));
      final service = CauceHeartbeatService(
        baseUrl: 'http://server:8000',
        deviceUid: 'SALA 1',
        client: client,
        interval: const Duration(seconds: 10),
        resolveIpAddress: () async => '10.15.1.99',
      );

      service.start();
      expect(service.isRunning, isTrue);

      async.elapse(const Duration(seconds: 12));
      expect(service.isRunning, isFalse);

      service.dispose();
    });
  });

  test('timeout del servidor no lanza y el servicio sigue', () {
    fakeAsync((async) {
      final client = MockClient((request) async {
        await Future<void>.delayed(const Duration(seconds: 30));
        return okResponse();
      });
      final service = CauceHeartbeatService(
        baseUrl: 'http://server:8000',
        deviceUid: 'SALA 1',
        client: client,
        interval: const Duration(seconds: 10),
        timeout: const Duration(seconds: 5),
        resolveIpAddress: () async => '10.15.1.99',
      );

      service.start();
      async.elapse(const Duration(seconds: 25));
      expect(service.isRunning, isTrue);

      service.dispose();
    });
  });

  test('device_state refleja el ciclo de vida', () async {
    final states = <String>[];
    final client = MockClient((request) async {
      states.add(
        (jsonDecode(request.body) as Map<String, dynamic>)['device_state']
            as String,
      );
      return okResponse();
    });
    final service = CauceHeartbeatService(
      baseUrl: 'http://server:8000',
      deviceUid: 'SALA 1',
      client: client,
      resolveIpAddress: () async => '10.15.1.99',
    );

    expect(service.deviceState, 'active'); // en primer plano al arrancar

    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    await service.sendHeartbeat();
    expect(service.deviceState, 'idle');
    expect(states.last, 'idle'); // un dispositivo idle sigue reportando

    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(service.deviceState, 'active');

    service.dispose();
  });

  group('device_state por estado de pantalla (Android)', () {
    test('pantalla encendida es active aunque la app esté pausada '
        '(web externa encima)', () async {
      final states = <String>[];
      final client = MockClient((request) async {
        states.add(
          (jsonDecode(request.body) as Map<String, dynamic>)['device_state']
              as String,
        );
        return okResponse();
      });
      final service = CauceHeartbeatService(
        baseUrl: 'http://server:8000',
        deviceUid: 'SALA 1',
        client: client,
        resolveIpAddress: () async => '10.15.1.99',
        resolveIsInteractive: () async => true,
      );

      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      await service.sendHeartbeat();

      // La experiencia externa corre EN pantalla: el dispositivo está
      // activo aunque el kiosk (la app) esté pausado debajo.
      expect(states.last, 'active');
      service.dispose();
    });

    test('pantalla apagada es idle aunque la app esté en primer plano',
        () async {
      final states = <String>[];
      final client = MockClient((request) async {
        states.add(
          (jsonDecode(request.body) as Map<String, dynamic>)['device_state']
              as String,
        );
        return okResponse();
      });
      final service = CauceHeartbeatService(
        baseUrl: 'http://server:8000',
        deviceUid: 'SALA 1',
        client: client,
        resolveIpAddress: () async => '10.15.1.99',
        resolveIsInteractive: () async => false,
      );

      // En espera: pantalla apagada es idle, sin importar el ciclo de
      // vida de la app (el guardián de pantalla sigue latiendo).
      await service.sendHeartbeat();
      expect(states.last, 'idle');

      service.dispose();
    });

    test('sin canal de pantalla decae al ciclo de vida (desktop/tests)',
        () async {
      final states = <String>[];
      final client = MockClient((request) async {
        states.add(
          (jsonDecode(request.body) as Map<String, dynamic>)['device_state']
              as String,
        );
        return okResponse();
      });
      final service = CauceHeartbeatService(
        baseUrl: 'http://server:8000',
        deviceUid: 'SALA 1',
        client: client,
        resolveIpAddress: () async => '10.15.1.99',
        resolveIsInteractive: () async => null,
      );

      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      await service.sendHeartbeat();
      expect(states.last, 'idle');

      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await service.sendHeartbeat();
      expect(states.last, 'active');

      service.dispose();
    });
  });

  group('veredictos de autorización (DeviceAuthorization)', () {
    CauceHeartbeatService build(
      http.Client client,
      DeviceAuthorization authorization,
    ) =>
        CauceHeartbeatService(
          baseUrl: 'http://server:8000',
          deviceUid: 'SALA 1',
          client: client,
          authorization: authorization,
          resolveIpAddress: () async => '10.15.1.99',
        );

    test('200 marca registrado y habilita el canal WS', () async {
      final authorization = DeviceAuthorization();
      final service = build(
        MockClient((request) async => okResponse()),
        authorization,
      );

      await service.sendHeartbeat();

      expect(authorization.status, DeviceAuthorizationStatus.registered);
      expect(authorization.isAuthorized, isTrue);
      service.dispose();
    });

    test('202 marca pendiente: el canal WS sigue bloqueado', () async {
      final authorization = DeviceAuthorization();
      final service = build(
        MockClient(
          (request) async => http.Response(
            jsonEncode({
              'device_uid': 'SALA 1',
              'status': 'pending_registration',
              'last_seen': '2026-10-19T12:00:00Z',
            }),
            202,
          ),
        ),
        authorization,
      );

      await service.sendHeartbeat();

      expect(authorization.status, DeviceAuthorizationStatus.pending);
      expect(authorization.isAuthorized, isFalse);
      service.dispose();
    });

    test('404 marca desconocido: el canal WS sigue bloqueado', () async {
      final authorization = DeviceAuthorization();
      final service = build(
        MockClient((request) async => http.Response('{}', 404)),
        authorization,
      );

      await service.sendHeartbeat();

      expect(authorization.status, DeviceAuthorizationStatus.unknown);
      expect(authorization.isAuthorized, isFalse);
      service.dispose();
    });

    test('un fallo de red marca unreachable (no unknown)', () async {
      final authorization = DeviceAuthorization();
      final service = build(
        MockClient(
          (request) async => throw const SocketException('network unreachable'),
        ),
        authorization,
      );

      await service.sendHeartbeat();

      expect(authorization.status, DeviceAuthorizationStatus.unreachable);
      expect(authorization.isAuthorized, isFalse,
          reason: 'servidor caído no es un rechazo de registro, pero sin '
              'confirmación no hay canal');
      service.dispose();
    });

    test('422 marca invalid (payload incompatible con el contrato)', () async {
      final authorization = DeviceAuthorization();
      final service = build(
        MockClient((request) async => http.Response('invalid', 422)),
        authorization,
      );

      await service.sendHeartbeat();

      expect(authorization.status, DeviceAuthorizationStatus.invalid);
      expect(authorization.isAuthorized, isFalse);
      service.dispose();
    });

    test('401 (clave de dispositivo rechazada) marca invalid', () async {
      final authorization = DeviceAuthorization();
      final service = build(
        MockClient(
          (request) async => http.Response(
            jsonEncode({
              'code': 'device_key_invalid',
              'detail': 'Missing or invalid device key',
            }),
            401,
          ),
        ),
        authorization,
      );

      await service.sendHeartbeat();

      expect(authorization.status, DeviceAuthorizationStatus.invalid);
      expect(authorization.isAuthorized, isFalse);
      service.dispose();
    });

    test('202 → 200: la transición habilita sin reiniciar la app', () async {
      var beat = 0;
      final authorization = DeviceAuthorization();
      final service = build(
        MockClient((request) async {
          beat++;
          if (beat == 1) {
            return http.Response(
              jsonEncode({
                'device_uid': 'SALA 1',
                'status': 'pending_registration',
                'last_seen': '2026-10-19T12:00:00Z',
              }),
              202,
            );
          }
          return okResponse();
        }),
        authorization,
      );

      await service.sendHeartbeat();
      expect(authorization.status, DeviceAuthorizationStatus.pending);

      // El administrador registra el equipo: el siguiente latido (sin
      // reinicio de la app) confirma el registro.
      await service.sendHeartbeat();
      expect(authorization.status, DeviceAuthorizationStatus.registered);
      expect(authorization.isAuthorized, isTrue);
      service.dispose();
    });
  });

  test('el primer heartbeat sale inmediatamente, antes del intervalo', () {
    fakeAsync((async) {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return okResponse();
      });
      final service = CauceHeartbeatService(
        baseUrl: 'http://server:8000',
        deviceUid: 'SALA 1',
        client: client,
        interval: const Duration(seconds: 10),
        resolveIpAddress: () async => '10.15.1.99',
      )..start();

      // Aun sin agotar el intervalo (10 s) el primer latido ya viajó.
      async.elapse(const Duration(milliseconds: 100));
      expect(calls, 1);
      expect(service.isRunning, isTrue);

      service.dispose();
    });
  });

  test('firstHeartbeat completa con el veredicto del primer latido', () {
    fakeAsync((async) {
      final authorization = DeviceAuthorization();
      final service = CauceHeartbeatService(
        baseUrl: 'http://server:8000',
        deviceUid: 'SALA 1',
        client: MockClient((request) async => okResponse()),
        authorization: authorization,
        resolveIpAddress: () async => '10.15.1.99',
      )..start();

      // El arranque espera este futuro antes de habilitar el canal: se
      // completa con el veredicto del primer latido (inmediato).
      var completed = false;
      service.firstHeartbeat.then((_) => completed = true);
      async.elapse(const Duration(milliseconds: 100));
      expect(completed, isTrue);
      expect(service.isRunning, isTrue);
      expect(authorization.status, DeviceAuthorizationStatus.registered);

      service.dispose();
    });
  });

  test('intervalo progresivo para no registrados: 10 → 15 → 20 (tope), '
      'sin perder el ritmo del autodescubrimiento', () {
    fakeAsync((async) {
      final times = <int>[];
      final client = MockClient((request) async {
        times.add(async.elapsed.inMilliseconds);
        return http.Response('{}', 404);
      });
      final service = CauceHeartbeatService(
        baseUrl: 'http://server:8000',
        deviceUid: 'SALA 1',
        client: client,
        interval: const Duration(seconds: 10),
        resolveIpAddress: () async => '10.15.1.99',
      )..start();
      async.elapse(const Duration(seconds: 75));

      // Latido inmediato + huecos progresivos con jitter (±1 s): el
      // tope de 20 s queda por debajo del TTL de pendientes del
      // servidor (30 s), conservando el autodescubrimiento.
      expect(times, hasLength(5));
      final gaps = [
        for (var i = 1; i < times.length; i++) times[i] - times[i - 1],
      ];
      expect(gaps[0], allOf(greaterThan(7500), lessThan(12500)));
      expect(gaps[1], allOf(greaterThan(12500), lessThan(17500)));
      expect(gaps[2], allOf(greaterThan(17500), lessThan(22500)));
      expect(gaps[3], allOf(greaterThan(17500), lessThan(22500)));

      service.dispose();
    });
  });

  test('con registro confirmado el intervalo es el base (10 s)', () {
    fakeAsync((async) {
      final times = <int>[];
      final client = MockClient((request) async {
        times.add(async.elapsed.inMilliseconds);
        return okResponse();
      });
      final service = CauceHeartbeatService(
        baseUrl: 'http://server:8000',
        deviceUid: 'SALA 1',
        client: client,
        interval: const Duration(seconds: 10),
        resolveIpAddress: () async => '10.15.1.99',
      )..start();
      async.elapse(const Duration(milliseconds: 44900));

      // Latido inmediato + 4 huecos del intervalo base: la cadencia
      // rápida se conserva para dispositivos registrados.
      expect(times, hasLength(5));
      final gaps = [
        for (var i = 1; i < times.length; i++) times[i] - times[i - 1],
      ];
      for (final gap in gaps) {
        expect(gap, allOf(greaterThan(7500), lessThan(12500)));
      }

      service.dispose();
    });
  });
}
