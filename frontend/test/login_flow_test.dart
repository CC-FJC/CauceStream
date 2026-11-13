// Prueba de integracion del flujo de login: escribe correo + PIN en la
// pantalla real, pulsa "Ingresar" y verifica que se envia
// el POST al contrato del backend con el cuerpo correcto. Usa los
// assets reales del paquete (disponibles en flutter test).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:cauce_stream/core/app_info.dart';
import 'package:cauce_stream/core/network/api_client.dart';
import 'package:cauce_stream/screens/login/login_screen.dart';
import 'package:cauce_stream/services/auth_service.dart';
import 'package:cauce_stream/services/user_service.dart';
import 'package:cauce_stream/session/session_controller.dart';
import 'package:cauce_stream/session/token_storage.dart';
import 'package:cauce_stream/widgets/identity_widgets.dart';

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

void main() {
  late List<http.Request> requests;
  late SessionController session;

  Future<void> pumpApp(WidgetTester tester, http.Client client) async {
    final apiClient = ApiClient(
      baseUrl: 'http://10.15.1.150:8000/api',
      client: client,
    );
    session = SessionController(
      storage: _FakeStorage(),
      authService: AuthService(client: apiClient),
      userService: UserService(client: apiClient),
      apiClient: apiClient,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: session,
        child: const MaterialApp(home: Scaffold(body: LoginScreen())),
      ),
    );
    await tester.pump();
  }

  Future<void> fillForm(WidgetTester tester) async {
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(5)); // 1 correo + 4 digitos PIN

    await tester.enterText(fields.at(0), 'mediador@cauce.edu');
    await tester.enterText(fields.at(1), '1');
    await tester.enterText(fields.at(2), '2');
    await tester.enterText(fields.at(3), '3');
    await tester.enterText(fields.at(4), '4');
    await tester.pump();
  }

  testWidgets('pulsar Ingresar envia POST /auth/login con el contrato',
      (tester) async {
    requests = [];
    final mock = MockClient((request) async {
      requests.add(request);
      return http.Response(
        jsonEncode({'access_token': 'a.b.c', 'token_type': 'bearer'}),
        200,
      );
    });
    await pumpApp(tester, mock);
    await fillForm(tester);

    await tester.tap(find.byType(FilledButton));
    await tester.pump(); // muestra "Conectando..."
    await tester.pump(const Duration(milliseconds: 100));

    expect(requests, hasLength(1));
    expect(requests.single.method, 'POST');
    expect(requests.single.url.toString(),
        'http://10.15.1.150:8000/api/auth/login');
    expect(jsonDecode(requests.single.body),
        {'email': 'mediador@cauce.edu', 'password': '1234'});
    expect(requests.single.headers['Content-Type'], 'application/json');
  });

  testWidgets('credenciales invalidas muestran el error de autenticacion',
      (tester) async {
    requests = [];
    final mock = MockClient((request) async {
      requests.add(request);
      return http.Response(
        jsonEncode({
          'code': 'not_authenticated',
          'detail': 'Invalid email or password'
        }),
        401,
      );
    });
    await pumpApp(tester, mock);
    await fillForm(tester);

    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Correo o PIN incorrectos.'), findsOneWidget);
  });

  testWidgets('con el servidor caido se informa el error de conexion',
      (tester) async {
    requests = [];
    final mock = MockClient((request) async {
      requests.add(request);
      throw http.ClientException('sin ruta al host');
    });
    await pumpApp(tester, mock);
    await fillForm(tester);

    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text(
          'No hay conexion con el servidor Cauce. Verifica la red de la sala.'),
      findsOneWidget,
    );
  });

  testWidgets('la pastilla de estado del servidor queda en la esquina '
      'superior derecha, sobre el formulario', (tester) async {
    requests = [];
    final mock = MockClient((request) async => http.Response('{}', 200));
    await pumpApp(tester, mock);

    final badge = tester.getRect(find.byType(LanBadge));
    final formTitle = tester.getRect(find.text('Iniciar Sesion'));
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;

    // Arriba del titulo del formulario...
    expect(badge.bottom, lessThan(formTitle.top));
    // ...en la mitad derecha de la pantalla...
    expect(badge.center.dx, greaterThan(size.width / 2));
    // ...y pegada al borde derecho (padding horizontal de 20).
    expect(size.width - badge.right, moreOrLessEquals(20, epsilon: 1.5));
  });

  testWidgets('la tarjeta no cambia de tamano al desplegarse el '
      'teclado numerico', (tester) async {
    requests = [];
    final mock = MockClient((request) async => http.Response('{}', 200));
    await pumpApp(tester, mock);

    final before = tester.getSize(find.byType(Form));

    // Teclado de ~300 dp sobre la pantalla de prueba.
    tester.view.viewInsets = FakeViewPadding(
      bottom: 300 * tester.view.devicePixelRatio,
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    final after = tester.getSize(find.byType(Form));
    expect(after.width, moreOrLessEquals(before.width, epsilon: 0.01));
    expect(after.height, moreOrLessEquals(before.height, epsilon: 0.01));

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
  });

  testWidgets('la tarjeta no cambia de tamano al mostrar el feedback '
      'del login', (tester) async {
    requests = [];
    final mock = MockClient((request) async {
      requests.add(request);
      return http.Response(
        jsonEncode({
          'code': 'not_authenticated',
          'detail': 'Invalid email or password'
        }),
        401,
      );
    });
    await pumpApp(tester, mock);

    final before = tester.getRect(find.byType(Form));

    await fillForm(tester);
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // El mensaje de error aparece en el slot reservado: la tarjeta
    // conserva exactamente su tamano y su posicion.
    expect(find.text('Correo o PIN incorrectos.'), findsOneWidget);
    final after = tester.getRect(find.byType(Form));
    expect(after.top, moreOrLessEquals(before.top, epsilon: 0.5));
    expect(after.bottom, moreOrLessEquals(before.bottom, epsilon: 0.5));
    expect(after.width, moreOrLessEquals(before.width, epsilon: 0.01));
    expect(after.height, moreOrLessEquals(before.height, epsilon: 0.5));
  });

  testWidgets('el boton dice Ingresar y el pie solo muestra la version',
      (tester) async {
    requests = [];
    final mock = MockClient((request) async => http.Response('{}', 200));
    await pumpApp(tester, mock);

    expect(find.text('Ingresar'), findsOneWidget);
    expect(find.text('Ingresar al Circuito'), findsNothing);
    expect(
      find.textContaining('Version ${AppInfo.appVersion}'),
      findsOneWidget,
      reason: 'el pie de pagina conserva la version de la app',
    );
    expect(find.textContaining('Nodo Central'), findsNothing);
    expect(find.textContaining('Autenticacion local'), findsNothing);
  });

  testWidgets('PIN incompleto no envia ninguna peticion', (tester) async {
    requests = [];
    final mock = MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200);
    });
    await pumpApp(tester, mock);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'mediador@cauce.edu');
    await tester.enterText(fields.at(1), '1');
    await tester.enterText(fields.at(2), '2');
    await tester.pump();

    await tester.tap(find.byType(FilledButton));
    await tester.pump();

    expect(requests, isEmpty);
    expect(find.text('Por favor ingresa los 4 digitos completos de tu PIN.'),
        findsOneWidget);
  });

  testWidgets('un login lento del servidor completa correctamente',
      (tester) async {
    // El backend ejecuta bcrypt y puede tardar varios segundos,
    // sobre todo con el contenedor arrancando en frio. El login debe
    // seguir esperando dentro del margen ampliado.
    requests = [];
    final mock = MockClient((request) async {
      requests.add(request);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return http.Response(
        jsonEncode({'access_token': 'a.b.c', 'token_type': 'bearer'}),
        200,
      );
    });
    await pumpApp(tester, mock);
    await fillForm(tester);

    await tester.tap(find.byType(FilledButton));
    await tester.pump(); // "Conectando..." visible
    expect(find.text('Conectando al servidor local de sala...'),
        findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(requests, hasLength(1));
    // El feedback de conexion desaparece al completar el login.
    expect(find.text('Conectando al servidor local de sala...'),
        findsNothing);
  });
}
