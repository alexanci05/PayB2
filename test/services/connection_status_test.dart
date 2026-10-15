import 'package:cloud_functions/cloud_functions.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/services/network/connection_status.dart';

void main() {
  test('a network interface does not confirm server synchronization', () {
    final status = ConnectionStatus();
    addTearDown(status.dispose);
    status.updateNetwork([ConnectivityResult.none]);
    expect(status.condition, ConnectionCondition.offline);
    status.updateNetwork([ConnectivityResult.wifi]);
    expect(status.condition, isNot(ConnectionCondition.online));
    status.updateCacheState(false);
    expect(status.condition, ConnectionCondition.online);
    status.updateNetwork([ConnectivityResult.none]);
    expect(status.condition, ConnectionCondition.offline);
  });

  test(
    'service failures remain visible despite successful database snapshots',
    () {
      final status = ConnectionStatus();
      addTearDown(status.dispose);
      status.reportFailure(
        FirebaseFunctionsException(code: 'unavailable', message: 'Unavailable'),
      );
      status.updateCacheState(false);
      expect(status.condition, ConnectionCondition.serviceError);
      status.confirmBackendOperation();
      expect(status.condition, ConnectionCondition.online);
      status.reportFailure(
        FirebaseFunctionsException(code: 'invalid-argument', message: 'Invalid'),
      );
      expect(status.condition, ConnectionCondition.online);
    },
  );
}
