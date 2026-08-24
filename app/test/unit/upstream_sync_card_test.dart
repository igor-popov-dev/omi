// Self-host patch: плашка апстрим-синка на главном экране.
//
// Проверяется то, ради чего плашка вообще существует и то, что делает её
// безопасной: она молчит там, где ей нечего сказать (и на чужом сервере, где
// пульта нет), показывает цену отставания, и НИКОГДА не вливает в `private` по
// одному нажатию — `private` это ствол, из которого растут все полосы.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/http/api/upstream_sync.dart';
import 'package:omi/pages/conversations/widgets/upstream_sync_card.dart';
import 'package:omi/providers/upstream_sync_provider.dart';

class _StubSyncProvider extends UpstreamSyncProvider {
  _StubSyncProvider(this._status);

  UpstreamSyncStatus _status;
  int runs = 0;
  final List<String> landed = [];

  @override
  UpstreamSyncStatus get status => _status;

  @override
  bool get loaded => true;

  @override
  bool get visible {
    if (!_status.available) return false;
    return _status.running || _status.needsAttention || _status.behind > 0 || _status.branch != null;
  }

  @override
  Future<void> run({bool dry = false}) async {
    runs++;
    notifyListeners();
  }

  @override
  Future<bool> land(String branch) async {
    landed.add(branch);
    notifyListeners();
    return true;
  }

  @override
  Future<String?> report() async => '# отчёт';
}

Future<void> _pump(WidgetTester tester, _StubSyncProvider provider) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ChangeNotifierProvider<UpstreamSyncProvider>.value(
        value: provider,
        child: const Scaffold(body: UpstreamSyncCard()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('на сервере без пульта плашки нет вовсе', (tester) async {
    final provider = _StubSyncProvider(UpstreamSyncStatus.unavailable);

    await _pump(tester, provider);

    expect(find.text('Апстрим'), findsNothing);
  });

  testWidgets('нулевое отставание — не новость, плашка молчит', (tester) async {
    final provider = _StubSyncProvider(const UpstreamSyncStatus(available: true, running: false, behind: 0));

    await _pump(tester, provider);

    expect(find.text('Апстрим'), findsNothing);
  });

  testWidgets('отставание показано вместе с его ценой', (tester) async {
    final provider = _StubSyncProvider(const UpstreamSyncStatus(available: true, running: false, behind: 292));

    await _pump(tester, provider);

    expect(find.text('Апстрим'), findsOneWidget);
    expect(find.text('−292'), findsOneWidget);
    expect(find.textContaining('292 коммита'), findsOneWidget);
    expect(find.text('Синхронизировать'), findsOneWidget);
  });

  testWidgets('склонения не ломаются на единице', (tester) async {
    final provider = _StubSyncProvider(const UpstreamSyncStatus(available: true, running: false, behind: 1));

    await _pump(tester, provider);

    expect(find.textContaining('1 коммит.'), findsOneWidget);
  });

  testWidgets('конфликты: показан класс «наши же PR» — он разбирается механически', (tester) async {
    final provider = _StubSyncProvider(const UpstreamSyncStatus(
      available: true,
      running: false,
      outcome: 'CONFLICTS',
      needsAttention: true,
      behind: 292,
      autoResolved: 51,
      conflictsCode: 19,
      branch: 'sync/upstream-2026-08-24',
      stamp: '2026-08-24-2058',
      files: [
        UpstreamSyncConflict(file: 'app/lib/services/sockets/pure_polling.dart', hunks: 8, oursUpstream: true),
        UpstreamSyncConflict(file: 'backend/utils/retrieval/graph.py', hunks: 1, oursUpstream: false),
      ],
    ));

    await _pump(tester, provider);

    expect(find.textContaining('19 файлов с конфликтами кода'), findsOneWidget);
    expect(find.textContaining('Из них 1 — наши же PR'), findsOneWidget);
    expect(find.text('Отчёт'), findsOneWidget);
  });

  testWidgets('пока нужен человек, кнопки «Влить» нет', (tester) async {
    final provider = _StubSyncProvider(const UpstreamSyncStatus(
      available: true,
      running: false,
      outcome: 'TESTS_RED',
      needsAttention: true,
      behind: 292,
      branch: 'sync/upstream-2026-08-24',
    ));

    await _pump(tester, provider);

    expect(find.text('Влить в private'), findsNothing);
  });

  testWidgets('вливание в private требует отдельного подтверждения', (tester) async {
    final provider = _StubSyncProvider(const UpstreamSyncStatus(
      available: true,
      running: false,
      outcome: 'AUTO',
      needsAttention: false,
      behind: 292,
      branch: 'sync/upstream-2026-08-24',
      stamp: '2026-08-24-2058',
    ));

    await _pump(tester, provider);
    await tester.tap(find.text('Влить в private'));
    await tester.pumpAndSettle();

    // Одно нажатие ничего не влило — открылся вопрос.
    expect(provider.landed, isEmpty);
    expect(find.text('Влить в private?'), findsOneWidget);

    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(provider.landed, isEmpty);

    await tester.tap(find.text('Влить в private'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Влить'));
    await tester.pumpAndSettle();

    expect(provider.landed, ['sync/upstream-2026-08-24']);
  });

  testWidgets('пока прогон идёт, запустить второй нечем', (tester) async {
    final provider = _StubSyncProvider(const UpstreamSyncStatus(available: true, running: true, behind: 292));

    await _pump(tester, provider);

    expect(find.text('Синхронизировать'), findsNothing);
    expect(find.text('идёт…'), findsOneWidget);
  });

  testWidgets('ошибка запуска доезжает до глаз, а не только в лог', (tester) async {
    final provider = _StubSyncProvider(const UpstreamSyncStatus(
      available: true,
      running: false,
      outcome: 'ERROR',
      needsAttention: true,
      behind: 292,
      error: 'занято: другой мерж в работе',
    ));

    await _pump(tester, provider);

    expect(find.textContaining('занято: другой мерж'), findsOneWidget);
  });
}
