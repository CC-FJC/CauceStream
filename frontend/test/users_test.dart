/// Tests de la administracion de usuarios (pestana Usuarios y
/// pantalla de Roles): servicios, controlador y pantallas contra
/// los endpoints existentes del backend. La app elimina usuarios
/// de forma logica (POST deactivate) aunque el backend ofrezca un
/// DELETE fisico; la creacion de roles no existe en el backend y
/// queda como aviso mockeado.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:cauce_stream/controllers/users_controller.dart';
import 'package:cauce_stream/core/network/api_client.dart';
import 'package:cauce_stream/core/network/api_exception.dart';
import 'package:cauce_stream/screens/users/roles_screen.dart';
import 'package:cauce_stream/screens/users/users_screen.dart';
import 'package:cauce_stream/services/auth_service.dart';
import 'package:cauce_stream/services/role_service.dart';
import 'package:cauce_stream/services/user_service.dart';
import 'package:cauce_stream/session/session_controller.dart';
import 'package:cauce_stream/session/token_storage.dart';

Map<String, dynamic> _userJson({
  int id = 1,
  String name = 'Carlos Mendoza',
  String email = 'carlos.mendoza@cauce.edu',
  String role = 'ADMINISTRADOR',
  bool active = true,
}) =>
    {
      'id': id,
      'name': name,
      'email': email,
      'role': {'id': 1, 'name': role, 'description': 'Rol de sala.'},
      'is_active': active,
      'created_at': '2026-02-14T09:30:00',
      'updated_at': '2026-03-15T10:15:00',
    };

Map<String, dynamic> _permissionJson(
  int id,
  String name,
  String description,
) =>
    {'id': id, 'name': name, 'description': description};

Map<String, dynamic> _roleJson(
  String name,
  List<Map<String, dynamic>> permissions,
) =>
    {
      'id': name == 'ADMINISTRADOR' ? 1 : 2,
      'name': name,
      'description': 'Rol del sistema.',
      'permissions': permissions,
    };

/// Catalogo reducido con las cinco areas del backend real.
final _catalog = [
  _permissionJson(1, 'users.view', 'Consultar usuarios.'),
  _permissionJson(
      2, 'users.mediators.manage', 'Crear, modificar, activar y desactivar mediadores.'),
  _permissionJson(3, 'devices.view', 'Consultar dispositivos y su estado.'),
  _permissionJson(4, 'devices.manage', 'Administrar dispositivos.'),
  _permissionJson(5, 'content.manage', 'Administrar y distribuir contenido.'),
];

ApiClient _api(http.Client client) =>
    ApiClient(baseUrl: 'http://server:8000/api', client: client);

