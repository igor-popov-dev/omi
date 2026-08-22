// Production wiring for the realtime voice hub — the "host" seam every
// prior tick in this series left explicitly open (design doc
// `~/omi-jarvis/docs/hub-port-design.md` §8 step 5; see e.g.
// `voice_turn_driver.dart`'s own header, `ask_claude_tool.dart`'s header).
// Every collaborator assembled here already exists as an injected seam —
// this file is pure assembly, no new capture/session/tool logic:
//   * `mintGeminiHubToken` — `HubMintToken`, `POST /v2/realtime/session`
//     per lane2's contract (lane2-log.md, 21.08 22:05, ~line 1424): Bearer
//     auth is added automatically by `makeApiCall`'s `buildHeaders`, same
//     as every other authenticated endpoint in this app — no separate auth
//     wiring needed here.
//   * `buildProductionHubInstructions` — `HubBuildInstructions`. Static
//     prose, not a port: the desktop TS source this whole series ports
//     from has no `desktop/` symlink in this worktree to copy verbatim.
//   * `fetchHubTools` — `HubFetchTools`. Today's catalog is exactly the one
//     tool this app declares, `askClaudeToolDeclaration`
//     (`ask_claude_tool.dart`).
//   * `createProductionVoiceHubTurnDriver` — assembles a real
//     `VoiceHubTurnDriver`: `HubController` (real mint/instructions/tools),
//     `GeminiHubSession` via `nativeVoicePlayerFactory`, mic capture via
//     `nativeMicHubCaptureFactory`, and `AskClaudeToolExecutor` wired to
//     `VoiceHubTurnDriverDeps.toolExecutor` (the seam this same tick added
//     to `voice_turn_driver.dart` — see that file's header for why the
//     defensive "tools not available" fallback alone isn't enough once a
//     real catalog is declared).
//
// NOT auto-invoked: nothing calls `createProductionVoiceHubTurnDriver` yet.
// Constructing it once at app bootstrap and assigning the result to
// `CaptureController().hubTurnDriver` (gated by `pttHubEnabled`, see that
// field's own doc comment) — plus the chat-screen UI toggle for
// `freeFormMode` — is deliberately left to a follow-up tick, same
// "additive, unconnected until explicitly wired" discipline the whole
// `voice_hub/` series has used throughout.
//
// Formerly a known gap (flagged by the tick that wrote `ask_claude_tool.dart`,
// its header, "Auth: NOT handled here"): `AskClaudeBridgeClient` needs a
// `http.Client` that stamps CF-Access-Client-Id/Secret, and this worktree
// (`feat/android-realtime-hub`) had no such client — the app's actual CF-Access
// wiring (`buildHeaders` in `backend/http/shared.dart`) lived only on lane2's
// `private` branch. Closed by two changes:
//   1. Cherry-picked `400c74b5d8` ("Cloudflare Access headers for the
//      self-host tunnel") from `private` into this branch — brings in
//      `Env.cfAccessClientId`/`cfAccessClientSecret`, the two dart-defines
//      everything else here reads.
//   2. `CfAccessHttpClient` (`cf_access_http_client.dart`) — a small
//      `http.Client` decorator built for this seam specifically, since
//      `buildHeaders` itself is a header-builder consumed by `makeApiCall`
//      and friends, not an injectable client (there was never a generic
//      intercepting client to reuse, contrary to `ask_claude_tool.dart`'s
//      original header comment — that assumption was wrong; see this
//      file's own header note there for the correction).
// `bridgeHttpClient` is therefore optional now, defaulting to
// `CfAccessHttpClient()`; a caller can still inject a bare `http.Client()`
// (or a fake) for tests or a non-tunnel deployment.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:omi/backend/http/shared.dart';
import 'package:omi/env/env.dart';
import 'package:omi/services/mic/native_mic_recorder_service.dart';

import 'ask_claude_tool.dart';
import 'cf_access_http_client.dart';
import 'gemini_hub_session.dart';
import 'hub_controller.dart';
import 'hub_ptt_capture.dart';
import 'hub_session.dart' show VoiceToolDeclaration;
import 'native_voice_player.dart';
import 'voice_turn_coordinator.dart' show VoiceTurnPresenter;
import 'voice_turn_driver.dart';

/// Thrown by [mintGeminiHubToken] on a transport failure, a non-200, or a
/// 200 body missing the `token` field.
class HubTokenMintException implements Exception {
  final String message;
  const HubTokenMintException(this.message);
  @override
  String toString() => 'HubTokenMintException: $message';
}

