/// Modelos de roles y permisos del frontend.
///
/// Reflejan los esquemas `RoleRead` y `PermissionRead` del backend
/// (app/schemas/role.py). Los roles son datos fijos del dominio
/// (ADMINISTRADOR, MEDIADOR): no hay CRUD de roles.
library;

class Permission {
  const Permission({required this.id, required this.name, this.description});

  final int id;

  /// Nombre canonico del permiso (clave de autorizacion del
  /// backend, p. ej. `devices.view`).
  final String name;
  final String? description;

  factory Permission.fromJson(Map<String, dynamic> json) => Permission(
    id: json['id'] as int,
    name: json['name'] as String,
    description: json['description'] as String?,
  );
}

class Role {
  const Role({
    required this.id,
    required this.name,
    this.description,
    this.permissions = const [],
  });

  final int id;

  /// Nombre canonico del rol (ADMINISTRADOR / MEDIADOR).
  final String name;
  final String? description;

  /// Permisos asignados al rol segun el servidor.
  final List<Permission> permissions;

  /// true cuando el rol tiene asignado [permissionName].
  bool has(String permissionName) =>
      permissions.any((p) => p.name == permissionName);

  factory Role.fromJson(Map<String, dynamic> json) => Role(
    id: json['id'] as int,
    name: json['name'] as String,
    description: json['description'] as String?,
    permissions: [
      for (final item in (json['permissions'] as List<dynamic>? ?? const []))
        Permission.fromJson(item as Map<String, dynamic>),
    ],
  );

  /// Copia con otro conjunto de permisos (estado sin guardar de la
  /// matriz de roles).
  Role withPermissions(List<Permission> next) => Role(
    id: id,
    name: name,
    description: description,
    permissions: next,
  );
}

/// Etiqueta legible de un rol (ADMINISTRADOR -> Administrador).
/// Usada por la pestana Usuarios y la pantalla de Roles.
String roleLabel(String roleName) {
  switch (roleName) {
    case 'ADMINISTRADOR':
      return 'Administrador';
    case 'MEDIADOR':
      return 'Mediador';
  }
  return roleName;
}
