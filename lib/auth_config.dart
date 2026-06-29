/// OIDC / Keycloak configuration.
///
/// [nexCoreUrl] is the only deployment knob and is **not exposed in the UI** —
/// it is injected at build time via `--dart-define=NEX_CORE_URL=...` and
/// defaults to the local environment. The Keycloak issuer is always
/// `NEX_CORE_URL + /idp/realms/default`.
class AuthConfig {
  AuthConfig._();

  /// Base URL of NexCore (reverse proxy in front of Keycloak + platform APIs).
  /// Override with `--dart-define=NEX_CORE_URL=https://...`.
  static const String nexCoreUrl =
      String.fromEnvironment('NEX_CORE_URL', defaultValue: 'https://app.nexemble.local');

  /// Public OIDC client registered in the `default` realm.
  static const String clientId =
      String.fromEnvironment('NEX_CLIENT_ID', defaultValue: 'mobile-app');

  /// Custom-scheme redirect captured by Custom Tabs (Android) /
  /// ASWebAuthenticationSession (iOS). Must be registered as a valid redirect
  /// URI on the Keycloak client. Scheme = the app id.
  static const String redirectUrl = 'com.nexemble.nexapp:/callback';

  static const List<String> scopes = ['openid', 'profile', 'email'];

  /// Keycloak realm issuer; OIDC endpoints are discovered from its
  /// `.well-known/openid-configuration`.
  static String get issuer => '$nexCoreUrl/idp/realms/default';
}
