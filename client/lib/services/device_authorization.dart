/// Estado de autorización del dispositivo frente al servidor Cauce.
///
/// Es un estado de REGISTRO, independiente de la conectividad: no
/// sustituye ni se mezcla con `online`/`offline` (conectividad, que
/// deriva el servidor de los heartbeats), ni con `active`/`idle`
/// (estado operativo que reporta el cliente).
///
/// Fuente única: las respuestas del heartbeat. Nada más puede cambiar
/// este estado: [CauceHeartbeatService] traduce cada respuesta del
/// servidor (`200`, `202`, `404`, `401`, `422` o fallo de red) a un
/// veredicto aquí. Solo `registered` autoriza a abrir el canal
/// WebSocket de playback: cualquier otro estado mantiene el canal
/// cerrado, con los reintentos cancelados, hasta que el heartbeat
/// confirme el registro.
library;

/// Veredicto del servidor sobre el registro de este dispositivo.
enum DeviceAuthorizationStatus {
  /// Todavía no hay confirmación de registro: arranque inicial o
  /// respuesta 404 (desconocido y no registrado).
  unknown,

  /// Respuesta 202: detectado por la autoconfiguración del servidor,
  /// pendiente de que un administrador lo registre.
  pending,

  /// Respuesta 200: registrado y autorizado a abrir el canal WS.
  registered,

  /// No fue posible consultar al servidor (red caída, timeout, 5xx):
  /// NO es un rechazo de registro. Mantiene el canal bloqueado hasta
  /// recuperar la confirmación.
  unreachable,

  /// Respuesta 422 (payload inválido) o 401 (clave de dispositivo
  /// rechazada): configuración incompatible, no recuperable por
  /// reintentos.
  invalid,
}

/// Estado de autorización compartido entre el heartbeat (que lo
/// escribe) y el canal de playback (que lo lee como puerta de
/// conexión). Puro y sin dependencias: la única mutación es [update],
/// que notifica exclusivamente en las transiciones reales.
class DeviceAuthorization {
  DeviceAuthorizationStatus _status = DeviceAuthorizationStatus.unknown;

  final List<void Function(DeviceAuthorizationStatus)> _listeners = [];

  DeviceAuthorizationStatus get status => _status;

  /// Único estado que autoriza conexiones WebSocket.
  bool get isAuthorized => _status == DeviceAuthorizationStatus.registered;

  void addListener(void Function(DeviceAuthorizationStatus) listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function(DeviceAuthorizationStatus) listener) {
    _listeners.remove(listener);
  }

  /// Actualiza el veredicto y notifica a los oyentes solo si el
  /// estado realmente cambia (un 200 tras otro 200 no dispara nada).
  /// Devuelve true cuando hubo transición.
  bool update(DeviceAuthorizationStatus next) {
    if (next == _status) return false;
    _status = next;
    for (final listener in List.of(_listeners)) {
      listener(next);
    }
    return true;
  }
}
