// Minimal listening/thinking/speaking indicator for the realtime voice hub
// (priority-22.08 "точка продолжения": bootstrap-wired `hubTurnDriver` needs
// a real `applyProjection` consumer, not a `(_) {}` stub — see
// `main.dart`'s `createProductionVoiceHubTurnDriver` call site and
// `CaptureController.hubProjection`).
//
// Deliberately NOT a mode toggle: starting/stopping the free-form voice mode
// (ДОПОЛНЕНИЕ 22.08's button) needs `FreeFormVoiceMode` wired to a
// `HubController` plus native audio focus / a foreground service — none of
// that exists yet. This widget only reflects turns the pendant's
// single-tap gesture already drives via `hubTurnDriver` (capture_controller.dart:861,886),
// gated by the `pttHubEnabled` dev flag — so it renders nothing for anyone
// who hasn't turned that on.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:omi/providers/capture_provider.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart' show VoiceTurnUiProjection;

class HubVoiceStatusIndicator extends StatelessWidget {
  const HubVoiceStatusIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final captureProvider = context.watch<CaptureProvider>();
    return ValueListenableBuilder<VoiceTurnUiProjection>(
      valueListenable: captureProvider.hubProjection,
      builder: (context, projection, _) {
        final label = _labelFor(projection);
        if (label == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 64, right: 8, bottom: 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1F1F25),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF35343B), width: 1),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.grey.shade400),
                  ),
                  const SizedBox(width: 8),
                  Text(label, style: TextStyle(color: Colors.grey.shade300, fontSize: 13)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// `null` means idle — nothing to show. Order matters: a turn can be
  /// listening AND have a stale `isResponseActive` from the prior turn for
  /// one frame, so listening wins.
  ///
  /// "Слышу…" is the free-form mode's server-VAD state (`isHearingUser`):
  /// same listening phase, but the provider is picking the user's voice up
  /// right now. It answers the question a silent screen cannot — whether the
  /// phone hears you at all — and the PTT path never sets it.
  String? _labelFor(VoiceTurnUiProjection projection) {
    // A hint is a specific thing the host wants said INSTEAD of the generic
    // phase word, and it only ever gets set when the phase word would be
    // misleading. The drop recovery is the live case: it sets "Связь
    // прервалась, восстанавливаю…" together with `isThinking`, and until this
    // line existed the hint was dropped on the floor and the user watched a
    // reconnect that called itself "Думаю…".
    if (projection.hint.isNotEmpty) return projection.hint;
    if (projection.isListening) return projection.isHearingUser ? 'Слышу…' : 'Слушаю…';
    if (projection.isThinking || projection.isResponseWaiting) return 'Думаю…';
    if (projection.isResponseActive) return 'Говорю…';
    return null;
  }
}
