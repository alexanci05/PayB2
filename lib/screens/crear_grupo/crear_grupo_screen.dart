import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:payb2/screens/home/main_screen.dart';

class CrearGrupoScreen extends StatefulWidget {
  const CrearGrupoScreen({super.key});

  @override
  CrearGrupoScreenState createState() => CrearGrupoScreenState();
}

class CrearGrupoScreenState extends State<CrearGrupoScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nombreController = TextEditingController();
  final List<TextEditingController> _miembrosControllers = [];

  @override
  void dispose() {
    _nombreController.dispose();
    for (final controller in _miembrosControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _agregarCampoMiembro() {
    setState(() {
      _miembrosControllers.add(TextEditingController());
    });
  }

  void _quitarCampoMiembro(int index) {
    setState(() {
      _miembrosControllers[index].dispose();
      _miembrosControllers.removeAt(index);
    });
  }

  Future<void> _onSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    final nombre = _nombreController.text.trim();
    final memberNames = _miembrosControllers
        .map((controller) => controller.text.trim())
        .where((name) => name.isNotEmpty)
        .toList();

    if (memberNames.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Añade al menos un miembro al grupo')),
      );
      return;
    }

    final normalizedNames = memberNames
        .map((name) => name.toLowerCase())
        .toSet();
    if (normalizedNames.length != memberNames.length) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Los miembros deben tener nombres distintos'),
        ),
      );
      return;
    }

    try {
      final callable = FirebaseFunctions.instance.httpsCallable('crearGrupo');
      await callable.call<Map<String, dynamic>>({
        'nombre': nombre,
        'miembros': memberNames,
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Grupo "$nombre" creado correctamente')),
      );
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const MainScreen()),
        (Route<dynamic> route) => false,
      );
    } on FirebaseFunctionsException catch (error) {
      if (!mounted) return;
      final message = switch (error.code) {
        'unauthenticated' => 'Usuario no autenticado',
        'invalid-argument' => 'Revisa el nombre y los miembros del grupo',
        _ => 'No se pudo crear el grupo',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo conectar con el servidor')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Crear Grupo'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(
                controller: _nombreController,
                decoration: const InputDecoration(
                  labelText: 'Nombre del grupo',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Por favor ingresa un nombre';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              const Text('Miembros del grupo (minimo 1):'),
              ..._miembrosControllers.asMap().entries.map((entry) {
                final index = entry.key;
                final controller = entry.value;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: controller,
                          decoration: InputDecoration(
                            labelText: 'Miembro ${index + 1}',
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.remove_circle,
                          color: Colors.red,
                        ),
                        onPressed: () => _quitarCampoMiembro(index),
                      ),
                    ],
                  ),
                );
              }),
              TextButton.icon(
                onPressed: _agregarCampoMiembro,
                icon: const Icon(Icons.add),
                label: const Text('Añadir miembro'),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _onSubmit,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Crear'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
