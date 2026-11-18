/// Shell principal con la barra de navegacion inferior. Dos modos
/// segun la sesion:
/// - Administrador (permiso de gestion de personal): barra de las 5
///   pestanas (Inicio, Dispositivos, Biblioteca, Actividad,
///   Usuarios) SOLO con iconos y su tooltip: con textos, cinco
///   elementos desbordan el ancho de la pantallas angostas.
/// - Mediador: 4 pestanas (sin "Usuarios") con sus textos: sobra
///   sitio para las etiquetas.
/// "Usuarios" es la pestana de administracion de personal (la
/// referencia "Mas" fue reemplazada); el perfil sigue alcanzable
/// desde el avatar del encabezado.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../controllers/devices_controller.dart';
import '../core/capabilities.dart';
import '../core/theme/cauce_colors.dart';
import '../core/theme/cauce_theme.dart';
import '../screens/activities/activities_screen.dart';
import '../screens/devices/devices_screen.dart';
import '../screens/home/home_screen.dart';
import '../screens/media/media_library_screen.dart';
import '../screens/users/users_screen.dart';
import '../session/session_controller.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;

  /// Historial de pestanas visitadas: el retroceso del sistema
  /// vuelve a la pestana anterior y solo sale de la app cuando ya no
  /// queda historial.
  final List<int> _tabHistory = [];

  late final DevicesController _devices;

  /// Pestanas del shell en orden fijo (el orden es el indice de la
  /// barra). "Usuarios" (gestion de personal) es la unica dependiente
  /// de permiso: [canManageUsers] decide en el build si forma parte
  /// del arbol, asi que la sesion carga tarde no le afecta.
  static const _destinations = <_Destination>[
    _Destination(Icons.home, 'Inicio', HomeScreen()),
    _Destination(Icons.devices, 'Dispositivos', DevicesScreen()),
    _Destination(Icons.video_library, 'Biblioteca', MediaLibraryScreen()),
    _Destination(Icons.hub, 'Actividad', ActivitiesScreen()),
    _Destination(Icons.group, 'Usuarios', UsersScreen()),
  ];

  @override
  void initState() {
    super.initState();
    // Referencia capturada aqui: dispose no puede usar context.read
    // sobre un elemento desmontandose.
    _devices = context.read<DevicesController>();
    // Un unico ciclo de sondeo compartido por todas las pestanas.
    _devices.startPolling();
    // La precarga del perfil (rol) puede fallar por red al arrancar;
    // sin rol la app ocultaria acciones de administracion (p. ej. el
    // boton "Nuevo Medio") para siempre. Al entrar al shell se
    // reintenta una vez si aun no se conoce el usuario.
    final session = context.read<SessionController>();
    if (!session.hasUser) {
      unawaited(session.loadProfile());
    }
  }

  @override
  void dispose() {
    // Evita timers huerfanos al cerrar sesion (el shell se desmonta).
    _devices.stopPolling();
    super.dispose();
  }

  void _onTap(int index) {
    if (index == _currentIndex) return;
    _tabHistory.add(_currentIndex);
    setState(() => _currentIndex = index);
  }

  /// Retroceso del sistema sobre el shell: pestana anterior o, sin
  /// historial, salida de la app.
  void _handleSystemBack() {
    if (_tabHistory.isNotEmpty) {
      setState(() => _currentIndex = _tabHistory.removeLast());
      return;
    }
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    // La quinta pestana existe solo con permiso de gestion de
    // personal. Con cinco elementos la barra prescinde de los textos
    // (solo iconos con tooltip); las cuatro del mediador conservan
    // sus etiquetas sin riesgo de desborde.
    final manageUsers = canManageUsers(context);
    final destinations = manageUsers
        ? _destinations
        : _destinations.sublist(0, _destinations.length - 1);
    // Defensivo ante un cambio de rol con una pestana del admin aun
    // seleccionada: el indice mostrado nunca sale de rango.
    final index = _currentIndex < destinations.length
        ? _currentIndex
        : destinations.length - 1;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleSystemBack();
      },
      child: Scaffold(
        // Fondo que asoma en la franja superior (bajo la barra de
        // estado) y en la franja inferior (sobre la barra de gestos).
        backgroundColor: CauceColors.peachSurface,
        body: Column(
          children: [
            // El contenido empieza bajo la barra de estado del
            // telefono: los encabezados reservan ese inset por si
            // mismos.
            Expanded(
              child: IndexedStack(
                index: index,
                children: [for (final d in destinations) d.screen],
              ),
            ),
            // SafeArea inferior: la barra de navegacion queda por
            // encima de la barra de gestos del sistema (el espacio
            // que antes dejaba la franja de version).
            SafeArea(
              top: false,
              child: _CauceNavBar(
                destinations: destinations,
                showLabels: !manageUsers,
                currentIndex: index,
                onTap: _onTap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pestana del shell: icono, etiqueta y pantalla; el orden de la
/// lista es su indice en la barra.
class _Destination {
  const _Destination(this.icon, this.label, this.screen);

  final IconData icon;
  final String label;
  final Widget screen;
}

class _CauceNavBar extends StatelessWidget {
  const _CauceNavBar({
    required this.destinations,
    required this.showLabels,
    required this.currentIndex,
    required this.onTap,
  });

  /// Pestanas visibles para la sesion: 5 (admin, solo iconos) o 4
  /// (mediador, con texto).
  final List<_Destination> destinations;

  /// false en el modo de 5: la barra muestra solo iconos con tooltip.
  final bool showLabels;

  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CauceColors.cream.withValues(alpha: 0.96),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF261813).withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SizedBox(
        height: 76,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (var i = 0; i < destinations.length; i++)
                _NavItem(
                  icon: destinations[i].icon,
                  label: destinations[i].label,
                  selected: i == currentIndex,
                  showLabel: showLabels,
                  onTap: () => onTap(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    this.showLabel = true,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;

  /// Modo solo iconos (barra de admin, 5 pestanas): sin texto, con
  /// tooltip y con un area tactil mas amplia para conservar la
  /// comodidad de toque que perdia con las etiquetas.
  final bool showLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? CauceColors.peachPrimary : Colors.transparent;
    final fg = selected
        ? Colors.white
        : CauceColors.peachOnSurfaceVariant.withValues(alpha: 0.8);

    Widget pill = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: showLabel
            ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: CauceColors.peachPrimary.withValues(alpha: 0.35),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: showLabel
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 22, color: fg),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: CauceTheme.displayFont,
                      fontSize: 11,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: fg,
                    ),
                  ),
                ],
              )
            : Icon(icon, size: 22, color: fg),
      ),
    );
    // Sin etiqueta, el nombre de la pestana viaja en el tooltip: los
    // cinco iconos siguen identificandose en el modo admin.
    return showLabel ? pill : Tooltip(message: label, child: pill);
  }
}
