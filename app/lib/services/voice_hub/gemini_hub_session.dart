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
// freeFormMode (added for the "свободный голосовой режим" priority,
// `~/omi-jarvis/marathon/lanes/lane5.md` §"ГЛАВНЫЙ ПРИОРИТЕТ 22.08" step 1 —
// no TS analog to port from; the desktop hub is manual-VAD-only). Default
// `false` keeps every existing branch byte-for-byte identical to before this
// flag existed (Igor's explicit requirement — the flag-off path must not
// change). When `true`:
//   * `automaticActivityDetection.disabled` flips to `false` in the setup
//     frame — Gemini's own VAD decides where an utterance starts/ends
//     instead of the client bracketing it with activityStart/activityEnd.
//   * `beginTurn()` (called once, when free-form mode is switched ON —
//     NOT once per utterance) opens continuous input (`_streamingActive`)
//     instead of a single PTT window; mic frames are meant to flow
//     continuously for as long as the mode stays on. No `activityStart`
//     frame is sent (the API contract for automatic detection is that the
//     client does not send manual activity signals at all).
//   * `commitTurn()` has nothing to do — the server ends each detected
//     utterance's turn on its own (still surfaces as `serverContent.
//     turnComplete`, same wire shape as manual mode) — it is a no-op here.
//     A correctly wired free-form driver should not call it; the no-op is
//     just a safe fallback.
//   * `cancelTurn()` is repurposed as "switch free-form mode off": it stops
//     accepting input (`_streamingActive = false`) without sending an
//     `activityEnd` frame (nothing to close — there was never a manual
//     window).
//   * Each server-detected utterance completing (`turnComplete`) still
//     plays its audio and fires `onTurnDone`, but — unlike manual mode —
//     does NOT close input: the session keeps `_streamingActive` true so
//     the next utterance is accepted without another `beginTurn()` call.
//   * Barge-in (`serverContent.interrupted`) still clears playback exactly
//     as in manual mode; it does not touch `_streamingActive`, since the
//     free-form session has no per-turn window to reopen.
// This only teaches the session layer the new wire shape and turn
// bookkeeping — it is NOT wired into `voice_turn_driver.dart`, the
// controller, or any UI yet (later steps of the same priority list:
// start/stop contract + foreground service, `ask_claude` tool, UI toggle).
//
// Tool-catalog assembly (lane5.md §"ГЛАВНЫЙ ПРИОРИТЕТ 22.08" step 3): the TS
// source projects `BaseHubSession.tools` through `sanitizeGeminiToolSchema`
// into `functionDeclarations` on every setup frame — ported verbatim below.
// `tools` is still just a plain injected list (see `hub_session.dart`); this
// file only owns the Gemini-specific wire projection.
//
// One scope cut carried over from `hub_session.dart` (already decided
// there, not re-litigated here): no `setSinkId` — not a TS concern in this
// file to begin with.
import 'dart:convert';

