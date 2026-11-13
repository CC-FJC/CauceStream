// Indicador LAN: sondeo del endpoint de salud del servidor Cauce
// (GET /api/health -> {"status": "ok"}). Cubre los estados exigidos:
// servidor respondiendo (active), servidor apagado (off: refused,
// timeout, respuesta invalida) y red inaccesible (unreachable: sin
// ruta o DNS caido), uso de la direccion local mientras Tailscale este
// vacia, UI no bloqueada durante la comprobacion, recuperacion
// automatica y reintento ante fallos transitorios de red.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:cauce_stream/controllers/connectivity_controller.dart';
import 'package:cauce_stream/core/config/api_config.dart';
import 'package:cauce_stream/services/connectivity_service.dart';
import 'package:cauce_stream/widgets/identity_widgets.dart';

void main() {
  group('ConnectivityService', () {
    test('considera activo solo el contrato de salud', () async {
      final requests = <Uri>[];
      final service = ConnectivityService(
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response('{"status": "ok"}', 200,
              headers: {'content-type': 'application/json'});
        }),
        serverUrl: 'http://10.15.1.150:8000',
      );
      expect(await service.check(), ServerHealth.active);
      expect(
        requests.single.toString(),
        'http://10.15.1.150:8000/api/health',
      );
    });

    test('cuerpo invalido o status distinto reportan servidor apagado',
        () async {
      final service = ConnectivityService(
        client: MockClient((request) async => http.Response('{"status": "no"}', 200)),
        serverUrl: 'http://10.15.1.150:8000',
      );
      expect(await service.check(), ServerHealth.off);

      final errorStatus = ConnectivityService(
        client: MockClient((request) async => http.Response('boom', 500)),
        serverUrl: 'http://10.15.1.150:8000',
      );
      expect(await errorStatus.check(), ServerHealth.off);
    });

    test('servidor detenido (connection refused) reporta apagado', () async {
      final service = ConnectivityService(
        client: MockClient((request) async {
          throw const SocketException('Connection refused');
        }),
        serverUrl: 'http://10.15.1.150:8000',
      );
      expect(await service.check(), ServerHealth.off);
    });

    test('timeout de red reporta servidor apagado', () async {
      final service = ConnectivityService(
        client: MockClient((request) async {
          await Future<void>.delayed(const Duration(seconds: 30));
          return http.Response('{"status": "ok"}', 200);
        }),
        serverUrl: 'http://10.15.1.150:8000',
        timeout: const Duration(milliseconds: 20),
      );
      final sw = Stopwatch()..start();
      expect(await service.check(), ServerHealth.off);
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('un fallo transitorio se recupera en el reintento', () async {
      // El primer intento se pierde (red congestionada), el segundo
      // pasa: la pastilla no debe caer por un sondeo perdido.
      var calls = 0;
      final service = ConnectivityService(
        client: MockClient((request) async {
          calls++;
          if (calls == 1) {
            throw const SocketException('Connection refused');
          }
          return http.Response('{"status": "ok"}', 200);
        }),
        serverUrl: 'http://10.15.1.150:8000',
      );
      expect(await service.check(), ServerHealth.active);
      expect(calls, 2);
    });

    test('un fallo transitorio de red se recupera en el reintento',
        () async {
      var calls = 0;
      final service = ConnectivityService(
        client: MockClient((request) async {
          calls++;
          if (calls == 1) {
            throw const SocketException('Network is unreachable');
          }
          return http.Response('{"status": "ok"}', 200);
        }),
        serverUrl: 'http://10.15.1.150:8000',
      );
      expect(await service.check(), ServerHealth.active);
      expect(calls, 2);
    });

    test('sin ruta hacia la red reporta red inaccesible', () async {
      final service = ConnectivityService(
        client: MockClient((request) async {
          throw const SocketException('No route to host');
        }),
        serverUrl: 'http://10.15.1.150:8000',
      );
      expect(await service.check(), ServerHealth.unreachable);
    });

    test('fallo de DNS reporta red inaccesible', () async {
      final service = ConnectivityService(
        client: MockClient((request) async {
          throw const SocketException('Failed host lookup: \'10.15.1.150\'');
        }),
        serverUrl: 'http://10.15.1.150:8000',
      );
      expect(await service.check(), ServerHealth.unreachable);
    });

    test('codigo de SO conocido clasifica sin depender del mensaje',
        () async {
      final refused = ConnectivityService(
        client: MockClient((request) async {
          throw SocketException(
            'x',
            osError: OSError('Connection refused', 111),
          );
        }),
        serverUrl: 'http://10.15.1.150:8000',
      );
      expect(await refused.check(), ServerHealth.off);

      final noRoute = ConnectivityService(
        client: MockClient((request) async {
          throw SocketException(
            'x',
            osError: OSError('No route to host', 113),
          );
        }),
        serverUrl: 'http://10.15.1.150:8000',
      );
      expect(await noRoute.check(), ServerHealth.unreachable);
    });
  });

  group('ApiConfig', () {
    test('sin Tailscale configurada se usa unicamente la direccion local',
        () {
      expect(ApiConfig.serverTailscaleUrl, isEmpty);
      expect(ApiConfig.activeServerUrl, ApiConfig.serverLocalUrl);
      expect(ApiConfig.apiBaseUrl, '${ApiConfig.serverLocalUrl}/api');
    });
  });

  group('ConnectivityController y badge', () {
    const okBody = '{"status": "ok"}';

    testWidgets('el backend responde: badge Servidor Activo', (tester) async {
      final controller = ConnectivityController(
        service: ConnectivityService(
          client: MockClient((request) async =>
              http.Response(okBody, 200)),
        ),
        interval: const Duration(milliseconds: 40),
      );
      await _pumpBadge(tester, controller);
      expect(find.text('Servidor\nActivo'), findsOneWidget);
      controller.dispose();
    });

    testWidgets('el backend esta detenido: badge Servidor Apagado y '
        'recuperacion automatica al volver', (tester) async {
      var up = false;
      final controller = ConnectivityController(
        service: ConnectivityService(
          client: MockClient((request) async {
            if (!up) {
              throw const SocketException('Connection refused');
            }
            return http.Response(okBody, 200);
          }),
        ),
        interval: const Duration(milliseconds: 40),
      );
      await _pumpBadge(tester, controller);
      expect(find.text('Servidor\nApagado'), findsOneWidget);

      // La red vuelve: el sondeo periodico recupera el estado sin
      // recargar nada.
      up = true;
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('Servidor\nActivo'), findsOneWidget);
      controller.dispose();
    });

    testWidgets('sin red: badge Red Inaccesible', (tester) async {
      final controller = ConnectivityController(
        service: ConnectivityService(
          client: MockClient((request) async {
            throw const SocketException('Network is unreachable');
          }),
        ),
        interval: const Duration(milliseconds: 40),
      );
      await _pumpBadge(tester, controller);
      expect(find.text('Red\nInaccesible'), findsOneWidget);
      expect(controller.status, LanStatus.unreachable);
      controller.dispose();
    });

    testWidgets('estado neutro mientras comprueba: la interfaz sigue '
        'respondiendo', (tester) async {
      // Comprobacion colgada: el badge muestra el estado neutro
      // mientras tanto y los frames siguen construyendose.
      final response = Completer<http.Response>();
      final controller = ConnectivityController(
        service: ConnectivityService(
          client: MockClient((request) => response.future),
          timeout: const Duration(seconds: 2),
        ),
        interval: const Duration(seconds: 5),
      );
      await _pumpBadge(tester, controller);
      expect(find.text('Comprobando'), findsOneWidget);

      // El servidor termina de responder: el badge pasa a activo sin
      // ninguna intervencion del usuario.
      response.complete(http.Response(okBody, 200));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Servidor\nActivo'), findsOneWidget);
      controller.dispose();
    });

    testWidgets('el estado solo notifica cuando cambia', (tester) async {
      final controller = ConnectivityController(
        service: ConnectivityService(
          client: MockClient((request) async =>
              http.Response(okBody, 200)),
        ),
        interval: const Duration(milliseconds: 20),
      );
      await tester.pumpWidget(const SizedBox());
      // La comprobacion inicial completa el estado.
      await tester.pump(const Duration(milliseconds: 50));
      var notifications = 0;
      controller.addListener(() => notifications++);
      final before = notifications;
      await tester.pump(const Duration(milliseconds: 100));
      expect(notifications, before);
      expect(controller.status, LanStatus.active);
      controller.dispose();
    });
  });
}

/// Bombea el badge y deja correr la comprobacion inicial del
/// controlador. Nunca usa pumpAndSettle: el punto del badge pulsa
/// con una animacion perpetua.
Future<void> _pumpBadge(
    WidgetTester tester, ConnectivityController controller) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: controller),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(child: LanBadge(compact: true)),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 120));
}
