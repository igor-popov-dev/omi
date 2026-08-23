// Шторка с ползунком «как часто голосовой режим ходит к Claude» (5 ячеек,
// просьба Игоря 24.08). Открывается долгим нажатием на кнопку голосового
// режима в чате (free_form_voice_mode_button.dart); та же настройка
// продублирована строкой в Settings → Developer.
//
// Пишет напрямую в SharedPreferencesUtil: хаб читает уровень при каждом
// открытии сессии (см. escalation_level.dart), поэтому провайдер настроек
// здесь не нужен — экран Developer сам перечитывает prefs при открытии.
// Смена уровня применяется со СЛЕДУЮЩЕГО запуска голосового режима — об этом
// честно написано внизу шторки.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/services/voice_hub/escalation_level.dart';

Future<void> showClaudeEscalationSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1F1F25),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) => const ClaudeEscalationSheet(),
    );

class ClaudeEscalationSheet extends StatefulWidget {
  const ClaudeEscalationSheet({super.key});

  @override
  State<ClaudeEscalationSheet> createState() => _ClaudeEscalationSheetState();
}

class _ClaudeEscalationSheetState extends State<ClaudeEscalationSheet> {
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = ClaudeEscalationLevel.fromIndex(SharedPreferencesUtil().claudeEscalationLevel).index;
  }

  @override
  Widget build(BuildContext context) {
    final level = ClaudeEscalationLevel.values[_index];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Мозг голосового режима',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Слева — быстрый Gemini Live, справа — каждый ответ думает Claude.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
            ),
            const SizedBox(height: 16),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: const Color(0xFF22C55E),
                inactiveTrackColor: const Color(0xFF3A3A3F),
                thumbColor: Colors.white,
                overlayColor: const Color(0x3322C55E),
                tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 3),
                activeTickMarkColor: Colors.white70,
                inactiveTickMarkColor: Colors.grey.shade600,
              ),
              child: Slider(
                value: _index.toDouble(),
                min: 0,
                max: (ClaudeEscalationLevel.values.length - 1).toDouble(),
                divisions: ClaudeEscalationLevel.values.length - 1,
                onChanged: (value) {
                  final next = value.round();
                  if (next == _index) return;
                  HapticFeedback.selectionClick();
                  setState(() => _index = next);
                  SharedPreferencesUtil().claudeEscalationLevel = next;
                  // Тёплый сокет хаба живёт и после остановки разговора и несёт
                  // инструкции СТАРОГО уровня — рвём его (если разговор не идёт),
                  // чтобы ползунок действовал со следующего же старта.
                  context.read<CaptureProvider>().invalidateWarmVoiceSessions();
                },
              ),
            ),
            const SizedBox(height: 4),
            Text(
              level.label,
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 2),
            Text(level.hint, style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
            const SizedBox(height: 12),
            Text(
              'Применится со следующего запуска голосового режима.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
