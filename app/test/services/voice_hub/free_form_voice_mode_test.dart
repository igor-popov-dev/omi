// Tests for `free_form_voice_mode.dart` — see that file's header for scope
// (start/stop contract + silence-timeout auto-off, priority-22.08 steps 2/6).
// No TS source to mirror; test names describe behavior directly.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:omi/services/voice_hub/free_form_voice_mode.dart';
import 'package:omi/services/voice_hub/free_form_voice_timeout.dart';
import 'package:omi/services/voice_hub/hub_controller.dart';
import 'package:omi/services/voice_hub/hub_ptt_capture.dart';
import 'package:omi/services/voice_hub/hub_session.dart';
import 'package:omi/services/voice_hub/voice_turn_machine.dart' show VoiceSessionId;

// ---- fixtures ---------------------------------------------------------

/// A minimal fake provider session that connects instantly on `ensureWarm()`
/// (see that method below) — tests pre-warm the hub via `buildMode()` so
/// `FreeFormVoiceMode`'s own logic runs against an already-live session.
class _FakeSession implements HubSession {
  @override
  HubProvider get provider => HubProvider.gemini;
  @override
  int get requiredInputSampleRate => 16000;
  @override
  HubBargeInStrategy get bargeInStrategy => HubBargeInStrategy.freshSession;

  final VoiceSessionId sessionId;
  final HubSessionEvents events;
  _FakeSession(this.sessionId, this.events);

  final List<bool> begun = [];
  final List<Uint8List> appended = [];
  int cancelled = 0;
  int cleared = 0;
  int muted = 0;
  int toreDown = 0;

  @override
  Future<void> ensureWarm() {
    // Connects instantly so `HubController.ensureWarm()` resolves
    // deterministically in one microtask — these tests exercise
    // `FreeFormVoiceMode`'s own logic, not `HubController`'s cold-start
    // races (already covered by `hub_controller_test.dart`).
    events.onConnected?.call(sessionId);
    return Future.value();
  }

  @override
  bool isWarm() => true;
  @override
  void beginTurn([HubBeginTurnOptions opts = const HubBeginTurnOptions()]) => begun.add(opts.interrupting);
  @override
  void appendAudio(Uint8List pcm) => appended.add(pcm);
  @override
  void commitTurn() {}
  @override
  void cancelTurn() => cancelled += 1;
  @override
  void sendToolResult(String callId, String name, String output) {}

  @override
  void sendUserText(String text) => userTexts.add(text);

  final List<String> userTexts = [];
  @override
  void clearPlayback() => cleared += 1;
  @override
  void muteCurrentResponse() => muted += 1;
  @override
  void teardown() => toreDown += 1;
}

class _FakeCapture implements HubPttCapture {
  int disposeCalls = 0;
  @override
  void dispose() => disposeCalls += 1;
}

class _FakeClock implements HubClock {
  final Map<int, void Function()> _timers = {};
  int _seq = 0;

  /// The duration the most recent [setTimer] was armed with — what a test
  /// asserting "the timeout the mode actually used" needs to see.
  Duration? lastDuration;

  /// How many times a timer was armed — what "the silence clock was NOT
  /// rearmed" needs, since a rearm looks identical to the first arm from
  /// [lastDuration] alone.
  int arms = 0;

  @override
  Object setTimer(Duration duration, void Function() fire) {
    final id = ++_seq;
    _timers[id] = fire;
    lastDuration = duration;
    arms += 1;
    return id;
  }

  @override
  void clearTimer(Object handle) => _timers.remove(handle as int);

  bool get pending => _timers.isNotEmpty;

  void fire() {
    if (_timers.isEmpty) throw StateError('no pending timer');
    final entry = _timers.entries.first;
    _timers.remove(entry.key);
    entry.value();
  }
}

