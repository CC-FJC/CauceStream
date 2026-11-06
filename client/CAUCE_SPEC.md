# CAUCE Stream — Especificación técnica y funcional (actual)

> **Nota histórica:** las fases iniciales de este cliente usaban Google
> Drive como fuente del catálogo (ver `PLANNING.md`). Esa integración fue
> **eliminada**: el contenido ahora llega exclusivamente desde el servidor
> Cauce de la LAN. Este documento describe el comportamiento vigente.

## Visión

Cliente de reproducción automática para los dispositivos (pantallas) de la
Sala CAUCE del Centro de Ciencias Francisco José de Caldas. Aplicación
Flutter para Android TV que muestra lo que el servidor Cauce le asigna y,
cuando no hay nada asignado, un screensaver clásico.

## Objetivo

- Reproducir en bucle el contenido asignado por el servidor (video, imagen,
  PDF o URL) descargándolo del propio servidor (`/api/media/{id}/file`).
- Sin asignación vigente: **screensaver estilo DVD** — el logo de CAUCE
  (`assets/logo.png`) rebota en los bordes de la pantalla y cambia de color
  en cada rebote. No usa red.
- Reportar estado al servidor: heartbeat HTTP periódico con el medio
  confirmado en pantalla (`current_media`) y WebSocket de playback
  (`/api/devices/{uid}/ws`) para recibir `playback.command`.

## Flujo de la aplicación

1. Al iniciar arranca el heartbeat y el WebSocket de playback (si
   `CAUCE_SERVER_URL` está definida).
2. Al conectar, el servidor envía `playback.sync` con la asignación vigente
   (o `assignment: null`).
3. Con asignación: descarga el medio y lo muestra (video en bucle con
   `video_player`/ExoPlayer, imagen, PDF con `pdfx`, URL con `webview_flutter`
   in-app). Al confirmar en pantalla, el heartbeat reporta ese `media_id`.
4. Sin asignación (o tras `showDefault`): screensaver DVD del logo.

## Configuración

Solo dos variables en `.env` (ya no hay claves de Google Drive):

- `CAUCE_SERVER_URL` (opcional): URL base del servidor Cauce en la LAN
  (p. ej. `http://10.15.1.150:8000`). Sin ella la app funciona igual, solo
  en screensaver, sin heartbeat ni WS. El `device_uid` no si configura: es
  el nombre del dispositivo tal como lo expone el SO.
- `CAUCE_DEVICE_SECRET` (opcional): secreto compartido con el servidor
  (header `X-Device-Key` en heartbeat, WS y descarga de medios).

## Stack técnico

| Capa | Tecnología |
|---|---|
| Framework | Flutter (Dart SDK ^3.6.2) |
| Plataforma | Android TV (API 24+) |
| Reproducción | `video_player` (plugin local `plugins/video_player_android` con fix del decoder Amlogic en TCL Google TV) |
| PDF | `pdfx` |
| URL | `webview_flutter` in-app |
| Comunicación | `http` (heartbeat) + `web_socket_channel` (WS playback) |
| Env vars | `flutter_dotenv` |
| Screensaver | `lib/widgets/dvd_screensaver.dart` (logo local rebotando) |

## Assets

- `assets/logo.png` — logo CAUCE usado por el screensaver DVD.

## Limitaciones conocidas

- **Solo Android TV como objetivo real**: en otras plataformas el video usa
  el fallback de la plataforma; el screensaver funciona en todas.
- **Sin catálogo local**: la app no explora contenido por sí misma; solo
  muestra lo que el servidor asigna.
