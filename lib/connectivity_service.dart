import 'package:flutter/foundation.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';

/// Reachability-based online/offline state (probes public hosts by default).
///
/// NOTE: when the real POST /visit/report exists, the source of truth for
/// "syncing vs offline" becomes the uploader's own success/failure; this
/// probe demotes to a hint for when to retry.
class ConnectivityService {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  final _changes = _ConnChanges();
  bool _online = true;

  Listenable get changes => _changes;
  bool get isOnline => _online;

  // App-lifetime singleton; the status subscription lives for the process.
  //
  // Deliberately not awaited and not a Future: subscribing already triggers an
  // immediate check (the package's StreamController.onListen calls
  // _maybeEmitStatusUpdate), so awaiting hasInternetAccess first would only
  // block the first frame — by up to the probe timeout on a flaky network.
  // [_online] starts optimistic and is corrected as soon as that check
  // resolves; a wrong guess just costs one upload attempt that fails and backs
  // off.
  void init() {
    InternetConnection().onStatusChange.listen((status) {
      final online = status == InternetStatus.connected;
      if (online != _online) {
        _online = online;
        _changes.bump();
      }
    });
  }

  /// Drives the online/offline state from a test (the real source is a platform
  /// probe with no injectable stream). Inert in the app — no production code
  /// calls it; [_online] is otherwise set only by [init]'s subscription.
  @visibleForTesting
  void setOnlineForTest(bool value) {
    if (value != _online) {
      _online = value;
      _changes.bump();
    }
  }
}

class _ConnChanges extends ChangeNotifier {
  void bump() => notifyListeners();
}
