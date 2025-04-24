import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';


// Pantalla principal cuando no se pertenece a ningún grupo

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  void _onCrearGrupo(BuildContext context) {
    // Aquí luego navegarás a CrearGrupoScreen
    Navigator.pushNamed(context, '/crearGrupo');
    /*
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Navegar a Crear Grupo')),
    );
    */
  }

  void _onUnirseGrupo(BuildContext context) {
    // Aquí luego navegarás a UnirseGrupoScreen
    // Navigator.pushNamed(context, '/unirseGrupo');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Navegar a Unirse a Grupo')),
    );
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
