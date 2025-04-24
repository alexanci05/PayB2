import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';
import 'package:payb2/screens/home/main_screen.dart';

class CrearGrupoScreen extends StatefulWidget {
  const CrearGrupoScreen({super.key});

  @override
  _CrearGrupoScreenState createState() => _CrearGrupoScreenState();
}

class _CrearGrupoScreenState extends State<CrearGrupoScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nombreController = TextEditingController();

  @override
  void dispose() {
    _nombreController.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    final nombre = _nombreController.text.trim();

    try {
      // 1. Obtener el deviceId
      final deviceId = await _getDeviceId();

      // 2. Crear el grupo
      final groupRef = FirebaseFirestore.instance.collection('groups').doc();
      final groupId = groupRef.id;
      final groupCode = await _generateUniqueGroupCode(); 

      await groupRef.set({
        'name': nombre,
        'createdAt': FieldValue.serverTimestamp(),
        'groupCode': groupCode,
        'ownerDeviceId': deviceId,
      });

      // 3. Crear el groupMember
      final memberRef = FirebaseFirestore.instance
          .collection('groupMembers')
          .doc('${groupId}_$deviceId');

      await memberRef.set({
        'groupId': groupId,
        'deviceId': deviceId,
        'joinedAt': FieldValue.serverTimestamp(),
      });

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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
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
              ElevatedButton(
                onPressed: _onSubmit,
                child: const Text('Crear'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


Future<String> _getDeviceId() async {
  final deviceInfo = DeviceInfoPlugin();
  if (Platform.isAndroid) {
    final androidInfo = await deviceInfo.androidInfo;
    return androidInfo.id; // o .androidId si prefieres
  } else if (Platform.isIOS) {
    final iosInfo = await deviceInfo.iosInfo;
    return iosInfo.identifierForVendor ?? 'unknown_ios';
  } else {
    return 'unknown_device';
  }
}

Future<String> _generateUniqueGroupCode() async {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final random = DateTime.now().millisecondsSinceEpoch.remainder(1000000);
  final randomString = () => String.fromCharCodes(
    List.generate(6, (index) => chars.codeUnitAt((random + index) % chars.length)),
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

