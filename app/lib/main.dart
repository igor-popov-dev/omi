import 'dart:async';
import 'dart:ui';
// trigger rebuild

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:marionette_flutter/marionette_flutter.dart';

import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/services/account_cutover/account_cutover_runtime.dart';
import 'package:omi/widgets/bluetooth_guidance_listener.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;
import 'package:provider/provider.dart';
import 'package:talker_flutter/talker_flutter.dart';

import 'package:omi/app_globals.dart';
import 'package:omi/backend/http/shared.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/coordinators/provider_capture_external_actions.dart';
import 'package:omi/core/app_shell.dart';
import 'package:omi/env/dev_env.dart';
import 'package:omi/env/env.dart';
import 'package:omi/env/environment_profile.dart';
import 'package:omi/env/prod_env.dart';
import 'package:omi/firebase_options_local.dart' as local;
import 'package:omi/firebase_options_prod.dart' as prod;
import 'package:omi/flavors.dart';
import 'package:omi/startup_auth.dart';
import 'package:omi/startup_failure_app.dart';
import 'package:omi/startup_routing.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/apps/providers/add_app_provider.dart';
import 'package:omi/pages/conversation_detail/conversation_detail_provider.dart';
import 'package:omi/pages/payments/payment_method_provider.dart';
import 'package:omi/providers/action_items_provider.dart';
import 'package:omi/providers/announcement_provider.dart';
import 'package:omi/providers/app_provider.dart';
import 'package:omi/providers/auth_provider.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/services/voice_call/voice_call_notification_permission.dart';
import 'package:omi/services/voice_call/voice_call_session.dart';
import 'package:omi/services/voice_hub/earcon.dart';
import 'package:omi/services/voice_hub/free_form_voice_mode_projection.dart';
import 'package:omi/services/voice_hub/free_form_voice_timeout.dart';
import 'package:omi/services/voice_hub/voice_hub_production.dart';
import 'package:omi/providers/connectivity_provider.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/providers/device_provider.dart';
import 'package:omi/providers/folder_provider.dart';
import 'package:omi/providers/goals_provider.dart';
import 'package:omi/providers/home_provider.dart';
import 'package:omi/providers/integration_provider.dart';
import 'package:omi/providers/local_recordings_provider.dart';
import 'package:omi/providers/locale_provider.dart';
import 'package:omi/providers/mcp_provider.dart';
import 'package:omi/providers/memories_provider.dart';
import 'package:omi/providers/message_provider.dart';
import 'package:omi/providers/onboarding_provider.dart';
import 'package:omi/providers/people_provider.dart';
import 'package:omi/providers/speech_profile_provider.dart';
import 'package:omi/providers/sync_provider.dart';
import 'package:omi/providers/task_integration_provider.dart';
import 'package:omi/providers/theme_provider.dart';
import 'package:omi/providers/usage_provider.dart';
import 'package:omi/providers/upstream_sync_provider.dart';
import 'package:omi/providers/user_provider.dart';
import 'package:omi/providers/voice_recorder_provider.dart';
import 'package:omi/providers/phone_call_provider.dart';
import 'package:omi/services/auth_service.dart';
import 'package:omi/services/notifications.dart';
import 'package:omi/services/notifications/action_item_notification_handler.dart';
import 'package:omi/services/notifications/important_conversation_notification_handler.dart';
import 'package:omi/services/notifications/merge_notification_handler.dart';
import 'package:omi/services/devices/connectors/limitless_connection.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/debugging/crashlytics_manager.dart';
import 'package:omi/utils/environment_detector.dart';
import 'package:omi/utils/analytics/rage_click_context_tracker.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/platform/platform_service.dart';
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:omi/utils/notification_channel_strings.dart';
import 'package:omi/utils/theme/glass_backdrop.dart';
import 'package:omi/utils/theme/omi_theme.dart';

/// Параметры Firebase для текущего флейвора — считаются одинаково во ВСЕХ движках.
FirebaseOptions _firebaseOptionsForFlavor() => Env.profile == AppEnvironmentProfile.localDev
    ? local.DefaultFirebaseOptions.currentPlatform
    : prod.DefaultFirebaseOptions.currentPlatform;

