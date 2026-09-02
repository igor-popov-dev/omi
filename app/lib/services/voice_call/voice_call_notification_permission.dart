// Self-host (02.09): на Android 13+ без runtime-разрешения POST_NOTIFICATIONS
// уведомление phoneCall-сервиса (CallStyle «идёт разговор» — VoiceCallForeground-
// Service.kt) система не показывает, хотя сам звонок и сервис живут. После
// `adb install -r` runtime-разрешения на этом телефоне уже слетали (WORKLOG
// 23.08, BLE/Location) — значок «пропадает» молча, и никто его не просит
// обратно: при старте голосового режима запрашивается только микрофон.
//
// Просим здесь, ДО placeCall, и только когда приложение на экране: старт с
// кулона при заблокированном телефоне диалог показать не сможет, а ждать его
// ответа нельзя. Одна попытка за запуск приложения — «нет» не переспрашиваем.
// Fail-open, как и вся оболочка: любая ошибка — лог и продолжение.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:omi/utils/logger.dart';
import 'package:permission_handler/permission_handler.dart';

bool _asked = false;

/// Ensures POST_NOTIFICATIONS before the voice-mode call shell is placed.
/// Never throws; a denied or unanswerable request only costs the status-bar
/// «Voice conversation» notification, not the session.
Future<void> ensureVoiceCallNotificationPermission({
  Future<PermissionStatus> Function()? status,
  Future<PermissionStatus> Function()? request,
  bool Function()? appVisible,
  bool? isAndroid,
}) async {
  if (!(isAndroid ?? Platform.isAndroid)) return;
  try {
    final current = await (status ?? () => Permission.notification.status)();
    if (current.isGranted) return;
    final visible = appVisible?.call() ?? (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
    if (!visible) {
      Logger.warning('[VoiceCallSession] нет POST_NOTIFICATIONS, приложение в фоне — '
          'уведомление «идёт разговор» не появится; разрешение спросим при старте с экрана');
      return;
    }
    if (_asked || current.isPermanentlyDenied) {
      Logger.warning('[VoiceCallSession] нет POST_NOTIFICATIONS ($current) — '
          'уведомление «идёт разговор» не появится (Настройки → Уведомления)');
      return;
    }
    _asked = true;
    final result = await (request ?? () => Permission.notification.request())().timeout(const Duration(seconds: 60));
    Logger.debug('[VoiceCallSession] POST_NOTIFICATIONS: $result');
  } catch (e) {
    Logger.debug('[VoiceCallSession] запрос POST_NOTIFICATIONS не удался: $e');
  }
}

@visibleForTesting
void resetVoiceCallNotificationPermissionPrompt() => _asked = false;
