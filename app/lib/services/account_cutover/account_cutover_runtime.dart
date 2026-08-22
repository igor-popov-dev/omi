/// Cached cutover control for offline-queue decisions and bootstrap gates.
///
/// LIFECYCLE: permanent
library;

import 'package:flutter/foundation.dart';

import 'package:omi/services/account_cutover/account_cutover_control.dart';
import 'package:omi/services/account_cutover/account_cutover_control_client.dart';
import 'package:omi/services/account_cutover/account_cutover_gate.dart';

class AccountCutoverRuntime extends ChangeNotifier {
  AccountCutoverRuntime._();
  static final AccountCutoverRuntime instance = AccountCutoverRuntime._();

  final AccountCutoverGate _gate = const AccountCutoverGate();
  AccountCutoverControl _control = AccountCutoverControl.legacyDefault();
  bool _hasAuthoritative = false;
  String? _ownerUid;
  int _refreshEpoch = 0;
  bool _resolvedForOwner = true;

  AccountCutoverControl get control => _control;
  bool get hasAuthoritativeControl => _hasAuthoritative;
  String? get ownerUid => _ownerUid;
  bool get isResolvedForOwner => _resolvedForOwner;

  AccountCutoverGateDecision get decision {
    // Owner transitions fail closed until the matching refresh settles so a
    // prior account's allow decision cannot leak into the new session.
    if (!_resolvedForOwner) {
      return AccountCutoverGateDecision.migrationMaintenance;
    }
    return _gate.decide(_control);
  }

  /// Test / bootstrap helper that applies a known-good projection directly.
  void apply(AccountCutoverControl control, {bool authoritative = true}) {
    _control = control;
    _hasAuthoritative = authoritative;
    _resolvedForOwner = true;
    notifyListeners();
  }

  void resetForTesting() {
    _control = AccountCutoverControl.legacyDefault();
    _hasAuthoritative = false;
    _ownerUid = null;
    _refreshEpoch = 0;
    _resolvedForOwner = true;
  }

  /// Bind runtime state to the authenticated owner and refresh control.
  ///
  /// A null/empty [uid] clears to legacy defaults. Owner changes immediately
  /// clear prior-account state and block product traffic until the in-flight
  /// refresh for that owner completes. Stale in-flight results are discarded.
  Future<void> bindAuthenticatedOwner(
    String? uid, {
    AccountCutoverControlClient? client,
  }) async {
    final epoch = ++_refreshEpoch;
    final normalized = (uid == null || uid.isEmpty) ? null : uid;

    if (normalized == null) {
      _ownerUid = null;
      _control = AccountCutoverControl.legacyDefault();
      _hasAuthoritative = false;
      _resolvedForOwner = true;
      notifyListeners();
      return;
    }

    if (normalized != _ownerUid) {
      // Only a genuine switch between two real accounts on this device needs
      // the synchronous fence: it stops account A's stale allow decision
      // from leaking into account B's session while B's fetch is in flight.
      // The very first bind of a fresh runtime (no prior owner in memory,
      // e.g. cold app start) has no prior decision to leak, so leave
      // `_control` at its legacy-compatible default — a transport failure on
      // this bind can then fall back to it in `applyFetchResult` instead of
      // being permanently stuck behind a fence it never needed.
      final isGenuineOwnerSwitch = _ownerUid != null;
      _ownerUid = normalized;
      _hasAuthoritative = false;
      _resolvedForOwner = false;
      if (isGenuineOwnerSwitch) {
        _control = AccountCutoverControl.unavailable();
      }
      notifyListeners();
    }

    final fetchClient = client ?? AccountCutoverControlClient();
    final result = await fetchClient.fetchControl();
    if (epoch != _refreshEpoch || _ownerUid != normalized) {
      return;
    }

    applyFetchResult(result);
    _resolvedForOwner = true;
    notifyListeners();
  }

  /// Refresh for the current owner without clearing state first.
  Future<void> refresh({AccountCutoverControlClient? client}) async {
    final owner = _ownerUid;
    if (owner == null) return;
    await bindAuthenticatedOwner(owner, client: client);
  }

  @visibleForTesting
  void applyFetchResult(AccountCutoverFetchResult result) {
    switch (result.kind) {
      case AccountCutoverFetchKind.success:
        _control = result.control!;
        _hasAuthoritative = true;
        break;
      case AccountCutoverFetchKind.unavailable:
        _control = AccountCutoverControl.unavailable(
          retaining: _hasAuthoritative ? _control : null,
        );
        break;
      case AccountCutoverFetchKind.transportFailure:
        if (_hasAuthoritative) {
          _control = AccountCutoverControl.unavailable(retaining: _control);
        } else if (_gate.decide(_control) == AccountCutoverGateDecision.allowProductTraffic) {
          // No authoritative projection yet (bridge rollout): stay legacy-compatible.
          _control = AccountCutoverControl.legacyDefault();
        }
        // If already blocked (e.g. owner-change unavailable), keep that fence.
        break;
    }
  }

  /// Self-host escape hatch for a stuck fail-closed screen: only takes effect
  /// when the server has NEVER returned an authoritative projection for this
  /// owner (unreachable backend, broken bootstrap fetch). Never overrides a
  /// confirmed migrating/new/rolled_back_stranded state — once a real
  /// projection has been seen, this is a no-op and the fence holds.
  bool skipUnresolvedFence() {
    if (_hasAuthoritative) return false;
    _control = AccountCutoverControl.legacyDefault();
    _resolvedForOwner = true;
    notifyListeners();
    return true;
  }

  bool get allowsOfflineQueueUpload {
    if (!_resolvedForOwner) return false;
    return _gate.shouldUploadOfflineQueues(_control);
  }

  bool get quarantinesOfflineQueues {
    if (!_resolvedForOwner) return true;
    return _gate.shouldQuarantineOfflineQueues(_control);
  }
}
