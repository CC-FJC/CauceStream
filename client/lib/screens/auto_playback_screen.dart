import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_custom_tabs/flutter_custom_tabs.dart' as custom_tabs;
import 'package:pdfx/pdfx.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../models/playback_message.dart';
import '../services/playback_socket_service.dart';
import '../widgets/dvd_screensaver.dart';
import '../widgets/kiosk_web_view.dart';
import '../widgets/river_loading_indicator.dart';

/// Vista inyectable para un medio `url` (pruebas). Firma idéntica a la
/// que usa la pantalla para montar el [KioskWebView] real.
typedef UrlViewBuilder = Widget Function(
  Uri url,
  void Function(bool displayed, String? error) onLoadResult,
);

class AutoPlaybackScreen extends StatefulWidget {
  final PlaybackSocketService? playbackService;
  final bool retryOnError;

  /// En producción es null: el medio `url` se monta con [KioskWebView]
  /// (WebView in-app) o, en plataformas sin WebView in-app, se abre con
  /// el navegador del sistema. En pruebas permite sustituir la vista.
  final UrlViewBuilder? urlViewBuilder;

  const AutoPlaybackScreen({
    super.key,
    this.playbackService,
    this.retryOnError = true,
    this.urlViewBuilder,
  });

  @override
  State<AutoPlaybackScreen> createState() => _AutoPlaybackScreenState();
}

/// Qué hay en pantalla ahora mismo.
enum _DisplayMode {
  /// Screensaver clásico (logo CAUCE rebotando en los bordes): comportamiento
  /// por defecto cuando el servidor no tiene contenido asignado.
  screensaver,

  /// Video asignado por Cauce reproduciéndose en bucle.
  assignedVideo,

  /// Imagen asignada por Cauce en pantalla.
  assignedImage,

  /// Medio `url` asignado por Cauce: WebView in-app a pantalla completa
  /// (o navegador externo en plataformas sin WebView in-app).
  assignedUrl,

  /// Documento PDF asignado por Cauce (render nativo con pdfx).
  assignedPdf,
}