void main() {
  group('UserService', () {
    test('listUsers decodifica el personal con su rol', () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/users');
        return http.Response(
          jsonEncode([
            _userJson(),
            _userJson(
                id: 2, name: 'Valentina Rivas', role: 'MEDIADOR'),
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final users = await UserService(client: _api(client)).listUsers();

      expect(users, hasLength(2));
      expect(users.first.name, 'Carlos Mendoza');
      expect(users.first.isAdmin, isTrue);
      expect(users.last.role.name, 'MEDIADOR');
    });

    test('createUser envia el contrato de POST /users', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
            jsonEncode(_userJson(id: 9, role: 'MEDIADOR')), 201,
            headers: {'content-type': 'application/json'});
      });

      final created = await UserService(client: _api(client)).createUser(
        name: 'Lucia Restrepo',
        email: 'lucia@cauce.edu',
        pin: '4321',
        role: 'MEDIADOR',
      );

      expect(created.role.name, 'MEDIADOR');
      expect(captured!.method, 'POST');
      expect(captured!.url.path, '/api/users');
      expect(jsonDecode(captured!.body), {
        'name': 'Lucia Restrepo',
        'email': 'lucia@cauce.edu',
        'password': '4321',
        'role': 'MEDIADOR',
      });
    });

    test('activate/deactivate usan los endpoints de estado', () async {
      final calls = <String>[];
      final client = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        return http.Response(jsonEncode(_userJson()), 200,
            headers: {'content-type': 'application/json'});
      });
      final service = UserService(client: _api(client));

      await service.deactivateUser(2);
      await service.activateUser(2);

      expect(calls, [
        'POST /api/users/2/deactivate',
        'POST /api/users/2/activate',
      ]);
    });

    test('updateUser incluye el cambio de rol en el PATCH', () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(jsonEncode(_userJson(role: 'MEDIADOR')), 200,
            headers: {'content-type': 'application/json'});
      });

      await UserService(client: _api(client)).updateUser(
        3,
        name: 'Nuevo Nombre',
        role: 'MEDIADOR',
      );

      expect(captured!.method, 'PATCH');
      expect(captured!.url.path, '/api/users/3');
      expect(jsonDecode(captured!.body), {
        'name': 'Nuevo Nombre',
        'role': 'MEDIADOR',
      });
    });

    test('un 403 de listUsers se clasifica como error de permisos',
        () async {
      final client = MockClient((request) async => http.Response(
          jsonEncode({
            'code': 'missing_permission',
            'detail': 'Requiere users.view.',
          }),
          403,
          headers: {'content-type': 'application/json'}));

      final service = UserService(client: _api(client));

      await expectLater(
        service.listUsers(),
        throwsA(isA<ApiException>()
            .having((e) => e.isAuthError, 'isAuthError', isTrue)),
      );
    });
  });

  group('RoleService', () {
    test('listRoles trae los roles del dominio con sus permisos',
        () async {
      final client = MockClient((request) async {
        expect(request.url.path, '/api/roles');
        return http.Response(
          jsonEncode([
            _roleJson('ADMINISTRADOR', _catalog),
            _roleJson('MEDIADOR', [_catalog[0]]),
          ]),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final roles = await RoleService(client: _api(client)).listRoles();

      expect(roles, hasLength(2));
      expect(roles.first.name, 'ADMINISTRADOR');
      expect(roles.first.permissions, hasLength(5));
      expect(roles.first.has('content.manage'), isTrue);
    });

    test('updateRolePermissions envia PUT con el conjunto completo',
        () async {
      http.Request? captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(_roleJson('MEDIADOR', [_catalog[0], _catalog[2]])),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final role = await RoleService(client: _api(client))
          .updateRolePermissions('MEDIADOR', ['users.view', 'devices.view']);

      expect(captured!.method, 'PUT');
      expect(captured!.url.path, '/api/roles/MEDIADOR/permissions');
      expect(jsonDecode(captured!.body), {
        'permissions': ['users.view', 'devices.view'],
      });
      expect(role.permissions.map((p) => p.name),
          ['users.view', 'devices.view']);
    });
  });

  group('UsersController', () {
    test('refresh arma la lista y los roles del dominio', () async {
      final api = _api(_staffClient());
      final controller = _users(api);

      await controller.refresh();

      expect(controller.status, UsersLoadStatus.ready);
      expect(controller.users, hasLength(2));
      expect(
          controller.roles.map((r) => r.name), ['ADMINISTRADOR', 'MEDIADOR']);
      expect(controller.roleCount('MEDIADOR'), 1);
      expect(controller.forbidden, isFalse);
    });

    test('un 403 deja la pestana en estado restringido (mediador)',
        () async {
      final client = MockClient((request) async => http.Response(
          jsonEncode({
            'code': 'missing_permission',
            'detail': 'Requiere users.view.',
          }),
          403,
          headers: {'content-type': 'application/json'}));
      final controller = _users(_api(client));

      await controller.refresh();

      expect(controller.status, UsersLoadStatus.error);
      expect(controller.forbidden, isTrue);
      expect(controller.users, isEmpty);
    });

    test('setActive desactiva (borrado logico) y recarga', () async {
      final deactivated = <String>[];
      final client = MockClient((request) async {
        if (request.method == 'POST' &&
            request.url.path.endsWith('/deactivate')) {
          deactivated.add(request.url.path);
          return http.Response(
              jsonEncode(_userJson(id: 2, role: 'MEDIADOR', active: false)),
              200,
              headers: {'content-type': 'application/json'});
        }
        // El listado refleja el estado tras cada mutacion.
        return http.Response(
            jsonEncode([
              _userJson(),
              _userJson(
                  id: 2,
                  name: 'Valentina',
                  role: 'MEDIADOR',
                  active: deactivated.isNotEmpty ? false : true),
            ]),
            200,
            headers: {'content-type': 'application/json'});
      });
      final controller = _users(_api(client));
      await controller.refresh();
      final mediadora = controller.users
          .singleWhere((u) => u.role.name == 'MEDIADOR');
      expect(mediadora.isActive, isTrue);

      final error = await controller.setActive(mediadora, active: false);

      expect(error, isNull);
      expect(deactivated, ['/api/users/2/deactivate']);
      expect(
        controller.users
            .singleWhere((u) => u.role.name == 'MEDIADOR')
            .isActive,
        isFalse,
      );
    });

    test('createUser expone el fallo sin lanzar', () async {
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(
              jsonEncode({
                'code': 'conflict',
                'detail': 'Email lucia@cauce.edu is already registered',
              }),
              409,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('[]', 200,
            headers: {'content-type': 'application/json'});
      });
      final controller = _users(_api(client));

      final error = await controller.createUser(
        name: 'Lucia',
        email: 'lucia@cauce.edu',
        pin: '1234',
        role: 'MEDIADOR',
      );

      expect(error, isNotNull);
      expect(controller.users, isEmpty);
    });
  });

  group('Pestana Usuarios', () {
    testWidgets(
        'admin: lista con chips por rol y acordeon con acciones',
        (tester) async {
      final api = _api(_staffClient());
      await _pumpUsers(tester, api: api, admin: true);

      // El titulo vive en el header de la pestana; la cabecera de
      // seccion desaparece y el boton Roles acompana los chips.
      expect(find.text('Usuarios'), findsOneWidget);
      expect(find.text('Gestion de personal y roles de sala'),
          findsNothing);
      expect(find.text('Roles'), findsOneWidget);
      expect(find.text('Nuevo Usuario'), findsOneWidget);

      // Chips: total + un chip por rol del dominio.
      expect(find.text('Todos (2)'), findsOneWidget);
      expect(find.text('Administrador (1)'), findsOneWidget);
      expect(find.text('Mediador (1)'), findsOneWidget);

      // El acordeon nace plegado: sin acciones visibles.
      expect(find.text('Carlos Mendoza'), findsOneWidget);
      expect(find.text('Eliminar Usuario'), findsNothing);

      // Al desplegar aparecen telemetria y acciones in-situ.
      await tester.tap(find.text('Carlos Mendoza'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Reset PIN'), findsOneWidget);
      expect(find.text('Eliminar Usuario'), findsOneWidget);
      // Ambas cuentas estan activas: una insignia por tarjeta.
      expect(find.text('Activo'), findsNWidgets(2));
    });

    testWidgets('mediador: aviso de seccion reservada y sin alta',
        (tester) async {
      final client = MockClient((request) async => http.Response(
          jsonEncode({
            'code': 'missing_permission',
            'detail': 'Requiere users.view.',
          }),
          403,
          headers: {'content-type': 'application/json'}));
      final api = _api(client);
      await _pumpUsers(tester, api: api, admin: false);

      expect(find.text('Seccion reservada a administradores'),
          findsOneWidget);
      expect(find.text('Nuevo Usuario'), findsNothing);
    });

    testWidgets('eliminar usuario confirma y ejecuta la desactivacion '
        'logica', (tester) async {
      final deactivated = <String>[];
      var active = true;
      final client = MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST' && path.endsWith('/deactivate')) {
          deactivated.add(path);
          active = false;
          return http.Response(
              jsonEncode(_userJson(active: false)), 200,
              headers: {'content-type': 'application/json'});
        }
        if (path == '/api/users') {
          return http.Response(
              jsonEncode([_userJson(active: active)]), 200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('[]', 200,
            headers: {'content-type': 'application/json'});
      });
      final api = _api(client);
      await _pumpUsers(tester, api: api, admin: true);

      await tester.tap(find.text('Carlos Mendoza'));
      await tester.pump(const Duration(milliseconds: 400));
      await _scrollToBottom(tester);
      await tester.tap(find.text('Eliminar Usuario'));
      await tester.pump(const Duration(milliseconds: 300));

      // El dialogo explicita que no hay borrado fisico.
      expect(find.text('Eliminar usuario'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Desactivar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(deactivated, ['/api/users/1/deactivate']);
      // La tarjeta refleja la cuenta desactivada tras el refresco.
      expect(find.text('Inactivo'), findsOneWidget);
      expect(
        find.text(
            '"Carlos Mendoza" desactivado del circuito de personal.'),
        findsOneWidget,
      );
    });

    testWidgets('el conmutador oculta y vuelve a mostrar los '
        'perfiles inactivos', (tester) async {
      final client = MockClient((request) async {
        final path = request.url.path;
        if (path == '/api/users') {
          return http.Response(
              jsonEncode([
                _userJson(),
                _userJson(
                    id: 2,
                    name: 'Ana Inactiva',
                    email: 'ana@cauce.edu',
                    role: 'MEDIADOR',
                    active: false),
              ]),
              200,
              headers: {'content-type': 'application/json'});
        }
        if (path == '/api/roles') {
          return http.Response(
              jsonEncode([
                _roleJson('ADMINISTRADOR', _catalog),
                _roleJson('MEDIADOR', [_catalog[0]]),
              ]),
              200,
              headers: {'content-type': 'application/json'});
        }
        return http.Response('[]', 200,
            headers: {'content-type': 'application/json'});
      });
      final api = _api(client);
      await _pumpUsers(tester, api: api, admin: true);

      // Con los inactivos a la vista, la lista incluye a Ana.
      expect(find.text('Ana Inactiva'), findsOneWidget);
      expect(find.text('Inactivo'), findsOneWidget);
      expect(find.text('Todos (2)'), findsOneWidget);

      // Ocultar: la tarjeta desaparece y los contadores se ajustan.
      await tester.tap(find.byIcon(Icons.visibility));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Ana Inactiva'), findsNothing);
      expect(find.text('Inactivo'), findsNothing);
      expect(find.text('Todos (1)'), findsOneWidget);
      expect(find.text('Mediador (0)'), findsOneWidget);

      // El icono conmutado vuelve a mostrar los inactivos.
      await tester.tap(find.byIcon(Icons.visibility_off));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Ana Inactiva'), findsOneWidget);
      expect(find.text('Todos (2)'), findsOneWidget);
    });
  });

  group('Pantalla Roles y Permisos', () {
    testWidgets('matriz: conmutar y guardar envia el PUT completo',
        (tester) async {
      final putBodies = <dynamic>[];
      final api = _api(_rolesClient((body) => putBodies.add(body)));
      await _pumpRoles(tester, api: api, admin: true);

      // Autoseleccion del primer rol del dominio (Administrador).
      expect(find.text('Administrador'), findsWidgets);
      expect(find.text('Mediador'), findsOneWidget);
      expect(find.text('Nuevo Rol'), findsOneWidget);
      expect(find.text('2 de 5 permisos concedidos'), findsOneWidget);

      // Conmutar un permiso activa el guardado.
      await _scrollToBottom(tester);
      await tester.tap(find.text('Administrar y distribuir contenido'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('3 de 5 permisos concedidos'), findsOneWidget);

      // El guardado queda a la vista tras el salto al fondo.
      await tester.tap(find.text('Guardar Cambios de Permisos'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));

      expect(putBodies, hasLength(1));
      expect(putBodies.single,
          ['users.view', 'devices.view', 'content.manage']);
      // Al guardar se cierra la matriz de permisos: regresa al punto
      // de partida y el aviso queda en el Scaffold de atras.
      expect(find.text('abrir roles'), findsOneWidget);
      expect(find.text('Guardar Cambios de Permisos'), findsNothing);
      expect(
        find.text('Permisos de Administrador actualizados en la LAN.'),
        findsOneWidget,
      );
    });

    testWidgets('nuevo rol avisa que el backend no lo ofrece (mock)',
        (tester) async {
      final api = _api(_rolesClient(null));
      await _pumpRoles(tester, api: api, admin: true);

      await tester.tap(find.text('Nuevo Rol'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.textContaining('Los roles son fijos del sistema'),
        findsOneWidget,
      );
    });

    testWidgets('cancelar deshace los cambios locales', (tester) async {
      final api = _api(_rolesClient(null));
      await _pumpRoles(tester, api: api, admin: true);

      await _scrollToBottom(tester);
      await tester.tap(find.text('Administrar y distribuir contenido'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('3 de 5 permisos concedidos'), findsOneWidget);

      await tester.tap(find.text('Cancelar'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('2 de 5 permisos concedidos'), findsOneWidget);
    });
  });
}

UsersController _users(ApiClient api) => UsersController(
      service: UserService(client: api),
      roleService: RoleService(client: api),
    );

/// Personal: una administradora y una mediadora activas.
http.Client _staffClient() {
  return MockClient((request) async {
    final path = request.url.path;
    if (path == '/api/users') {
      return http.Response(
          jsonEncode([
            _userJson(),
            _userJson(id: 2, name: 'Valentina Rivas', role: 'MEDIADOR'),
          ]),
          200,
          headers: {'content-type': 'application/json'});
    }
    if (path == '/api/roles') {
      return http.Response(
          jsonEncode([
            _roleJson('ADMINISTRADOR', _catalog),
            _roleJson('MEDIADOR', [_catalog[0], _catalog[2]]),
          ]),
          200,
          headers: {'content-type': 'application/json'});
    }
    return http.Response('[]', 200,
        headers: {'content-type': 'application/json'});
  });
}

/// Roles: ADMINISTRADOR con users.view y devices.view; catalogo de 5.
/// [onPut] captura el cuerpo del PUT de permisos.
http.Client _rolesClient(void Function(dynamic body)? onPut) {
  final adminPerms = [_catalog[0], _catalog[2]];
  return MockClient((request) async {
    final path = request.url.path;
    final method = request.method;
    if (method == 'PUT' && path == '/api/roles/ADMINISTRADOR/permissions') {
      final body = jsonDecode(request.body);
      if (onPut != null) {
        onPut((body as Map<String, dynamic>)['permissions']);
      }
      final names = (body['permissions'] as List<dynamic>).cast<String>();
      return http.Response(
          jsonEncode(_roleJson('ADMINISTRADOR', [
            for (final p in _catalog)
              if (names.contains(p['name'])) p,
          ])),
          200,
          headers: {'content-type': 'application/json'});
    }
    if (path == '/api/roles' && method == 'GET') {
      return http.Response(
          jsonEncode([
            _roleJson('ADMINISTRADOR', adminPerms),
            _roleJson('MEDIADOR', [_catalog[0]]),
          ]),
          200,
          headers: {'content-type': 'application/json'});
    }
    if (path == '/api/permissions') {
      return http.Response(jsonEncode(_catalog), 200,
          headers: {'content-type': 'application/json'});
    }
    if (path == '/api/roles/ADMINISTRADOR/permissions') {
      return http.Response(
          jsonEncode(_roleJson('ADMINISTRADOR', adminPerms)), 200,
          headers: {'content-type': 'application/json'});
    }
    if (path == '/api/roles/MEDIADOR/permissions') {
      return http.Response(
          jsonEncode(_roleJson('MEDIADOR', [_catalog[0]])), 200,
          headers: {'content-type': 'application/json'});
    }
    if (path == '/api/users') {
      return http.Response(
          jsonEncode([
            _userJson(),
            _userJson(id: 2, name: 'Valentina Rivas', role: 'MEDIADOR'),
          ]),
          200,
          headers: {'content-type': 'application/json'});
    }
    return http.Response('[]', 200,
        headers: {'content-type': 'application/json'});
  });
}

/// Lleva el scroll vertical principal al fondo. Las pantallas con
/// encabezado llevan el badge LAN latiendo en bucle, asi que no se
/// puede usar pumpAndSettle ni el scroll animado de ensureVisible:
/// se asientan unos fotogramas y se salta directamente.
Future<void> _scrollToBottom(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  final scrollable = tester.state<ScrollableState>(
    find
        .descendant(
          of: find.byType(SingleChildScrollView),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _pumpUsers(
  WidgetTester tester, {
  required ApiClient api,
  required bool admin,
}) async {
  final controller = _users(api);
  await controller.refresh();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionController>.value(
          value: _FakeSession(apiClient: api, admin: admin),
        ),
        ChangeNotifierProvider.value(value: controller),
      ],
      // La pestana vive dentro del Scaffold del shell: aqui se
      // envuelve para que TextField/InkWell tengan Material.
      child: const MaterialApp(home: Scaffold(body: UsersScreen())),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pumpRoles(
  WidgetTester tester, {
  required ApiClient api,
  required bool admin,
}) async {
  final controller = _users(api);
  await controller.refresh();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionController>.value(
          value: _FakeSession(apiClient: api, admin: admin),
        ),
        ChangeNotifierProvider.value(value: controller),
      ],
      // La matriz se abre como ruta apilada sobre una pagina base:
      // al guardar se cierra (pop) y regresa aqui, como en el shell.
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const RolesScreen(),
                  ),
                ),
                child: const Text('abrir roles'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('abrir roles'));
  await tester.pump();
  // La pantalla carga roles + catalogo + permisos del rol en su
  // initState diferido; el badge LAN late en bucle, asi que se
  // asientan fotogramas fijos (sin pumpAndSettle).
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
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
