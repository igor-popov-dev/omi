// The silence-timeout setting for the free-form voice mode, on its own so the
// three unrelated layers that need it can share one definition.
//
// `preferences.dart` (storage), `developer.dart` (the picker) and
// `free_form_voice_mode.dart` (the timer itself) all need the default and the
// minutes -> Duration rule. Putting them in `free_form_voice_mode.dart` would
// make `preferences.dart` import the whole hub through
// `hub_ptt_capture.dart`'s `services.dart`; this file deliberately imports
// nothing at all.
//
// Why the setting exists: free-form mode streams the microphone continuously
// and Gemini Live bills per minute of input (~$0.002/min), so a session left
// running by accident keeps costing money. Priority 22.08 step 6 asked for the
// auto-off to be user-configurable rather than a constant in the code.

/// Minutes stored when the user has never touched the setting. Three minutes
/// was the hard-coded value before the setting existed, kept as the default so
/// behaviour does not change silently for anyone already running the mode.
const int kDefaultFreeFormVoiceIdleTimeoutMinutes = 3;

/// The minute values the settings picker offers, in order. `0` is "never" — it
/// maps to a `null` timeout, i.e. the mode runs until it is switched off by
/// hand.
const List<int> kFreeFormVoiceIdleTimeoutChoicesMinutes = [1, 2, 3, 5, 10, 0];

/// Turns the stored minute count into the mode's timeout.
///
/// Anything at or below zero means "no auto-off" — one rule for the stored `0`
/// and for a nonsense negative value a hand-edited preference could hold, so a
/// bad number can never arm a timer that fires the instant it is armed.
Duration? freeFormIdleTimeoutFromMinutes(int minutes) => minutes <= 0 ? null : Duration(minutes: minutes);

/// Label for [minutes] as the picker and the settings row show it.
String freeFormVoiceIdleTimeoutLabel(int minutes) {
  if (minutes <= 0) return 'Never';
  return minutes == 1 ? '1 minute' : '$minutes minutes';
}
