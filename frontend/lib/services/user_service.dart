/// Servicio de usuarios contra el backend Cauce.
///
/// Contratos reales usados por el perfil y la administracion de
/// usuarios:
/// - GET  /api/users              (permiso `users.view`)
/// - GET  /api/users/{id}        (permiso `users.view`)
/// - POST /api/users              (permiso de gestion del rol objetivo)
/// - PATCH /api/users/{id}        (permiso de gestion del rol objetivo)
/// - POST /api/users/{id}/activate   (permiso de gestion del rol)
/// - POST /api/users/{id}/deactivate (permiso de gestion del rol)
///
/// El backend tambien ofrece DELETE /api/users/{id} (borrado fisico),
/// pero la app usa deliberadamente la eliminacion logica:
/// desactivacion (`is_active = false`) reactivable con /activate.
/// [UserService] no expone el borrado fisico por diseno.
library;

import '../core/config/api_config.dart';
import '../core/network/api_client.dart';
import '../models/user.dart';

class UserService {
  UserService({required ApiClient client}) : _client = client;

  final ApiClient _client;

  /// Lista el personal registrado (admins y mediadores). Requiere
  /// `users.view` (solo ADMINISTRADOR): con un token de mediador el
  /// servidor responde 403.
  Future<List<User>> listUsers() async {
    final data = await _client.get(ApiConfig.usersPath);
    return (data as List<dynamic>)
        .map((item) => User.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// Obtiene un usuario por id. Con un token de mediador el servidor
  /// responde 403 (permiso `users.view` insuficiente).
  Future<User> getUser(int id) async {
    final data = await _client.get('${ApiConfig.usersPath}/$id');
    return User.fromJson(data as Map<String, dynamic>);
  }

  /// Crea un usuario (mediador o administrador). El PIN es de 4
  /// digitos; el cliente necesita el permiso de gestion del rol
  /// objetivo (`users.mediators.manage` / `users.admins.manage`).
  Future<User> createUser({
    required String name,
    required String email,
    required String pin,
    required String role,
  }) async {
    final data = await _client.post(ApiConfig.usersPath, body: {
      'name': name,
      'email': email,
      'password': pin,
      'role': role,
    });
    return User.fromJson(data as Map<String, dynamic>);
  }

  /// Actualiza nombre, correo, PIN y/o rol de un usuario.
  Future<User> updateUser(
    int id, {
    String? name,
    String? email,
    String? pin,
    String? role,
  }) async {
    final body = <String, dynamic>{
      if (name != null && name.isNotEmpty) 'name': name,
      if (email != null && email.isNotEmpty) 'email': email,
      if (pin != null && pin.isNotEmpty) 'password': pin,
      if (role != null && role.isNotEmpty) 'role': role,
    };
    final data = await _client.patch('${ApiConfig.usersPath}/$id', body: body);
    return User.fromJson(data as Map<String, dynamic>);
  }

  /// Reactiva una cuenta desactivada.
  Future<User> activateUser(int id) async {
    final data = await _client.post('${ApiConfig.usersPath}/$id/activate');
    return User.fromJson(data as Map<String, dynamic>);
  }

  /// Desactiva una cuenta (eliminacion logica usada por la app): el
  /// usuario no podra iniciar sesion, pero el registro se conserva y
  /// puede reactivarse con /activate. El DELETE fisico del backend
  /// no se expone en este cliente deliberadamente.
  Future<User> deactivateUser(int id) async {
    final data = await _client.post('${ApiConfig.usersPath}/$id/deactivate');
    return User.fromJson(data as Map<String, dynamic>);
  }
}
