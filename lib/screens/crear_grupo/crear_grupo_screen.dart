import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:payb2/screens/home/main_screen.dart';
import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';


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

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw Exception('Usuario no autenticado');
      }
      final uid = user.uid;
      final groupRef = FirebaseFirestore.instance.collection('groups').doc();
      final groupId = groupRef.id;
      final groupCode = await _generateUniqueGroupCode();

      // 1. Crear el grupo
      await groupRef.set({
        'name': nombre,
        'createdAt': FieldValue.serverTimestamp(),
        'groupCode': groupCode,
        'ownerDeviceId': uid,
      });

      // 2. Añadir miembro creador a groupMembers
      final memberRef = FirebaseFirestore.instance
          .collection('groupMembers')
          .doc('${groupId}_$uid');

      await memberRef.set({
        'groupId': groupId,
        'deviceId': uid,
        'joinedAt': FieldValue.serverTimestamp(),
      });

      // Después de crear el grupo y al añadir al miembro “creador”:
      /*
      await groupRef
        .collection('members')
        .add({'name': 'Alex', 'reclamadoPor': deviceId});
      */


      // 3. Añadir miembros del grupo (si hay)
      final membersCollection = groupRef.collection('members');
      for (final controller in _miembrosControllers) {
        final name = controller.text.trim();
        if (name.isNotEmpty) {
          await membersCollection.add({
            'name': name,
            'reclamadoPor': null,   // fuerza que exista el campo en null
          });
        }
      }

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Grupo "$nombre" creado correctamente')),
      );
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const MainScreen()),
        (Route<dynamic> route) => false,
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Crear Grupo'),
        centerTitle: true,
      ),
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
                        icon: const Icon(Icons.remove_circle, color: Colors.red),
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



Future<String> _generateUniqueGroupCode() async {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final rand = Random();

  String randomString() => String.fromCharCodes(
        List.generate(8, (_) => chars.codeUnitAt(rand.nextInt(chars.length))),
      );

  String code;
  bool exists = true;

  do {
    code = randomString();

    final snapshot = await FirebaseFirestore.instance
        .collection('groups')
        .where('groupCode', isEqualTo: code)
        .limit(1)
        .get();

    exists = snapshot.docs.isNotEmpty;
  } while (exists);

  return code;
}

