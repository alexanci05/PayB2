import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../controladores/registrar_usuario.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService shared = NotificationService._();

  static const _enabledPreferenceKey = 'notifications.enabled';
  static const _permissionRequestedPreferenceKey =
      'notifications.permissionRequested';

  final ValueNotifier<bool> _enabled = ValueNotifier<bool>(false);
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();
  final AndroidNotificationChannel _androidChannel =
      const AndroidNotificationChannel(
        'canal_notificaciones',
        'Notificaciones',
        importance: Importance.high,
      );

  Future<void>? _initialization;
  Future<void> _stateChanges = Future<void>.value();
  Future<void> _tokenOperations = Future<void>.value();
  StreamSubscription<RemoteMessage>? _foregroundMessages;
  StreamSubscription<String>? _tokenRefresh;
  int _registrationGeneration = 0;

  ValueListenable<bool> get enabled => _enabled;
  bool get isEnabled => _enabled.value;

  Future<void> initialize() {
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    await _initializeLocalNotifications();
    _foregroundMessages ??= FirebaseMessaging.onMessage.listen(
      _showForegroundNotification,
    );

    final preferences = await SharedPreferences.getInstance();
    var settings = await FirebaseMessaging.instance.getNotificationSettings();
    final permissionWasRequested =
        preferences.getBool(_permissionRequestedPreferenceKey) ?? false;

    if (!permissionWasRequested) {
      settings = await _requestPermission(preferences);
    }

    final storedEnabled =
        preferences.getBool(_enabledPreferenceKey) ?? _isAuthorized(settings);
    await _applyStatus(storedEnabled && _isAuthorized(settings), preferences);

    if (_enabled.value) {
      await _registerCurrentToken();
    }
  }

  Future<bool> setEnabled(bool enabled) {
    final result = _stateChanges.then((_) => _setEnabled(enabled));
    _stateChanges = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  Future<bool> _setEnabled(bool enabled) async {
    await initialize();
    final preferences = await SharedPreferences.getInstance();

    if (!enabled) {
      await preferences.setBool(_enabledPreferenceKey, false);
      await _applyStatus(false, preferences);
      await _enqueueTokenOperation(removeCurrentDeviceMessagingToken);
      return true;
    }

    var settings = await FirebaseMessaging.instance.getNotificationSettings();
    if (!_isAuthorized(settings)) {
      settings = await _requestPermission(preferences);
    }

    final authorized = _isAuthorized(settings);
    await _applyStatus(authorized, preferences);
    if (!authorized) return false;

    await _registerCurrentToken();
    return true;
  }

  Future<void> refreshStatus() async {
    await initialize();

    final preferences = await SharedPreferences.getInstance();
    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    final storedEnabled = preferences.getBool(_enabledPreferenceKey) ?? false;
    await _applyStatus(storedEnabled && _isAuthorized(settings), preferences);
  }

  Future<void> refreshRegistration() async {
    await refreshStatus();
    if (_enabled.value) {
      await _registerCurrentToken();
    }
  }

  Future<void> _initializeLocalNotifications() async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );

    await _localNotifications.initialize(settings);
    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(_androidChannel);
  }

  Future<NotificationSettings> _requestPermission(
    SharedPreferences preferences,
  ) async {
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    await preferences.setBool(_permissionRequestedPreferenceKey, true);
    return settings;
  }

  Future<void> _applyStatus(bool enabled, SharedPreferences preferences) async {
    await preferences.setBool(_enabledPreferenceKey, enabled);
    _enabled.value = enabled;

    if (!enabled) {
      _registrationGeneration += 1;
      await _stopTokenRefresh();
    }
  }

  Future<void> _registerCurrentToken() async {
    final registrationGeneration = _registrationGeneration;
    await _enqueueTokenOperation(() async {
      if (!_enabled.value ||
          registrationGeneration != _registrationGeneration) {
        return;
      }

      await registerUserForNotifications();
    });

    if (!_enabled.value || registrationGeneration != _registrationGeneration) {
      return;
    }

    _tokenRefresh ??= FirebaseMessaging.instance.onTokenRefresh.listen((
      token,
    ) async {
      try {
        await _enqueueTokenOperation(() async {
          if (!_enabled.value ||
              registrationGeneration != _registrationGeneration) {
            return;
          }

          await saveMessagingTokenForCurrentUser(token);
        });
      } catch (error, stackTrace) {
        debugPrint('No se pudo renovar el token FCM: $error\n$stackTrace');
      }
    });
  }

  Future<void> _stopTokenRefresh() async {
    await _tokenRefresh?.cancel();
    _tokenRefresh = null;
  }

  Future<void> _enqueueTokenOperation(Future<void> Function() operation) {
    final result = _tokenOperations.then((_) => operation());
    _tokenOperations = result.catchError((_) {});
    return result;
  }

  Future<void> _showForegroundNotification(RemoteMessage message) async {
    if (!_enabled.value) return;

    final notification = message.notification;
    if (notification == null) return;

    await _localNotifications.show(
      notification.hashCode,
      notification.title,
      notification.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannel.id,
          _androidChannel.name,
          importance: Importance.max,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
    );
  }

  bool _isAuthorized(NotificationSettings settings) {
    return settings.authorizationStatus == AuthorizationStatus.authorized;
  }
}
