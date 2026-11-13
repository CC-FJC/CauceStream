// Prueba de humo de la pantalla de Perfil: encabezado reducido (solo
// "Perfil", sin logo ni subtitulo), tarjeta de identidad sin foto de
// perfil (el dominio no contempla imagenes de usuario), datos de la
// cuenta sin el ID, y sin las opciones de fases futuras (Notificar
// Incidencia Tecnica, Sincronizacion Continua). El logout queda como
// "Cerrar Sesion" con una confirmacion simple, sin jerga tecnica. La
// sesion se establece contra un API simulada.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:cauce_stream/core/network/api_client.dart';
import 'package:cauce_stream/screens/profile/profile_screen.dart';
import 'package:cauce_stream/services/auth_service.dart';
import 'package:cauce_stream/services/user_service.dart';
import 'package:cauce_stream/session/session_controller.dart';
import 'package:cauce_stream/session/token_storage.dart';

/// JWT firmado a mano (la firma no se valida en el cliente): basta
/// con que el payload decodifique `sub` como id de usuario.
String _tokenFor(int sub) {
  final payload = base64Url.encode(
    utf8.encode(jsonEncode({'sub': '$sub', 'role': 'ADMINISTRADOR'})),
  );
  return 'header.$payload.signature';
}

const _userJson = {
  'id': 7,
  'name': 'Admin de Sala',
  'email': 'admin@cauce.edu',
  'role': {'id': 1, 'name': 'ADMINISTRADOR'},
  'is_active': true,
  'created_at': '2025-01-15T10:00:00',
  'updated_at': '2025-02-20T10:00:00',
};

http.Client _mockApi() => MockClient((request) async {
  if (request.url.path == '/api/auth/login') {
    return http.Response(
      jsonEncode({'access_token': _tokenFor(7), 'token_type': 'bearer'}),
      200,
    );
  }
  if (request.url.path == '/api/users/7') {
    return http.Response(jsonEncode(_userJson), 200);
  }
  return http.Response('not found', 404);
});

class _FakeStorage implements TokenStorage {
  String? _token;
  String? _email;

  @override
  Future<void> clear() async {
    _token = null;
    _email = null;
  }

  @override
  Future<String?> readRememberedEmail() async => _email;

  @override
  Future<String?> readToken() async => _token;

  @override
  Future<void> saveSession({
    required String token,
    String? rememberedEmail,
  }) async {
    _token = token;
    _email = rememberedEmail;
  }
}

/// Sesion activa con perfil precargado contra el API simulada.
Future<SessionController> _loggedInSession() async {
  final apiClient = ApiClient(
    baseUrl: 'http://10.15.1.150:8000/api',
    client: _mockApi(),
  );
  final session = SessionController(
    storage: _FakeStorage(),
    authService: AuthService(client: apiClient),
    userService: UserService(client: apiClient),
    apiClient: apiClient,
  );
  final ok = await session.login(email: 'admin@cauce.edu', pin: '1234');
  expect(ok, isTrue, reason: 'la sesion simulada debe quedar activa');
  return session;
}

void main() {
  testWidgets('perfil ajustado: encabezado, identidad y opciones', (tester) async {
    final session = await _loggedInSession();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: session,
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Encabezado: solo "Perfil", sin subtitulo ni logo de Cauce (las
    // decoraciones del fondo permanecen: no son parte del encabezado).
    expect(find.text('Perfil'), findsOneWidget);
    expect(find.text('Perfil & Sesion'), findsNothing);
    expect(find.text('CAUCE_STREAM'), findsNothing);
    expect(
      find.byWidgetPredicate((w) {
        if (w is! Image) return false;
        final image = w.image;
        return image is AssetImage && image.assetName.contains('logo');
      }),
      findsNothing,
    );

    // Identidad: sin foto de perfil; datos de la cuenta sin el ID.
    expect(find.text('Admin de Sala'), findsOneWidget);
    expect(find.text('ID de usuario'), findsNothing);

    // Opciones eliminadas.
    expect(find.text('Notificar Incidencia Tecnica'), findsNothing);
    expect(find.text('Sincronizacion Continua'), findsNothing);

    // Las opciones que permanecen.
    expect(find.text('Alertas de Red Local'), findsOneWidget);
    expect(find.text('Actualizar PIN de Seguridad'), findsOneWidget);
    expect(find.text('Editar nombre y correo'), findsOneWidget);
    expect(find.text('Cerrar Sesion'), findsOneWidget);
    expect(find.text('Cerrar Sesion Activa'), findsNothing);

    session.dispose();
  });

  testWidgets('la confirmacion de cierre es simple y sin jerga tecnica',
      (tester) async {
    final session = await _loggedInSession();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: session,
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Cerrar Sesion'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cerrar Sesion'));
    await tester.pumpAndSettle();

    expect(find.text('¿Cerrar Sesion?'), findsOneWidget);
    expect(
      find.textContaining('Se cerrara tu sesion en este dispositivo'),
      findsOneWidget,
    );
    // Sin palabras tecnicas del backend en el mensaje al usuario.
    expect(find.textContaining('token'), findsNothing);

    // Cancelar mantiene la sesion activa.
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.text('¿Cerrar Sesion?'), findsNothing);
    expect(session.status, SessionStatus.authenticated);

    session.dispose();
  });
}
