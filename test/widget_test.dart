import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/screens/home/home_screen.dart';

void main() {
  testWidgets('la pantalla inicial ofrece los dos accesos principales', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const HomeScreen(),
        routes: {
          '/crearGrupo': (_) => const Scaffold(body: Text('Crear grupo')),
          '/unirseGrupo': (_) => const Scaffold(body: Text('Unirse a grupo')),
        },
      ),
    );

    expect(find.text('¡Bienvenido a PayB2!'), findsOneWidget);
    expect(find.text('Crear Grupo'), findsOneWidget);
    expect(find.text('Unirse a Grupo'), findsOneWidget);

    await tester.tap(find.text('Crear Grupo'));
    await tester.pumpAndSettle();

    expect(find.text('Crear grupo'), findsOneWidget);
  });
}
