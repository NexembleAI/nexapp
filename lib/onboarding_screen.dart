import 'dart:math';

import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'permissions_onboarding.dart';
import 'theme.dart';

/// First-run permission wizard (design screen 03): intro → one page per
/// not-yet-granted permission (with real OS requests + escalation) → done.
class OnboardingScreen extends StatefulWidget {
  final VoidCallback onFinish;
  const OnboardingScreen({super.key, required this.onFinish});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with WidgetsBindingObserver {
  final _controller = PageController();
  final Map<OnboardingPermission, PermissionGrant> _status = {};
  // Steps where we've already shown the in-app "Always" upgrade prompt, so a
  // later tap while still stuck routes to Settings instead of re-prompting.
  final Set<OnboardingPermission> _triedAlways = {};
  List<OnboardingPermission> _permSteps = const [];
  bool _loading = true;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final pending = await PermissionsOnboarding.pendingSteps();
    for (final s in pending) {
      _status[s] = await PermissionsOnboarding.status(s);
    }
    if (!mounted) return;
    setState(() {
      _permSteps = pending;
      _loading = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // After returning from a Settings redirect (e.g. Android background
    // location), re-check the current step and auto-advance if it's now granted.
    if (state == AppLifecycleState.resumed) _recheckCurrent();
  }

  Future<void> _recheckCurrent() async {
    final permIndex = _index - 1;
    if (permIndex < 0 || permIndex >= _permSteps.length) return;
    final step = _permSteps[permIndex];
    final was = _status[step];
    final now = await PermissionsOnboarding.status(step);
    if (!mounted) return;
    setState(() => _status[step] = now);
    if (was != PermissionGrant.granted && now == PermissionGrant.granted) {
      _next();
    }
  }

  void _next() {
    // Total pages = intro + perm steps + completion.
    if (_index < _permSteps.length + 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      widget.onFinish();
    }
  }

  Future<void> _allow(OnboardingPermission step) async {
    // iOS location escalation: the first tap at "while using" shows the in-app
    // "Change to Always?" prompt (a resume re-check advances once granted). If
    // we're still at "while using" when tapped again, route to Settings —
    // covers a declined prompt or a one-time "Allow Once" that can't upgrade.
    final atPartial = _status[step] == PermissionGrant.partial;
    final settingsFallback = atPartial && _triedAlways.contains(step);
    if (atPartial) _triedAlways.add(step);

    final result = await PermissionsOnboarding.request(
      step,
      settingsFallback: settingsFallback,
    );
    if (!mounted) return;
    setState(() => _status[step] = result);
    // Granted → move on. Location "while using" stays put so the next tap
    // triggers the Always upgrade (pill now explains the current state).
    if (result == PermissionGrant.granted) {
      _triedAlways.remove(step);
      _next();
    }
  }

  static ({IconData icon, String title, String body, String allow}) _content(
    AppLocalizations l,
    OnboardingPermission p,
  ) {
    switch (p) {
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
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final permIndex = _index - 1;
    final onPermPage = permIndex >= 0 && permIndex < _permSteps.length;

    final pages = <Widget>[
      _WizardPage(
        illustration: const _Illustration(
          icon: Icons.near_me_rounded,
          gradient: [AppTheme.spectrumIndigo, AppTheme.spectrumBlue],
        ),
        title: l.onboardingIntroTitle,
        body: l.onboardingIntroBody,
        primaryLabel: l.onboardingIntroStart,
        onPrimary: _next,
      ),
      for (final step in _permSteps) _permPage(l, step),
      _WizardPage(
        illustration: const _Illustration(
          icon: Icons.check_rounded,
          gradient: [AppTheme.success, Color(0xFF22C55E)],
          glow: AppTheme.success,
        ),
        title: l.onboardingDoneTitle,
        body: l.onboardingDoneBody,
        primaryLabel: l.onboardingDoneButton,
        onPrimary: widget.onFinish,
      ),
    ];

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 44,
              child: onPermPage
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _ProgressBar(
                            count: _permSteps.length,
                            current: permIndex,
                          ),
                          const Spacer(),
                          Text(
                            l.onboardingStepLabel(
                              permIndex + 1,
                              _permSteps.length,
                            ),
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    )
                  : null,
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (i) => setState(() => _index = i),
                children: pages,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _permPage(AppLocalizations l, OnboardingPermission step) {
    final c = _content(l, step);
    final status = _status[step] ?? PermissionGrant.denied;
    final showPill = step == OnboardingPermission.location &&
        status == PermissionGrant.partial;
    return _WizardPage(
      illustration: _Illustration(icon: c.icon),
      title: c.title,
      body: c.body,
      emphasis: step == OnboardingPermission.location
          ? l.onboardingLocationBodyEmphasis
          : null,
      pill: showPill
          ? _CurrentPill(text: l.onboardingLocationCurrentPartial)
          : null,
      primaryLabel: c.allow,
      onPrimary: () => _allow(step),
      secondaryLabel: l.onboardingNotNow,
      onSecondary: _next,
    );
  }
}

class _WizardPage extends StatelessWidget {
  final Widget illustration;
  final String title;
  final String body;
  final String? emphasis;
  final Widget? pill;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  const _WizardPage({
    required this.illustration,
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimary,
    this.emphasis,
    this.pill,
    this.secondaryLabel,
    this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(
      color: AppTheme.mutedLabel(theme.brightness),
      height: 1.45,
    );
    // Bold an emphasised phrase within the body (e.g. "Always allow"), matching
    // the design; falls back to plain text when the phrase isn't present.
    final e = emphasis;
    final Widget bodyText = (e != null && body.contains(e))
        ? Text.rich(
            TextSpan(
              style: bodyStyle,
              children: [
                TextSpan(text: body.substring(0, body.indexOf(e))),
                TextSpan(
                  text: e,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: body.substring(body.indexOf(e) + e.length)),
              ],
            ),
            textAlign: TextAlign.center,
          )
        : Text(body, textAlign: TextAlign.center, style: bodyStyle);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          const Spacer(flex: 3),
          illustration,
          const SizedBox(height: 34),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 14),
          bodyText,
          const SizedBox(height: 18),
          pill ?? const SizedBox(height: 4),
          const Spacer(flex: 4),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onPrimary,
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
              child: Text(primaryLabel),
            ),
          ),
          const SizedBox(height: 6),
          if (secondaryLabel != null)
            TextButton(
              onPressed: onSecondary,
              child: Text(
                secondaryLabel!,
                style: TextStyle(
                  color: AppTheme.mutedLabel(theme.brightness),
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            const SizedBox(height: 40),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _Illustration extends StatelessWidget {
  final IconData icon;
  final List<Color> gradient;
  final Color? glow;

  const _Illustration({
    required this.icon,
    this.gradient = const [AppTheme.spectrumIndigo, AppTheme.spectrumBlue],
    this.glow,
  });

  @override
  Widget build(BuildContext context) {
    final ring = glow ?? Theme.of(context).colorScheme.primary;
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
                  color: ring.withValues(alpha: 0.22),
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
              painter: _DashedRingPainter(ring.withValues(alpha: 0.55)),
            ),
          ),
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradient,
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
