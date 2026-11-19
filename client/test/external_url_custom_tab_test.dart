import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'package:cauce_stream/main.dart';
import 'package:cauce_stream/models/playback_message.dart';
import 'package:cauce_stream/screens/auto_playback_screen.dart';
import 'package:cauce_stream/services/playback_socket_service.dart';
import 'package:cauce_stream/widgets/kiosk_web_view.dart';

/// Canales de plataforma del flujo de URL externa: el nativo
/// `cauce_stream/device` (keep-alive) y el del plugin Custom Tabs. En
/// el entorno de test nadie registra la implementación Android
/// (pigeon), así que el plugin va por su implementación por defecto
/// `MethodChannelCustomTabs` — canal `plugins.flutter.droibit.github.io/
/// custom_tabs`. En la tablet (APK real) sí se registra la versión
/// pigeon; el mock por nombre de canal cubre la ruta de test.
const _deviceChannel = MethodChannel('cauce_stream/device');
const _tabsChannel =
    MethodChannel('plugins.flutter.droibit.github.io/custom_tabs');

class _ChannelCalls {
  int startKeepAlive = 0;
  int stopKeepAlive = 0;
  int closeAll = 0;
  final List<String> launchedUrls = [];
}

/// Instala handlers simulados con contadores de llamadas. Sin esto,
/// en `testWidgets` las llamadas a canales sin mock nunca completan.
_ChannelCalls _mockChannels() {
  final calls = _ChannelCalls();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(
    _deviceChannel,
    (message) async {
      switch (message.method) {
        case 'startKeepAlive':
          calls.startKeepAlive++;
          return null;
        case 'stopKeepAlive':
          calls.stopKeepAlive++;
          return null;
      }
      return null;
    },
  );

  messenger.setMockMethodCallHandler(
    _tabsChannel,
    (message) async {
      switch (message.method) {
        case 'launch':
          calls.launchedUrls
              .add((message.arguments as Map)['url'] as String);
          return null;
        case 'closeAllIfPossible':
          calls.closeAll++;
          return null;
      }
      return null;
    },
  );

  return calls;
}

/// Como `_mockChannels` pero sin el canal del plugin Custom Tabs:
/// simula un dispositivo donde la ventana no puede abrirse.
_ChannelCalls _mockChannelsNoTab() {
  final calls = _ChannelCalls();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    _deviceChannel,
    (message) async {
      if (message.method == 'startKeepAlive') calls.startKeepAlive++;
      if (message.method == 'stopKeepAlive') calls.stopKeepAlive++;
      return null;
    },
  );
  return calls;
}

void _clearChannelMocks() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_deviceChannel, null);
  messenger.setMockMethodCallHandler(_tabsChannel, null);
}

AssignmentMedia _mediaUrl(String name) => AssignmentMedia(
      name: name,
      mediaType: PlaybackMediaType.url,
      fileUrl: null,
      externalUrl: 'https://example.com/$name',
    );

Uri _arUrl() => Uri.parse('https://flow.example.com/ar');

