import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:payb2/screens/home/main_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';

class UnirseGrupoScreen extends StatefulWidget {
  const UnirseGrupoScreen({super.key});

  @override
  UnirseGrupoScreenState createState() => UnirseGrupoScreenState();
}

class UnirseGrupoScreenState extends State<UnirseGrupoScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _codigoController = TextEditingController();

  int failedAttempts = 0;
  DateTime? lockUntil;

  @override
  void dispose() {
    _codigoController.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    // Verificar si está bloqueado
    if (lockUntil != null && DateTime.now().isBefore(lockUntil!)) {
      final remaining = lockUntil!.difference(DateTime.now()).inSeconds;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Demasiados intentos fallidos. Intenta de nuevo en $remaining segundos.')),
      );
      return;
    }

    if (!_formKey.currentState!.validate()) return;

    final codigoGrupo = _codigoController.text.trim();

    try {
      // 1. Obtener el deviceId
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error: Usuario no autenticado')),
        );
        return;
      }

      // 2. Verificar si el grupo con el código existe
      final groupQuery = await FirebaseFirestore.instance
          .collection('groups')
          .where('groupCode', isEqualTo: codigoGrupo)
          .get();

      if (!mounted) return;

      if (groupQuery.docs.isEmpty) {
        failedAttempts += 1;

        if (failedAttempts >= 3) {
          lockUntil = DateTime.now().add(const Duration(seconds: 30));
          failedAttempts = 0; // opcional: reiniciar para el próximo ciclo
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Demasiados intentos fallidos. Bloqueado por 30 segundos.')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Código inválido. Intento fallido $failedAttempts de 3')),
          );
        }
        return;
      }

      // Si el código es correcto, reiniciar contador
      failedAttempts = 0;
      lockUntil = null;

      final doc = groupQuery.docs.first;
      final groupId = doc.id;

      // 3. Verificar si el dispositivo ya es miembro del grupo
      final memberQuery = await FirebaseFirestore.instance
          .collection('groupMembers')
          .where('deviceId', isEqualTo: uid)
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
          .doc('${groupId}_$uid');

      await memberRef.set({
        'groupId': groupId,
        'deviceId': uid,
        'joinedAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Te has unido al grupo exitosamente')),
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
                  child: const Text('Unirse')),
            ],
          ),
        ),
      ),
    );
  }
}
