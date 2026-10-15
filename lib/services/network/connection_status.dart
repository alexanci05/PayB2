import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

enum ConnectionCondition { online, checking, offline, cached, serviceError }

class ConnectionStatus extends ChangeNotifier {
  static final shared = ConnectionStatus();

  bool _hasNetwork = true;
  bool _confirmed = false;
  bool _checking = true;
  bool _serviceError = false;
  bool _started = false;
  Timer? _confirmationTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  StreamSubscription<User?>? _auth;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _memberships;
  int _session = 0;

  ConnectionCondition get condition {
    if (!_hasNetwork) return ConnectionCondition.offline;
    if (_serviceError) return ConnectionCondition.serviceError;
    if (_confirmed) return ConnectionCondition.online;
    return _checking
        ? ConnectionCondition.checking
        : ConnectionCondition.cached;
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    final connectivity = Connectivity();
    _connectivity = connectivity.onConnectivityChanged.listen(
      updateNetwork,
      onError: (Object error) =>
          debugPrint('Estado de red no disponible: $error'),
    );
    await refreshNetwork();
    _auth = FirebaseAuth.instance.authStateChanges().listen(_watchSession);
  }

  Future<void> refreshNetwork() async {
    try {
      updateNetwork(await Connectivity().checkConnectivity());
    } catch (error) {
      debugPrint('No se pudo comprobar la red: $error');
    }
  }

  void updateNetwork(List<ConnectivityResult> connections) {
    _hasNetwork = connections.any(
      (result) => result != ConnectivityResult.none,
    );
    if (!_hasNetwork) _confirmed = false;
    notifyListeners();
  }

  void updateCacheState(bool fromCache) {
    _confirmationTimer?.cancel();
    _confirmed = !fromCache;
    _checking = fromCache;
    if (fromCache) {
      _confirmationTimer = Timer(const Duration(seconds: 8), () {
        _checking = false;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  void reportFailure(Object error) {
    if (error is FirebaseException &&
        {
          'unavailable',
          'deadline-exceeded',
          'internal',
          'network-request-failed',
        }.contains(error.code)) {
      _serviceError = true;
      notifyListeners();
    }
  }

  void confirmBackendOperation() {
    if (!_serviceError) return;
    _serviceError = false;
    notifyListeners();
  }

  void dismissServiceError() => confirmBackendOperation();

  void _watchSession(User? user) {
    final session = ++_session;
    unawaited(_memberships?.cancel());
    _memberships = null;
    updateCacheState(true);
    if (user == null) return;
    _memberships = FirebaseFirestore.instance
        .collection('groupMembers')
        .where('deviceId', isEqualTo: user.uid)
        .snapshots(includeMetadataChanges: true)
        .listen(
          (snapshot) {
            if (session != _session) return;
            updateCacheState(snapshot.metadata.isFromCache);
          },
          onError: (Object error) {
            if (session != _session) return;
            updateCacheState(true);
            reportFailure(error);
          },
        );
  }

  @override
  void dispose() {
    _confirmationTimer?.cancel();
    unawaited(_memberships?.cancel());
    unawaited(_connectivity?.cancel());
    unawaited(_auth?.cancel());
    super.dispose();
  }
}

Future<T> runBackendRequest<T>(Future<T> Function() request) async {
  try {
    final result = await request();
    ConnectionStatus.shared.confirmBackendOperation();
    return result;
  } catch (error) {
    ConnectionStatus.shared.reportFailure(error);
    rethrow;
  }
}

extension ObservedCallable on HttpsCallable {
  Future<HttpsCallableResult<T>> callObserved<T>([dynamic parameters]) =>
      runBackendRequest(() => call<T>(parameters));
}