Future<PlaybackApplier> _pumpScreen(WidgetTester tester) async {
  await tester.pumpWidget(
    CauceStreamApp(home: const AutoPlaybackScreen(retryOnError: false)),
  );
  await tester.pump();
  final state = tester.state<State<AutoPlaybackScreen>>(
    find.byType(AutoPlaybackScreen),
  );
  return state as PlaybackApplier;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await dotenv.load(fileName: '.env');
  });

  tearDown(_clearChannelMocks);

  group('URL externa (Custom Tab fullscreen)', () {
    testWidgets('showUrl external lanza el Custom Tab y deja la tarjeta '
        'con nombre, url y botón "Volver a la WEB" (sin WebView in-app)',
        (tester) async {
      final calls = _mockChannels();
      final applier = await _pumpScreen(tester);

      final ok = await applier.showUrl(
        _arUrl(),
        _mediaUrl('arflow'),
        UrlDisplayMode.external,
      );
      await tester.pump();

      expect(ok, isTrue);
      expect(calls.startKeepAlive, 1);
      expect(calls.launchedUrls, [_arUrl().toString()]);

      // El kiosk queda en la tarjeta con todo a la vista: nunca WebView.
      expect(find.text('arflow'), findsOneWidget);
      expect(find.text(_arUrl().toString()), findsOneWidget);
      expect(find.text('Volver a la WEB'), findsOneWidget);
      expect(find.byType(KioskWebView), findsNothing);
    });

    testWidgets('"Volver a la WEB" relanza el Custom Tab con la misma '
        'URL y vuelve a levantar el keep-alive', (tester) async {
      final calls = _mockChannels();
      final applier = await _pumpScreen(tester);

      await applier.showUrl(
        _arUrl(),
        _mediaUrl('arflow'),
        UrlDisplayMode.external,
      );
      await tester.pump();
      expect(calls.startKeepAlive, 1);

      await tester.tap(find.text('Volver a la WEB'));
      await tester.pump();

      expect(calls.startKeepAlive, 2);
      expect(calls.launchedUrls, [_arUrl().toString(), _arUrl().toString()]);
      // La asignación no cambia: la tarjeta sigue en pantalla.
      expect(find.text('Volver a la WEB'), findsOneWidget);
    });

    testWidgets('tras cerrar la web con la X (resume del mediador) el '
        'kiosk apaga el keep-alive, NO monta el WebView in-app y '
        'conserva el botón', (tester) async {
      final calls = _mockChannels();
      final applier = await _pumpScreen(tester);

      await applier.showUrl(
        _arUrl(),
        _mediaUrl('arflow'),
        UrlDisplayMode.external,
      );
      await tester.pump();
      expect(calls.stopKeepAlive, 0,
          reason: 'El keep-alive corre mientras la web está abierta.');

      // El mediador cierra la ventana (la X) y el kiosk vuelve al frente.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(calls.stopKeepAlive, 1);
      expect(calls.closeAll, 0,
          reason: 'La ventana ya la cerró el mediador; re-cerrarla '
              'sobraría (y mataría una sesión viva tras un Home).');

      // Regresión central de F1: nada de WebView fantasma sin acción.
      expect(find.byType(KioskWebView), findsNothing);
      expect(find.text('Volver a la WEB'), findsOneWidget);
      expect(find.text(_arUrl().toString()), findsOneWidget);
    });

    testWidgets('cambiar de medio (showDefault) cierra la ventana de '
        'Chrome y apaga el keep-alive: el servidor manda siempre',
        (tester) async {
      final calls = _mockChannels();
      final applier = await _pumpScreen(tester);

      await applier.showUrl(
        _arUrl(),
        _mediaUrl('arflow'),
        UrlDisplayMode.external,
      );
      await tester.pump();

      expect(await applier.showDefault(), isTrue);
      await tester.pump();

      expect(calls.stopKeepAlive, 1);
      expect(calls.closeAll, 1);
      expect(find.text('Volver a la WEB'), findsNothing);
      expect(find.byType(KioskWebView), findsNothing);
    });

    testWidgets('si el Custom Tab no puede abrirse, showUrl external '
        'devuelve false sin romper el kiosk', (tester) async {
      final calls = _mockChannelsNoTab();
      final applier = await _pumpScreen(tester);

      var ok = false;
      await tester.runAsync(() async {
        ok = await applier
            .showUrl(_arUrl(), _mediaUrl('arflow'), UrlDisplayMode.external)
            .timeout(const Duration(seconds: 5));
      });
      await tester.pump();

      expect(ok, isFalse);
      expect(calls.startKeepAlive, 1);
      // Sin tarjeta de medio externo: no se asignó nada.
      expect(find.text('Volver a la WEB'), findsNothing);
    });
  });
}
