import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'auth_service.dart';
import 'l10n/app_localizations.dart';
import 'theme.dart';
import 'today_stats_row.dart';
import 'today_visits_list.dart';
import 'tracking_card.dart';

/// Home tab (design screen 04): header (date, greeting, avatar), hero
/// tracking card, today stats, visits list, and the file-a-report action.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _firstName;
  String _initials = '';

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  /// Display name from the ID-token claims: given_name, else the first word
  /// of name, else preferred_username. Initials from the full name.
  Future<void> _loadUser() async {
    final claims = await AuthService.instance.idTokenClaims();
    if (!mounted || claims == null) return;
    String? clean(Object? v) {
      final s = (v as String?)?.trim();
      return (s == null || s.isEmpty) ? null : s;
    }

    final name = clean(claims['name']);
    final given = clean(claims['given_name']);
    final username = clean(claims['preferred_username']);
    final display = given ?? name?.split(' ').first ?? username;
    final initialsSource = name ?? display ?? '';
    final initials = initialsSource
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    setState(() {
      _firstName = display;
      _initials = initials;
    });
  }

  String _greeting(AppLocalizations l) {
    final hour = DateTime.now().hour;
    if (hour < 12) return l.homeGreetingMorning;
    if (hour < 17) return l.homeGreetingAfternoon;
    return l.homeGreetingEvening;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toString();
    final date = DateFormat('EEEE, MMMM d', locale).format(DateTime.now());
    final greeting = _firstName == null
        ? _greeting(l)
        : '${_greeting(l)}, $_firstName';

    return Scaffold(
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              elevation: 3,
              shadowColor: theme.colorScheme.shadow,
            ),
            onPressed: () {
              // Opens the visit-capture screen (design screen 05) once built.
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l.comingSoonMessage),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            icon: const Icon(Icons.add),
            label: Text(l.fileVisitReport),
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          // Extra bottom inset so the last row scrolls clear of the button.
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            Text(
              date,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Expanded(
                  child: Text(
                    greeting,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _Avatar(initials: _initials),
              ],
            ),
            const SizedBox(height: 16),
            const TrackingCard(),
            const SizedBox(height: 16),
            const TodayStatsRow(),
            const SizedBox(height: 20),
            const TodayVisitsList(),
          ],
        ),
      ),
    );
  }
}

/// Header initials avatar: primary-tint circle with flat primary initials
/// (measured from the home mockups: letters #356EDE light / #3B82F6 dark —
/// the spectrum-gradient avatar style belongs to the Settings account card).
class _Avatar extends StatelessWidget {
  final String initials;

  const _Avatar({required this.initials});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppTheme.primary.withValues(alpha: 0.18),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          // Lighter blue in dark mode for contrast against the dark tint.
          color: dark ? const Color(0xFF3B82F6) : AppTheme.primary,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    );
  }
}
