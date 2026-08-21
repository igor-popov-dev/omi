// Gemini Live hub lane over WebSocket — a 1:1 port of
// `desktop/windows/src/renderer/src/lib/voice/hub/geminiHubSession.ts`
// (`GeminiHubSession`), design doc `~/omi-jarvis/docs/hub-port-design.md` §8
// step 2. Gemini uses MANUAL activity detection
// (`automaticActivityDetection.disabled: true`): each PTT turn is bracketed
// `activityStart` … `activityEnd`, sent every turn on the warm socket
// (sending it once at connect makes turns 2+ arrive with no speech window).
// Gemini has no reliable in-session cancel of a streaming reply, so
// barge-in is a fresh session at the controller boundary (design doc §6,
// not this file); `_responsePending` gates BOTH audio playback and turn
// completion to the current turn so an interrupted/abandoned turn's
// trailing audio can't leak.
//
// Two scope cuts carried over from `hub_session.dart` (already decided
// there, not re-litigated here):
//   * No tool-catalog assembly. The TS source projects a per-instance
//     `tools` list through `sanitizeGeminiToolSchema` into
//     `functionDeclarations`; `BaseHubSession` here has no `tools` seam
//     (design doc §3 — deferred until the hub declares a real tool), so
//     this setup frame always emits the same faithful EMPTY catalog
//     (`tools: [{functionDeclarations: []}]`) the TS test asserts for the
//     "no catalog wired" case. Inbound tool-call requests from the
//     provider are still fully modeled (`emitToolRequest`) — only the
//     outbound declaration list is cut, and `sanitizeGeminiToolSchema`
//     (`geminiToolSchema.ts`) is not ported since nothing calls it yet.
//   * No `setSinkId` — not a TS concern in this file to begin with.
import 'dart:convert';

import 'hub_session.dart';

/// `desktop/windows/.../voice/tokenMint.ts` `GEMINI_LIVE_MODEL`, copied
/// verbatim (not re-exported — that module pulls in the desktop token-mint
/// graph this port does not have).
const String geminiLiveModel = 'models/gemini-3.1-flash-live-preview';

class GeminiHubSession extends BaseHubSession {
  GeminiHubSession({
    required super.token,
    required super.instructions,
    required super.playerFactory,
    super.events,
    super.socketFactory,
    super.clock,
    super.mintSessionId,
    super.idleRelease,
    super.warmTimeout,
  });

  @override
  HubProvider get provider => HubProvider.gemini;
  @override
  int get requiredInputSampleRate => 16000;
  @override
  HubBargeInStrategy get bargeInStrategy => HubBargeInStrategy.freshSession;

  // Manual-VAD: a turn's speech window is open between activityStart and
  // activityEnd.
  bool _activityOpen = false;
  bool _pendingActivityStart = false;

  // A committed turn is awaiting its spoken reply. Gates audio + turnComplete
  // to the CURRENT turn (set on activityEnd/commit; cleared on this turn's
  // turnComplete, a server `interrupted`, or a barge-in beginTurn).
  bool _responsePending = false;
  final Set<String> _pendingToolCallIds = {};
  int _syntheticToolCallCounter = 0;

  @override
  HubConnectSpec connectSpec() {
    // Managed (ephemeral) path: the Constrained endpoint on v1alpha with
    // ?access_token= (TS/Swift `.ephemeral`). BYOK (?key=, v1beta) is a host
    // concern not needed for the managed flow — deferred.
    const base = 'wss://generativelanguage.googleapis.com/ws/'
        'google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained';
    return HubConnectSpec(url: '$base?access_token=${Uri.encodeQueryComponent(token)}');
  }

