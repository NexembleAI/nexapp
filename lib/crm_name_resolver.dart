import 'dart:developer' as developer;

import 'tracking_api_client.dart';

/// Result of a name resolution: id → display name, split by entity type
/// (customer and lead id-spaces are distinct, so they never share a map).
/// An id absent from a map = unresolved; the caller shows a fallback
/// (e.g. "Unnamed customer").
class CrmNames {
  final Map<String, String> customers;
  final Map<String, String> leads;
  const CrmNames({this.customers = const {}, this.leads = const {}});

  String? customer(String id) => customers[id];
  String? lead(String id) => leads[id];
}

/// Resolves Odoo customer/lead ids to display names via `tracking/crm/names`,
/// with a client cache so re-renders don't re-hit the network (the server also
/// caches ~5 min). Degrades gracefully: the resolver is OFF by default on the
/// backend (returns Unavailable), and unknown ids are silently omitted — either
/// way the affected id is simply absent from the result. Never throws.
class CrmNameResolver {
  CrmNameResolver._();
  static final CrmNameResolver instance = CrmNameResolver._();

  static const int _maxPerCall = 500; // combined customer + lead cap
  static const Duration _ttl = Duration(minutes: 5); // match the server cache
  // After an Unavailable (resolver disabled), stop firing doomed calls for a
  // cooldown so a Home refresh doesn't hit crm/names every time; still recovers
  // once the resolver is enabled server-side.
  static const Duration _cooldown = Duration(minutes: 2);

  final Map<String, _Entry> _customers = {};
  final Map<String, _Entry> _leads = {};
  DateTime? _mutedUntil;

  /// Convenience for Home (customers only).
  Future<Map<String, String>> customerNames(Iterable<String> ids) async =>
      (await resolve(customerIds: ids)).customers;

  /// Drops all cached names on sign-out. Names are tenant-scoped (correct across
  /// users of the same tenant), so this is defensive — a no-cost reset that also
  /// covers a future multi-tenant sign-in. An in-flight fetch is harmless (same
  /// tenant → same names), so no generation guard is needed.
  void clear() {
    _customers.clear();
    _leads.clear();
    _mutedUntil = null;
  }

  /// Resolve any mix of customer and lead ids. Cached hits return immediately;
  /// misses are fetched (batched, deduped) unless we're in the post-Unavailable
  /// cooldown. Unresolvable ids are just omitted from the result.
  Future<CrmNames> resolve({
    Iterable<String> customerIds = const [],
    Iterable<String> leadIds = const [],
  }) async {
    final now = DateTime.now();
    final custOut = <String, String>{};
    final leadOut = <String, String>{};
    final needCust = <String>[];
    final needLead = <String>[];
    _partition(customerIds, _customers, now, needCust, custOut);
    _partition(leadIds, _leads, now, needLead, leadOut);

    final canFetch = (needCust.isNotEmpty || needLead.isNotEmpty) &&
        (_mutedUntil == null || now.isAfter(_mutedUntil!));
    if (canFetch) {
      await _chunkAndFetch(needCust, needLead, now);
      _collect(needCust, _customers, custOut); // read back what we just cached
      _collect(needLead, _leads, leadOut);
    }
    return CrmNames(customers: custOut, leads: leadOut);
  }

  /// Split requested ids into cache-satisfied ([out]) vs to-fetch ([need]).
  void _partition(Iterable<String> ids, Map<String, _Entry> cache, DateTime now,
      List<String> need, Map<String, String> out) {
    for (final id in ids.toSet()) {
      if (id.isEmpty) continue;
      final e = cache[id];
      if (e != null && e.fresh(now)) {
        if (e.name != null) out[id] = e.name!; // fresh positive hit
        // fresh negative (known-unknown) -> intentionally omitted
      } else {
        need.add(id);
      }
    }
  }

  void _collect(
      List<String> ids, Map<String, _Entry> cache, Map<String, String> out) {
    for (final id in ids) {
      final name = cache[id]?.name;
      if (name != null) out[id] = name;
    }
  }

  /// Fetch the needed ids in batches of <= [_maxPerCall] combined. Stops early
  /// if a call fails (the cooldown/absence is handled in [_fetchOne]).
  Future<void> _chunkAndFetch(
      List<String> needCust, List<String> needLead, DateTime now) async {
    var ci = 0, li = 0;
    while (ci < needCust.length || li < needLead.length) {
      final custChunk = <String>[];
      final leadChunk = <String>[];
      while (custChunk.length + leadChunk.length < _maxPerCall &&
          ci < needCust.length) {
        custChunk.add(needCust[ci++]);
      }
      while (custChunk.length + leadChunk.length < _maxPerCall &&
          li < needLead.length) {
        leadChunk.add(needLead[li++]);
      }
      final ok = await _fetchOne(custChunk, leadChunk, now);
      if (!ok) break; // resolver off / error - don't hammer the rest
    }
  }

  /// One GET. On success, positive-cache resolved names and negative-cache the
  /// requested ids the server omitted. Returns false (and arms the cooldown on
  /// Unavailable) so the caller stops; never throws.
  Future<bool> _fetchOne(
      List<String> custIds, List<String> leadIds, DateTime now) async {
    try {
      final raw = await TrackingApiClient.instance.get('crm/names', query: {
        if (custIds.isNotEmpty) 'customerIds': custIds,
        if (leadIds.isNotEmpty) 'leadIds': leadIds,
      });
      final j = (raw is Map) ? raw.cast<String, dynamic>() : const {};
      _merge(_customers, custIds, j['customers'], now);
      _merge(_leads, leadIds, j['leads'], now);
      return true;
    } catch (e) {
      // Catch-all: names are best-effort, so NOTHING here may escape and fail
      // the caller's Home refresh (a malformed body / parse error would too,
      // not just an ApiException). Only Unavailable (resolver off) arms the
      // cooldown; other errors just degrade to ids and retry next time.
      if (e is ApiException && e.kind == ApiErrorKind.unavailable) {
        _mutedUntil = now.add(_cooldown);
      }
      developer.log('CrmNameResolver: resolve failed ($e) - showing ids');
      return false;
    }
  }

  /// Cache the {id,name} pairs from a response array, then negative-cache any
  /// requested id the server didn't return (genuinely unknown, per the API).
  void _merge(Map<String, _Entry> cache, List<String> requested, Object? arr,
      DateTime now) {
    final resolved = <String>{};
    if (arr is List) {
      for (final item in arr) {
        if (item is Map) {
          final id = (item['id'] ?? '').toString();
          final name = (item['name'] ?? '').toString();
          if (id.isNotEmpty && name.isNotEmpty) {
            cache[id] = _Entry(name, now);
            resolved.add(id);
          }
        }
      }
    }
    for (final id in requested) {
      if (!resolved.contains(id)) cache[id] = _Entry(null, now);
    }
  }
}

class _Entry {
  final String? name; // null = negative cache (resolved-as-unknown)
  final DateTime at;
  const _Entry(this.name, this.at);
  bool fresh(DateTime now) => now.difference(at) < CrmNameResolver._ttl;
}
