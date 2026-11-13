/// Servicio de roles y permisos contra el backend Cauce.
///
/// Contratos reales:
/// - GET /api/roles                       (permiso `users.view`)
/// - GET /api/permissions                 (permiso `users.view`)
/// - GET  /api/roles/{name}/permissions   (permiso `users.view`)
/// - PUT  /api/roles/{name}/permissions   (permiso `roles.permissions.manage`)
///
/// Los roles son datos fijos del dominio: no existe CRUD de roles
/// ni endpoint para crearlos.
library;

import '../core/config/api_config.dart';
import '../core/network/api_client.dart';
import '../models/role.dart';

class RoleService {
  RoleService({required ApiClient client}) : _client = client;

  final ApiClient _client;

  /// Roles del dominio con sus permisos asignados.
  Future<List<Role>> listRoles() async {
    final data = await _client.get(ApiConfig.rolesPath);
    return (data as List<dynamic>)
        .map((item) => Role.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// Catalogo completo de permisos del sistema.
  Future<List<Permission>> listPermissions() async {
    final data = await _client.get(ApiConfig.permissionsPath);
    return (data as List<dynamic>)
        .map((item) => Permission.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// Permisos vigentes de un rol.
  Future<Role> getRolePermissions(String roleName) async {
    final data = await _client.get(
      '${ApiConfig.rolesPath}/${Uri.encodeComponent(roleName)}/permissions',
    );
    return Role.fromJson(data as Map<String, dynamic>);
  }

  /// Reemplaza por completo el conjunto de permisos del rol (PUT).
  /// La lista son nombres canonicos de permisos; el backend ignora
  /// duplicados y rechaza nombres desconocidos.
  Future<Role> updateRolePermissions(
    String roleName,
    List<String> permissionNames,
  ) async {
    final data = await _client.put(
      '${ApiConfig.rolesPath}/${Uri.encodeComponent(roleName)}/permissions',
      body: {'permissions': permissionNames},
    );
    return Role.fromJson(data as Map<String, dynamic>);
  }
}
