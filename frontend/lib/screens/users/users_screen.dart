/// Pestana Usuarios: administracion de usuarios de la sala
/// (referencia usuarios_administraci_n_de_personal).
///
/// Los datos provienen de GET /api/users y GET /api/roles a traves
/// de [UsersController]; ambas consultas requieren `users.view`
/// (solo ADMINISTRADOR), asi que un mediador ve un aviso en lugar de
/// la lista. La busqueda, el filtro por rol y el conmutador de
/// perfiles inactivos operan en memoria. Las acciones por usuario
/// usan los endpoints existentes:
/// - Editar / Reset PIN: PATCH /api/users/{id}.
/// - "Eliminar Usuario": la app aplica deliberadamente un borrado
///   logico via POST /api/users/{id}/deactivate; no usa el DELETE
///   fisico del backend. Una cuenta desactivada puede reactivarse
///   con /activate.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app.dart';
import '../../controllers/users_controller.dart';
import '../../core/capabilities.dart';
import '../../core/theme/cauce_colors.dart';
import '../../core/theme/cauce_theme.dart';
import '../../core/utils/date_labels.dart';
import '../../models/role.dart';
import '../../models/user.dart';
import '../../widgets/cauce_headers.dart';
import '../../widgets/organic_background.dart';

class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  final _searchController = TextEditingController();

  /// Rol seleccionado en las capsulas de filtro; null = todos.
  String? _roleFilter;

  /// Cuando es false, la lista y los contadores de las capsulas
  /// ocultan los perfiles desactivados.
  bool _showInactive = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<UsersController>().ensureLoaded();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<User> _filtered(List<User> users) {
    final query = _searchController.text.trim().toLowerCase();
    Iterable<User> out = users;
    if (!_showInactive) {
      out = out.where((u) => u.isActive);
    }
    final role = _roleFilter;
    if (role != null) {
      out = out.where((u) => u.role.name == role);
    }
    if (query.isNotEmpty) {
      out = out.where(
        (u) =>
            u.name.toLowerCase().contains(query) ||
            u.email.toLowerCase().contains(query) ||
            u.role.name.toLowerCase().contains(query),
      );
    }
    return out.toList();
  }

  /// Lista base que respetan los contadores de las capsulas: con los
  /// inactivos ocultos, "Todos (n)" y cada rol cuentan solo lo
  /// visible.
  List<User> _visibleUsers(List<User> users) {
    if (_showInactive) return users;
    return users.where((u) => u.isActive).toList();
  }

  Future<void> _openNewUserSheet() async {
    final controller = context.read<UsersController>();
    final created = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: CauceColors.peachSurfaceContainerLow,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => _UserFormSheet(
        roles: controller.roles,
        onSubmit: (name, email, pin, role) async {
          final error = await controller.createUser(
            name: name,
            email: email,
            pin: pin,
            role: role,
          );
          if (error != null) return error;
          return null;
        },
      ),
    );
    if (!mounted || created != true) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Usuario creado. Ya puede iniciar sesion con su PIN.'),
        backgroundColor: CauceColors.teal,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const ColoredBox(color: CauceColors.peachSurface),
        const OrganicBackground(
          topRight: true,
          bottomLeft: false,
          baseColor: CauceColors.peachSurface,
        ),
        Column(
          children: [
            TabHeader(
              title: 'Usuarios',
              onAvatarTap: () => Navigator.of(context).pushNamed(Routes.profile),
            ),
            Expanded(
              child: Consumer<UsersController>(
                builder: (context, controller, _) {
                  if (controller.status == UsersLoadStatus.loading) {
                    return const Center(
                      child: CircularProgressIndicator(
                        color: CauceColors.peachPrimary,
                      ),
                    );
                  }
                  if (controller.forbidden && controller.users.isEmpty) {
                    return _NoticeCard(
                      icon: Icons.lock_outline,
                      title: 'Seccion reservada a administradores',
                      message:
                          'La administracion de usuarios y roles requiere '
                          'el permiso del rol ADMINISTRADOR. Tu cuenta de '
                          'mediacion no puede consultar el personal de la '
                          'sala.',
                    );
                  }
                  if (controller.status == UsersLoadStatus.error &&
                      controller.users.isEmpty) {
                    return _NoticeCard(
                      icon: Icons.wifi_off,
                      title: 'No fue posible consultar el personal',
                      message: controller.errorMessage ??
                          'Verifica que el servidor de la sala este disponible.',
                      actionLabel: 'Reintentar',
                      onAction: () => controller.refresh(),
                    );
                  }
                  return RefreshIndicator(
                    color: CauceColors.peachPrimary,
                    onRefresh: () => controller.refresh(),
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 140),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _UserSearchBar(
                            controller: _searchController,
                            onChanged: (_) => setState(() {}),
                            onRefresh: () => controller.refresh(),
                            refreshing: controller.isRefreshing,
                            showInactive: _showInactive,
                            onToggleInactive: () => setState(
                              () => _showInactive = !_showInactive,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _RoleFilterChips(
                                  users: _visibleUsers(controller.users),
                                  roles: controller.roles,
                                  selected: _roleFilter,
                                  onSelect: (role) =>
                                      setState(() => _roleFilter = role),
                                ),
                              ),
                              if (canManageUsers(context)) ...[
                                const SizedBox(width: 8),
                                _RolesButton(
                                  onTap: () => Navigator.of(
                                    context,
                                  ).pushNamed(Routes.roles),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 16),
                          ..._buildList(context, controller),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
        // Accion flotante de registro de personal: solo con permiso
        // de gestion (la UI decide, el 403 del backend es la red de
        // seguridad).
        if (canManageUsers(context))
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.extended(
              onPressed: _openNewUserSheet,
              backgroundColor: CauceColors.peachPrimaryContainer,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.person_add, size: 22),
              label: const Text(
                'Nuevo Usuario',
                style: TextStyle(
                  fontFamily: CauceTheme.bodyFont,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildList(BuildContext context, UsersController controller) {
    final users = _filtered(controller.users);
    if (controller.users.isNotEmpty && users.isEmpty) {
      return [
        const _NoticeCard(
          icon: Icons.search_off,
          title: 'Ningun usuario coincide',
          message:
              'Ajusta la busqueda o el filtro de rol para ver mas '
              'resultados.',
        ),
      ];
    }
    if (users.isEmpty) {
      return [
        const _NoticeCard(
          icon: Icons.group_add,
          title: 'Todavia no hay personal registrado',
          message:
              'Crea la primera cuenta con el boton Nuevo Usuario; el '
              'rol queda definido en cada cuenta.',
        ),
      ];
    }
    return [
      for (final user in users) ...[_UserCard(user: user)],
    ];
  }
}

/// Boton de acceso directo a la pantalla de roles, junto a las
/// capsulas de filtro (solo administradores).
class _RolesButton extends StatelessWidget {
  const _RolesButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: CauceColors.peachSurfaceContainer,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.admin_panel_settings,
                size: 18,
                color: CauceColors.peachPrimary,
              ),
              SizedBox(width: 6),
              Text(
                'Roles',
                style: TextStyle(
                  fontFamily: CauceTheme.displayFont,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: CauceColors.peachPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Busqueda de personal: nombre, correo o rol. El boton de refresco
/// relanza la consulta GET /api/users y el conmutador junto a el
/// muestra u oculta los perfiles inactivos.
class _UserSearchBar extends StatelessWidget {
  const _UserSearchBar({
    required this.controller,
    this.onChanged,
    this.onRefresh,
    this.refreshing = false,
    this.showInactive = true,
    this.onToggleInactive,
  });

  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onRefresh;
  final bool refreshing;

  /// Estado del conmutador de perfiles inactivos: true = visibles.
  final bool showInactive;
  final VoidCallback? onToggleInactive;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.search,
                  size: 20,
                  color: CauceColors.peachOnSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: controller,
                    onChanged: onChanged,
                    decoration: const InputDecoration(
                      hintText: 'Buscar por nombre, correo o rol...',
                      border: InputBorder.none,
                      filled: false,
                      contentPadding: EdgeInsets.zero,
                      isDense: true,
                    ),
                    style: const TextStyle(
                      fontFamily: CauceTheme.bodyFont,
                      fontSize: 15,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(
            color: CauceColors.peachSurfaceContainer,
            shape: BoxShape.circle,
          ),
          child: refreshing
              ? const Padding(
                  padding: EdgeInsets.all(10),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: CauceColors.peachOnSurface,
                  ),
                )
              : InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onRefresh,
                  child: const Icon(
                    Icons.refresh,
                    size: 18,
                    color: CauceColors.peachOnSurface,
                  ),
                ),
        ),
        const SizedBox(width: 8),
        Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(
            color: CauceColors.peachSurfaceContainer,
            shape: BoxShape.circle,
          ),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onToggleInactive,
            child: Tooltip(
              message: showInactive
                  ? 'Ocultar perfiles inactivos'
                  : 'Mostrar perfiles inactivos',
              child: Icon(
                showInactive ? Icons.visibility : Icons.visibility_off,
                size: 18,
                color: CauceColors.peachOnSurface,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Capsulas de filtro por rol: "Todos (n)" mas una por cada rol del
/// dominio con su conteo; [users] llega ya filtrada por el
/// conmutador de inactivos, asi que el conteo refleja lo visible.
class _RoleFilterChips extends StatelessWidget {
  const _RoleFilterChips({
    required this.users,
    required this.roles,
    required this.selected,
    required this.onSelect,
  });

  final List<User> users;
  final List<Role> roles;

  /// Rol seleccionado; null significa "todos".
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: roles.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index == 0) {
            return _filterChip(
              context,
              label: 'Todos (${users.length})',
              active: selected == null,
              onTap: () => onSelect(null),
            );
          }
          final role = roles[index - 1];
          return _filterChip(
            context,
            label: '${roleLabel(role.name)} (${users.where((u) => u.role.name == role.name).length})',
            active: selected == role.name,
            onTap: () => onSelect(role.name),
          );
        },
      ),
    );
  }

  Widget _filterChip(
    BuildContext context, {
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Material(
      color: active ? CauceColors.peachPrimary : Colors.white,
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: CauceTheme.displayFont,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: active ? Colors.white : CauceColors.peachOnSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(icon, size: 32, color: CauceColors.peachSecondary),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: CauceTheme.displayFont,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: CauceColors.peachOnSurface,
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
              color: CauceColors.peachOnSurfaceVariant,
            ),
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                backgroundColor: CauceColors.peachPrimaryContainer,
              ),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

/// Tarjeta acordeon de usuario (referencia: fila con iniciales, nombre,
/// insignia de rol y correo; el despliegue Revela telemetria y
/// acciones in-situ).
class _UserCard extends StatefulWidget {
  const _UserCard({required this.user});

  final User user;

  @override
  State<_UserCard> createState() => _UserCardState();
}

class _UserCardState extends State<_UserCard> {
  /// Nace plegada: el acordeon de la referencia inicia colapsado y
  /// solo la primera tarjeta de ejemplo esta desplegada.
  bool _expanded = false;

  void _resultSnackBar(bool ok, String? error, String okMessage) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(okMessage), backgroundColor: CauceColors.teal),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text(error ?? 'El servidor rechazo la operacion.'),
          backgroundColor: CauceColors.error,
        ),
      );
    }
  }

  Future<void> _edit() async {
    final controller = context.read<UsersController>();
    final updated = await showModalBottomSheet<(String, String?, String?)>(
      context: context,
      backgroundColor: CauceColors.peachSurfaceContainerLow,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => _UserEditSheet(
        user: widget.user,
        roles: controller.roles,
      ),
    );
    if (updated == null) return;
    final (name, email, role) = updated;
    final error = await controller.updateUser(
      widget.user,
      name: name,
      email: email,
      role: role,
    );
    _resultSnackBar(
      error == null,
      error,
      '"${name.isEmpty ? widget.user.name : name}" actualizado.',
    );
  }

  /// Reset del PIN: el backend no tiene un endpoint propio de reset;
  /// PATCH /api/users/{id} con `password` es el contrato vigente.
  Future<void> _resetPin() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        title: Text('Reset PIN de ${widget.user.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('El nuevo PIN debe tener 4 digitos numericos.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: true,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              autofocus: true,
              decoration: const InputDecoration(
                counterText: '',
                hintText: '****',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final pin = controller.text.trim();
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El PIN debe tener exactamente 4 digitos numericos.'),
          backgroundColor: CauceColors.error,
        ),
      );
      return;
    }
    final error = await context
        .read<UsersController>()
        .updateUser(widget.user, pin: pin);
    _resultSnackBar(error == null, error, 'PIN actualizado correctamente.');
  }

  /// "Eliminar Usuario" de la referencia: la app aplica
  /// deliberadamente un borrado logico (POST /deactivate) y no usa
  /// el DELETE fisico del backend. El dialogo lo deja explicito.
  Future<void> _confirmRemove() async {
    final user = widget.user;
    final controller = context.read<UsersController>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('Eliminar usuario'),
        content: Text(
          '"${user.name}" quedara desactivado y no podra iniciar '
          'sesion. Su registro se conserva y puede reactivarse mas '
          'adelante.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: CauceColors.error),
            child: const Text('Desactivar'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final error = await controller.setActive(user, active: false);
    _resultSnackBar(
      error == null,
      error,
      '"${user.name}" desactivado del circuito de personal.',
    );
  }

  Future<void> _reactivate() async {
    final error = await context
        .read<UsersController>()
        .setActive(widget.user, active: true);
    _resultSnackBar(
      error == null,
      error,
      '"${widget.user.name}" reactivado. Ya puede iniciar sesion.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final manage = canManageUsers(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: _expanded ? 0.08 : 0.04),
            blurRadius: _expanded ? 12 : 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(22),
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    _UserAvatar(user: user),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  user.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: CauceTheme.displayFont,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: CauceColors.peachOnSurface,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              _RoleBadge(roleName: user.role.name),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            user.email,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: CauceTheme.bodyFont,
                              fontSize: 13,
                              color: CauceColors.peachOnSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _ActiveBadge(active: user.isActive),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(
                        Icons.keyboard_arrow_down,
                        size: 22,
                        color: CauceColors.peachOnSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _AuditRow(
                          icon: Icons.calendar_today,
                          label: 'Fecha de Creacion',
                          value: localDateTime(user.createdAt),
                        ),
                        _AuditRow(
                          icon: Icons.update,
                          label: 'Ultima Actualizacion',
                          value: localDateTime(user.updatedAt),
                        ),
                        if (manage) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: _ActionTile(
                                  icon: Icons.edit,
                                  label: 'Editar',
                                  onPressed: _edit,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _ActionTile(
                                  icon: Icons.key,
                                  label: 'Reset PIN',
                                  onPressed: _resetPin,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (user.isActive)
                            _RemoveTile(onPressed: _confirmRemove)
                          else
                            _ActionTile(
                              icon: Icons.restore,
                              label: 'Reactivar Usuario',
                              color: CauceColors.teal,
                              onPressed: _reactivate,
                            ),
                        ],
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// Avatar con las iniciales del nombre y punto de estado (verde
/// activo / neutro inactivo).
class _UserAvatar extends StatelessWidget {
  const _UserAvatar({required this.user});

  final User user;

  String _initials(String name) {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return '?';
    final first = words.first[0];
    final last = words.length > 1 ? words.last[0] : '';
    return (first + last).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final admin = user.isAdmin;
    return Stack(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: admin
                ? CauceColors.maroon
                : CauceColors.teal,
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child: Text(
            _initials(user.name),
            style: const TextStyle(
              fontFamily: CauceTheme.displayFont,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: user.isActive ? CauceColors.success : Colors.grey,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.roleName});

  final String roleName;

  @override
  Widget build(BuildContext context) {
    final admin = roleName == 'ADMINISTRADOR';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: admin
            ? CauceColors.creamPrimaryFixed
            : CauceColors.creamSecondaryFixed,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        admin ? 'Admin' : 'Mediador',
        style: TextStyle(
          fontFamily: CauceTheme.bodyFont,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: admin
              ? CauceColors.creamOnSurfaceVariant
              : CauceColors.creamOnSecondaryFixed,
        ),
      ),
    );
  }
}

class _ActiveBadge extends StatelessWidget {
  const _ActiveBadge({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: active
            ? const Color(0xFFD1FAE5)
            : CauceColors.peachSurfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.circle,
            size: 6,
            color: active ? const Color(0xFF047857) : Colors.grey,
          ),
          const SizedBox(width: 4),
          Text(
            active ? 'Activo' : 'Inactivo',
            style: TextStyle(
              fontFamily: CauceTheme.bodyFont,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: active
                  ? const Color(0xFF065F46)
                  : CauceColors.peachOnSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _AuditRow extends StatelessWidget {
  const _AuditRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 15, color: CauceColors.peachSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: CauceTheme.bodyFont,
                fontSize: 12,
                color: CauceColors.peachOnSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontFamily: CauceTheme.bodyFont,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: CauceColors.peachOnSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// Boton de accion del panel desplegado (Editar / Reset PIN).
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color = CauceColors.peachPrimary,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: CauceColors.peachSurfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: CauceTheme.bodyFont,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: CauceColors.peachOnSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Boton de "Eliminar Usuario": conectado a la desactivacion logica
/// (la app no usa el DELETE fisico del backend), con tono granate de
/// la referencia.
class _RemoveTile extends StatelessWidget {
  const _RemoveTile({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: CauceColors.maroon.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.delete_outline,
                size: 18,
                color: CauceColors.maroon,
              ),
              SizedBox(width: 6),
              Text(
                'Eliminar Usuario',
                style: TextStyle(
                  fontFamily: CauceTheme.bodyFont,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: CauceColors.maroon,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Formulario de nuevo usuario: nombre, correo, PIN (4 digitos) y
/// rol del dominio. El backend exige el permiso de gestion del rol
/// objetivo; los errores del servidor se muestran en el propio
/// formulario sin cerrarlo.
class _UserFormSheet extends StatefulWidget {
  const _UserFormSheet({
    required this.roles,
    required this.onSubmit,
  });

  final List<Role> roles;

  /// Ejecuta el POST; devuelve el mensaje de error o null en exito.
  final Future<String?> Function(String name, String email, String pin,
      String role) onSubmit;

  @override
  State<_UserFormSheet> createState() => _UserFormSheetState();
}

class _UserFormSheetState extends State<_UserFormSheet> {
  late final TextEditingController _name;
  late final TextEditingController _email;
  late final TextEditingController _pin;
  late String _role;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController();
    _email = TextEditingController();
    _pin = TextEditingController();
    _role = widget.roles.isNotEmpty ? widget.roles.first.name : 'MEDIADOR';
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final email = _email.text.trim();
    final pin = _pin.text.trim();
    if (name.isEmpty || email.isEmpty) {
      setState(() => _error = 'Nombre y correo son obligatorios.');
      return;
    }
    if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
      setState(() => _error = 'El PIN debe tener 4 digitos numericos.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.onSubmit(name, email, pin, _role);
    if (!mounted) return;
    if (error != null) {
      setState(() {
        _saving = false;
        _error = error;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'NUEVO USUARIO',
            style: TextStyle(
              fontFamily: CauceTheme.displayFont,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: CauceColors.maroon,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'La cuenta queda activa de inmediato con el PIN indicado.',
            style: TextStyle(
              fontFamily: CauceTheme.bodyFont,
              fontSize: 12,
              height: 1.4,
              color: CauceColors.peachOnSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Nombre',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Correo',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _pin,
            keyboardType: TextInputType.number,
            maxLength: 4,
            obscureText: true,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'PIN (4 digitos)',
              counterText: '',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: widget.roles.any((r) => r.name == _role)
                ? _role
                : widget.roles.isNotEmpty
                      ? widget.roles.first.name
                      : null,
            items: [
              for (final role in widget.roles)
                DropdownMenuItem(
                  value: role.name,
                  child: Text(roleLabel(role.name)),
                ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _role = value);
            },
            decoration: const InputDecoration(
              labelText: 'Rol',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: const TextStyle(color: CauceColors.error, fontSize: 12),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
              backgroundColor: CauceColors.peachPrimaryContainer,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: const StadiumBorder(),
            ),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'Crear Usuario',
                    style: TextStyle(
                      fontFamily: CauceTheme.displayFont,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed:
                _saving ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
  }
}

/// Hoja de edicion de un usuario existente: nombre, correo y rol
/// (PATCH). Campos vacios mantienen el valor actual.
class _UserEditSheet extends StatefulWidget {
  const _UserEditSheet({required this.user, required this.roles});

  final User user;
  final List<Role> roles;

  @override
  State<_UserEditSheet> createState() => _UserEditSheetState();
}

class _UserEditSheetState extends State<_UserEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _email;
  late String _role;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.user.name);
    _email = TextEditingController(text: widget.user.email);
    _role = widget.user.role.name;
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'EDITAR "${widget.user.name}"',
            style: const TextStyle(
              fontFamily: CauceTheme.displayFont,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: CauceColors.maroon,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Nombre',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: 'Correo',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _role,
            items: [
              for (final role in widget.roles)
                DropdownMenuItem(
                  value: role.name,
                  child: Text(roleLabel(role.name)),
                ),
              // Rol actual fuera de la lista del servidor: se muestra
              // como item extra para no romper el dropdown.
              if (!widget.roles.any((r) => r.name == _role))
                DropdownMenuItem(value: _role, child: Text('$_role (legacy)')),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _role = value);
            },
            decoration: const InputDecoration(
              labelText: 'Rol',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).pop((
              _name.text.trim(),
              _email.text.trim(),
              _role != widget.user.role.name ? _role : null,
            )),
            style: FilledButton.styleFrom(
              backgroundColor: CauceColors.peachPrimaryContainer,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: const StadiumBorder(),
            ),
            child: const Text(
              'Guardar Cambios',
              style: TextStyle(
                fontFamily: CauceTheme.displayFont,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );
  }
}
