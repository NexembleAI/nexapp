import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'auth_service.dart';
import 'entity_avatar.dart';
import 'l10n/app_localizations.dart';
import 'theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  String? _name;
  String? _email;
  String _initials = '';
  bool _locationAlways = false;
  bool _notificationsGranted = false;
  bool _batteryOk = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadUser();
    _loadPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check after the user returns from OS settings / a system dialog.
    if (state == AppLifecycleState.resumed) _loadPermissions();
  }

  Future<void> _loadUser() async {
    final claims = await AuthService.instance.idTokenClaims();
    if (!mounted || claims == null) return;
    String? clean(Object? v) {
      final s = (v as String?)?.trim();
      return (s == null || s.isEmpty) ? null : s;
    }

    final name = clean(claims['name']);
    final email = clean(claims['email']);
    final username = clean(claims['preferred_username']);
    setState(() {
      _name = name ?? username;
      _email = email ?? username;
      _initials = initialsOf(name ?? _name ?? '?');
    });
  }

  Future<void> _loadPermissions() async {
    final loc = await Geolocator.checkPermission();
    final notif = await Permission.notification.isGranted;
    final battery = Platform.isAndroid
        ? await Permission.ignoreBatteryOptimizations.isGranted
        : true;
    if (!mounted) return;
    setState(() {
      // Continuous background tracking needs Always — whileInUse is not enough.
      _locationAlways = loc == LocationPermission.always;
      _notificationsGranted = notif;
      _batteryOk = battery;
    });
  }

  Future<void> _fixLocation() async {
    var p = await Geolocator.checkPermission();
    // Request in-app first — this shows the OS prompt, including iOS's
    // "Change to Always Allow?" upgrade when currently whileInUse. Only fall
    // back to the app settings page if the OS won't (re-)prompt.
    if (p == LocationPermission.denied ||
        p == LocationPermission.whileInUse) {
      p = await Geolocator.requestPermission();
    }
    if (p != LocationPermission.always) await Geolocator.openAppSettings();
  }

  Future<void> _fixNotifications() async {
    // request() shows the OS dialog on Android 13+/iOS first-time; on older
    // Android (no runtime permission) or once decided it returns without a
    // dialog, so fall back to the app settings page whenever it's not granted.
    final s = await Permission.notification.request();
    if (!s.isGranted) await openAppSettings();
  }

  Future<void> _fixBattery() => Permission.ignoreBatteryOptimizations.request();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    Widget sectionLabel(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: AppTheme.mutedLabel(theme.brightness),
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _AccountCard(
            name: _name ?? '',
            email: _email ?? '',
            initials: _initials,
            onSignOut: () => AuthService.instance.logout(),
          ),
          const SizedBox(height: 20),
          sectionLabel(l.permissionsReliabilityLabel),
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _PermissionRow(
                  icon: Icons.location_on_outlined,
                  title: l.permissionLocationTitle,
                  subtitle: l.permissionLocationSubtitle,
                  granted: _locationAlways,
                  onFix: _fixLocation,
                ),
                const Divider(height: 1, indent: 54),
                _PermissionRow(
                  icon: Icons.notifications_outlined,
                  title: l.permissionNotificationsTitle,
                  subtitle: l.permissionNotificationsSubtitle,
                  granted: _notificationsGranted,
                  onFix: _fixNotifications,
                ),
                if (Platform.isAndroid) ...[
                  const Divider(height: 1, indent: 54),
                  _PermissionRow(
                    icon: Icons.battery_saver_outlined,
                    title: l.permissionBatteryTitle,
                    subtitle: l.permissionBatterySubtitle,
                    granted: _batteryOk,
                    onFix: _fixBattery,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  final String name;
  final String email;
  final String initials;
  final VoidCallback onSignOut;

  const _AccountCard({
    required this.name,
    required this.email,
    required this.initials,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
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
                  fontSize: 15,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    email,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: onSignOut,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.recording,
                side: BorderSide(
                  color: AppTheme.recording.withValues(alpha: 0.5),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.controlRadius),
                ),
              ),
              child: Text(l.signOutButton),
            ),
          ],
        ),
      ),
    );
  }
}

/// One permission row: green "Granted" when ok, else an amber-tinted row with
/// a "Fix" button.
class _PermissionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool granted;
  final Future<void> Function() onFix;

  const _PermissionRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.granted,
    required this.onFix,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final accent = granted ? AppTheme.success : AppTheme.warning;
    return Container(
      color: granted ? null : AppTheme.warning.withValues(alpha: 0.10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(
            icon,
            size: 22,
            color: granted ? theme.colorScheme.onSurfaceVariant : accent,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (granted)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.success.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check, size: 13, color: AppTheme.success),
                  const SizedBox(width: 4),
                  Text(
                    l.grantedChip,
                    style: const TextStyle(
                      color: AppTheme.success,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            )
          else
            FilledButton(
              onPressed: onFix,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.warning,
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: Text(l.fixButton),
            ),
        ],
      ),
    );
  }
}
