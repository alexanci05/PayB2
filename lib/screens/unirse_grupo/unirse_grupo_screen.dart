import 'package:flutter/material.dart';
import 'package:cloud_functions/cloud_functions.dart';
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

  Future<void> _onSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    final codigoGrupo = _codigoController.text.trim();

    try {
      final callable = FirebaseFunctions.instance.httpsCallable('unirseAGrupo');
      final response = await callable.call<Map<String, dynamic>>({
        'codigo': codigoGrupo,
      });

      if (!mounted) return;

      final alreadyMember = response.data['status'] == 'already-member';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            alreadyMember
                ? 'Ya pertenecías a este grupo'
                : 'Te has unido al grupo exitosamente',
          ),
        ),
      );

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const MainScreen()),
        (Route<dynamic> route) => false,
      );
    } on FirebaseFunctionsException catch (error) {
      if (!mounted) return;
      final message = switch (error.code) {
        'not-found' => 'Código de grupo incorrecto',
        'resource-exhausted' =>
          'Demasiados intentos. Inténtalo de nuevo en ${_retrySeconds(error)} segundos',
        'unauthenticated' => 'Usuario no autenticado',
        _ => 'No se pudo completar la unión al grupo',
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

  int _retrySeconds(FirebaseFunctionsException error) {
    final details = error.details;
    if (details is Map && details['retryAfterSeconds'] is num) {
      return (details['retryAfterSeconds'] as num).ceil();
    }
    return 30;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Unirse a Grupo'), centerTitle: true),
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
                child: const Text('Unirse'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
