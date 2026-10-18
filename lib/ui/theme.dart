import 'package:flutter/material.dart';

const kSosRed = Color(0xFFD32F2F);

ThemeData buildTheme(Brightness b) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF00897B),
    brightness: b,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    ),
  );
}

/// Stable colour per node id, for avatars.
Color colorForId(String id, Brightness b) {
  final h = int.parse(id.substring(0, 4), radix: 16) % 360;
  return HSLColor.fromAHSL(1, h.toDouble(), 0.45, b == Brightness.dark ? 0.45 : 0.55)
      .toColor();
}

String timeLabel(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  final now = DateTime.now();
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return '$hh:$mm';
  }
  return '${d.day}/${d.month} $hh:$mm';
}
