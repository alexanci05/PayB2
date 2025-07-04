import 'package:flutter/material.dart';
import 'package:payb2/controladores/registrar_usuario.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();

    // Registrar usuario para notificaciones al entrar por primera vez
    registerUserForNotifications();
  }

  void _onCrearGrupo(BuildContext context) {
    Navigator.pushNamed(context, '/crearGrupo');
  }

  void _onUnirseGrupo(BuildContext context) {
    Navigator.pushNamed(context, '/unirseGrupo');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PayB2'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            const Text(
              '¡Bienvenido a PayB2!',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              onPressed: () => _onCrearGrupo(context),
              icon: const Icon(Icons.group_add),
              label: const Text('Crear Grupo'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _onUnirseGrupo(context),
              icon: const Icon(Icons.meeting_room),
              label: const Text('Unirse a Grupo'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