/// Инициализация Firebase, которая не убивает запуск.
///
/// `Firebase.apps` пуст до первого `initializeApp` даже когда нативный `[DEFAULT]`
/// уже поднят (на Android его заводит FirebaseInitProvider из google-services.json,
/// на macOS — нативный SDK). Поэтому старая проверка `if (Firebase.apps.isEmpty)`
/// ничего не гарантировала: внутри `initializeApp` firebase_core подтягивает
/// нативные приложения и, если наши apiKey/databaseURL/storageBucket не совпали
/// с нативными, бросает `[core/duplicate-app]`
/// (firebase_core_platform_interface/method_channel_firebase.dart).
///
/// Ловится это только на устройстве и выглядит катастрофой: исключение летит из
/// `_init` до первого кадра, `runApp` не вызывается, и пользователь видит
/// StartupFailureApp с «Omi could not start» — приложение мертво, хотя рядом
/// живёт совершенно рабочее нативное приложение Firebase. Именно так и случилось
/// 23.08 на self-host сборке.
///
/// Правильное поведение: несовпадение конфигурации — повод громко пожаловаться,
/// но НЕ повод не запуститься. Берём то приложение, которое уже есть, и проверяем
/// его проект нашей же проверкой — если проект действительно чужой,
/// `validateFirebaseProject` сам всё скажет.
Future<FirebaseApp> _ensureFirebaseApp() async {
  if (Firebase.apps.isNotEmpty) {
    final existing = Firebase.app();
    Env.validateFirebaseProject(projectId: existing.options.projectId);
    return existing;
  }

  final options = _firebaseOptionsForFlavor();
  Env.validateFirebaseProject(projectId: options.projectId);
  try {
    return await Firebase.initializeApp(options: options);
  } on FirebaseException catch (error) {
    if (error.code != 'duplicate-app') rethrow;
    final existing = Firebase.app();
    debugPrint(
      'Firebase уже поднят нативно (проект ${existing.options.projectId}), '
      'наши параметры (${options.projectId}) с ним разошлись — работаем с существующим.',
    );
    Env.validateFirebaseProject(projectId: existing.options.projectId);
    return existing;
  }
}

/// Background message handler for FCM data messages
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Тот же путь, что и в _init: отдельный движок не должен поднимать [DEFAULT]
  // с параметрами из ресурсов, расходящимися с теми, что использует UI-движок.
  await _ensureFirebaseApp();
  await NotificationChannelStrings.loadAppLocale();

  await AwesomeNotifications().initialize(null, [
    NotificationChannel(
      channelKey: 'channel',
      channelName: NotificationChannelStrings.omiChannelName,
      channelDescription: NotificationChannelStrings.omiChannelDescription,
      defaultColor: const Color(0xFF9D50DD),
      ledColor: Colors.white,
    ),
  ]);

  final data = message.data;
  final messageType = data['type'];
  const channelKey = 'channel';

  // Handle action item messages
  if (messageType == 'action_item_reminder') {
    await ActionItemNotificationHandler.handleReminderMessage(data, channelKey);
  } else if (messageType == 'action_item_update') {
    await ActionItemNotificationHandler.handleUpdateMessage(data, channelKey);
  } else if (messageType == 'action_item_delete') {
    await ActionItemNotificationHandler.handleDeletionMessage(data);
  } else if (messageType == 'merge_completed') {
    await MergeNotificationHandler.handleMergeCompleted(data, channelKey, isAppInForeground: false);
  } else if (messageType == 'important_conversation') {
    await ImportantConversationNotificationHandler.handleImportantConversation(
      data,
      channelKey,
      isAppInForeground: false,
    );
  }
}

