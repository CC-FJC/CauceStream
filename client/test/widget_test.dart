import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'package:cauce_stream/main.dart';
import 'package:cauce_stream/screens/auto_playback_screen.dart';
import 'package:cauce_stream/widgets/dvd_screensaver.dart';

void main() {
  testWidgets('Sin asignación del servidor arranca en el screensaver '
      '(logo CAUCE rebotando), no en carga de video', (WidgetTester tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await dotenv.load(fileName: '.env');

    await tester.pumpWidget(
      CauceStreamApp(home: const AutoPlaybackScreen(retryOnError: false)),
    );
    await tester.pump();

    expect(find.byType(AutoPlaybackScreen), findsOneWidget);
    // Modo por defecto: screensaver DVD, sin spinner de carga ni red.
    expect(find.byType(DvdScreensaver), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
