/// Pantalla Roles y Permisos (referencia administraci_n_de_roles).
///
/// Usa los endpoints existentes: GET /api/roles (chips de rol),
/// GET /api/permissions (catalogo) y GET/PUT
/// /api/roles/{name}/permissions (matriz de permisos). El "Guardar
/// Cambios" envia PUT con el conjunto COMPLETO: el backend sustituye
/// la asignacion del rol y, al confirmar, la matriz se CIERRA y
/// vuelve a la pestana de Usuarios. Se muestran solo las
/// descripciones humanas del catalogo: los codigos canonicos no
/// interesan en la sala.
///
/// Fuera de contrato en el backend (dejar mockeado en la UI):
/// - "Nuevo Rol": los roles son fijos del dominio (ADMINISTRADOR,
///   MEDIADOR); no existe endpoint de creacion, asi que el aviso lo
///   explica en lugar de fingir el alta.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../controllers/users_controller.dart';
import '../../core/capabilities.dart';
import '../../core/network/api_exception.dart';
import '../../core/theme/cauce_colors.dart';
import '../../core/theme/cauce_theme.dart';
import '../../models/role.dart';
import '../../widgets/cauce_headers.dart';
import '../../widgets/organic_background.dart';

class RolesScreen extends StatefulWidget {
  const RolesScreen({super.key});

  @override
  State<RolesScreen> createState() => _RolesScreenState();
}

class _RolesScreenState extends State<RolesScreen> {
  List<Role> _roles = const [];
  List<Permission> _catalog = const [];
  String? _selected;

  /// Conjunto editado (sin guardar) y el vigente en el servidor.
  Set<String> _checked = {};
  Set<String> _initial = {};