/// Production [HubMintToken]. Contract (lane2-log.md, 21.08 22:05):
/// `POST v2/realtime/session`, body `{"provider": "gemini"}` ->
/// `200 {"provider", "token", "expires_at"}`. Only `token` is consumed —
/// `expires_at` isn't used proactively; `HubController.mintToken` is
/// called fresh on every warm, so an early re-mint isn't needed.
Future<String> mintGeminiHubToken() async {
  final res = await makeApiCall(
    url: '${Env.apiBaseUrl}v2/realtime/session',
    headers: const {'Content-Type': 'application/json'},
    body: jsonEncode(const {'provider': 'gemini'}),
    method: 'POST',
  );
  if (res == null) {
    throw const HubTokenMintException('no response (transport error)');
  }
  if (res.statusCode != 200) {
    throw HubTokenMintException('HTTP ${res.statusCode}: ${res.body}');
  }
  final dynamic decoded = jsonDecode(res.body);
  final token = decoded is Map ? decoded['token'] : null;
  if (token is! String || token.isEmpty) {
    throw const HubTokenMintException('200 response missing "token"');
  }
  return token;
}

/// Production [HubBuildInstructions]. Static system prompt — no
/// per-user/context templating yet (a future tick that wants that plugs it
/// in here; the seam is a `String Function()`, not a constant, precisely so
/// this can grow that later without touching `hub_controller.dart`).
String buildProductionHubInstructions() => _kHubInstructions;

const String _kHubInstructions = 'You are Omi, a warm and concise voice assistant running on the '
    "user's phone. Speak naturally and briefly, like a helpful friend, not a chatbot reading a "
    'list. For anything that needs real reasoning, remembered context, or looking something up — '
    "rather than a quick reply you're confident in — call the ask_claude tool instead of guessing, "
    'and say a short filler like "one sec, let me check" out loud in the SAME turn while it runs, '
    'so the user is never left in silence.';

/// Production [HubFetchTools]: the one tool this app declares today.
Future<List<VoiceToolDeclaration>> fetchHubTools() async => const [askClaudeToolDeclaration];

/// Assembles a real, network-backed [VoiceHubTurnDriver] — see file header
/// for exactly what's wired and what's deliberately still not (bootstrap
/// call site, chat UI toggle).
///
/// [applyProjection] and [pttHubEnabled] are passed straight through to
/// [VoiceHubTurnDriverDeps] (same contract, see that class's doc comments).
/// [bridgeHttpClient] defaults to [CfAccessHttpClient] — see file header's
/// "Formerly a known gap" note; pass a bare `http.Client()` or a fake to
/// override (e.g. tests, a non-tunnel deployment). [freeFormMode] defaults
/// to always-off (today's manual-VAD/PTT behavior, unchanged) so a caller
/// that hasn't wired the free-form preference yet gets the old behavior,
/// not a crash.
VoiceHubTurnDriver createProductionVoiceHubTurnDriver({
  required VoiceTurnPresenter applyProjection,
  required bool Function() pttHubEnabled,
  http.Client? bridgeHttpClient,
  bool Function() freeFormMode = _defaultFreeFormModeOff,
}) {
  // Assigned synchronously inside `createHub` below, before the
  // `VoiceHubTurnDriver` constructor returns — `toolExecutor`'s closure is
  // only ever invoked later (a real tool call arriving over the warm
  // socket), strictly after that assignment, so this `late final` is safe.
  late final HubController hub;

  final askClaudeExecutor = AskClaudeToolExecutor(
    client: AskClaudeBridgeClient(httpClient: bridgeHttpClient ?? CfAccessHttpClient()),
    sendToolResult: (callId, name, output) => hub.sendToolResult(callId, name, output),
  );

  return VoiceHubTurnDriver(VoiceHubTurnDriverDeps(
    createHub: (events) {
      hub = HubController(
        events: events,
        buildInstructions: buildProductionHubInstructions,
        mintToken: mintGeminiHubToken,
        createSession: (spec) => GeminiHubSession(
          token: spec.token,
          instructions: spec.instructions,
          playerFactory: nativeVoicePlayerFactory,
          events: spec.events,
          tools: spec.tools,
          freeFormMode: freeFormMode(),
        ),
        fetchTools: fetchHubTools,
      );
      return hub;
    },
    startCapture: nativeMicHubCaptureFactory(() => NativeMicRecorderService()),
    applyProjection: applyProjection,
    pttHubEnabled: pttHubEnabled,
    toolExecutor: askClaudeExecutor.handle,
  ));
}

bool _defaultFreeFormModeOff() => false;