  @override
  Map<String, dynamic> sessionSetupFrame() {
    // AUDIO modality, manual activity detection, Charon voice, sliding-window
    // context compression, empty (unwired) tool catalog — see file header.
    return {
      'setup': {
        'model': geminiLiveModel,
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          'temperature': 0.3,
          'mediaResolution': 'MEDIA_RESOLUTION_HIGH',
          'speechConfig': {
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': 'Charon'},
            },
          },
        },
        'systemInstruction': {
          'parts': [
            {'text': instructions},
          ],
        },
        'tools': [
          {'functionDeclarations': const <Map<String, dynamic>>[]},
        ],
        'inputAudioTranscription': {},
        'outputAudioTranscription': {},
        'realtimeInputConfig': {
          'automaticActivityDetection': {'disabled': true},
          'turnCoverage': 'TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO',
        },
        'contextWindowCompression': {'slidingWindow': {}},
      },
    };
  }

  @override
  bool canAcceptInput() => isOpen && _activityOpen;

  @override
  void appendAudioFrame(String b64) {
    send({
      'realtimeInput': {
        'audio': {'data': b64, 'mimeType': 'audio/pcm;rate=16000'},
      },
    });
  }

  @override
  void onBeginTurn(bool interrupting) {
    if (interrupting) {
      // Local gate for abandoned/stale events before the fresh-session
      // replacement.
      _responsePending = false;
      _pendingToolCallIds.clear();
    }
    if (_activityOpen) return;
    _activityOpen = true;
    if (isOpen) {
      send({
        'realtimeInput': {'activityStart': {}},
      });
      flushPendingAudio();
      if (pendingCommit) {
        pendingCommit = false;
        commitTurnNow();
      }
    } else {
      _pendingActivityStart = true;
    }
  }

  @override
  void commitTurnNow() {
    send({
      'realtimeInput': {'activityEnd': {}},
    });
    _activityOpen = false;
    _responsePending = true;
    // Gemini auto-responds at activityEnd; no explicit response request.
  }

  @override
  void onCancelTurn() {
    // Abandon (silent tap / cancel), keeping the warm socket.
    _responsePending = false;
    _pendingToolCallIds.clear();
    _pendingActivityStart = false;
    if (_activityOpen && isOpen) {
      send({
        'realtimeInput': {'activityEnd': {}},
      });
    }
    _activityOpen = false;
  }

  @override
  void onSendToolResult(String callId, String name, String output) {
    _pendingToolCallIds.remove(callId);
    send({
      'toolResponse': {
        'functionResponses': [
          {
            'id': callId,
            'name': name,
            'response': {'result': output},
          },
        ],
      },
    });
  }

  @override
  void onProviderReady() {
    // Open the speech window if a turn started before we connected.
    if (_pendingActivityStart) {
      _pendingActivityStart = false;
      send({
        'realtimeInput': {'activityStart': {}},
      });
    }
  }

  @override
  void resetProviderState() {
    _activityOpen = false;
    _pendingActivityStart = false;
    _responsePending = false;
    _pendingToolCallIds.clear();
  }

  // MARK: Receive

  @override
  void handleProviderMessage(Map<String, dynamic> obj) {
    if (obj.containsKey('setupComplete')) {
      markReady();
      return;
    }
    // usageMetadata (client-reported billing) is a host concern — deferred,
    // same as the TS source.
    final toolCall = obj['toolCall'] as Map<String, dynamic>?;
    if (toolCall != null) {
      final calls = (toolCall['functionCalls'] as List<dynamic>?) ?? const [];
      // An abandoned/discarded turn still reaches Gemini (we send
      // activityEnd to close the window); without this guard it acts on
      // half-heard audio.
      if (!_responsePending) return;
      for (final callRaw in calls) {
        final call = callRaw as Map<String, dynamic>;
        final name = call['name'] is String ? call['name'] as String : '';
        final callId = call['id'] is String ? call['id'] as String : _nextSyntheticToolCallId(name);
        _pendingToolCallIds.add(callId);
        final args = (call['args'] as Map<String, dynamic>?) ?? const {};
        final argsJson = jsonEncode(args);
        if (name.isNotEmpty) {
          emitToolRequest(HubToolCallRequest(name: name, callId: callId, argumentsJson: argsJson));
        }
      }
      return;
    }
    final sc = obj['serverContent'] as Map<String, dynamic>?;
    if (sc == null) return;
    if (sc['interrupted'] == true) {
      // Barge-in: drop the pending reply so its trailing audio + bookkeeping
      // turnComplete are ignored, and flush queued playback immediately.
      _responsePending = false;
      _pendingToolCallIds.clear();
      clearPlayback();
    }
    final it = sc['inputTranscription'] as Map<String, dynamic>?;
    if (it != null && it['text'] is String) emitInputTranscript(it['text'] as String, false);
    final ot = sc['outputTranscription'] as Map<String, dynamic>?;
    if (ot != null && ot['text'] is String) emitAssistantText(ot['text'] as String, false);
    final modelTurn = sc['modelTurn'] as Map<String, dynamic>?;
    final parts = (modelTurn?['parts'] as List<dynamic>?) ?? const [];
    for (final partRaw in parts) {
      final part = partRaw as Map<String, dynamic>;
      if (part['text'] is String) emitAssistantText(part['text'] as String, false);
      final inline = part['inlineData'] as Map<String, dynamic>?;
      final mime = inline?['mimeType'] is String ? inline!['mimeType'] as String : '';
      final data = inline?['data'] is String ? inline!['data'] as String : '';
      if (mime.contains('audio/pcm') && data.isNotEmpty && _responsePending) {
        playAudio(data); // gated: only the live turn's reply
      }
    }
    if (sc['turnComplete'] == true) {
      if (_pendingToolCallIds.isNotEmpty) return; // defer until tool results are in
      // Only finish the turn we're actually awaiting a reply for. A
      // turnComplete that closes an interrupted/abandoned generation
      // (pending=false) is ignored.
      if (_responsePending) {
        _responsePending = false;
        flushPlayback();
        emitAssistantText('', true);
        emitTurnDone();
      }
    }
  }

  String _nextSyntheticToolCallId(String name) {
    _syntheticToolCallCounter += 1;
    return '$name:$_syntheticToolCallCounter';
  }
}