class _AutoPlaybackScreenState extends State<AutoPlaybackScreen>
    with WidgetsBindingObserver
    implements PlaybackApplier {
  static const MethodChannel _deviceChannel =
      MethodChannel('cauce_stream/device');
  VideoPlayerController? _controller;
  bool _initialized = false;
  String? _statusMessage;
  int _initRetryCount = 0;
  bool _disposed = false;
  bool _recovering = false;
  Timer? _watchdogTimer;
  Duration _lastWatchdogPosition = Duration.zero;

  _DisplayMode _mode = _DisplayMode.screensaver;

  /// Generación de visualización: cada orden del servicio la incrementa;
  /// los bucles y awaits pendientes de una generación anterior se
  /// abortan. Evita que dos órdenes controlen el reproductor a la vez.
  int _displayGen = 0;

  File? _assignedVideoFile;
  File? _assignedImageFile;
  Uri? _assignedUrl;
  File? _assignedPdfFile;
  PdfController? _pdfController;
  String? _assignedMediaName;

  /// Medio `url` que ya está abierto en un Custom Tab fullscreen (webAR
  /// con cámara por Chrome externo): la pantalla muestra solo la
  /// dirección con el botón "Volver a la WEB", nunca monta el WebView
  /// in-app para el mismo URL. Si el mediador cierra la ventana con
  /// la X, la asignación sigue vigente y la tarjeta queda en pantalla.
  bool _assignedUrlExternal = false;

  /// La web externa se cerró por orden del servidor pero el cierre
  /// pudo ser ignorado por un Chrome congelado en espera: un solo
  /// reintento corre en el próximo resumed (pantalla ya despierta) y
  /// libera la marca. Ver [_closeExternalUrlIfOpen].
  bool _externalCloseRetryOnResume = false;

  /// Completers de carga pendientes por URL asignada (modo `url` con
  /// WebView in-app): el `showUrl` espera a que la web confirme en
  /// pantalla antes de devolver true.
  final Map<String, Completer<bool>> _urlLoadCompleters = {};

  /// WebView in-app solo existe en Android/iOS (webview_flutter). En el
  /// resto de plataformas el medio `url` se abre con el navegador del
  /// sistema vía url_launcher.
  bool get _inAppWebViewSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Al volver el kiosk a primer plano la web externa ya no está: el
    // mediador cerró el Custom Tab (gesto atrás). Se detiene la vida
    // artificial y queda la dirección debajo; la próxima asignación
    // reabre la web con su nueva generación.
    // Sin asignación del servidor la pantalla arranca directamente en
    // screensaver; el servicio global (WS) conduce mediante este applier.
    widget.playbackService?.attach(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Cierre diferido de la web externa: en espera el Chrome
    // congelado puede haber ignorado el close original; ahora que
    // el sistema lo despertó, reintenta una única vez.
    if (_externalCloseRetryOnResume) {
      unawaited(_didResumeExternalCloseRetry());
    }
    if (_mode == _DisplayMode.assignedUrl && _assignedUrlExternal) {
      // El mediador volvió al kiosk con el medio externo asignado (lo
      // más común: cerró la web con la X del Custom Tab o el gesto
      // atrás, sin orden nueva del servidor). La asignación sigue
      // vigente: la tarjeta queda en pantalla con "Volver a la WEB".
      // Solo se apaga la vida artificial: con la web cerrada nada
      // corre fuera de la app. No se toca la ventana de Chrome (si
      // quedó viva tras un Home, el mediador puede volver a ella
      // desde recientes con la sesión intacta, y "Volver a la WEB"
      // vuelve a levantar el servicio). No se reabre sola (el gesto
      // fue deliberado) y jamás se monta el WebView in-app para un
      // medio marcado externo.
      unawaited(_stopForegroundKeepAlive());
    }
  }

  /// Detiene el servicio de primer plano: el kiosk está en pantalla,
  /// nada corriendo fuera de la app necesita vida artificial.
  Future<void> _stopForegroundKeepAlive() async {
    try {
      await _deviceChannel.invokeMethod('stopKeepAlive');
    } catch (e) {
      debugPrint('[CAUCE] No se pudo detener el keep-alive: $e');
    }
  }

  /// Cierra la web externa (Custom Tab) si hay una abierta y detiene
  /// el servicio en primer plano que mantuvo vivo al cliente en
  /// background. Lo llama todo cambio de medio: cambiar de experiencia
  /// cierra la ventana del navegador — el servidor nunca pierde el
  /// control del dispositivo.
  Future<void> _closeExternalUrlIfOpen() async {
    if (!_assignedUrlExternal) return;
    _assignedUrlExternal = false;
    // El cierre puede ser ignorado por un Chrome congelado (el
    // freezer suspende su proceso en espera): se reintenta al volver a
    // resumed, cuando el sistema ya lo descongeló.
    _externalCloseRetryOnResume = true;
    try {
      await _deviceChannel.invokeMethod('stopKeepAlive');
      await custom_tabs.closeCustomTabs();
    } catch (e) {
      debugPrint('[CAUCE] No se pudo cerrar la web externa: $e');
    }
  }

  /// Garantiza que sea el kiosk lo que está encima del task aunque la
  /// Custom Tab zombi de una experiencia anterior siga viva: la trae
  /// al frente (REORDER_TO_FRONT). El cierre de la zombie queda
  /// cubierto por el reintento en [_didResumeExternalCloseRetry].
  Future<void> _assertKioskSurface() async {
    try {
      await _deviceChannel.invokeMethod('reorderKioskToFront');
    } catch (e) {
      debugPrint('[CAUCE] No se pudo traer el kiosk al frente: $e');
    }
  }

  /// Reintento único del cierre de la web externa: corre en el
  /// primer resumed posterior (p. ej. al encender la pantalla) — el
  /// Chrome ya descongelado procesa el close que en espera ignoró.
  Future<void> _didResumeExternalCloseRetry() async {
    _externalCloseRetryOnResume = false;
    try {
      await custom_tabs.closeCustomTabs();
      debugPrint('[CAUCE] Reintento de cierre de web externa aplicado');
    } catch (e) {
      debugPrint('[CAUCE] Falló el reintento de cierre de web externa: $e');
    }
  }

  /// Abre (o reabre) la web externa del medio asignado: Custom Tab
  /// fullscreen de Chrome por encima del kiosk. Lo llama la orden de
  /// reproducción del servidor y el botón "Volver a la WEB" cuando el
  /// mediador cerró la ventana con la X; la asignación no cambia.
  Future<bool> _openExternalUrl(Uri url) async {
    try {
      // Sin el servicio en primer plano Android congela al cliente en
      // background mientras el Custom Tab está encima: timers y red se
      // detienen, el heartbeat da "unreachable", el propio cliente
      // revoca el WS y el servidor pierde el control hasta cerrar la
      // web.
      await _deviceChannel.invokeMethod('startKeepAlive');
      await custom_tabs.launchUrl(
        url,
        prefersDeepLink: false,
        customTabsOptions: const custom_tabs.CustomTabsOptions(
          urlBarHidingEnabled: true,
          showTitle: false,
        ),
      );
      return true;
    } catch (e) {
      debugPrint('[CAUCE] No se pudo abrir el Custom Tab fullscreen: $e');
      return false;
    }
  }

  // --- PlaybackApplier (órdenes del WS de Cauce) ---

  @override
  Future<bool> showImage(File file, AssignmentMedia media) async {
    final gen = ++_displayGen;
    await _closeExternalUrlIfOpen();
    // Si una Custom Tab zombie quedó viva (cierre ignorado), el
    // kiosk con la imagen debe ser lo que se vea encima.
    unawaited(_assertKioskSurface());
    try {
      // Confirma que la imagen decodifica ANTES de quitar el medio
      // actual de pantalla.
      if (!mounted || _disposed) return false;
      await precacheImage(FileImage(File(file.path)), context);
      if (_disposed || gen != _displayGen) return false;
      _stopVideo();
      _failPendingUrlLoads();
      _disposePdf();
      setState(() {
        _mode = _DisplayMode.assignedImage;
        _assignedImageFile = file;
        _assignedMediaName = media.name;
        _initialized = false;
      });
      debugPrint('[CAUCE] Imagen asignada en pantalla: ${media.name}');
      return true;
    } catch (e) {
      debugPrint('[CAUCE] No se pudo mostrar la imagen: $e');
      return false;
    }
  }

  @override
  Future<bool> showVideo(File file, AssignmentMedia media) async {
    final gen = ++_displayGen;
    await _closeExternalUrlIfOpen();
    // Custom Tab zombie: el video del kiosk manda en superficie.
    unawaited(_assertKioskSurface());
    try {
      final ctrl = VideoPlayerController.file(file);
      await ctrl.initialize();
      await ctrl.setLooping(true);
      await ctrl.setVolume(1.0);
      await ctrl.play();
      if (_disposed || gen != _displayGen) {
        await ctrl.dispose();
        return false;
      }
      _failPendingUrlLoads();
      _disposePdf();
      _adoptVideoController(ctrl);
      setState(() {
        _mode = _DisplayMode.assignedVideo;
        _assignedVideoFile = file;
        _assignedMediaName = media.name;
        _initialized = true;
      });
      debugPrint('[CAUCE] Video asignado reproduciéndose: ${media.name}');
      return true;
    } catch (e) {
      debugPrint('[CAUCE] No se pudo reproducir el video asignado: $e');
      return false;
    }
  }

  @override
  Future<bool> showUrl(
    Uri url,
    AssignmentMedia media,
    UrlDisplayMode displayMode,
  ) async {
    final gen = ++_displayGen;
    if (_disposed || gen != _displayGen) return false;
    _stopVideo();
    await _closeExternalUrlIfOpen();
    if (_disposed || gen != _displayGen) return false;
    // El modo webview corre en nuestra activity: una Custom Tab
    // zombie no puede taparla. (La rama external de abajo abre una
    // pestaña nueva que queda por encima de este reorden, que es
    // exactamente lo que debe verse.)
    unawaited(_assertKioskSurface());
    // Asignado como 'external': la web (p. ej. webAR con cámara que
    // el WebView in-app no captura en este dispositivo) abre en una
    // pestaña fullscreen de Chrome por encima del kiosk. El cliente
    // queda debajo, vivo y latiendo — NUNCA se trae al frente. Solo
    // Android/iOS: el resto de plataformas cae al navegador del
    // sistema igual (misma pieza de abajo).
    if (displayMode == UrlDisplayMode.external && _inAppWebViewSupported) {
      final opened = await _openExternalUrl(url);
      if (_disposed || gen != _displayGen) return false;
      if (!opened) return false;
      _failPendingUrlLoads();
      setState(() {
        _mode = _DisplayMode.assignedUrl;
        _assignedUrl = url;
        _assignedMediaName = media.name;
        _assignedUrlExternal = true;
        _initialized = false;
      });
      debugPrint('[CAUCE] Medio url abierto en Custom Tab fullscreen: $url');
      return true;
    }

    if (!_inAppWebViewSupported) {
      // Plataformas sin WebView in-app (Windows/Linux/web): la URL se
      // abre con el navegador del sistema como aplicación externa
      // (estándar de la plataforma); aquí solo se muestra la dirección.
      try {
        final launched = await launchUrl(
          url,
          mode: LaunchMode.externalApplication,
        );
        if (!launched) {
          debugPrint('[CAUCE] No se pudo abrir la URL externa: $url');
          return false;
        }
        if (_disposed || gen != _displayGen) return false;
        setState(() {
          _mode = _DisplayMode.assignedUrl;
          _assignedUrl = url;
          _assignedMediaName = media.name;
          _initialized = false;
        });
        debugPrint('[CAUCE] Medio url abierto en navegador externo: $url');
        return true;
      } catch (e) {
        debugPrint('[CAUCE] Error abriendo la URL externa: $e');
        return false;
      }
    }

    // WebView in-app (Android/iOS): true SOLO cuando la página terminó
    // de cargar en pantalla (UrlLoadGate dentro de KioskWebView).
    final completer = Completer<bool>();
    _urlLoadCompleters[url.toString()] = completer;
    setState(() {
      _mode = _DisplayMode.assignedUrl;
      _assignedUrl = url;
      _assignedMediaName = media.name;
      _initialized = false;
    });
    final displayed = await completer.future;
    _urlLoadCompleters.remove(url.toString());
    if (_disposed || gen != _displayGen) return false;
    debugPrint(displayed
        ? '[CAUCE] Medio url en pantalla: $url'
        : '[CAUCE] Medio url NO se pudo mostrar: $url');
    return displayed;
  }

  /// PDF asignado: se descarga como image/video y se renderiza con
  /// pdfx. true SOLO cuando el documento terminó de cargar en pantalla.
  @override
  Future<bool> showPdf(File file, AssignmentMedia media) async {
    final gen = ++_displayGen;
    await _closeExternalUrlIfOpen();
    if (_disposed || gen != _displayGen) return false;
    // Custom Tab zombie: el PDF del kiosk manda en superficie.
    unawaited(_assertKioskSurface());
    _stopVideo();
    _failPendingUrlLoads();
    _disposePdf();
    try {
      final document = await PdfDocument.openFile(file.path);
      if (_disposed || gen != _displayGen) {
        await document.close();
        return false;
      }
      final controller = PdfController(document: Future.value(document));
      _pdfController = controller;
      setState(() {
        _mode = _DisplayMode.assignedPdf;
        _assignedPdfFile = file;
        _assignedMediaName = media.name;
        _initialized = false;
      });
      final loaded = await _waitPdfLoaded(controller);
      if (_disposed || gen != _displayGen) return false;
      debugPrint(
        loaded
            ? '[CAUCE] PDF en pantalla: ${file.path}'
            : '[CAUCE] PDF no terminó de cargar: ${file.path}',
      );
      return loaded;
    } catch (e) {
      debugPrint('[CAUCE] No se pudo abrir el PDF ${file.path}: $e');
      return false;
    }
  }

  /// Espera a que el PdfView termine de cargar (o falle) con timeout.
  Future<bool> _waitPdfLoaded(PdfController controller) async {
    final state = controller.loadingState;
    if (state.value == PdfLoadingState.success) return true;
    if (state.value == PdfLoadingState.error) return false;
    final completer = Completer<bool>();
    void listener() {
      final s = state.value;
      if (s == PdfLoadingState.success || s == PdfLoadingState.error) {
        if (!completer.isCompleted) {
          completer.complete(s == PdfLoadingState.success);
        }
      }
    }

    state.addListener(listener);
    try {
      return await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => false,
      );
    } finally {
      state.removeListener(listener);
    }
  }

  void _disposePdf() {
    _pdfController?.dispose();
    _pdfController = null;
    _assignedPdfFile = null;
  }

  @override
  Future<bool> showDefault() async {
    if (_disposed) return false;
    await _closeExternalUrlIfOpen();
    // Custom Tab zombie: el screensaver del kiosk manda en superficie.
    unawaited(_assertKioskSurface());
    // Ya en el modo por defecto (screensaver con el logo rebotando).
    if (_mode == _DisplayMode.screensaver) return true;
    // Nueva generación: invalida cargas pendientes de órdenes viejas.
    ++_displayGen;
    _stopVideo();
    _failPendingUrlLoads();
    _disposePdf();
    setState(() {
      _mode = _DisplayMode.screensaver;
      _initialized = false;
      _statusMessage = null;
    });
    return true;
  }

  /// Inicializa y reproduce [file] en bucle, con reintentos. Retorna
  /// cuando la reproducción está activa (o agotadas las opciones sin
  /// retryOnError). Si la generación cambia, el controlador nuevo se
  /// descarta y el de pantalla queda como esté.
  Future<void> _initVideoController(File file, int gen) async {
    while (!_disposed) {
      if (gen != _displayGen) return;
      try {
        _setStatus('Preparando video...');
        final ctrl = VideoPlayerController.file(file);
        await ctrl.initialize();
        await ctrl.setLooping(true);
        await ctrl.setVolume(1.0);

        if (_disposed || gen != _displayGen) {
          await ctrl.dispose();
          return;
        }

        _adoptVideoController(ctrl);
        setState(() => _initialized = true);
        await ctrl.play();
        _startWatchdog();
        return;
      } catch (e) {
        debugPrint('[CAUCE] Error al inicializar el reproductor: $e');
        _initRetryCount++;
        _setStatus('Error al reproducir. Reintentando...');
        if (!widget.retryOnError) return;
        await _waitSeconds(math.min(2 + _initRetryCount * 2, 30));
      }
    }
  }

  /// Sustituye el controlador vigente por [ctrl] (listener + dispose
  /// del anterior). El cambio atómico evita que una orden fallida deje
  /// la pantalla sin reproductor.
  void _adoptVideoController(VideoPlayerController ctrl) {
    _controller?.removeListener(_onControllerUpdate);
    _controller?.dispose();
    _controller = ctrl;
    ctrl.addListener(_onControllerUpdate);
  }

  void _onControllerUpdate() {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized) return;

    if (ctrl.value.hasError) {
      debugPrint(
          '[CAUCE] Error en reproducción: ${ctrl.value.errorDescription}');
      _scheduleRecovery();
      return;
    }

    // Respaldo por si setLooping no funcionara en algún dispositivo.
    if (!ctrl.value.isPlaying &&
        ctrl.value.position >= ctrl.value.duration) {
      ctrl.seekTo(Duration.zero);
      ctrl.play();
    }
  }

  void _scheduleRecovery() {
    if (_recovering || _disposed) return;
    _recovering = true;
    _stopWatchdog();
    _setStatus('Reconectando video...');
    Future.microtask(() async {
      try {
        if (_disposed) return;
        final gen = _displayGen;
        _initRetryCount = 0;
        if (_mode == _DisplayMode.assignedVideo && _assignedVideoFile != null) {
          // El archivo ya está en caché: reintentar solo el reproductor.
          await _initVideoController(_assignedVideoFile!, gen);
        }
        // Screensaver, imágenes y url no tienen reproductor que recuperar.
      } finally {
        _recovering = false;
      }
    });
  }

  void _startWatchdog() {
    _stopWatchdog();
    _lastWatchdogPosition = _controller?.value.position ?? Duration.zero;
    _watchdogTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_disposed) return;
      final ctrl = _controller;
      if (ctrl == null || !ctrl.value.isInitialized) return;

      if (ctrl.value.hasError) {
        _scheduleRecovery();
        return;
      }

      if (ctrl.value.isPlaying &&
          !ctrl.value.isBuffering &&
          ctrl.value.position == _lastWatchdogPosition) {
        debugPrint('[CAUCE] Reproducción estancada. Reconectando...');
        _scheduleRecovery();
        return;
      }

      _lastWatchdogPosition = ctrl.value.position;
    });
  }

  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  /// Retira el video actual de pantalla y libera su controlador.
  void _stopVideo() {
    _stopWatchdog();
    _controller?.removeListener(_onControllerUpdate);
    _controller?.dispose();
    _controller = null;
    _initialized = false;
  }

  void _setStatus(String message) {
    if (mounted && !_disposed) {
      setState(() => _statusMessage = message);
    }
  }

  Future<void> _waitSeconds(int seconds) async {
    await Future.delayed(Duration(seconds: seconds));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.playbackService?.detach(this);
    _disposed = true;
    _failPendingUrlLoads();
    _disposePdf();
    _stopWatchdog();
    _controller?.removeListener(_onControllerUpdate);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: switch (_mode) {
          _DisplayMode.screensaver => const DvdScreensaver(),
          _DisplayMode.assignedImage => _buildAssignedImage(),
          _DisplayMode.assignedUrl => _buildAssignedUrl(),
          _DisplayMode.assignedPdf => _buildAssignedPdf(),
          _DisplayMode.assignedVideo => _initialized && _controller != null
              ? _buildPlayer()
              : _buildLoading(),
        },
      ),
    );
  }

  Widget _buildPlayer() {
    return IgnorePointer(
      child: SizedBox.expand(
        child: FittedBox(
          // contain: conserva la relación de aspecto real del video
          // (incluida la rotación de metadatos ya resuelta por el
          // controlador) sin recortar ni deformar; el hueco restante
          // queda sobre el fondo negro del Scaffold.
          fit: BoxFit.contain,
          child: SizedBox(
            width: _controller!.value.size.width,
            height: _controller!.value.size.height,
            child: VideoPlayer(_controller!),
          ),
        ),
      ),
    );
  }

  Widget _buildAssignedImage() {
    final file = _assignedImageFile;
    if (file == null) return _buildLoading();
    return IgnorePointer(
      child: SizedBox.expand(
        child: Image.file(
          file,
          // contain: la imagen completa, centrada y sin recortes ni
          // deformaciones para cualquier relación de aspecto.
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) {
            debugPrint('[CAUCE] Error decodificando la imagen: $error');
            return const SizedBox.expand();
          },
        ),
      ),
    );
  }

  /// Medio `url`: WebView in-app a pantalla completa cuando la plataforma
  /// lo soporta (Android/iOS, p. ej. el iFFALCON G09 con Android 12);
  /// en el resto la página ya se abrió en el navegador del sistema y aquí
  /// solo se muestra la dirección.
  Widget _buildAssignedUrl() {
    final url = _assignedUrl;
    if (url == null) return _buildLoading();
    final customBuilder = widget.urlViewBuilder;
    final Widget child;
    if (customBuilder != null) {
      child = KeyedSubtree(
        key: ValueKey('url-view:$url'),
        child: customBuilder(url, (ok, _) => _completeUrlLoad(url, ok)),
      );
    } else if (_assignedUrlExternal) {
      // El medio es 'external': la web corre en el Custom Tab encima
      // del kiosk, o el mediador la cerró con la X y la tarjeta le
      // deja reabrirla. Nunca se monta el WebView in-app (la
      // asignación decidió que este URL no va ahí).
      child = _buildExternalUrlCard(url);
    } else if (_inAppWebViewSupported) {
      child = KioskWebView(
        key: ValueKey('kiosk-web-view:$url'),
        initialUrl: url,
        onLoadResult: (ok, _) => _completeUrlLoad(url, ok),
      );
    } else {
      child = _buildAssignedUrlText(url);
    }
    return SizedBox.expand(child: child);
  }

  /// Medio `pdf`: render nativo a pantalla completa (pdfx). El D-pad
  /// del control navega el PageView; sin interacción queda en la página 1.
  Widget _buildAssignedPdf() {
    final controller = _pdfController;
    if (controller == null) return _buildLoading();
    return IgnorePointer(
      child: ColoredBox(
        color: Colors.black,
        child: PdfView(
          key: ValueKey('pdf-view:${_assignedPdfFile?.path}'),
          controller: controller,
        ),
      ),
    );
  }

  void _completeUrlLoad(Uri url, bool displayed) {
    final completer = _urlLoadCompleters[url.toString()];
    if (completer != null && !completer.isCompleted) {
      completer.complete(displayed);
    }
  }

  /// Una orden nueva (imagen/video/modo por defecto) deja inválidas las
  /// cargas de URL pendientes: sus `showUrl` deben resolver false.
  void _failPendingUrlLoads() {
    for (final completer in _urlLoadCompleters.values) {
      if (!completer.isCompleted) completer.complete(false);
    }
    _urlLoadCompleters.clear();
  }

  Widget _buildAssignedUrlText(Uri url) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _assignedMediaName ?? 'Medio asignado',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              letterSpacing: 1,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Text(
            url.toString(),
            style: const TextStyle(color: Colors.white70, fontSize: 22),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  /// Tarjeta del medio `url` externo mientras la web no está en
  /// pantalla: nombre, dirección y el botón que la reabre. La
  /// asignación vigente no cambia: reabrir no es reasignar.
  Widget _buildExternalUrlCard(Uri url) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(
              Icons.open_in_new,
              size: 44,
              color: Color(0xFF1565C0),
            ),
            const SizedBox(height: 16),
            Text(
              _assignedMediaName ?? 'Experiencia web',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              url.toString(),
              style: const TextStyle(color: Colors.white70, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () => _reopenExternalUrl(url),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: const StadiumBorder(),
              ),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Volver a la WEB'),
            ),
          ],
        ),
      ),
    );
  }

  /// El mediador pulsó "Volver a la WEB": relanza el Custom Tab (la
  /// web vuelve a cubrir el kiosk). La asignación vigente no cambia:
  /// reabrir no es reasignar, así que no hay órdenes al servidor.
  Future<void> _reopenExternalUrl(Uri url) async {
    final opened = await _openExternalUrl(url);
    debugPrint('[CAUCE] Web externa ${opened ? 'reabierta' : 'no reabierta'} '
        'tras la X: $url');
  }

  Widget _buildLoading() {
    final size = MediaQuery.of(context).size;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(
            color: Color(0xFF1565C0),
          ),
          SizedBox(height: size.height * 0.04),
          Text(
            _statusMessage ?? 'Cargando video...',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 20,
              letterSpacing: 1,
            ),
          ),
          SizedBox(height: size.height * 0.04),
          const RiverLoadingIndicator(
            width: 240,
            height: 12,
          ),
        ],
      ),
    );
  }
}
