/// Screensaver clásico estilo DVD: el logo de CAUCE recorre la pantalla
/// en línea recta, rebota en los bordes y cambia de color en cada rebote.
///
/// Es el comportamiento por defecto del cliente cuando el servidor no
/// tiene ningún contenido asignado: no usa red ni video, solo el logo
/// local (`assets/logo.png`).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

class DvdScreensaver extends StatefulWidget {
  const DvdScreensaver({
    super.key,
    this.logoAsset = 'assets/logo.png',
    this.logoWidthFactor = 0.2,
  });

  /// Asset del logo (blanco/monocromo: se tinta con [BlendMode.srcIn]).
  final String logoAsset;

  /// Ancho del logo como fracción del ancho de la pantalla.
  final double logoWidthFactor;

  @override
  State<DvdScreensaver> createState() => _DvdScreensaverState();
}

class _DvdScreensaverState extends State<DvdScreensaver>
    with SingleTickerProviderStateMixin {
  // Velocidades en px/s, distintas en cada eje para que el recorrido no
  // cierre un patrón simple.
  static const double _vx = 240;
  static const double _vy = 170;

  // Aspect del asset (276x259).
  static const double _logoAspect = 276 / 259;

  // El logo se tinta en cada rebote (estilo DVD clásico).
  static const List<Color> _palette = [
    Colors.white,
    Color(0xFF1565C0),
    Color(0xFFE53935),
    Color(0xFF43A047),
    Color(0xFFFB8C00),
    Color(0xFF8E24AA),
    Color(0xFF00ACC1),
  ];

  late final AnimationController _tick;

  @override
  void initState() {
    super.initState();
    // Duración arbitraria muy larga: la posición se deriva del tiempo
    // transcurrido, así que no hay deriva acumulada entre frames.
    _tick = AnimationController(
      vsync: this,
      duration: const Duration(hours: 1),
    )..addListener(() => setState(() {}))..repeat();
  }

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  /// Onda triangular: recorre [0, range] y regresa, en bucle infinito.
  static double _bounce(double t, double range) {
    if (range <= 0) return 0;
    final period = 2 * range;
    final m = t % period;
    return m <= range ? m : period - m;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final logoW = (w * widget.logoWidthFactor).clamp(60.0, w);
        final logoH = logoW / _logoAspect;
        final rangeX = math.max(0.0, w - logoW);
        final rangeY = math.max(0.0, h - logoH);

        final elapsed =
            (_tick.lastElapsedDuration ?? Duration.zero).inMicroseconds / 1e6;
        final x = _bounce(elapsed * _vx, rangeX);
        final y = _bounce(elapsed * _vy, rangeY);
        // Un rebote por cada vez que la onda triangular toca un borde.
        final bounces = (elapsed * _vx / (rangeX == 0 ? 1 : rangeX)).floor() +
            (elapsed * _vy / (rangeY == 0 ? 1 : rangeY)).floor();
        final color = _palette[bounces.abs() % _palette.length];

        return ColoredBox(
          color: Colors.black,
          child: Stack(
            children: [
              Positioned(
                left: x,
                top: y,
                child: ColorFiltered(
                  colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                  child: Image.asset(widget.logoAsset, width: logoW),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
