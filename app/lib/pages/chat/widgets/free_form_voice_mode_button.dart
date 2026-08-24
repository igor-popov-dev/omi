// The hands-free voice-mode toggle from ДОПОЛНЕНИЕ 22.08 п.1 ("справа от
// иконки микрофона, круглая, как в ChatGPT/Claude"). Gated by the
// `freeFormMode` dev flag — `preferences.dart`'s own doc comment for that
// flag already reads "hands-free voice-mode button in chat (experimental)",
// i.e. this button IS what that flag was added to gate (`developer.dart`'s
// settings toggle). Hidden entirely while the flag is off, same discipline
// as every other experimental hub surface in this series
// (`HubVoiceStatusIndicator`, `pttHubEnabled`'s gesture routing).
//
// Tapping the button calls `CaptureController.startFreeFormVoiceMode()` /
// `stopFreeFormVoiceMode()` (`main.dart` wires `capture.freeFormVoiceMode`
// at bootstrap via `createProductionFreeFormVoiceMode`) — a real network
// call the moment it turns on (mints a token, opens a socket, starts
// continuous mic capture), not a stub: real per-minute-billed voice traffic
// (ДОПОЛНЕНИЕ 22.08 п.6), which is exactly why it stays behind the flag.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/services/mic/mic_arbiter.dart' show MicBusyError, kConversationMicOwner;
import 'package:omi/utils/alerts/app_snackbar.dart';

class FreeFormVoiceModeButton extends StatelessWidget {
  /// True when the chat composer holds a draft. An idle button stands down in
  /// that case: with dictation appending to the draft, mic + Send are the two
  /// controls the draft needs, and a third circle only eats the width they are
  /// fighting for. An ACTIVE session keeps its button no matter what is in the
  /// field — it is the only way to stop a per-minute-billed socket, and text
  /// can appear (typed, dictated) while the session runs.
  final bool composerHasDraft;

  const FreeFormVoiceModeButton({super.key, this.composerHasDraft = false});

  @override
  Widget build(BuildContext context) {
    if (!SharedPreferencesUtil().freeFormMode) return const SizedBox.shrink();
    final captureProvider = context.watch<CaptureProvider>();
    return ValueListenableBuilder<bool>(
      valueListenable: captureProvider.freeFormModeActive,
      builder: (context, active, _) {
        if (!active && composerHasDraft) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(left: 8),
          child: GestureDetector(
            onTap: () => _onTap(context, captureProvider, active),
            child: Container(
              height: 38,
              width: 38,
              decoration: BoxDecoration(
                color: active ? Colors.white : const Color(0xFF4A4A4F),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: FaIcon(
                  active ? FontAwesomeIcons.stop : FontAwesomeIcons.waveSquare,
                  color: active ? const Color(0xFF1f1f25) : Colors.grey.shade400,
                  size: 16,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _onTap(BuildContext context, CaptureProvider captureProvider, bool active) {
    HapticFeedback.mediumImpact();
    if (active) {
      captureProvider.stopFreeFormVoiceMode();
      return;
    }
    captureProvider.startFreeFormVoiceMode().catchError((Object error) {
      AppSnackbar.showSnackbarError(freeFormVoiceModeStartErrorMessage(error));
    });
  }
}

/// What the toggle says when the mode refuses to start.
///
/// A busy microphone is the one failure here that is not a malfunction: the
/// hub and conversation capture share one recorder through [MicArbiter], so
/// asking for the mic while the phone is recording a conversation is an
/// ordinary situation with an ordinary answer. Showing "Bad state:
/// Microphone is busy (held by conversation)" for it reads as a crash.
String freeFormVoiceModeStartErrorMessage(Object error) {
  if (error is MicBusyError) {
    return error.owner == kConversationMicOwner
        ? 'Микрофон занят записью разговора — остановите запись и включите режим снова'
        : 'Микрофон сейчас занят (${error.owner})';
  }
  return 'Не удалось включить голосовой режим: $error';
}
