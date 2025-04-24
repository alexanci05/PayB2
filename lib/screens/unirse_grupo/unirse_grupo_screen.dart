import 'package:flutter/material.dart';

class UnirseGrupoScreen extends StatefulWidget {
  const UnirseGrupoScreen({super.key});

  @override
  _UnirseGrupoScreenState createState() => _UnirseGrupoScreenState();
}

class _UnirseGrupoScreenState extends State<UnirseGrupoScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _codigoController = TextEditingController();

  void _onSubmit() {
    if (_formKey.currentState!.validate()) {
      final codigo = _codigoController.text.trim();
      // Aquí llamas a tu lógica de unión a grupo, por ejemplo:
      // GrupoService.unirseGrupo(codigo);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Solicitud para unirse al grupo "$codigo" enviada')),
      );
      Navigator.pop(context); // Vuelve a la pantalla anterior
    }
  }

  @override
  void dispose() {
    _codigoController.dispose();
    super.dispose();
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
                child: const Text('Unirse'),
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
