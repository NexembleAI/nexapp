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
  Future<void> init() async {
    _online = await InternetConnection().hasInternetAccess;
    InternetConnection().onStatusChange.listen((status) {
      final online = status == InternetStatus.connected;
      if (online != _online) {
        _online = online;
        _changes.bump();
      }
    });
  }
}

class _ConnChanges extends ChangeNotifier {
  void bump() => notifyListeners();
}