  bool _loading = true;
  bool _saving = false;
  bool _forbidden = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<UsersController>().ensureLoaded();
      _loadRoles();
    });
  }

  bool get _dirty {
    if (_checked.length != _initial.length) return true;
    return _checked.any((name) => !_initial.contains(name));
  }

  /// Roles del dominio + catalogo de permisos (GET /roles y
  /// GET /permissions) y permisos vigentes del rol seleccionado.
  Future<void> _loadRoles({bool keepSelection = false}) async {
    final service = context.read<UsersController>().roleService;
    setState(() {
      _loading = true;
      _error = null;
      _forbidden = false;
    });
    try {
      final roles = await service.listRoles();
      final catalog = await service.listPermissions();
      final target = keepSelection && _selected != null && roles.any((r) => r.name == _selected)
          ? _selected!
          : (roles.isNotEmpty ? roles.first.name : _selected);
      Role? current;
      if (target != null) {
        current = await service.getRolePermissions(target);
      }
      if (!mounted) return;
      setState(() {
        _roles = roles;
        _catalog = catalog;
        _selected = target;
        _checked = current == null
            ? <String>{}
            : {for (final p in current.permissions) p.name};
        _initial = Set.of(_checked);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _forbidden = e.isAuthError;
        _error = e.message;
      });
    }
  }

  /// Cambia el chip de rol y trae sus permisos vigentes (GET).
  Future<void> _selectRole(String name) async {
    if (name == _selected) return;
    final service = context.read<UsersController>().roleService;
    setState(() {
      _selected = name;
      _loading = true;
      _error = null;
    });
    try {
      final role = await service.getRolePermissions(name);
      if (!mounted) return;
      setState(() {
        _checked = {for (final p in role.permissions) p.name};
        _initial = Set.of(_checked);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
        _forbidden = e.isAuthError;
      });
    }
  }

  void _toggle(String permissionName) {
    setState(() {
      if (_checked.contains(permissionName)) {
        _checked.remove(permissionName);
      } else {
        _checked.add(permissionName);
      }
    });
  }

  /// PUT /api/roles/{name}/permissions con el conjunto completo.
  /// Requiere `roles.permissions.manage`; un rechazo (403) se
  /// muestra sin cerrar la pantalla. Al confirmar, la matriz se
  /// cierra y vuelve a la pestana Usuarios.
  Future<void> _save() async {
    final role = _selected;
    if (role == null || _saving) return;
    final service = context.read<UsersController>().roleService;
    setState(() => _saving = true);
    try {
      await service.updateRolePermissions(role, _checked.toList());
      if (!mounted) return;
      // Guardado: se refresca el dominio (chips y contadores), se
      // avisa al volver y se cierra la matriz de permisos.
      final messenger = ScaffoldMessenger.of(context);
      unawaited(context.read<UsersController>().refresh());
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Permisos de ${roleLabel(role)} actualizados en la '
              'LAN.'),
          backgroundColor: CauceColors.teal,
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isAuthError) {
        // Sin `roles.permissions.manage`: la matriz es solo
        // consulta; se deshace el cambio local.
        setState(() {
          _checked = Set.of(_initial);
          _saving = false;
        });
      } else {
        setState(() => _saving = false);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.isAuthError
              ? 'No tienes permiso para modificar esta matriz.'
              : e.message),
          backgroundColor: CauceColors.error,
        ),
      );
    }
  }

  void _cancel() {
    setState(() => _checked = Set.of(_initial));
  }

  /// "Nuevo Rol" de la referencia: el backend no tiene CRUD de roles
  /// (son datos fijos del dominio). Aviso explicito, alta simulada.
  void _newRoleMock() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Los roles son fijos del sistema (Administrador y Mediador): '
          'el backend no ofrece la creacion de roles por ahora.',
        ),
        backgroundColor: CauceColors.darkTeal,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = canManageUsers(context);
    return Scaffold(
      backgroundColor: CauceColors.creamSurface,
      body: Stack(
        children: [
          const OrganicBackground(
            topRight: true,
            bottomLeft: true,
            baseColor: CauceColors.creamSurface,
          ),
          Column(
            children: [
              StackHeader(
                title: 'Roles y\nPermisos',
                showLogo: false,
                titleFontSize: 16,
                onAvatarTap: () =>
                    Navigator.of(context).pushNamed('/profile'),
                backgroundColor: CauceColors.creamSurface,
              ),
              Expanded(
                child: SafeArea(
                  top: false,
                  child: RefreshIndicator(
                    color: CauceColors.creamSecondary,
                    onRefresh: () => _loadRoles(keepSelection: true),
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _headerNotice(canEdit),
                          const SizedBox(height: 12),
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'SELECCIONAR PERFIL',
                              style: TextStyle(
                                fontFamily: CauceTheme.bodyFont,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.6,
                                color: CauceColors.creamOnSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          _RoleChips(
                            roles: _roles,
                            selected: _selected,
                            onSelect: _selectRole,
                            onNewRole: _newRoleMock,
                          ),
                          const SizedBox(height: 16),
                          if (_loading)
                            const Center(
                              child: CircularProgressIndicator(
                                color: CauceColors.creamSecondary,
                              ),
                            )
                          else if (_forbidden)
                            _noticeCard(
                              icon: Icons.lock_outline,
                              title: 'Consulta reservada a administradores',
                              message:
                                  'La matriz de permisos requiere el '
                                  'permiso `users.view`; tu sesion actual '
                                  'no lo posee.',
                            )
                          else if (_error != null)
                            _noticeCard(
                              icon: Icons.wifi_off,
                              title: 'No fue posible consultar los permisos',
                              message: _error!,
                              actionLabel: 'Reintentar',
                              onAction: () =>
                                  _loadRoles(keepSelection: true),
                            )
                          else ...[
                            Consumer<UsersController>(
                              builder: (context, controller, _) =>
                                  _RoleFiche(
                                roleName: _selected ?? '',
                                description: _roles
                                    .where((r) => r.name == _selected)
                                    .firstOrNull
                                    ?.description,
                                userCount: controller.roleCount(
                                  _selected ?? '',
                                ),
                                granted: _checked.length,
                                total: _catalog.length,
                              ),
                            ),
                            const SizedBox(height: 16),
                            for (final category in _categorized())
                              _CategoryCard(
                                category: category,
                                checked: _checked,
                                enabled: canEdit,
                                onToggle: _toggle,
                              ),
                            const SizedBox(height: 20),
                            if (canEdit) ...[
                              FilledButton.icon(
                                onPressed: _dirty && !_saving ? _save : null,
                                style: FilledButton.styleFrom(
                                  backgroundColor: CauceColors.creamPrimary,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: const StadiumBorder(),
                                ),
                                icon: _saving
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(Icons.save, size: 20),
                                label: Text(
                                  _saving
                                      ? 'Guardando matriz de acceso...'
                                      : 'Guardar Cambios de Permisos',
                                  style: const TextStyle(
                                    fontFamily: CauceTheme.displayFont,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextButton.icon(
                                onPressed: _dirty ? _cancel : null,
                                icon: const Icon(Icons.restart_alt, size: 18),
                                label: const Text('Cancelar'),
                              ),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _headerNotice(bool canEdit) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CauceColors.creamSurfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline,
            size: 18,
            color: CauceColors.creamSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              canEdit
                  ? 'Los cambios reemplazan por completo la asignacion del '
                      'rol; guardalos para que apliquen en la LAN.'
                  : 'Vista de solo lectura para tu sesion.',
              style: const TextStyle(
                fontFamily: CauceTheme.bodyFont,
                fontSize: 12,
                height: 1.4,
                color: CauceColors.creamOnSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _noticeCard({
    required IconData icon,
    required String title,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: CauceColors.creamSurfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, size: 32, color: CauceColors.creamTertiary),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: CauceTheme.displayFont,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: CauceColors.creamOnSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: CauceTheme.bodyFont,
              fontSize: 13,
              height: 1.4,
              color: CauceColors.creamOnSurfaceVariant,
            ),
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onAction,
              child: Text(actionLabel),
            ),
          ],
        ],
      ),
    );
  }

  /// Agrupa el catalogo de permisos por categoria segun su clave
  /// canonica (devices.* -> Control de Sala..., etc.).
  List<_PermissionCategory> _categorized() {
    final byCategory = <String, List<Permission>>{};
    for (final permission in _catalog) {
      final (title, icon, color) = _categoryOf(permission.name);
      byCategory.putIfAbsent(title, () => []).add(permission);
    }
    // Orden estable: el orden de insercion del catalogo del backend.
    final seen = <String>{};
    final out = <_PermissionCategory>[];
    for (final permission in _catalog) {
      final (title, icon, color) = _categoryOf(permission.name);
      if (seen.contains(title)) continue;
      seen.add(title);
      out.add(_PermissionCategory(
        icon: icon,
        color: color,
        title: title,
        permissions: byCategory[title]!,
      ));
    }
    return out;
  }

  (String, IconData, Color) _categoryOf(String permissionName) {
    if (permissionName.startsWith('devices.')) {
      return (
        'Control de Sala y Dispositivos',
        Icons.tv,
        CauceColors.creamSecondary,
      );
    }
    if (permissionName.startsWith('content.')) {
      return (
        'Biblioteca de Medios',
        Icons.video_library,
        CauceColors.creamPrimary,
      );
    }
    if (permissionName.startsWith('experiences.')) {
      return ('Experiencias', Icons.view_in_ar, CauceColors.teal);
    }
    if (permissionName.startsWith('schedules.')) {
      return ('Programacion de Sala', Icons.schedule, Color(0xFF7E513A));
    }
    if (permissionName.startsWith('users.')) {
      return ('Personal de Sala', Icons.group, CauceColors.creamSecondary);
    }
    return ('Seguridad y Permisos', Icons.security, CauceColors.error);
  }
}

/// Titulo de un permiso: su descripcion del catalogo del backend,
/// capitalizada y sin el punto final. El codigo canonico
/// (`users.view`, `devices.manage`...) no se muestra: es un detalle
/// tecnico del backend.
String _permissionTitle(Permission permission) {
  final description = (permission.description ?? permission.name).trim();
  final title = description.endsWith('.')
      ? description.substring(0, description.length - 1)
      : description;
  return title.isEmpty
      ? title
      : title[0].toUpperCase() + title.substring(1);
}

/// Selector horizontal de perfiles + chip "Nuevo Rol" (mockeado:
/// los roles son fijos del sistema).
class _RoleChips extends StatelessWidget {
  const _RoleChips({
    required this.roles,
    required this.selected,
    required this.onSelect,
    required this.onNewRole,
  });

  final List<Role> roles;
  final String? selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onNewRole;

  IconData _iconFor(String roleName) {
    switch (roleName) {
      case 'ADMINISTRADOR':
        return Icons.admin_panel_settings;
      case 'MEDIADOR':
        return Icons.record_voice_over;
    }
    return Icons.groups;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: roles.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index == roles.length) {
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _NewRoleChip(onTap: onNewRole),
            );
          }
          final role = roles[index];
          final active = role.name == selected;
          return Material(
            color: active
                ? CauceColors.creamPrimary
                : CauceColors.creamSurfaceContainerLow,
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => onSelect(role.name),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _iconFor(role.name),
                      size: 18,
                      color: active ? Colors.white : CauceColors.creamSecondary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      roleLabel(role.name),
                      style: TextStyle(
                        fontFamily: CauceTheme.displayFont,
                        fontSize: 13,
                        fontWeight: active
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: active
                            ? Colors.white
                            : CauceColors.creamOnSurface,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _NewRoleChip extends StatelessWidget {
  const _NewRoleChip({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: CauceColors.creamSecondaryFixed.withValues(alpha: 0.5),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add_moderator,
                size: 18,
                color: CauceColors.creamOnSecondaryFixed,
              ),
              SizedBox(width: 6),
              Text(
                'Nuevo Rol',
                style: TextStyle(
                  fontFamily: CauceTheme.displayFont,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: CauceColors.creamOnSecondaryFixed,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ficha del rol seleccionado: descripcion, usuarios del rol y barra
/// de privilegios activos (X de Y).
class _RoleFiche extends StatelessWidget {
  const _RoleFiche({
    required this.roleName,
    this.description,
    required this.userCount,
    required this.granted,
    required this.total,
  });

  final String roleName;
  final String? description;
  final int userCount;
  final int granted;
  final int total;

  @override
  Widget build(BuildContext context) {
    final ratio = total == 0 ? 0.0 : granted / total;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CauceColors.creamSurfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 4),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: CauceColors.creamSurfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.groups_3,
                  size: 26,
                  color: CauceColors.creamPrimary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      roleLabel(roleName),
                      style: const TextStyle(
                        fontFamily: CauceTheme.displayFont,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: CauceColors.creamOnSurface,
                      ),
                    ),
                    if (description != null)
                      Text(
                        description!,
                        style: const TextStyle(
                          fontFamily: CauceTheme.bodyFont,
                          fontSize: 12,
                          height: 1.4,
                          color: CauceColors.creamOnSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: CauceColors.creamSurfaceContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.badge,
                      size: 14,
                      color: CauceColors.creamSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$userCount usuario${userCount == 1 ? '' : 's'}',
                      style: const TextStyle(
                        fontFamily: CauceTheme.bodyFont,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: CauceColors.creamSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Capacidades activas',
                  style: TextStyle(
                    fontFamily: CauceTheme.bodyFont,
                    fontSize: 12,
                    color: CauceColors.creamOnSurfaceVariant,
                  ),
                ),
              ),
              Text(
                '$granted de $total permisos concedidos',
                style: const TextStyle(
                  fontFamily: CauceTheme.bodyFont,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: CauceColors.creamPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: SizedBox(
              height: 6,
              child: Stack(
                children: [
                  Container(
                    color: CauceColors.creamSurfaceContainerHighest,
                  ),
                  FractionallySizedBox(
                    widthFactor: ratio,
                    child: Container(color: CauceColors.creamPrimary),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionCategory {
  const _PermissionCategory({
    required this.icon,
    required this.color,
    required this.title,
    required this.permissions,
  });

  final IconData icon;
  final Color color;
  final String title;
  final List<Permission> permissions;
}

/// Tarjeta de una categoria de permisos con sus casillas.
class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.category,
    required this.checked,
    required this.enabled,
    required this.onToggle,
  });

  final _PermissionCategory category;
  final Set<String> checked;

  /// false = solo lectura (sin `roles.permissions.manage`).
  final bool enabled;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    var granted = 0;
    for (final p in category.permissions) {
      if (checked.contains(p.name)) granted++;
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(category.icon, size: 20, color: category.color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  category.title,
                  style: const TextStyle(
                    fontFamily: CauceTheme.displayFont,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: CauceColors.creamOnSurface,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: CauceColors.creamSurfaceContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$granted/${category.permissions.length}',
                  style: const TextStyle(
                    fontFamily: CauceTheme.bodyFont,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: CauceColors.creamOnSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final permission in category.permissions) ...[
            _PermissionRow(
              permission: permission,
              value: checked.contains(permission.name),
              enabled: enabled,
              onChanged: () => onToggle(permission.name),
            ),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.permission,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final Permission permission;
  final bool value;

  /// Sin `roles.permissions.manage` la fila esta atenuada y no
  /// responde: la matriz es solo consulta.
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final title = _permissionTitle(permission);
    return Opacity(
      opacity: enabled ? 1 : 0.65,
      child: Material(
        color: value
            ? CauceColors.creamSurfaceContainerLow.withValues(alpha: 0.6)
            : CauceColors.creamSurfaceContainerLow.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: enabled ? onChanged : null,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 22,
                  height: 22,
                  margin: const EdgeInsets.only(top: 2),
                  decoration: BoxDecoration(
                    color: value
                        ? CauceColors.creamPrimary
                        : CauceColors.creamSurfaceContainerHigh,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: value
                      ? const Icon(Icons.check, size: 16, color: Colors.white)
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontFamily: CauceTheme.bodyFont,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: CauceColors.creamOnSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
