// Self-host patch, not for upstream: плашка апстрим-синка на главном экране.
//
// WHY
// ---
// Отставание от upstream дорожает нелинейно, а замечается только когда уже
// поздно — в момент, когда очередная полоса вливается в `private` и получает
// сотню конфликтов. Плашка держит цифру отставания на глазах, поэтому решение
// «пора» принимается заранее и осознанно.
//
// Тексты русские и не заведены в l10n намеренно: это пульт разработчика на
// личном сервере, он существует только в приватной ветке и в upstream не
// уходит, а лишние ключи в `app_*.arb` — это 49 файлов, которые надо тащить
// через каждый мерж.
import 'package:flutter/material.dart';
import 'package:omi/backend/http/api/upstream_sync.dart';
import 'package:omi/providers/upstream_sync_provider.dart';
import 'package:omi/utils/responsive/responsive_helper.dart';
import 'package:provider/provider.dart';

class UpstreamSyncCard extends StatelessWidget {
  const UpstreamSyncCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<UpstreamSyncProvider>(
      builder: (context, provider, _) {
        if (!provider.visible) return const SizedBox.shrink();
        final status = provider.status;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1C1C1E),
            borderRadius: BorderRadius.circular(20),
            // Рамка появляется только когда нужен человек: спокойное состояние
            // не должно выглядеть тревожно, иначе тревожное перестанут замечать.
            border:
                status.needsAttention ? Border.all(color: ResponsiveHelper.errorColor.withValues(alpha: 0.6)) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(status),
              const SizedBox(height: 8),
              Text(
                _subtitle(status),
                style: TextStyle(color: Colors.grey.shade400, fontSize: 13, height: 1.35),
              ),
              if (status.needsAttention && status.files.isNotEmpty) ...[
                const SizedBox(height: 10),
                _conflictSummary(status),
              ],
              if (status.lastError != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Последний прогон не состоялся (${status.lastErrorAt ?? '?'}): ${status.lastError}. '
                  'Цифры выше — от предыдущего.',
                  style: TextStyle(color: ResponsiveHelper.warningColor, fontSize: 12),
                ),
              ],
              if (provider.lastError != null) ...[
                const SizedBox(height: 10),
                Text(
                  provider.lastError!,
                  style: const TextStyle(color: ResponsiveHelper.errorColor, fontSize: 12),
                ),
              ],
              const SizedBox(height: 14),
              _actions(context, provider, status),
            ],
          ),
        );
      },
    );
  }

  Widget _header(UpstreamSyncStatus status) {
    final Color accent =
        status.running ? Colors.white : (status.needsAttention ? ResponsiveHelper.errorColor : Colors.white);
    return Row(
      children: [
        Icon(status.running ? Icons.sync : Icons.merge_type, size: 18, color: accent),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'Апстрим',
            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
          ),
        ),
        if (status.behind > 0)
          Text(
            '−${status.behind}',
            style: TextStyle(color: accent, fontSize: 14, fontWeight: FontWeight.w600),
          ),
      ],
    );
  }

  String _subtitle(UpstreamSyncStatus status) {
    if (status.running) return 'Идёт синхронизация — фетч, мерж, регенерация, тесты.';
    if (status.error != null) return status.error!;
    switch (status.outcome) {
      case 'CONFLICTS':
        return 'Ветка ${status.branch ?? 'синка'} ждёт разбора: '
            '${status.conflictsCode} ${_files(status.conflictsCode)} с конфликтами кода. '
            'Локализация и генерённое (${status.autoResolved}) сняты автоматически.';
      case 'TESTS_RED':
        return 'Слилось чисто, но тесты красные. Вливать нельзя, пока не разберёшься.';
      case 'TESTS_SKIP':
        return 'Слилось, но тесты не прогнаны — вливать вслепую не стоит.';
      case 'ERROR':
        return 'Прогон не состоялся.';
      case 'CLEAN':
      case 'AUTO':
        if (status.branch != null) {
          return 'Ветка ${status.branch} готова: тесты зелёные, конфликтов кода нет.';
        }
        return 'Отставания нет.';
      default:
        return status.behind > 0
            ? 'Отстаём на ${status.behind} ${_commits(status.behind)}. '
                'Чем дольше ждать, тем дороже вливание полос.'
            : 'Синк ещё не запускался.';
    }
  }

  Widget _conflictSummary(UpstreamSyncStatus status) {
    final ours = status.files.where((f) => f.oursUpstream).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (ours > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Из них $ours — наши же PR, вмерженные upstream: разбираются механически.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ),
        ...status.files.take(3).map(
              (f) => Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '· ${f.file.split('/').last} — ${f.hunks}',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ),
            ),
        if (status.files.length > 3)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '· и ещё ${status.files.length - 3}',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _actions(BuildContext context, UpstreamSyncProvider provider, UpstreamSyncStatus status) {
    if (status.running) {
      return Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          ),
          const SizedBox(width: 10),
          Text('идёт…', style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
        ],
      );
    }

    final buttons = <Widget>[];
    if (status.canLand && status.branch != null) {
      buttons.add(_primary('Влить в private', () => _confirmLand(context, provider, status.branch!)));
    } else {
      buttons.add(_primary('Синхронизировать', () => provider.run()));
    }
    if (status.stamp != null) {
      buttons.add(_secondary('Отчёт', () => _showReport(context, provider)));
    }
    return Row(children: _spaced(buttons));
  }

  List<Widget> _spaced(List<Widget> items) {
    final out = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) out.add(const SizedBox(width: 8));
      out.add(items[i]);
    }
    return out;
  }

  Widget _primary(String label, VoidCallback onTap) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          backgroundColor: Colors.white.withValues(alpha: 0.1),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
      );

  Widget _secondary(String label, VoidCallback onTap) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
        child: Text(label, style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
      );

  /// Вливание в `private` — второе подтверждение, а не продолжение первого:
  /// `private` это ствол, из которого растут все полосы разработки.
  Future<void> _confirmLand(BuildContext context, UpstreamSyncProvider provider, String branch) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        title: const Text('Влить в private?', style: TextStyle(color: Colors.white, fontSize: 17)),
        content: Text(
          'Ветка $branch уйдёт в private — ствол, из которого растут все полосы. '
          'Откат остаётся: снимок private сохранён отдельным ref.',
          style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Влить')),
        ],
      ),
    );
    if (confirmed != true) return;
    await provider.land(branch);
  }

  Future<void> _showReport(BuildContext context, UpstreamSyncProvider provider) async {
    final markdown = await provider.report();
    if (!context.mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.7,
            child: SingleChildScrollView(
              child: SelectableText(
                markdown ?? 'Отчёта пока нет.',
                style: TextStyle(color: Colors.grey.shade300, fontSize: 12, height: 1.4),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _files(int n) {
    if (n % 10 == 1 && n % 100 != 11) return 'файл';
    if (n % 10 >= 2 && n % 10 <= 4 && !(n % 100 >= 12 && n % 100 <= 14)) return 'файла';
    return 'файлов';
  }

  String _commits(int n) {
    if (n % 10 == 1 && n % 100 != 11) return 'коммит';
    if (n % 10 >= 2 && n % 10 <= 4 && !(n % 100 >= 12 && n % 100 <= 14)) return 'коммита';
    return 'коммитов';
  }
}
