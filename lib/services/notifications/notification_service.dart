import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../controladores/registrar_usuario.dart';

class NotificationService {
  NotificationService._({
    Future<void> Function(bool)? setAutoInitEnabled,
    Future<void> Function()? removeRegistration,
  }) : _setAutoInitEnabled =
           setAutoInitEnabled ?? FirebaseMessaging.instance.setAutoInitEnabled,
       _removeRegistration =
           removeRegistration ?? removeCurrentDeviceMessagingToken;

  @visibleForTesting
  factory NotificationService.forTesting({
    required Future<void> Function(bool) setAutoInitEnabled,
    required Future<void> Function() removeRegistration,
  }) => NotificationService._(
    setAutoInitEnabled: setAutoInitEnabled,
    removeRegistration: removeRegistration,
  );

  static final NotificationService shared = NotificationService._();

  static const _enabledPreferenceKey = 'notifications.enabled';
  static const _permissionRequestedPreferenceKey =
      'notifications.permissionRequested';
  static const _removalPendingPreferenceKey = 'notifications.removalPending';
  static const _registrationRevisionPreferenceKey =
      'notifications.registrationRevision';
  static const _removalAcknowledgedRevisionPreferenceKey =
      'notifications.removalAcknowledgedRevision';

  final ValueNotifier<bool> _enabled = ValueNotifier<bool>(false);
  final Future<void> Function(bool) _setAutoInitEnabled;
  final Future<void> Function() _removeRegistration;
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

  Future<void> initialize() async {
    final pendingInitialization = _initialization;
    if (pendingInitialization != null) return pendingInitialization;

    final initialization = _initialize();
    _initialization = initialization;
    try {
      await initialization;
    } catch (_) {
      if (identical(_initialization, initialization)) {
        _initialization = null;
      }
      rethrow;
    }
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
    if (!preferences.containsKey(_enabledPreferenceKey)) {
      await preferences.setBool(_enabledPreferenceKey, storedEnabled);
    }
    final desiredEnabled =
        preferences.getBool(_enabledPreferenceKey) ?? storedEnabled;
    await _applyRuntimeStatus(desiredEnabled && _isAuthorized(settings));

    if (_enabled.value) {
      await _registerCurrentToken();
    } else {
      _scheduleRegistrationRemoval();
    }
  }

  Future<bool> setEnabled(bool enabled) {
    final result = _stateChanges.then((_) => _setEnabled(enabled));
    _stateChanges = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  Future<bool> _setEnabled(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();

    if (!enabled) {
      await preferences.setBool(_removalPendingPreferenceKey, true);
      await preferences.setBool(_enabledPreferenceKey, false);
      await _applyRuntimeStatus(false);
      _scheduleRegistrationRemoval();
      return true;
    }

    await initialize();
    await preferences.setBool(_enabledPreferenceKey, true);

    var settings = await FirebaseMessaging.instance.getNotificationSettings();
    if (!_isAuthorized(settings)) {
      settings = await _requestPermission(preferences);
    }

    final authorized = _isAuthorized(settings);
    await _applyRuntimeStatus(authorized);
    if (!authorized) return false;

    await _registerCurrentToken();
    return true;
  }

  Future<void> refreshStatus() {
    final result = _stateChanges.then((_) => _refreshStatus());
    _stateChanges = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  Future<void> _refreshStatus() async {
    await initialize();

    final preferences = await SharedPreferences.getInstance();
    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    final storedEnabled = preferences.getBool(_enabledPreferenceKey) ?? false;
    await _applyRuntimeStatus(storedEnabled && _isAuthorized(settings));
    if (_enabled.value) {
      await _registerCurrentToken();
    } else {
      _scheduleRegistrationRemoval();
    }
  }

  Future<void> refreshRegistration() async {
    await refreshStatus();
  }

  Future<void> reconcileAccountMerge(Future<void> Function() merge) async {
    final preferences = await SharedPreferences.getInstance();
    // Persist before the request: the server may commit without a client reply.
    await _invalidateRemovalAcknowledgement(preferences);
    try {
      await merge();
    } finally {
      await _invalidateRemovalAcknowledgement(preferences);
      if (preferences.getBool(_enabledPreferenceKey) == false) {
        // Removal takes the identity lock, which the merge caller still owns.
        _scheduleRegistrationRemoval();
      }
    }
  }

  Future<void> _invalidateRemovalAcknowledgement(
    SharedPreferences preferences,
  ) async {
    final revision =
        preferences.getInt(_registrationRevisionPreferenceKey) ?? 0;
    if (!await preferences.setInt(
      _registrationRevisionPreferenceKey,
      revision + 1,
    )) {
      throw StateError(
        'No se pudo guardar la baja pendiente de notificaciones',
      );
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

  Future<void> _applyRuntimeStatus(bool enabled) async {
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

      await _setAutoInitEnabled(true);
      final token = await registerUserForNotifications();
      if (token != null &&
          _enabled.value &&
          registrationGeneration == _registrationGeneration) {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setBool(_removalPendingPreferenceKey, false);
      }
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

  void _scheduleRegistrationRemoval() {
    final generation = _registrationGeneration;
    unawaited(
      _enqueueTokenOperation(() async {
        if (_enabled.value || generation != _registrationGeneration) return;
        await _setAutoInitEnabled(false);
        final preferences = await SharedPreferences.getInstance();
        final pending =
            preferences.getBool(_removalPendingPreferenceKey) ?? true;
        final revision =
            preferences.getInt(_registrationRevisionPreferenceKey) ?? 0;
        final acknowledgedRevision =
            preferences.getInt(_removalAcknowledgedRevisionPreferenceKey) ?? 0;
        if (!pending && revision == acknowledgedRevision) return;

        await _removeRegistration();
        // A late delete must not acknowledge a merge that started after it.
        await preferences.setInt(
          _removalAcknowledgedRevisionPreferenceKey,
          revision,
        );
        await preferences.setBool(_removalPendingPreferenceKey, false);
      }).catchError((Object error, StackTrace stackTrace) {
        debugPrint(
          'La baja de notificaciones sigue pendiente: $error\n$stackTrace',
        );
      }),
    );
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
