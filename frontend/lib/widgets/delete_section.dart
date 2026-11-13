/// Seccion de eliminacion compartida por los detalles de medio y
/// dispositivo.
///
/// La estetica de todas las zonas de eliminar de la app vive aqui:
/// el aviso de consecuencias sobre fondo de riesgo y el dialogo de
/// confirmacion. Cambios esteticos en las secciones de eliminar se
/// aplican a ambas pantallas al tocar solo este archivo.
library;

import 'package:flutter/material.dart';

import '../core/theme/cauce_colors.dart';
import '../core/theme/cauce_theme.dart';

/// Zona de riesgo: aviso de consecuencias + boton de eliminar.
/// El que dispara es cada pantalla; aqui solo se pinta.
class DeleteSection extends StatelessWidget {
  const DeleteSection({
    super.key,
    required this.warning,
    required this.buttonLabel,
    required this.onDelete,
  });

  /// Texto de advertencia con las consecuencias concretas de esta
  /// pantalla (que se pierde, que no se puede deshacer).
  final String warning;

  /// Etiqueta del boton de eliminar.
  final String buttonLabel;

  /// Abre la confirmacion de borrado. La pantalla decide que hacer
  /// tras confirmar.
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFDAD6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.warning, size: 20, color: CauceColors.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  warning,
                  style: const TextStyle(
                    fontFamily: CauceTheme.bodyFont,
                    fontSize: 13,
                    height: 1.4,
                    color: CauceColors.creamOnSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onDelete,
            style: OutlinedButton.styleFrom(
              foregroundColor: CauceColors.error,
              side: const BorderSide(color: CauceColors.error),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.symmetric(vertical: 10),
            ),
            icon: const Icon(Icons.delete_forever, size: 20),
            label: Text(buttonLabel),
          ),
        ],
      ),
    );
  }
}

/// Dialogo de confirmacion estandar de eliminacion: true solo si el
/// usuario pulsa Eliminar. Cerrar el dialogo por cualquier otra via
/// (Cancelar, atras, tocar fuera) cuenta como no.
Future<bool> showDeleteConfirmation({
  required BuildContext context,
  required String title,
  required String message,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: CauceColors.cream,
      title: Text(title),
      content: Text(
        message,
        style: const TextStyle(
          fontFamily: CauceTheme.bodyFont,
          fontSize: 13,
          height: 1.4,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: FilledButton.styleFrom(backgroundColor: CauceColors.error),
          child: const Text('Eliminar'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
