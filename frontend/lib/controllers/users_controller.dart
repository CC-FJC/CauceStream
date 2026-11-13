/// Controlador de la administracion de personal: usuarios y roles
/// (unica fuente de verdad compartida por la pestana Usuarios y la
/// pantalla de Roles, que usa los contadores por rol).
///
/// Toda la informacion requiere `users.view` (solo ADMINISTRADOR):
/// para un mediador el servidor responde 403 y el estado queda en
/// [forbidden], que la UI presenta como aviso en lugar de lista. El
/// backend sigue siendo la autoridad; esta pantalla solo consulta.
///
/// Tras cada mutacion se recarga del servidor: nunca estado
/// optimista.
library;

import 'package:flutter/foundation.dart';

import '../core/network/api_exception.dart';
import '../models/role.dart';
import '../models/user.dart';
import '../services/role_service.dart';
import '../services/user_service.dart';

enum UsersLoadStatus { idle, loading, ready, error }

class UsersController extends ChangeNotifier {
  UsersController({
    required UserService service,
    required RoleService roleService,
  }) : _service = service,
       _roleService = roleService;

  final UserService _service;
  final RoleService _roleService;

  /// Servicio de roles compartido (pantalla de Roles y Permisos).
  RoleService get roleService => _roleService;

  List<User> _users = const [];
  List<User> get users => _users;

  /// Roles del dominio con sus permisos vigentes (GET /api/roles).
  List<Role> _roles = const [];
  List<Role> get roles => _roles;

  UsersLoadStatus _status = UsersLoadStatus.idle;
  UsersLoadStatus get status => _status;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  /// true cuando el backend rechazo la consulta por permisos (403):
  /// la sesion no es administradora. La UI muestra un aviso, nunca
  /// una lista vacia enganosa.
  bool _forbidden = false;
  bool get forbidden => _forbidden;

  bool get isRefreshing => _fetching;

  bool _fetching = false;

  /// Carga la primera vez que la pestana se construye.
  Future<void> ensureLoaded() async {
    if (_fetching || _status != UsersLoadStatus.idle) return;
    await refresh();
  }

  /// Recarga usuarios y roles contra la API. Nunca lanza: los
  /// fallos se exponen en [errorMessage].
  Future<void> refresh() async {
    if (_fetching) return;
    _fetching = true;
    if (_users.isEmpty) {
      _status = UsersLoadStatus.loading;
      notifyListeners();
    }
    try {
      _users = await _service.listUsers();
      _errorMessage = null;
      _forbidden = false;
      _status = UsersLoadStatus.ready;
      // Roles de apoyo (chips de filtro, contadores, formulario):
      // un fallo puntual no rompe la lista de usuarios; el proximo
      // sondeo reintenta.
      try {
        _roles = await _roleService.listRoles();
      } on ApiException {
        _roles = const [];
      }
    } on ApiException catch (e) {
      _errorMessage = e.message;
      _forbidden = e.isAuthError;
      // Sin datos previos el fallo es pantalla de aviso; con datos
      // previos se conserva la ultima lista conocida.
      _status = _users.isEmpty
          ? UsersLoadStatus.error
          : UsersLoadStatus.ready;
    } finally {
      _fetching = false;
      notifyListeners();
    }
  }

  /// Usuarios activos de un rol (los desactivados no cuentan como
  /// personal operativo de sala).
  int roleCount(String roleName) =>
      _users.where((u) => u.role.name == roleName && u.isActive).length;

  // --- Mutaciones: null en exito, mensaje de error en fallo ---

  Future<String?> createUser({
    required String name,
    required String email,
    required String pin,
    required String role,
  }) async {
    try {
      await _service.createUser(
        name: name,
        email: email,
        pin: pin,
        role: role,
      );
    } on ApiException catch (e) {
      return e.message;
    }
    await refresh();
    return null;
  }

  Future<String?> updateUser(
    User user, {
    String? name,
    String? email,
    String? pin,
    String? role,
  }) async {
    try {
      await _service.updateUser(
        user.id,
        name: name,
        email: email,
        pin: pin,
        role: role,
      );
    } on ApiException catch (e) {
      return e.message;
    }
    await refresh();
    return null;
  }

  /// Activa o desactiva una cuenta (eliminacion logica). Devuelve
  /// null en exito o el motivo del rechazo (p. ej. un usuario no
  /// puede desactivarse a si mismo: el backend lo impide).
  Future<String?> setActive(User user, {required bool active}) async {
    try {
      if (active) {
        await _service.activateUser(user.id);
      } else {
        await _service.deactivateUser(user.id);
      }
    } on ApiException catch (e) {
      return e.message;
    }
    await refresh();
    return null;
  }
}
