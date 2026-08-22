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
  AccountCutoverControl? _lastAuthoritativeControl;
  String? _ownerUid;
  int _refreshEpoch = 0;
  bool _resolvedForOwner = true;

  AccountCutoverControl get control => _control;
  bool get hasAuthoritativeControl => _hasAuthoritative;
  String? get ownerUid => _ownerUid;
  bool get isResolvedForOwner => _resolvedForOwner;

  /// True only when the latest AUTHORITATIVE server projection itself decides
  /// a fence. A fence synthesized from unavailability (503, timeouts, an
  /// in-flight owner refresh) is NOT confirmed: it still fails closed, but the
  /// user keeps an escape hatch and the blocking screen keeps retrying.
  ///
  /// This is the distinction the old `hasAuthoritativeControl` gate got wrong:
  /// after one successful "legacy/allow" fetch, a single blown refresh
  /// (transport blip, control-plane 503) produced a maintenance fence with no
  /// exit at all — the server never actually said "migrating", but the skip
  /// button was hidden because SOME authoritative projection had been seen.
  bool get fenceIsConfirmedByServer {
    final last = _lastAuthoritativeControl;
    if (last == null) return false;
    return _gate.decide(last) != AccountCutoverGateDecision.allowProductTraffic;
  }

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
    if (authoritative) {
      _lastAuthoritativeControl = control;
    }
    _resolvedForOwner = true;
    notifyListeners();
  }

  void resetForTesting() {
    _control = AccountCutoverControl.legacyDefault();
    _hasAuthoritative = false;
    _lastAuthoritativeControl = null;
    _ownerUid = null;
    _refreshEpoch = 0;
    _resolvedForOwner = true;
  }

  /// Bind runtime state to the authenticated owner and refresh control.
  ///
  /// A null/empty [uid] clears to legacy defaults. Owner changes immediately
  /// clear prior-account state and block product traffic until the in-flight
  /// refresh for that owner completes. Stale in-flight results are discarded.
  Future<void> bindAuthenticatedOwner(String? uid, {AccountCutoverControlClient? client}) async {
    final epoch = ++_refreshEpoch;
    final normalized = (uid == null || uid.isEmpty) ? null : uid;

    if (normalized == null) {
      _ownerUid = null;
      _control = AccountCutoverControl.legacyDefault();
      _hasAuthoritative = false;
      _lastAuthoritativeControl = null;
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
      // The prior owner's projection must not survive an owner change in any
      // form — including as the "last known good" a skip could restore.
      _lastAuthoritativeControl = null;
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
    final lastAuth = _lastAuthoritativeControl;
    final lastAuthAllows = lastAuth != null && _gate.decide(lastAuth) == AccountCutoverGateDecision.allowProductTraffic;
    switch (result.kind) {
      case AccountCutoverFetchKind.success:
        _control = result.control!;
        _hasAuthoritative = true;
        _lastAuthoritativeControl = result.control;
        break;
      case AccountCutoverFetchKind.unavailable:
        // The server explicitly failed closed — respect it and fence. When the
        // last authoritative word was "allow", the fence is unconfirmed: the
        // blocking screen offers skip and keeps retrying (see
        // fenceIsConfirmedByServer).
        _control = AccountCutoverControl.unavailable(retaining: _hasAuthoritative ? _control : null);
        break;
      case AccountCutoverFetchKind.transportFailure:
        if (lastAuthAllows) {
          // The control plane is unreachable, but its last authoritative word
          // for this owner was "allow". A transport blip is not evidence of a
          // migration — stay on the last-known-good projection instead of
          // synthesizing a maintenance fence with no exit. (Live incident:
          // one timed-out refresh over a PMTU-black-holed VPN threw the app
          // into a permanent fence while the server kept answering
          // legacy/none.)
          _control = lastAuth;
        } else if (_hasAuthoritative) {
          // Last authoritative state was itself a fence (migrating/new/...):
          // keep failing closed across the outage.
          _control = AccountCutoverControl.unavailable(retaining: _control);
        } else if (_gate.decide(_control) == AccountCutoverGateDecision.allowProductTraffic) {
          // No authoritative projection yet (bridge rollout): stay legacy-compatible.
          _control = AccountCutoverControl.legacyDefault();
        }
        // If already blocked (e.g. owner-change unavailable), keep that fence.
        break;
    }
  }

  /// Self-host escape hatch for a stuck fail-closed screen: takes effect only
  /// while the fence is UNCONFIRMED — the server has never authoritatively
  /// decided a fence for this owner (unreachable backend, broken bootstrap
  /// fetch, or a blown refresh after the server last said "allow"). Never
  /// overrides a confirmed migrating/new/rolled_back_stranded state — once
  /// the server itself has fenced, this is a no-op and the fence holds.
  bool skipUnresolvedFence() {
    if (fenceIsConfirmedByServer) return false;
    _control = _lastAuthoritativeControl ?? AccountCutoverControl.legacyDefault();
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
