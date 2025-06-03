import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';
import 'package:payb2/screens/home/main_screen.dart';

class UnirseGrupoScreen extends StatefulWidget {
  const UnirseGrupoScreen({super.key});

  @override
  UnirseGrupoScreenState createState() => UnirseGrupoScreenState();
}

class UnirseGrupoScreenState extends State<UnirseGrupoScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _codigoController = TextEditingController();

 @override
  void dispose() {
    _codigoController.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async{
    if (!_formKey.currentState!.validate()) return;

    final codigoGrupo = _codigoController.text.trim();

    try{
      // 1. Obtener el deviceId
      final deviceId = await _getDeviceId();

      // 2. Verificar si el grupo con el código existe
      final groupQuery = await FirebaseFirestore.instance
          .collection('groups')
          .where('groupCode', isEqualTo: codigoGrupo)
          .get();

      if (!mounted) return;

      if (groupQuery.docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('El código de grupo no pertenece a ningún grupo o no es válido')),
        );
        return;
      }

      final doc     = groupQuery.docs.first;
      final groupId = doc.id;
      final nombre = doc.data()['name'];

      // 3. Verificar si el dispositivo ya es miembro del grupo
      final memberQuery = await FirebaseFirestore.instance
          .collection('groupMembers')
          .where('deviceId', isEqualTo: deviceId)
          .where('groupId', isEqualTo: groupId)
          .get();

      if (!mounted) return;

      if (memberQuery.docs.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ya eres miembro de este grupo')),
        );
        return;
      }

      // 4. Crear el groupMember
      final memberRef = FirebaseFirestore.instance
          .collection('groupMembers')
          .doc('${groupId}_$deviceId');

      await memberRef.set({
        'groupId': groupId,
        'deviceId': deviceId,
        'joinedAt': FieldValue.serverTimestamp(),
      });

      // ✅ Verificar si el widget aún está montado, context puede no ser válido
      // si la pantalla se ha cerrado antes de que se complete la operación
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Te has unido al grupo exitosamente')),
      );

      // Volver a la pantalla principal en caso de éxito
      /*
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const MainScreen()),
        (Route<dynamic> route) => false,
      );
      */
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
        title: const Text('Unirse a Grupo'),
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
                controller: _codigoController,
                decoration: const InputDecoration(
                  labelText: 'Código del grupo',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Por favor ingresa el código';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _onSubmit,
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Unirse')
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
