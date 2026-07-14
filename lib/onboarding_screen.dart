import 'dart:math';

import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'permissions_onboarding.dart';
import 'theme.dart';

/// First-run permission wizard (design screen 03). A paged walk-through of the
/// platform's applicable permissions. Request semantics are stubbed in this
/// step — "Allow"/"Not now" simply advance; real OS requests land next.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onFinish;
  const OnboardingScreen({super.key, required this.onFinish});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  final List<OnboardingPermission> _steps = PermissionsOnboarding.steps;
  final Map<OnboardingPermission, PermissionGrant> _status = {};
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    for (final s in _steps) {
      _status[s] = await PermissionsOnboarding.status(s);
    }
    if (mounted) setState(() {});
  }

  void _next() {
    if (_index < _steps.length - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      widget.onFinish();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ProgressBar(count: _steps.length, current: _index),
                  const Spacer(),
                  Text(
                    l.onboardingStepLabel(_index + 1, _steps.length),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _index = i),
                children: [
                  for (final p in _steps)
                    _PermissionPage(
                      permission: p,
                      status: _status[p] ?? PermissionGrant.denied,
                      onAllow: _next,
                      onSkip: _next,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionPage extends StatelessWidget {
  final OnboardingPermission permission;
  final PermissionGrant status;
  final VoidCallback onAllow;
  final VoidCallback onSkip;

  const _PermissionPage({
    required this.permission,
    required this.status,
    required this.onAllow,
    required this.onSkip,
  });

  ({IconData icon, String title, String body, String allow}) _content(
    AppLocalizations l,
  ) {
    switch (permission) {
      case OnboardingPermission.location:
        return (
          icon: Icons.location_on,
          title: l.onboardingLocationTitle,
          body: l.onboardingLocationBody,
          allow: l.onboardingLocationAllow,
        );
      case OnboardingPermission.notifications:
        return (
          icon: Icons.notifications,
          title: l.onboardingNotificationsTitle,
          body: l.onboardingNotificationsBody,
          allow: l.onboardingNotificationsAllow,
        );
      case OnboardingPermission.battery:
        return (
          icon: Icons.battery_charging_full,
          title: l.onboardingBatteryTitle,
          body: l.onboardingBatteryBody,
          allow: l.onboardingBatteryAllow,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final c = _content(l);
    // Only the location step surfaces a "current state" pill, and only when the
    // user is stuck at while-using (matches the mock). Refined next step.
    final showPill = permission == OnboardingPermission.location &&
        status == PermissionGrant.partial;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          const Spacer(flex: 3),
          _Illustration(icon: c.icon),
          const SizedBox(height: 34),
          Text(
            c.title,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            c.body,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppTheme.mutedLabel(theme.brightness),
              height: 1.45,
            ),
          ),
          const SizedBox(height: 18),
          if (showPill)
            _CurrentPill(text: l.onboardingLocationCurrentPartial)
          else
            const SizedBox(height: 4),
          const Spacer(flex: 4),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onAllow,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
                textStyle: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              child: Text(c.allow),
            ),
          ),
          const SizedBox(height: 6),
          TextButton(
            onPressed: onSkip,
            child: Text(
              l.onboardingNotNow,
              style: TextStyle(
                color: AppTheme.mutedLabel(theme.brightness),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _Illustration extends StatelessWidget {
  final IconData icon;
  const _Illustration({required this.icon});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox(
      width: 150,
      height: 150,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 132,
            height: 132,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: primary.withValues(alpha: 0.22),
                  blurRadius: 32,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
          SizedBox(
            width: 132,
            height: 132,
            child: CustomPaint(
              painter: _DashedRingPainter(primary.withValues(alpha: 0.55)),
            ),
          ),
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppTheme.spectrumIndigo, AppTheme.spectrumBlue],
              ),
            ),
            child: Icon(icon, color: Colors.white, size: 44),
          ),
        ],
      ),
    );
  }
}

class _DashedRingPainter extends CustomPainter {
  final Color color;
  _DashedRingPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    final r = size.width / 2;
    final center = Offset(r, r);
    const dash = 3.5, gap = 5.5;
    final sweep = dash / r, gapAngle = gap / r;
    final count = (2 * pi / (sweep + gapAngle)).floor();
    var a = -pi / 2;
    for (var i = 0; i < count; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r),
        a,
        sweep,
        false,
        paint,
      );
      a += sweep + gapAngle;
    }
  }

  @override
  bool shouldRepaint(_DashedRingPainter old) => old.color != color;
}

class _CurrentPill extends StatelessWidget {
  final String text;
  const _CurrentPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 16, color: AppTheme.warning),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.warning,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final int count;
  final int current;
  const _ProgressBar({required this.count, required this.current});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            margin: const EdgeInsets.only(right: 6),
            height: 6,
            width: i == current ? 22 : 8,
            decoration: BoxDecoration(
              color: i == current
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}
