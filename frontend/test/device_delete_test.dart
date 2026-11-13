/// Eliminacion de dispositivo desde el detalle.
///
/// La seccion vive al final del panel INFORMACION desplegado y solo
/// para admins (`devices.manage`); el dialogo de confirmacion es el
/// compartido con la eliminacion de medio (delete_section.dart).
/// Confirmar dispara el DELETE 204, el controlador recarga el
/// inventario y la vista vuelve a la pantalla anterior. Cancelar no
/// envia nada; un rechazo del servidor se muestra sin cerrar el
/// detalle.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:cauce_stream/controllers/devices_controller.dart';
import 'package:cauce_stream/controllers/media_library_controller.dart';
import 'package:cauce_stream/core/network/api_client.dart';
import 'package:cauce_stream/models/device.dart';
import 'package:cauce_stream/screens/devices/device_detail_screen.dart';
import 'package:cauce_stream/services/assignment_service.dart';
import 'package:cauce_stream/services/auth_service.dart';
import 'package:cauce_stream/services/device_service.dart';
import 'package:cauce_stream/services/media_service.dart';
import 'package:cauce_stream/services/thumbnail_service.dart';
import 'package:cauce_stream/services/user_service.dart';
import 'package:cauce_stream/session/session_controller.dart';
import 'package:cauce_stream/session/token_storage.dart';

const _deleteButtonLabel = 'Eliminar Dispositivo del Inventario';

Map<String, dynamic> _device() => {
      'id': 1,
      'device_uid': 'totem-sala-1',
      'name': 'Totem Sala 1',
      'type': 'TV',
      'status': 'online',
      'device_state': 'active',
      'ws_connected': true,
      'ip_address': '10.15.1.10',
      'created_at': '2026-10-20T10:00:00',
      'updated_at': '2026-10-27T10:00:00',
    };

ApiClient _api(http.Client client) =>
    ApiClient(baseUrl: 'http://server:8000/api', client: client);

/// Inventario vivo: devuelve el dispositivo hasta que llega el
/// DELETE, y lista vacia despues (el estado real tras el borrado).
/// Los demas endpoints responden listas vacias.
http.Client _inventoryClient({
  List<Uri>? deleted,
  http.Response Function()? deleteResponse,
}) {
  return MockClient((request) async {
    if (request.method == 'DELETE') {
      deleted?.add(request.url);
      return deleteResponse?.call() ??
          http.Response('', 204, headers: {
            'content-type': 'application/json',
          });
    }
    final body = request.url.path == '/api/devices' &&
            (deleted?.isEmpty ?? true)
        ? jsonEncode([_device()])
        : '[]';
    return http.Response(body, 200,
        headers: {'content-type': 'application/json'});
  });
}

