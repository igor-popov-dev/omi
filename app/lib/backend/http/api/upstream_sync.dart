// Self-host patch, not for upstream: клиент пульта апстрим-синка.
//
// WHY
// ---
// Форк живёт рядом с очень быстрым upstream, и отставание дорожает нелинейно:
// каждая полоса разработки при вливании в `private` получает тем больше
// конфликтов, чем дольше не синкались. Напоминание должно быть там, где человек
// бывает каждый день, — то есть на главном экране приложения.
//
// Роуты живут в `backend/routers/selfhost_upstream_sync.py` и есть только на
// своём сервере. На чужом бэкенде они отвечают 503/404 — это не ошибка, а
// «здесь не настроено», и клиент обязан отличать одно от другого.
import 'dart:convert';

import 'package:omi/backend/http/shared.dart';
import 'package:omi/env/env.dart';
import 'package:omi/utils/logger.dart';

/// Один файл, который ждёт разбора человеком.
class UpstreamSyncConflict {
  final String file;
  final int hunks;

  /// Конфликт с нашим же PR, который upstream уже вмержил. Самый частый и самый
  /// дешёвый класс: решается «взять upstream и вернуть приватные надстройки».
  final bool oursUpstream;

  const UpstreamSyncConflict({required this.file, required this.hunks, required this.oursUpstream});

  factory UpstreamSyncConflict.fromJson(Map<String, dynamic> json) => UpstreamSyncConflict(
        file: (json['file'] ?? '') as String,
        hunks: (json['hunks'] ?? 0) as int,
        oursUpstream: (json['ours_upstream'] ?? false) as bool,
      );
}

/// Состояние синка так, как его видит приложение.
class UpstreamSyncStatus {
  /// Скрипт синка есть на этом сервере. False — плашку показывать не надо.
  final bool available;

  /// Прогон идёт прямо сейчас (замок держит сам скрипт, поэтому это правда и
  /// когда синк запустили из терминала).
  final bool running;

  /// CLEAN / AUTO / CONFLICTS / TESTS_RED / TESTS_SKIP / ERROR, либо null, если
  /// синк ещё ни разу не отрабатывал.
  final String? outcome;

  /// Нужен человек. Только при этом флаге плашка становится красной.
  final bool needsAttention;

  final int behind;
  final int ahead;
  final int autoResolved;
  final int conflictsCode;
  final String? branch;
  final String? stamp;
  final String? started;
  final String? error;

  /// Прогон, который не состоялся до начала работы (занято, нет сети). Цифры
  /// при этом остались от прошлого удачного — плашка обязана сказать, что
  /// свежесть под вопросом, а не молча стареть.
  final String? lastError;
  final String? lastErrorAt;
  final List<String> nextSteps;
  final List<UpstreamSyncConflict> files;

  const UpstreamSyncStatus({
    required this.available,
    required this.running,
    this.outcome,
    this.needsAttention = false,
    this.behind = 0,
    this.ahead = 0,
    this.autoResolved = 0,
    this.conflictsCode = 0,
    this.branch,
    this.stamp,
    this.started,
    this.error,
    this.lastError,
    this.lastErrorAt,
    this.nextSteps = const [],
    this.files = const [],
  });

  /// Сервер без пульта: не ошибка, просто нечего показывать.
  static const UpstreamSyncStatus unavailable = UpstreamSyncStatus(available: false, running: false);

  factory UpstreamSyncStatus.fromJson(Map<String, dynamic> json) => UpstreamSyncStatus(
        available: (json['available'] ?? false) as bool,
        running: (json['running'] ?? false) as bool,
        outcome: json['outcome'] as String?,
        needsAttention: (json['needs_attention'] ?? false) as bool,
        behind: (json['behind'] ?? 0) as int,
        ahead: (json['ahead'] ?? 0) as int,
        autoResolved: (json['auto_resolved'] ?? 0) as int,
        conflictsCode: (json['conflicts_code'] ?? 0) as int,
        branch: json['branch'] as String?,
        stamp: json['stamp'] as String?,
        started: json['started'] as String?,
        error: json['error'] as String?,
        lastError: json['last_error'] as String?,
        lastErrorAt: json['last_error_at'] as String?,
        nextSteps: ((json['next_steps'] ?? []) as List).map((e) => e.toString()).toList(),
        files: ((json['files'] ?? []) as List)
            .map((e) => UpstreamSyncConflict.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// Есть что вливать: ветка подготовлена и человека ничто не держит.
  bool get canLand => branch != null && !needsAttention && !running;
}

/// Отказ пульта, который стоит показать человеку дословно.
class UpstreamSyncException implements Exception {
  final String message;

  const UpstreamSyncException(this.message);

  @override
  String toString() => message;
}

String? _detail(String body) {
  try {
    final parsed = jsonDecode(body);
    if (parsed is Map && parsed['detail'] is String) return parsed['detail'] as String;
  } catch (_) {}
  return null;
}

Future<UpstreamSyncStatus> getUpstreamSyncStatus() async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/selfhost/upstream-sync/status',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null) return UpstreamSyncStatus.unavailable;
  // 503 — пульта нет на этом сервере, 404 — чужой uid. И то и другое означает
  // «плашку не показывать», а не «что-то сломалось».
  if (response.statusCode == 503 || response.statusCode == 404) return UpstreamSyncStatus.unavailable;
  if (response.statusCode != 200) {
    Logger.debug('getUpstreamSyncStatus: ${response.statusCode} ${response.body}');
    return UpstreamSyncStatus.unavailable;
  }
  return UpstreamSyncStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
}

/// Запустить синк. Возвращается сразу: прогон идёт на сервере минутами.
Future<UpstreamSyncStatus> runUpstreamSync({bool dry = false}) async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/selfhost/upstream-sync/run',
    headers: {'Content-Type': 'application/json'},
    method: 'POST',
    body: jsonEncode({'mode': dry ? 'dry' : 'full'}),
  );
  if (response == null) throw const UpstreamSyncException('Сервер не ответил');
  if (response.statusCode != 200) {
    throw UpstreamSyncException(_detail(response.body) ?? 'Не удалось запустить синк (${response.statusCode})');
  }
  return UpstreamSyncStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
}

/// Влить готовую ветку синка в `private`. Ветка называется явно — это второе
/// подтверждение, а не продолжение первого.
Future<UpstreamSyncStatus> landUpstreamSync(String branch) async {
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/selfhost/upstream-sync/land',
    headers: {'Content-Type': 'application/json'},
    method: 'POST',
    body: jsonEncode({'branch': branch}),
  );
  if (response == null) throw const UpstreamSyncException('Сервер не ответил');
  if (response.statusCode != 200) {
    throw UpstreamSyncException(_detail(response.body) ?? 'Влить не удалось (${response.statusCode})');
  }
  return UpstreamSyncStatus.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
}

/// Markdown-отчёт последнего (или названного) прогона.
Future<String?> getUpstreamSyncReport({String? stamp}) async {
  final query = stamp == null ? '' : '?stamp=$stamp';
  final response = await makeApiCall(
    url: '${Env.apiBaseUrl}v1/selfhost/upstream-sync/report$query',
    headers: {},
    method: 'GET',
    body: '',
  );
  if (response == null || response.statusCode != 200) return null;
  final parsed = jsonDecode(response.body) as Map<String, dynamic>;
  return parsed['markdown'] as String?;
}
