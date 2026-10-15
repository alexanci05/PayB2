import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/services/network/connection_status.dart';
import 'package:payb2/widgets/connection_banner.dart';

void main() {
  testWidgets('connection messages fit a narrow mobile screen', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final condition in ConnectionCondition.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ConnectionBanner(condition: condition)),
        ),
      );
      expect(tester.takeException(), isNull);
    }
  });
}
