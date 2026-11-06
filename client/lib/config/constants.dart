import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  AppConfig._();

  static const String appName = 'CAUCE Stream';

  /// URL base del servidor Cauce en la LAN (p. ej. http://10.15.1.150:8000).
  /// Opcional: si no está definida, la app funciona igual, solo que sin
  /// heartbeats ni canal de playback (pantalla siempre en screensaver).
  /// Todo el contenido llega desde este servidor; no se usa Google Drive.
  static String? get cauceServerUrl {
    final value = dotenv.env['CAUCE_SERVER_URL'];
    if (value == null || value.trim().isEmpty) return null;
    // Normaliza solo el formato de la URL, nunca su contenido.
    return value.trim().replaceAll(RegExp(r'/+$'), '');
  }

  /// Secreto compartido con el servidor Cauce (header X-Device-Key en
  /// el heartbeat y el WebSocket). Opcional: si no está definida en el
  /// servidor, no se envía (modo transición).
  static String? get deviceSecret {
    final value = dotenv.env['CAUCE_DEVICE_SECRET'];
    if (value == null || value.trim().isEmpty) return null;
    return value.trim();
  }
}
