import 'package:flutter/material.dart';
import 'screens/home/main_screen.dart';
import 'screens/crear_grupo/crear_grupo_screen.dart';
import 'screens/unirse_grupo/unirse_grupo_screen.dart'; 
import 'package:provider/provider.dart';
import 'providers/theme_provider.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) {
          return MaterialApp(
            title: 'PayB2',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(primarySwatch: Colors.indigo),
            darkTheme: ThemeData.dark(),
            themeMode: themeProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
            initialRoute: '/',
            routes: {
              '/': (context) => const MainScreen(),
              '/crearGrupo': (context) => const CrearGrupoScreen(),
              '/unirseGrupo': (context) => const UnirseGrupoScreen(),
            },
          );
        },
      ),
    );
  }
}
