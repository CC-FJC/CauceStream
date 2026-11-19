# Abrir webs con cámara (AR) en Chrome externo desde el kiosk

Mecanismo verificado en sala (2026-11-18, tablet Samsung `TabletAR2`
10.15.1.165) para experiencias webAR tipo
`https://flow.centrodeciencia-maker.workers.dev/`.

## Por qué por Chrome y no en el cliente

Diagnóstico de esa fecha (ver `contexto.md` sección 19 y notas de sesión):

- El WebView in-app (Android System WebView 157.0.8103.50) **no
  implementa WebXR**: las experiencias AR inmersivas solo corren en
  Chrome completo con ARCore.
- La captura de la cámara trasera **dentro del WebView** abre el
  dispositivo pero no entrega frames en este Samsung (~1 s y Chromium
  hace fallback a la frontal; la web exige `environment` y queda en
  "sin cámara"). En Chrome de la misma tablet la misma web corre con
  la cámara viva. El fallo es del motor del WebView; ningún flag de la
  app lo arregla.
- La palanca restante para AR in-app vive en el código de la web
  (constraints de `getUserMedia` / selección por `enumerateDevices`),
  no en el cliente.

## Mecanismo verificado (tres piezas)

### 1. Abrir la web en Chrome (con cámara viva)

```powershell
adb -s <ip>:5555 shell "am start -a android.intent.action.VIEW -d '<url-de-la-experiencia>' com.android.chrome"
```

- Chrome recuerda su propio permiso de cámara por sitio: tras la
  primera aceptación ya no vuelve a preguntar.
- Verificación de cámara viva: dos `screencap` con 3 s de separación
  deben dar md5 DISTINTO (imagen en movimiento) y ~2.5 MB por frame;
  congelado/vacío da md5 igual y ~290 KB.

### 2. Pantalla completa

Android no admite abrir Chrome con una flag de kiosk (`--kiosk` es de
escritorio). La pantalla completa la pide **la propia web** en el
gesto de inicio (el botón "empezar" de la experiencia); una línea en
el Worker:

```js
document.documentElement.requestFullscreen();
```

Chrome entra en inmersivo (barra y omnibox fuera) y al `Esc`/atrás
restaura. `requestFullscreen` requiere gesto del usuario: llamarlo
dentro del handler del botón, no al cargar la página.

### 3. Salir de la web

El mecanismo **jamás lanza ni trae al frente al cliente**: el Custom
Tab corre por encima y el kiosk queda debajo, vivo (heartbeats y WS
corriendo; `device_state` es independiente de la conectividad, el
servidor nunca da el dispositivo por caído). Al cerrar la web (gesto
atrás de la tablet o `Esc` del fullscreen), simplemente reaparece el
kiosk que ya estaba debajo: no hay comando de retorno.

Cambio de medio desde el servidor: la siguiente asignación se aplica
en el kiosk, que espera debajo; recommendable notificar al mediador
antes de cambiar de contenido con la web abierta.

## Mecanismo implementado en el cliente (2026-11-18, rev. mismo día)

La superficie de reproducción de un medio `url` se elige **al
asignar** (nunca al registrar el medio, nunca en el `.env`): el
PUT de asignación viaja con `display_mode` (`webview` |
`external`, default `webview`), persiste en la asignación y llega
al cliente en el payload del WS (`assignment.display_mode`).

- `external` en Android/iOS: `showUrl` abre un Custom Tab de Chrome
  fullscreen por encima del kiosk (`flutter_custom_tabs`,
  `urlBarHidingEnabled`) y arranca el servicio en primer plano
  (`KeepAliveService`) para que el congelador de Android no detenga
  heartbeats ni WS mientras la web está en pantalla.
- Todo cambio de medio (y el flip `webview`↔`external`, que reasigna
  con revisión nueva) cierra la web: `closeCustomTabs()` +
  `stopKeepAlive()`.
- `webview`: `KioskWebView` in-app + `UrlLoadGate` como siempre.
- En plataformas sin WebView in-app ambos modos caen al navegador
  del sistema (la decisión no cambia nada ahí).
- La pantalla completa inmersiva la pide la propia web en su botón
  de inicio (`document.documentElement.requestFullscreen()` en el
  Worker): una línea, requiere gesto del usuario.

## Prueba ejecutada (2026-11-18)

| Paso | Comando | Resultado |
|------|---------|-----------|
| Abrir Chrome con la web | `am start -a VIEW -d <url> com.android.chrome` | Web arriba; foco `ChromeTabbedActivity` |
| Cámara viva | 2× `screencap` (3 s) | md5 distintos, 2.6 MB/frame: EN VIVO |
| Volver al kiosk | `am start -n com.cauce.cauce_stream/.MainActivity` | Foco de vuelta en el kiosk; heartbeat sin interrupciones |
