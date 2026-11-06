# CAUCE Stream (cliente de sala)

Aplicación Flutter para **Android TV** que corre en cada dispositivo de la
Sala CAUCE del **Centro de Ciencias Francisco José de Caldas**. No tiene
catálogo propio: **todo el contenido llega desde el servidor Cauce** de la
LAN (asignación vigente por WebSocket + descarga del archivo vía
`/api/media/{id}/file`). Google Drive ya no se usa para nada.

## Comportamiento

- **Con contenido asignado**: reproduce en bucle el video asignado, muestra
  la imagen asignada, renderiza el PDF o abre la URL asignada (WebView
  in-app en Android).
- **Sin contenido asignado** (comportamiento por defecto): **screensaver
  clásico estilo DVD** — el logo de CAUCE (`assets/logo.png`) rebota en los
  bordes de la pantalla y cambia de color en cada rebote. No usa red.
- **Heartbeat** periódico al servidor (`POST /api/devices/{uid}/heartbeat`)
  con el `current_media` confirmado en pantalla, y **WebSocket de playback**
  (`/api/devices/{uid}/ws`) para recibir órdenes `playback.command`.

## Requisitos

- Flutter SDK ^3.6.2
- Android TV (API 24+) como dispositivo objetivo

## Configuración

1. Clona el repositorio y entra en la carpeta:
   ```sh
   git clone <repo-url>
   cd cauce_stream
   ```

2. Copia el archivo de entorno:
   ```sh
   cp .env.example .env
   ```

3. Edita `.env` solo con el servidor Cauce (ya no hay claves de Drive):
   ```env
   CAUCE_SERVER_URL=http://ip-del-servidor-cauce:8000
   CAUCE_DEVICE_SECRET=secreto-compartido-igual-al-del-servidor
   ```

   > `CAUCE_SERVER_URL` es opcional: sin él la app funciona igual, solo que
   > sin heartbeat ni canal de playback (pantalla siempre en screensaver).
   > El `device_uid` no se configura: es el nombre del dispositivo tal como
   > lo expone el sistema operativo.
   >
   > **Importante:** el archivo `.env` contiene secretos y está incluido en
   > `.gitignore`.

4. Instala dependencias y ejecuta:
   ```sh
   flutter pub get
   flutter run                  # desarrollo
   flutter build apk --release  # APK de producción
   ```

## Arquitectura

```
lib/
├── main.dart                       # entry point: arranca heartbeat + WS
├── config/
│   └── constants.dart              # AppConfig (CAUCE_SERVER_URL, CAUCE_DEVICE_SECRET)
├── models/
│   └── playback_message.dart       # protocolo WS del servidor
├── screens/
│   └── auto_playback_screen.dart   # reproduce lo asignado o screensaver
├── services/
│   ├── cauce_heartbeat_service.dart    # heartbeat HTTP
│   ├── cauce_media_downloader.dart     # descarga de medios del servidor
│   ├── device_identity.dart            # device_uid (nombre del SO)
│   ├── playback_socket_service.dart    # WS de playback + RevisionGate
│   ├── playback_state.dart             # medio confirmado en pantalla
│   ├── power_executor.dart             # comandos de energía (ADB/DeviceOwner)
│   └── url_load_gate.dart
└── widgets/
    ├── dvd_screensaver.dart        # logo CAUCE rebotando (sin asignación)
    ├── kiosk_web_view.dart         # medio URL en WebView in-app
    └── river_loading_indicator.dart
```

## Stack técnico

| Componente | Tecnología |
|---|---|
| Framework | Flutter (Dart SDK ^3.6.2) |
| Plataforma destino | Android TV (API 24+) |
| Fuente de contenido | Servidor Cauce (LAN) — nada de Google Drive |
| Reproductor | `video_player` (plugin local parcheado para ExoPlayer/decoder Amlogic) |
| PDF | `pdfx` |
| URL | `webview_flutter` in-app (Android) |
| Comunicación | `http` (heartbeat) + `web_socket_channel` (playback WS) |
| Env vars | `flutter_dotenv` |

## Comandos útiles

```sh
flutter analyze                  # análisis estático
flutter test                     # pruebas
flutter build apk --release      # APK para Android TV
```

## Desarrollo

Corre `flutter analyze` antes de cada commit. Ver `PLANNING.md` (histórico)
y `CAUCE_SPEC.md` (nota de obsolescencia de la fase Google Drive).

## Licencia

Uso interno — Centro de Ciencias Francisco José de Caldas.
