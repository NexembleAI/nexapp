import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'auth_service.dart';
import 'nexemble_reveal.dart' show kNexembleBlue, kNexembleCubeSvg;

/// Sign-in screen. Launches Keycloak (OIDC Authorization Code + PKCE) in the
/// system browser; on success [AuthService.authState] flips and the auth gate
/// swaps to the app, so no manual navigation is needed here.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
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
      if (mounted) {
        setState(() => _error = _humanError(e));
      }
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
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SvgPicture.string(kNexembleCubeSvg, width: 96, height: 96),
              const SizedBox(height: 28),
              const Text(
                'Nexapp',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: kNexembleBlue),
              ),
              const SizedBox(height: 8),
              Text(
                'Sign in with your Nexemble account to continue.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 36),
              FilledButton(
                onPressed: _busy ? null : _signIn,
                style: FilledButton.styleFrom(
                  backgroundColor: kNexembleBlue,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _busy
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                      )
                    : const Text('Sign in', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.red.shade700, fontSize: 13),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
