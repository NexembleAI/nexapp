import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'auth_service.dart';
import 'nexemble_reveal.dart' show kNexembleCubeSvg;
import 'theme.dart';

/// Sign-in screen. Launches Keycloak (OIDC Authorization Code + PKCE) in the
/// system browser; on success [AuthService.authState] flips and the auth gate
/// swaps to the app, so no manual navigation is needed here.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  static const _version = 'v10.0.0';

  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AuthService.instance.login();
      // Success: the auth gate rebuilds via authState; nothing to do here.
    } catch (e) {
      if (mounted) setState(() => _error = _humanError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _humanError(Object e) {
    final s = e.toString();
    if (s.contains('cancel')) return 'Sign-in was cancelled.';
    return 'Sign-in failed. Please check your connection and try again.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = AppTheme.mutedLabel(theme.brightness);
    final primary = theme.colorScheme.primary;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(flex: 3),
              Center(
                child: Container(
                  width: 88,
                  height: 88,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        AppTheme.spectrumMagenta,
                        AppTheme.spectrumIndigo,
                        AppTheme.spectrumBlue,
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.spectrumIndigo.withValues(alpha: 0.35),
                        blurRadius: 28,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: SvgPicture.string(
                    kNexembleCubeSvg,
                    width: 44,
                    height: 44,
                    colorFilter: const ColorFilter.mode(
                      Colors.white,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 22),
              Text(
                'Nexapp',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'BY NEXEMBLE',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                  color: muted,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Boost your productivity and never miss a deadline.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: muted,
                  height: 1.4,
                ),
              ),
              const Spacer(flex: 3),
              if (_error != null) ...[
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
                ),
                const SizedBox(height: 14),
              ],
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: [
                    BoxShadow(
                      color: primary.withValues(alpha: 0.35),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: FilledButton(
                  onPressed: _busy ? null : _signIn,
                  style: FilledButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26),
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Colors.white,
                          ),
                        )
                      : const Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.lock_outline, size: 18),
                            SizedBox(width: 8),
                            Text(
                              'Sign in with Nexemble',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline, size: 13, color: muted),
                  const SizedBox(width: 6),
                  Text(
                    'Single sign-on via Microsoft 365',
                    style: TextStyle(fontSize: 12.5, color: muted),
                  ),
                ],
              ),
              const Spacer(flex: 1),
              _FooterBar(version: _version, muted: muted),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

/// Version + inactive Support/Privacy links (wired later).
class _FooterBar extends StatelessWidget {
  final String version;
  final Color muted;
  const _FooterBar({required this.version, required this.muted});

  @override
  Widget build(BuildContext context) {
    Text dot() => Text('  ·  ', style: TextStyle(fontSize: 12, color: muted));
    Text link(String t) => Text(
      t,
      style: TextStyle(
        fontSize: 12,
        color: muted,
        decoration: TextDecoration.underline,
      ),
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(version, style: TextStyle(fontSize: 12, color: muted)),
        dot(),
        link('Support'),
        dot(),
        link('Privacy'),
      ],
    );
  }
}
