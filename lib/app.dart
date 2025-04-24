import 'package:flutter/material.dart';
import 'screens/home/main_screen.dart';
import 'screens/crear_grupo/crear_grupo_screen.dart';
import 'screens/unirse_grupo/unirse_grupo_screen.dart'; // crea este archivo más adelante

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PayB2',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.indigo),
      initialRoute: '/',
      routes: {
        '/': (context) => const MainScreen(),
        //'/': (context) => const HomeScreen(), // Pantalla principal cuando no se pertenece a ningún grupo
        '/crearGrupo': (context) => const CrearGrupoScreen(),
        '/unirseGrupo': (context) => const UnirseGrupoScreen(),
      },
    );
  }
}
