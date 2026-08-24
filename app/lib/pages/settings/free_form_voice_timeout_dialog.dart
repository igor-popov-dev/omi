import 'package:flutter/material.dart';

import 'package:omi/services/voice_hub/free_form_voice_timeout.dart';

/// Picker for the free-form voice mode auto-off (priority 22.08 step 6).
///
/// Deliberately plain English, not `context.l10n`: everything about free-form
/// voice mode is a self-host feature behind the `freeFormMode` developer flag
/// (like the "PTT Hub" / "Free-form Voice Mode" switches next to it), and
/// adding keys to every upstream .arb file for a screen only we can reach
/// would be noise in a future upstream diff.
///
/// Shaped after `ConversationTimeoutDialog` — same card, same selected-border
/// treatment, same cancel/save pair — so the two timeouts in Developer settings
/// do not look like they came from different apps.
class FreeFormVoiceTimeoutDialog {
  /// Returns the chosen minute count, or `null` if the user cancelled. The
  /// caller does the saving: this dialog touches no preferences itself, which
  /// is what lets a widget test drive it without a `SharedPreferences` binding.
  static Future<int?> show(BuildContext context, {required int currentMinutes}) {
    int selected = currentMinutes;
    return showDialog<int>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1A1A1A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text(
                'Voice mode auto-off',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Free-form voice mode streams the microphone the whole time it is on, '
                        'and that airtime is billed by the minute. Switch it off after this '
                        'much silence.',
                        style: TextStyle(color: Color(0xFF8E8E93), fontSize: 14),
                      ),
                      const SizedBox(height: 16),
                      ...kFreeFormVoiceIdleTimeoutChoicesMinutes.map((minutes) {
                        final isSelected = selected == minutes;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => setState(() => selected = minutes),
                              child: Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isSelected ? Colors.white : const Color(0xFF3C3C43),
                                    width: isSelected ? 2 : 1,
                                  ),
                                  color: isSelected ? const Color(0xFF2C2C2E) : Colors.transparent,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            freeFormVoiceIdleTimeoutLabel(minutes),
                                            style: TextStyle(
                                              color: isSelected ? Colors.white : const Color(0xFFE5E5E7),
                                              fontSize: 16,
                                              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            minutes <= 0
                                                ? 'Runs until you switch it off — costs keep running too'
                                                : 'Stops itself after $minutes minute${minutes == 1 ? '' : 's'} '
                                                    'with nothing said',
                                            style: TextStyle(
                                              color: isSelected ? const Color(0xFFAEAEB2) : const Color(0xFF8E8E93),
                                              fontSize: 12,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (isSelected) const Icon(Icons.check_circle, color: Colors.white, size: 20),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel', style: TextStyle(color: Color(0xFF8E8E93))),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(selected),
                  child: const Text('Save', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
