import 'package:flutter/material.dart';

/// First letters of the first two words, uppercased ("Meridian Logistics"
/// -> "ML").
String initialsOf(String name) => name
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .take(2)
    .map((w) => w[0].toUpperCase())
    .join();

/// Rounded-square tinted initials avatar used by list rows (Home visits,
/// Reports history). [color] drives both tint and letters — primary normally,
/// amber for queued report cards.
class EntityAvatar extends StatelessWidget {
  final String name;
  final Color color;

  const EntityAvatar({super.key, required this.name, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Text(
        initialsOf(name),
        style:
            TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13),
      ),
    );
  }
}