Future _init() async {
  // Env
  if (F.env == Environment.prod) {
    Env.init(ProdEnv());
  } else {
    Env.init(DevEnv());
  }
  Env.validateProfilePairing();
  validateApplicationStartupRouting();

  FlutterForegroundTask.initCommunicationPort();

  // Service manager
  await ServiceManager.init();
  LimitlessDeviceConnection.realtimeSuppressionPolicy = () => SharedPreferencesUtil().batchModeEnabled;

  // Firebase
  await _ensureFirebaseApp();

  if (Env.profile.usesFirebaseAuthEmulator && Env.firebaseAuthEmulatorHost.isNotEmpty) {
    await FirebaseAuth.instance.useAuthEmulator(Env.firebaseAuthEmulatorHost, Env.firebaseAuthEmulatorPort);
  }

  await PlatformManager.initializeServices();
  await NotificationChannelStrings.loadAppLocale();
  await NotificationService.instance.initialize();

  // Register FCM background message handler
  if (PlatformManager().isFCMSupported) {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  }

  await SharedPreferencesUtil.init();

  // TestFlight remains a distribution/telemetry signal; production-family
  // builds always use the established production backend.
  if (F.env == Environment.prod) {
    Env.isTestFlight = await EnvironmentDetector.isTestFlight();
  }

  bool isAuth = await resolveStartupAuth(() => AuthService.instance.getIdToken());
  if (isAuth) {
    PlatformManager.instance.analytics.identify();
    // Restore onboarding state from server if not already set locally
    // This handles the case where cached credentials are used on startup
    if (!SharedPreferencesUtil().onboardingCompleted) {
      await AuthService.instance.restoreOnboardingState();
    }
    // Fail-closed cutover gate before product traffic / offline uploads.
    // Anonymous Firebase sessions are not cutover product owners.
    final bootstrapUser = FirebaseAuth.instance.currentUser;
    if (bootstrapUser != null && !bootstrapUser.isAnonymous) {
      await AccountCutoverRuntime.instance.bindAuthenticatedOwner(bootstrapUser.uid);
    }
  }
  initOpus(await opus_flutter.load());

  // Register native BLE bridge
  BleFlutterApi.setUp(BleBridge.instance);

  BleBridge.instance.stateRestoredCallback = (List<String> peripheralUuids) {
    Logger.debug('main: restored ${peripheralUuids.length} BLE peripherals');
  };

  await CrashlyticsManager.init();
  if (isAuth) {
    PlatformManager.instance.crashReporter.identifyUser(
      FirebaseAuth.instance.currentUser?.email ?? '',
      SharedPreferencesUtil().fullName,
      SharedPreferencesUtil().uid,
    );
  }
  FlutterError.onError = (FlutterErrorDetails details) {
    FirebaseCrashlytics.instance.recordFlutterFatalError(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
    return true;
  };

  await ServiceManager.instance().start();
  return;
}

void main() {
  runZonedGuarded(
    () async {
      // Ensure
      if (kDebugMode) {
        MarionetteBinding.ensureInitialized();
      } else {
        WidgetsFlutterBinding.ensureInitialized();
      }
      try {
        await _init();
      } catch (error, stack) {
        // Startup failed before the first frame. Without this the launch
        // storyboard stays on screen forever: runApp() is never reached, and the
        // zone handler below only calls debugPrint, which goes nowhere in
        // profile/release builds. A misconfigured OMI_API_BASE_URL cost about a
        // day of investigation for exactly this reason — the app looked hung
        // when it had in fact thrown a precise, actionable StateError.
        if (Firebase.apps.isNotEmpty) {
          FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        }
        runApp(StartupFailureApp(error: error, stack: stack));
        return;
      }
      runApp(const MyApp());
    },
    (error, stack) {
      debugPrint('Uncaught error: $error\n$stack');
      if (Firebase.apps.isNotEmpty) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      }
    },
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();

  static _MyAppState of(BuildContext context) => context.findAncestorStateOfType<_MyAppState>()!;

  // The navigator key is necessary to navigate using static methods
  // Delegates to the extracted globalNavigatorKey so files don't need to import main.dart
  static GlobalKey<NavigatorState> get navigatorKey => globalNavigatorKey;
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    NotificationUtil.initializeNotificationsEventListeners();
    NotificationUtil.initializeIsolateReceivePort();
    WidgetsBinding.instance.addObserver(this);
    if (SharedPreferencesUtil().devLogsToFileEnabled) {
      DebugLogManager.setEnabled(true);
    }

    super.initState();
  }

  void _deinit() {
    Logger.debug("App > _deinit");
    ServiceManager.instance().deinit();
    ApiClient.dispose();
  }

  Future<void> _refreshAccountCutoverThenWakeUploads() async {
    if (!AuthService.instance.isSignedIn()) {
      await AccountCutoverRuntime.instance.bindAuthenticatedOwner(null);
      return;
    }
    // Apply fresh cutover control before waking WAL recovery so a stale
    // legacy/allow projection cannot admit one offline upload.
    final resumeUser = FirebaseAuth.instance.currentUser;
    final resumeOwner = (resumeUser != null && !resumeUser.isAnonymous) ? resumeUser.uid : null;
    await AccountCutoverRuntime.instance.bindAuthenticatedOwner(resumeOwner);
    SyncReconciler.instance.onForeground();
    unawaited(SyncUploadGate.instance.reconcileFairUseStatus());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshAccountCutoverThenWakeUploads());
    } else if (state == AppLifecycleState.paused) {
      SyncReconciler.instance.onBackground();
      _onAppPaused();
    } else if (state == AppLifecycleState.detached) {
      _deinit();
    }
  }

  void _onAppPaused() {
    imageCache.clear();
    imageCache.clearLiveImages();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ListenableProvider(create: (context) => ConnectivityProvider()),
        ChangeNotifierProvider(create: (context) => AuthenticationProvider()),
        ChangeNotifierProvider(create: (context) => ConversationProvider()),
        ListenableProvider(create: (context) => AppProvider()),
        ChangeNotifierProvider(create: (context) => PeopleProvider()),
        ChangeNotifierProvider(create: (context) => UsageProvider()),
        ChangeNotifierProxyProvider<AppProvider, MessageProvider>(
          create: (context) => MessageProvider(),
          update: (BuildContext context, value, MessageProvider? previous) =>
              (previous?..updateAppProvider(value)) ?? MessageProvider(),
        ),
        ChangeNotifierProxyProvider4<ConversationProvider, MessageProvider, PeopleProvider, UsageProvider,
            CaptureProvider>(
          create: (context) {
            final capture = CaptureProvider();
            // Gated by `pttHubEnabled` (dev flag, default off — see
            // `voice_turn_host.dart`'s `selectPttRoute` kill-switch) at every
            // real call site; constructing/assigning the driver here is
            // itself side-effect-free (no I/O until a turn actually starts).
            capture.hubTurnDriver = createProductionVoiceHubTurnDriver(
              applyProjection: (projection) => capture.hubProjection.value = projection,
              pttHubEnabled: () => SharedPreferencesUtil().pttHubEnabled,
            );
            // Gated by the `freeFormMode` dev flag at the one real call
            // site (the chat toggle button, `FreeFormVoiceModeButton`) —
            // constructing it here is side-effect-free, same as
            // `hubTurnDriver` above (no I/O until `startFreeFormVoiceMode`
            // actually calls `FreeFormVoiceMode.start()`).
            capture.onVoiceModeStartSound = () {
              unawaited(voiceStartEarcon.play());
              // Прогрев «думаю» на старте режима: холодный первый play() —
              // сотни миллисекунд, сигнал опаздывал к концу фразы или терялся.
              unawaited(thinkingEarcon.preload());
              // Фразы-статусы ожидания ask_claude: греем только плеер, файл
              // выбирается по активности в момент фразы (см. ProgressVoice).
              unawaited(progressVoice.preload());
            };
            // Telecom call shell: the running voice session is a self-managed
            // Android call (CallStyle notification, hang-up on the lock
            // screen, background-mic legality) — voice-call-mode-design.md.
            // Fail-open everywhere: on iOS or any telecom refusal the mode
            // just runs without the shell.
            final voiceCallSession = VoiceCallSession();
            voiceCallSession.onEndedBySystem = capture.stopFreeFormVoiceMode;
            // Self-host (02.09): без POST_NOTIFICATIONS (слетает после
            // `adb install -r`) уведомление «идёт разговор» не показывается —
            // спрашиваем перед звонком, только с экрана, один раз за запуск.
            capture.onVoiceModeCallStart = () async {
              await ensureVoiceCallNotificationPermission();
              await voiceCallSession.start();
            };
            capture.onVoiceModeCallEnd = voiceCallSession.end;
            capture.freeFormVoiceMode = createProductionFreeFormVoiceMode(
              // Живая иконка в чате дышит по громкости ответа ассистента.
              outputEnvelope: capture.voiceOutputEnvelope,
              events: freeFormModeProjectionEvents(
                // Гейт по активности: поздние события уже остановленной сессии
                // (хвост speaking-end и т.п.) перещёлкивали индикатор обратно в
                // «слушаю» при выключенном режиме (баг Игоря 24.08).
                applyProjection: (projection) {
                  if (capture.freeFormModeActive.value) capture.hubProjection.value = projection;
                },
                onDisconnected: capture.recoverFreeFormVoiceMode,
                // Self-host patch: the spoken exchange lands in chat history, so
                // the voice and chat assistants share one conversation instead of
                // each pretending the other never happened.
                chatLog: capture.voiceChatLog,
                onSocketExpiring: capture.rebuildFreeFormVoiceModeSocket,
                // Звук «услышал, думаю» по концу речи пользователя (тот же гейт
                // по активности, что и у индикатора выше: хвост событий уже
                // остановленной сессии не должен звучать).
                onThinkingStart: () {
                  if (capture.freeFormModeActive.value) unawaited(thinkingEarcon.play());
                },
              ),
              // Read per arm, not captured once: the user can change the
              // auto-off in Developer -> Experimental while the app is
              // running, and this object is built once here and never rebuilt.
              resolveIdleTimeout: () =>
                  freeFormIdleTimeoutFromMinutes(SharedPreferencesUtil().freeFormVoiceIdleTimeoutMinutes),
              // Полный stop (не только сброс UI): выключение по тишине тоже
              // обязано рвать тёплую сессию — иначе она держит аудиорежим.
              onIdleTimeout: capture.stopFreeFormVoiceMode,
              // Модель сама закончила разговор (end_conversation): гасим режим
              // штатно — стоп, сброс UI, досылка диалога в чат, перечитка.
              onConversationEnd: capture.stopFreeFormVoiceMode,
              // The mic can be taken away mid-session (a call, another app).
              // Nothing else in the wiring notices: the hub only sees frames
              // stop arriving, which is indistinguishable from a person who
              // has stopped talking.
              onMicInterruption: capture.applyFreeFormMicInterruption,
            );
            return capture;
          },
          update: (BuildContext context, conversation, message, people, usage, CaptureProvider? previous) {
            final externalActions = ProviderCaptureExternalActions(
              conversationProvider: conversation,
              messageProvider: message,
              peopleProvider: people,
              usageProvider: usage,
            );
            return (previous?..updateExternalActions(externalActions)) ??
                CaptureProvider(externalActions: externalActions);
          },
        ),
        ChangeNotifierProxyProvider<ConversationProvider, LocalRecordingsProvider>(
          create: (context) => LocalRecordingsProvider(),
          update: (BuildContext context, conversation, LocalRecordingsProvider? previous) =>
              (previous?..setConversationProvider(conversation)) ?? LocalRecordingsProvider(),
        ),
        ChangeNotifierProxyProvider2<CaptureProvider, LocalRecordingsProvider, DeviceProvider>(
          create: (context) => DeviceProvider(),
          update: (BuildContext context, captureProvider, localRecordings, DeviceProvider? previous) =>
              (previous?..setProviders(captureProvider, localRecordings)) ?? DeviceProvider(),
        ),
        ChangeNotifierProxyProvider<DeviceProvider, OnboardingProvider>(
          create: (context) => OnboardingProvider(),
          update: (BuildContext context, value, OnboardingProvider? previous) =>
              (previous?..setDeviceProvider(value)) ?? OnboardingProvider(),
        ),
        ListenableProvider(create: (context) => HomeProvider()),
        ChangeNotifierProxyProvider<DeviceProvider, SpeechProfileProvider>(
          create: (context) => SpeechProfileProvider(),
          update: (BuildContext context, device, SpeechProfileProvider? previous) =>
              (previous?..setProviders(device)) ?? SpeechProfileProvider(),
        ),
        ChangeNotifierProxyProvider2<AppProvider, ConversationProvider, ConversationDetailProvider>(
          create: (context) => ConversationDetailProvider(),
          update: (BuildContext context, app, conversation, ConversationDetailProvider? previous) =>
              (previous?..setProviders(app, conversation)) ?? ConversationDetailProvider(),
        ),
        ChangeNotifierProxyProvider<AppProvider, AddAppProvider>(
          create: (context) => AddAppProvider(),
          update: (BuildContext context, value, AddAppProvider? previous) =>
              (previous?..setAppProvider(value)) ?? AddAppProvider(),
        ),
        ChangeNotifierProxyProvider<ConnectivityProvider, MemoriesProvider>(
          create: (context) => MemoriesProvider(),
          update: (context, connectivity, previous) =>
              (previous?..setConnectivityProvider(connectivity)) ?? MemoriesProvider(),
        ),
        ChangeNotifierProvider(create: (context) => UserProvider()),
        ChangeNotifierProvider(lazy: true, create: (context) => ActionItemsProvider()),
        ChangeNotifierProvider(lazy: true, create: (context) => GoalsProvider()..init()),
        ChangeNotifierProvider(create: (context) => SyncProvider()),
        ChangeNotifierProvider(lazy: true, create: (context) => TaskIntegrationProvider()),
        ChangeNotifierProvider(lazy: true, create: (context) => IntegrationProvider()),
        ChangeNotifierProvider(lazy: true, create: (context) => FolderProvider()),
        ChangeNotifierProvider(lazy: true, create: (context) => McpProvider()),
        ChangeNotifierProvider(lazy: true, create: (context) => PaymentMethodProvider()),
        ChangeNotifierProvider(create: (context) => VoiceRecorderProvider()..checkPendingRecording()),
        // Self-host patch (providers/upstream_sync_provider.dart, docs/selfhost-patches.md):
        // пульт апстрим-синка. lazy — на чужом сервере роутов нет, и запрос
        // не должен уходить, пока плашку никто не смотрит.
        ChangeNotifierProvider(lazy: true, create: (context) => UpstreamSyncProvider()..refresh()),
        ChangeNotifierProvider(create: (context) => LocaleProvider()),
        ChangeNotifierProvider(create: (context) => ThemeProvider()),
        ChangeNotifierProvider(create: (context) => AnnouncementProvider()),
        // A call must hush the phone's own always-on recording, or one call becomes two
        // conversations and the two captures fight over the microphone (lane 6 tick 22).
        // Wired here rather than inside the provider so calls keep knowing nothing about
        // the capture stack.
        ChangeNotifierProxyProvider<CaptureProvider, PhoneCallProvider>(
          lazy: true,
          create: (context) => PhoneCallProvider(),
          update: (BuildContext context, capture, PhoneCallProvider? previous) {
            final phoneCalls = previous ?? PhoneCallProvider();
            phoneCalls.ambientCapture.gate =
                (paused) => paused ? capture.pauseForInAppCall() : capture.resumeAfterInAppCall();
            // The gate above hushes the always-on capture only. The arbiter is the other
            // half: it is what refuses a chat voice memo or a speech profile started
            // mid-call, which would otherwise record silence beside the live call and
            // report success.
            phoneCalls.ambientCapture.arbiter = ServiceManager.instance().micArbiter;
            return phoneCalls;
          },
        ),
      ],
      builder: (context, child) {
        final themeProvider = context.watch<ThemeProvider>();
        return WithForegroundTask(
          child: MaterialApp(
            debugShowCheckedModeBanner: F.env == Environment.dev,
            title: F.title,
            navigatorKey: MyApp.navigatorKey,
            locale: context.watch<LocaleProvider>().locale,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: AppLocalizations.supportedLocales,
            theme: themeProvider.themeData,
            builder: (context, child) {
              FlutterError.onError = (FlutterErrorDetails details) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  Logger.instance.talker.handle(details.exception, details.stack);
                  DebugLogManager.logError(details.exception, details.stack, 'FlutterError');
                });
              };
              ErrorWidget.builder = (errorDetails) {
                return CustomErrorWidget(errorMessage: errorDetails.exceptionAsString());
              };
              final content = child!;
              final guidedContent = BluetoothGuidanceListener(child: content);
              // Т8: матовое стекло существует только в Glass — в Classic слой
              // не вставляется в дерево вовсе.
              final themed = themeProvider.isGlass ? GlassBackdrop(child: guidedContent) : guidedContent;
              return PlatformService.isIOS && Env.posthogApiKey != null
                  ? RageClickContextTracker(child: themed)
                  : themed;
            },
            home: AnnotatedRegion<SystemUiOverlayStyle>(
              // Glass is a light theme, so the status bar and the Android
              // navigation bar both need dark icons on transparent bars; see
              // [omiSystemUiOverlayStyle]. This region spans the whole app, so
              // it is what drives the navigation bar at the bottom of the
              // screen — an AppBar only ever overrides the status bar half.
              value: omiSystemUiOverlayStyle(themeProvider.isGlass),
              child: TalkerWrapper(
                talker: Logger.instance.talker,
                options: const TalkerWrapperOptions(enableErrorAlerts: false, enableExceptionAlerts: false),
                child: const AppShell(),
              ),
            ),
          ),
        );
      },
    );
  }
}

class CustomErrorWidget extends StatelessWidget {
  final String errorMessage;

  const CustomErrorWidget({super.key, required this.errorMessage});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 50.0),
            const SizedBox(height: 10.0),
            Text(
              context.l10n.somethingWentWrong,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18.0, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10.0),
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.all(16),
              height: 200,
              decoration: BoxDecoration(
                color: const Color.fromARGB(255, 63, 63, 63),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(errorMessage, textAlign: TextAlign.start, style: const TextStyle(fontSize: 16.0)),
            ),
            const SizedBox(height: 10.0),
            SizedBox(
              width: 210,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: errorMessage));
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.errorCopied)));
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(context.l10n.copyErrorMessage),
                    const SizedBox(width: 10),
                    const Icon(Icons.copy_rounded),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
