// Self-host patch, not for upstream: состояние пульта апстрим-синка.
//
// WHY
// ---
// Синк идёт минутами, а запускается одним нажатием. Значит нужно состояние,
// которое переживёт уход с экрана и вернёт правду при возвращении: сервер —
// единственный источник истины (замок ставит сам скрипт), поэтому провайдер не
// хранит собственное представление о ходе прогона, а переспрашивает.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omi/backend/http/api/upstream_sync.dart';
import 'package:omi/utils/logger.dart';

class UpstreamSyncProvider extends ChangeNotifier {
  UpstreamSyncStatus _status = UpstreamSyncStatus.unavailable;
  bool _loaded = false;
  String? _lastError;
  Timer? _poll;

  UpstreamSyncStatus get status => _status;

  /// Первый ответ сервера ещё не пришёл — плашку рисовать рано.
  bool get loaded => _loaded;

  String? get lastError => _lastError;

  /// Плашку показываем только на своём сервере и только когда есть что сказать:
  /// нулевое отставание без активного прогона — это не новость.
  bool get visible {
    if (!_loaded || !_status.available) return false;
    return _status.running || _status.needsAttention || _status.behind > 0 || _status.branch != null;
  }

  Future<void> refresh() async {
    try {
      _status = await getUpstreamSyncStatus();
    } catch (e) {
      Logger.debug('upstream sync refresh: $e');
      _status = UpstreamSyncStatus.unavailable;
    }
    _loaded = true;
    _syncPolling();
    notifyListeners();
  }

  Future<void> run({bool dry = false}) async {
    _lastError = null;
    try {
      _status = await runUpstreamSync(dry: dry);
    } on UpstreamSyncException catch (e) {
      _lastError = e.message;
    } catch (e) {
      _lastError = e.toString();
    }
    _syncPolling();
    notifyListeners();
  }

  Future<bool> land(String branch) async {
    _lastError = null;
    try {
      _status = await landUpstreamSync(branch);
      notifyListeners();
      return true;
    } on UpstreamSyncException catch (e) {
      _lastError = e.message;
    } catch (e) {
      _lastError = e.toString();
    }
    notifyListeners();
    return false;
  }

  Future<String?> report() => getUpstreamSyncReport(stamp: _status.stamp);

  /// Опрашиваем сервер, только пока прогон идёт. Постоянный поллинг ради плашки,
  /// которая меняется раз в сутки, — это трафик и батарея впустую.
  void _syncPolling() {
    if (_status.running && _poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 10), (_) => refresh());
    } else if (!_status.running) {
      _poll?.cancel();
      _poll = null;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _poll = null;
    super.dispose();
  }
}