void main() {
  group('FreeFormVoiceMode', () {
    late HubController hub;
    late _FakeSession session;
    late _FakeClock clock;
    late void Function(Uint8List)? lastOnChunk;
    late void Function(bool)? lastOnInterruption;
    final List<bool> micInterruptions = [];
    late _FakeCapture capture;
    Object? captureError;
    int captureCalls = 0;
    int idleTimeoutCalls = 0;
    int turnIdCalls = 0;

    HubController buildHub() {
      return HubController(
        buildInstructions: () => 'INSTRUCTIONS',
        mintToken: () async => 'ek_token',
        createSession: (spec) {
          session = _FakeSession('sess-1', spec.events);
          return session;
        },
      );
    }

    Future<HubPttCapture> fakeStartCapture(HubPttCaptureOptions options) async {
      captureCalls += 1;
      lastOnChunk = options.onChunk;
      lastOnInterruption = options.onInterruption;
      if (captureError != null) throw captureError!;
      capture = _FakeCapture();
      return capture;
    }

    // Pre-warms the hub before handing back the mode under test: every test
    // here exercises `FreeFormVoiceMode`'s own start/stop/idle-timeout
    // logic against an already-warm session, not `HubController`'s
    // cold-start race (covered separately by `hub_controller_test.dart`).
    // `idleTimeout` is passed as a resolver, mirroring production: the real
    // one reads a user-editable preference on every arm.
    Future<FreeFormVoiceMode> buildMode({Duration? Function()? idleTimeout}) async {
      hub = buildHub();
      await hub.ensureWarm();
      clock = _FakeClock();
      return FreeFormVoiceMode(
        hub: hub,
        startCapture: fakeStartCapture,
        mintTurnId: () {
          turnIdCalls += 1;
          return 'turn-$turnIdCalls';
        },
        clock: clock,
        now: () => 0,
        resolveIdleTimeout: idleTimeout ?? () => const Duration(minutes: 3),
        onIdleTimeout: () => idleTimeoutCalls += 1,
        onMicInterruption: micInterruptions.add,
      );
    }

    setUp(() {
      captureCalls = 0;
      captureError = null;
      idleTimeoutCalls = 0;
      turnIdCalls = 0;
      lastOnChunk = null;
      lastOnInterruption = null;
      micInterruptions.clear();
    });

    // Conversation resumption (design doc §10): the two ways the mode ends
    // stopped meaning the same thing once the hub could carry a conversation
    // across sockets.
    test('an explicit stop() ends the conversation, not just the socket', () async {
      final mode = await buildMode();
      await mode.start();
      session.events.onResumptionHandle?.call('H1');
      expect(hub.canResumeConversation, isTrue);

      mode.stop();
      expect(hub.canResumeConversation, isFalse);
    });

    test('the silence auto-stop keeps the conversation — coming back continues it', () async {
      final mode = await buildMode();
      await mode.start();
      session.events.onResumptionHandle?.call('H1');

      clock.fire(); // the idle timer elapses -> auto-stop
      expect(mode.isRunning, isFalse);
      expect(idleTimeoutCalls, 1);
      expect(hub.canResumeConversation, isTrue);
    });

    test('start() opens one hub turn and starts continuous capture', () async {
      final mode = await buildMode();
      await mode.start();

      expect(mode.isRunning, isTrue);
      expect(captureCalls, 1);
      expect(session.begun, [false]);
      expect(session.cleared, 1); // barge-in safety on entry
    });

    test('start() is idempotent while already running', () async {
      final mode = await buildMode();
      await mode.start();
      await mode.start();

      expect(captureCalls, 1);
      expect(turnIdCalls, 1);
    });

    test('capture chunks feed appendAudio under the mode turn id', () async {
      final mode = await buildMode();
      await mode.start();

      final chunk = Uint8List.fromList([1, 2, 3]);
      lastOnChunk!(chunk);

      expect(session.appended, [chunk]);
    });

    // The mic can be taken away mid-session — a phone call takes the audio
    // mode, or another app preempts the input (`PhoneMicController.kt`). From
    // the hub's side that is indistinguishable from a person who stopped
    // talking, so without this signal nothing in the stack knows.
    test('a mic interruption is relayed to the host and flips micInterrupted', () async {
      final mode = await buildMode();
      await mode.start();
      expect(mode.micInterrupted, isFalse);

      lastOnInterruption!(true);
      expect(mode.micInterrupted, isTrue);
      expect(micInterruptions, [true]);

      lastOnInterruption!(false);
      expect(mode.micInterrupted, isFalse);
      expect(micInterruptions, [true, false]);
    });

    test('a repeated interruption event does not re-announce the same state', () async {
      final mode = await buildMode();
      await mode.start();

      lastOnInterruption!(true);
      lastOnInterruption!(true);

      expect(micInterruptions, [true], reason: 'состояние не менялось — сообщать нечего');
    });

    // Losing the mic is the opposite of the user still being there: rearming
    // the silence auto-off on it would buy an unusable session another full
    // timeout of per-minute billing.
    test('an interruption does NOT rearm the silence auto-off', () async {
      final mode = await buildMode();
      await mode.start();
      final armsAfterStart = clock.arms;

      lastOnInterruption!(true);
      expect(clock.arms, armsAfterStart);

      mode.noteActivity();
      expect(clock.arms, armsAfterStart + 1, reason: 'обычная активность таймер всё ещё взводит');
    });

    // The flag describes a mic we are holding. Once the mode lets go of it,
    // saying "the mic came back" would paint a live indicator over a session
    // that no longer exists.
    test('stop() clears micInterrupted silently', () async {
      final mode = await buildMode();
      await mode.start();
      lastOnInterruption!(true);
      micInterruptions.clear();

      mode.stop();

      expect(mode.micInterrupted, isFalse);
      expect(micInterruptions, isEmpty);
    });

    // Capture events are turn-scoped like the audio chunks: the mic session a
    // restart replaced is already stopped, and its late resume event would
    // clear the flag of the live one.
    test('an interruption from the capture a restart replaced is ignored', () async {
      final mode = await buildMode();
      await mode.start();
      final staleOnInterruption = lastOnInterruption!;

      await mode.restart();
      lastOnInterruption!(true);
      micInterruptions.clear();

      staleOnInterruption(false);

      expect(mode.micInterrupted, isTrue, reason: 'живой захват всё ещё без микрофона');
      expect(micInterruptions, isEmpty);
    });

    test('stop() disposes capture and cancels the hub turn', () async {
      final mode = await buildMode();
      await mode.start();
      mode.stop();

      expect(mode.isRunning, isFalse);
      expect(capture.disposeCalls, 1);
      expect(session.cancelled, 1);
    });

    test('restart() rebuilds the socket and KEEPS the conversation', () async {
      final mode = await buildMode();
      await mode.start();
      final old = session;
      session.events.onResumptionHandle?.call('H1');

      await mode.restart();

      expect(mode.isRunning, isTrue);
      expect(captureCalls, 2, reason: 'захват перезапущен');
      // The point of the whole exercise: a NEW socket. Restarting capture
      // around the same dying socket would look identical from the outside
      // and achieve nothing.
      expect(identical(session, old), isFalse, reason: 'сокет действительно новый');
      expect(old.toreDown, 1, reason: 'старый сокет закрыт — сервер этого и требует');
      expect(session.begun, isNotEmpty, reason: 'новый сокет получил begin-кадр');
      expect(hub.canResumeConversation, isTrue, reason: 'разговор переживает пересборку сокета');
    });

    test('restart() starts a stopped mode rather than politely doing nothing', () async {
      // The recovery path calls this after a failed rebuild has already left
      // the mode stopped; a no-op there would leave the toggle showing "on"
      // with no session behind it.
      final mode = await buildMode();
      await mode.restart();
      expect(mode.isRunning, isTrue);
      expect(captureCalls, 1);
    });

    test('stop() during startCapture: осиротевший капчер гасится, микрофон не висит', () async {
      // Гонка с живого теста Игоря 24.08: стоп во время восстановления сессии
      // оставлял готовый капчер без хозяина — индикатор микрофона висел вечно
      // при выключенном режиме.
      hub = buildHub();
      await hub.ensureWarm();
      clock = _FakeClock();
      final captureReady = Completer<HubPttCapture>();
      final lateCapture = _FakeCapture();
      final mode = FreeFormVoiceMode(
        hub: hub,
        startCapture: (_) => captureReady.future,
        mintTurnId: () => 'race-turn',
        clock: clock,
        now: () => 0,
      );
      final starting = mode.start();
      mode.stop(); // пользователь выключил, пока капчер строился
      captureReady.complete(lateCapture);
      await starting;

      expect(mode.isRunning, isFalse);
      // Без пост-await защиты в start() здесь был бы 0 — захват жил бы вечно.
      expect(lateCapture.disposeCalls, 1);
    });

    test('stop() while not running is a no-op', () async {
      final mode = await buildMode();
      mode.stop();
      expect(session.cancelled, 0);
    });

    test('a capture start failure cancels the turn and leaves the mode not running', () async {
      captureError = StateError('mic denied');
      final mode = await buildMode();

      await expectLater(mode.start(), throwsStateError);

      expect(mode.isRunning, isFalse);
      expect(session.cancelled, 1);
    });

    test('idle timeout auto-stops and fires onIdleTimeout', () async {
      final mode = await buildMode(idleTimeout: () => const Duration(minutes: 3));
      await mode.start();
      expect(clock.pending, isTrue);

      clock.fire();

      expect(idleTimeoutCalls, 1);
      expect(mode.isRunning, isFalse);
      expect(capture.disposeCalls, 1);
    });

    test('noteActivity() rearms the idle timer instead of letting it fire', () async {
      final mode = await buildMode();
      await mode.start();
      final firstHandleCount = clock.pending;
      expect(firstHandleCount, isTrue);

      mode.noteActivity();

      // The old timer was cancelled and a fresh one armed — still exactly
      // one pending, mode still running, no timeout fired yet.
      expect(clock.pending, isTrue);
      expect(idleTimeoutCalls, 0);
      expect(mode.isRunning, isTrue);
    });

    test('noteActivity() while not running is a no-op', () async {
      final mode = await buildMode();
      mode.noteActivity();
      expect(clock.pending, isFalse);
    });

    test('a resolver returning null disables the auto-stop timer', () async {
      final mode = await buildMode(idleTimeout: () => null);
      await mode.start();

      expect(clock.pending, isFalse);
      expect(mode.isRunning, isTrue);
    });

    // The setting behind the resolver is user-editable while the app runs, and
    // this object is built once at bootstrap — so a changed value has to reach
    // the timer without anything being rebuilt.
    test('the idle timeout is re-read on every arm, not captured once', () async {
      Duration? current = const Duration(minutes: 3);
      final mode = await buildMode(idleTimeout: () => current);
      await mode.start();
      expect(clock.lastDuration, const Duration(minutes: 3));

      current = const Duration(minutes: 10);
      mode.noteActivity();
      expect(clock.lastDuration, const Duration(minutes: 10));

      // ...including all the way to "never", which must cancel the pending
      // timer rather than leave the old one armed.
      current = null;
      mode.noteActivity();
      expect(clock.pending, isFalse);
      expect(mode.isRunning, isTrue);
    });

    test('a mode built without a resolver still auto-stops after the stock 3 minutes', () async {
      hub = buildHub();
      await hub.ensureWarm();
      clock = _FakeClock();
      final mode = FreeFormVoiceMode(
        hub: hub,
        startCapture: fakeStartCapture,
        mintTurnId: () => 'turn-default',
        clock: clock,
        now: () => 0,
      );
      await mode.start();

      expect(clock.lastDuration, const Duration(minutes: kDefaultFreeFormVoiceIdleTimeoutMinutes));
    });

    test('an explicit stop() cancels a pending idle timer without firing onIdleTimeout', () async {
      final mode = await buildMode();
      await mode.start();
      mode.stop();

      expect(clock.pending, isFalse);
      expect(idleTimeoutCalls, 0);
    });

    // The regression these guard: before `freeFormActivityEvents` existed
    // NOTHING called `noteActivity()` in production, so the mode auto-stopped
    // a fixed interval after `start()` however much the user was talking.
    group('freeFormActivityEvents', () {
      // A rearm is observed through the resolver: change what it returns, fire
      // an event, and a fresh `lastDuration` proves the timer was re-armed
      // rather than left alone.
      Future<(FreeFormVoiceMode, HubControllerEvents, void Function(Duration?))> wired(
        HubControllerEvents inner,
      ) async {
        Duration? current = const Duration(minutes: 3);
        final mode = await buildMode(idleTimeout: () => current);
        await mode.start();
        return (mode, freeFormActivityEvents(inner, mode.noteActivity), (Duration? d) => current = d);
      }

      test('every content event rearms the clock and still reaches the inner handler', () async {
        final seen = <String>[];
        final (_, events, setTimeout) = await wired(HubControllerEvents(
          onInputTranscript: (t, f, i) => seen.add('in:$t'),
          onAssistantText: (t, f, i) => seen.add('out:$t'),
          onUserSpeechState: (speaking) => seen.add('vad:$speaking'),
          onSpeakingStart: () => seen.add('speak-start'),
          onSpeakingEnd: () => seen.add('speak-end'),
          onToolRequest: (call, i) => seen.add('tool:${call.name}'),
          onTurnDone: (i) => seen.add('turn-done'),
        ));

        var minutes = 4;
        for (final fire in <void Function()>[
          () => events.onInputTranscript!('привет', false, null),
          () => events.onAssistantText!('здравствуй', false, null),
          // The user simply opening their mouth counts — and counts earliest:
          // the VAD says so ~1s before any transcript of that sentence exists.
          () => events.onUserSpeechState!(true),
          () => events.onUserSpeechState!(false),
          () => events.onSpeakingStart!(),
          () => events.onSpeakingEnd!(),
          () => events.onToolRequest!(
              const HubToolCallRequest(name: 'ask_claude', callId: 'c1', argumentsJson: '{}'), null),
          () => events.onTurnDone!(null),
        ]) {
          setTimeout(Duration(minutes: minutes));
          fire();
          expect(clock.lastDuration, Duration(minutes: minutes),
              reason: 'event #$minutes did not rearm the idle timer');
          minutes += 1;
        }

        expect(seen, [
          'in:привет',
          'out:здравствуй',
          'vad:true',
          'vad:false',
          'speak-start',
          'speak-end',
          'tool:ask_claude',
          'turn-done',
        ]);
      });

      test('an event the host does not listen to still rearms the clock', () async {
        final (mode, events, setTimeout) = await wired(const HubControllerEvents());

        setTimeout(const Duration(minutes: 7));
        events.onInputTranscript!('слышно?', false, null);

        expect(clock.lastDuration, const Duration(minutes: 7));
        expect(mode.isRunning, isTrue);
      });

      // A socket that reconnects itself in an empty room must still time out —
      // otherwise the auto-off never fires on an abandoned session, which is
      // the whole point of the timeout (it is billed per minute of input).
      test('connect/error/cascade are NOT activity: passed through, clock untouched', () async {
        var connected = 0;
        var errors = 0;
        final (_, events, setTimeout) = await wired(HubControllerEvents(
          onConnected: (_) => connected += 1,
          onError: (_) => errors += 1,
        ));

        setTimeout(const Duration(minutes: 9));
        events.onConnected!('sess-2');
        events.onError!(const HubControllerError(reason: 'socket died', retryable: true, aliveForMs: 1200));

        expect(connected, 1);
        expect(errors, 1);
        expect(clock.lastDuration, const Duration(minutes: 3), reason: 'clock was rearmed by a non-content event');
      });
    });
  });
}
