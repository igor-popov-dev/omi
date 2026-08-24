import 'package:omi/env/env.dart';

/// Who transcribes offline (locally buffered) recordings, and whether that
/// warrants asking the user first.
///
/// Upstream rule: a custom-STT user's *live* speech goes to that user's own
/// provider and never touches Omi, but offline files can only be processed on
/// Omi's servers — so draining them silently would spend Omi transcription the
/// user did not ask for. Every automatic drain is therefore closed for those
/// users (`SyncProvider`, the home-page offline-data hook,
/// `canAutoUploadPhoneRecordings`) and manual Sync asks for consent first
/// (`confirmSyncForCustomStt`).
///
/// Self-host patch, not for upstream: on our build "Omi's servers" are the
/// user's own machine, whose pre-recorded path goes to the very same STT the
/// live path uses (`OMI_SELFHOST_PRERECORDED_STT_PATH` on the backend). Nothing
/// leaves the user's own stack and nothing is billed, so the drains stay open —
/// otherwise pendant audio piles up on the phone forever, which is exactly what
/// happened here: 181 files / ~2 h of speech with `retry_count = 0`, i.e. not a
/// single upload attempt in two days.
///
/// [selfHostOwnsOfflineStt] is a parameter only so both branches stay testable
/// without a second `flutter test` run with the dart-define set.
bool offlineSyncNeedsConsent(
  bool useCustomStt, {
  bool selfHostOwnsOfflineStt = Env.selfHostOwnsOfflineStt,
}) =>
    useCustomStt && !selfHostOwnsOfflineStt;