void main() {
  group('DeviceService', () {
    test('deleteDevice envia DELETE al uid codificado', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('', 204, headers: {
          'content-type': 'application/json',
        });
      });

      await DeviceService(client: _api(client)).deleteDevice('tocador tv');

      expect(captured!.method, 'DELETE');
      // El uid es un nombre de SO y puede llevar espacios: se
      // codifica para la URL, tal cual el resto de los endpoints.
      expect(captured!.url.path, '/api/devices/tocador%20tv');
    });
  });

  group('DevicesController.remove', () {
    test('borra y recarga el inventario', () async {
      final deleted = <Uri>[];
      final client = _inventoryClient(deleted: deleted);
      final controller = DevicesController(
        service: DeviceService(client: _api(client)),
      );

      await controller.refresh();
      expect(controller.devices, hasLength(1));

      final ok = await controller.remove(Device.fromJson(_device()));

      expect(ok, isTrue);
      expect(deleted.single.path, '/api/devices/totem-sala-1');
      expect(controller.devices, isEmpty);
      expect(controller.errorMessage, isNull);
    });

    test('expone el fallo sin lanzar', () async {
      final client = _inventoryClient(
        deleteResponse: () => http.Response(
          jsonEncode({
            'code': 'not_found',
            'detail': 'El dispositivo ya no existe.',
          }),
          404,
          headers: {'content-type': 'application/json'},
        ),
      );
      final controller = DevicesController(
        service: DeviceService(client: _api(client)),
      );

      final ok = await controller.remove(Device.fromJson(_device()));

      expect(ok, isFalse);
      expect(controller.errorMessage, 'El dispositivo ya no existe.');
    });
  });

  group('Detalle: seccion de eliminacion', () {
    testWidgets('plegada con el panel, desplegada al final y solo '
        'para admins', (tester) async {
      final client = _inventoryClient();
      final api = _api(client);
      await _pumpDetail(tester, api: api, admin: true);

      // Con el panel plegado no existe; el detalle no muestra
      // destructivas por defecto.
      expect(find.text('INFORMACION'), findsOneWidget);
      expect(find.text(_deleteButtonLabel), findsNothing);

      // Desplegar el panel: la seccion aparece tras la ultima celda.
      await tester.ensureVisible(find.text('INFORMACION'));
      await tester.tap(find.text('INFORMACION'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(_deleteButtonLabel), findsOneWidget);
      final statsY = tester.getTopLeft(find.text('ULTIMA CONEXION')).dy;
      final deleteY = tester.getTopLeft(find.text(_deleteButtonLabel)).dy;
      expect(deleteY, greaterThan(statsY));
    });

    testWidgets('un mediador no ve la seccion de eliminar', (tester) async {
      final client = _inventoryClient();
      final api = _api(client);
      await _pumpDetail(tester, api: api, admin: false);

      await tester.ensureVisible(find.text('INFORMACION'));
      await tester.tap(find.text('INFORMACION'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('ULTIMA CONEXION'), findsOneWidget);
      expect(find.text(_deleteButtonLabel), findsNothing);
    });

    testWidgets('cancelar el dialogo no envia nada', (tester) async {
      final deleted = <Uri>[];
      final client = _inventoryClient(deleted: deleted);
      final api = _api(client);
      await _pumpDetail(tester, api: api, admin: true);

      await _openDeleteSection(tester);

      // El dialogo aparece; Cancelar lo cierra sin DELETE y el
      // detalle sigue abierto.
      await tester.tap(find.text(_deleteButtonLabel));
      await tester.pump();
      expect(find.text('Eliminar dispositivo'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('INFORMACION'), findsOneWidget);
      expect(deleted, isEmpty);
    });

    testWidgets('confirmar dispara el DELETE 204, avisa y vuelve',
        (tester) async {
      final deleted = <Uri>[];
      final client = _inventoryClient(deleted: deleted);
      final api = _api(client);
      await _pumpDetail(tester, api: api, admin: true);

      await _openDeleteSection(tester);

      await tester.tap(find.text(_deleteButtonLabel));
      await tester.pump();
      await tester.tap(find.text('Eliminar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // El pop dispara la transicion de salida de la ruta
      // (300 ms): se completa antes de afirmar que el detalle ya
      // no esta montado.
      await tester.pump(const Duration(milliseconds: 600));
      expect(deleted.single.path, '/api/devices/totem-sala-1');
      expect(find.text('"Totem Sala 1" eliminado del inventario.'),
          findsOneWidget);
      // El detalle se cerro: volvio a la pantalla de origen.
      expect(find.text('INFORMACION'), findsNothing);
      expect(find.text('abrir detalle'), findsOneWidget);
    });

    testWidgets('un rechazo del servidor se muestra y no cierra el '
        'detalle', (tester) async {
      final client = _inventoryClient(
        deleteResponse: () => http.Response(
          jsonEncode({
            'code': 'not_found',
            'detail': 'El dispositivo ya no existe.',
          }),
          404,
          headers: {'content-type': 'application/json'},
        ),
      );
      final api = _api(client);
      await _pumpDetail(tester, api: api, admin: true);

      await _openDeleteSection(tester);

      await tester.tap(find.text(_deleteButtonLabel));
      await tester.pump();
      await tester.tap(find.text('Eliminar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('El dispositivo ya no existe.'), findsOneWidget);
      expect(find.text('INFORMACION'), findsOneWidget);
    });
  });
}

/// Monta el detalle de dispositivo sobre un boton que lo abre:
/// permite verificar que tras eliminar se vuelve a la pantalla
/// anterior (Navigator.pop).
Future<void> _pumpDetail(
  WidgetTester tester, {
  required ApiClient api,
  required bool admin,
}) async {
  final mediaService = MediaService(client: api);
  final devices = DevicesController(
    service: DeviceService(client: api),
    assignmentService: AssignmentService(client: api),
  );
  final mediaLibrary = MediaLibraryController(
    service: mediaService,
    thumbnails: ThumbnailService(
      service: mediaService,
      cacheDirectory: Directory.systemTemp.createTempSync('cauce_delete'),
    ),
  );
  await devices.refresh();

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionController>.value(
          value: _FakeSession(apiClient: api, admin: admin),
        ),
        ChangeNotifierProvider.value(value: devices),
        ChangeNotifierProvider.value(value: mediaLibrary),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => DeviceDetailScreen(
                      device: Device.fromJson(_device()),
                    ),
                  ),
                ),
                child: const Text('abrir detalle'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir detalle'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Despliega el panel INFORMACION y deja visible la seccion de
/// eliminar.
Future<void> _openDeleteSection(WidgetTester tester) async {
  await tester.ensureVisible(find.text('INFORMACION'));
  await tester.tap(find.text('INFORMACION'), warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 400));
  // El extent del viewport queda desfasado hasta que el AnimatedSize
  // del panel termina de medirse, con lo cual ensureVisible cree que
  // ya es visible y no hace nada. Se asientan unos fotogramas y se
  // salta el scroll al fondo del contenido (la pastilla del
  // dispositivo late en bucle, asi que no se usa pumpAndSettle).
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  final scrollable = tester.state<ScrollableState>(
    find.byType(Scrollable).first,
  );
  scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
  await tester.pump(const Duration(milliseconds: 100));
}

class _FakeSession extends SessionController {
  _FakeSession({required ApiClient apiClient, required this.admin})
      : super(
          storage: _FakeStorage(),
          authService: AuthService(client: apiClient),
          userService: UserService(client: apiClient),
          apiClient: apiClient,
        );

  final bool admin;

  @override
  bool get isAdmin => admin;
}

class _FakeStorage implements TokenStorage {
  @override
  Future<void> clear() async {}

  @override
  Future<String?> readRememberedEmail() async => null;

  @override
  Future<String?> readToken() async => null;

  @override
  Future<void> saveSession({
    required String token,
    String? rememberedEmail,
  }) async {}
}