import 'gemini_tool_schema.dart';
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
    super.tools,
    this.freeFormMode = false,
  });

  /// See file header. Default `false` == today's manual-VAD/PTT behavior,
  /// unchanged.
  final bool freeFormMode;

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

  // freeFormMode: continuous input is accepted for as long as this is true
  // (set by beginTurn() when the mode is switched on, cleared by
  // cancelTurn() when it's switched off, or by resetProviderState() on
  // teardown). Unlike `_activityOpen`, this is NOT cleared per-utterance —
  // see file header.
  bool _streamingActive = false;

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
          {
            'functionDeclarations': tools
                .map((t) => {
                      'name': t.name,
                      'description': t.description,
                      'parameters': sanitizeGeminiToolSchema(t.parameters),
                    })
                .toList(),
          },
        ],
        'inputAudioTranscription': {},
        'outputAudioTranscription': {},
        'realtimeInputConfig': {
          'automaticActivityDetection': {'disabled': !freeFormMode},
          'turnCoverage': 'TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO',
        },
        'contextWindowCompression': {'slidingWindow': {}},
      },
    };
  }

  @override
  bool canAcceptInput() => isOpen && (freeFormMode ? _streamingActive : _activityOpen);

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
    if (freeFormMode) {
      // One call switches the mode ON for the whole session — not one call
      // per utterance (see file header). No activityStart frame: the API
      // contract for automatic detection is that the client sends none.
      if (_streamingActive) return;
      _streamingActive = true;
      if (isOpen) {
        flushPendingAudio();
      } else {
        _pendingActivityStart = true; // flushed (without a frame) in onProviderReady
      }
      return;
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
    if (freeFormMode) {
      // The server ends each detected utterance's turn on its own
      // (handleProviderMessage's turnComplete branch) — there is no manual
      // commit frame to send. A correctly wired free-form driver should not
      // be calling commitTurn() at all; this is just a safe no-op if it is.
      return;
    }
    send({
      'realtimeInput': {'activityEnd': {}},
    });
    _activityOpen = false;
    _responsePending = true;
    // Gemini auto-responds at activityEnd; no explicit response request.
  }

  @override
  void onCancelTurn() {
    if (freeFormMode) {
      // Repurposed as "switch free-form mode off": stop accepting input.
      // Nothing to close on the wire — there was never a manual window.
      _streamingActive = false;
      _pendingActivityStart = false;
      _pendingToolCallIds.clear();
      return;
    }
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
  void onSendUserText(String text) {
    send({
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text},
            ],
          },
        ],
        'turnComplete': true,
      },
    });
  }

  @override
  void onProviderReady() {
    // Open the speech window if a turn started before we connected.
    if (_pendingActivityStart) {
      _pendingActivityStart = false;
      // freeFormMode never sends this frame — see file header.
      if (!freeFormMode) {
        send({
          'realtimeInput': {'activityStart': {}},
        });
      }
    }
  }

  @override
  void resetProviderState() {
    _activityOpen = false;
    _pendingActivityStart = false;
    _responsePending = false;
    _pendingToolCallIds.clear();
    _streamingActive = false;
  }

  /// The gate `handleProviderMessage` uses to accept tool calls / reply
  /// audio / turn completion. Manual mode gates on the per-turn commit
  /// (`_responsePending`); free-form mode gates on the mode still being on
  /// (`_streamingActive`) — see file header.
  bool get _turnGateOpen => freeFormMode ? _streamingActive : _responsePending;

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
      if (!_turnGateOpen) return;
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
      // freeFormMode leaves `_streamingActive` alone — there is no per-turn
      // window to reopen, the session just keeps listening (see file
      // header).
      if (!freeFormMode) _responsePending = false;
      _pendingToolCallIds.clear();
      clearPlayback();
    }
    // Server-VAD verdict (free-form mode only; manual mode never sends it).
    // Unknown values are ignored rather than guessed at: a future third state
    // must not silently read as "user stopped talking".
    final speechState = sc['speechState'];
    if (speechState == 'SPEECH') {
      emitUserSpeechState(true);
    } else if (speechState == 'NON_SPEECH') {
      emitUserSpeechState(false);
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
      if (mime.contains('audio/pcm') && data.isNotEmpty && _turnGateOpen) {
        playAudio(data); // gated: only the live turn's reply
      }
    }
    if (sc['turnComplete'] == true) {
      if (_pendingToolCallIds.isNotEmpty) return; // defer until tool results are in
      if (freeFormMode) {
        // A completion that arrives after the mode was switched off
        // (`_streamingActive` false) belongs to a dead generation — ignore
        // it, same spirit as the manual-mode guard below.
        if (!_streamingActive) return;
        flushPlayback();
        emitAssistantText('', true);
        emitTurnDone();
        // `_streamingActive` stays true: unlike manual mode, this does NOT
        // close input — the next server-detected utterance is accepted
        // without another beginTurn() call (see file header).
        return;
      }
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
