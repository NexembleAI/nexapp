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
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
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

/// Spectrum-gradient initials avatar (design: brand accent on avatars).
class _Avatar extends StatelessWidget {
  final String initials;

  const _Avatar({required this.initials});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [
            AppTheme.spectrumMagenta,
            AppTheme.spectrumIndigo,
            AppTheme.spectrumBlue,
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    );
  }
}
