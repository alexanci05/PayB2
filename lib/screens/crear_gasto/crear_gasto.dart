import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';


class CrearGastoScreen extends StatefulWidget{
  final String groupId;
  final String currentdeviceId;

  const CrearGastoScreen({super.key, required this.groupId, required this.currentdeviceId});

  @override
  CrearGastoScreenState createState() => CrearGastoScreenState();
}

class CrearGastoScreenState extends State<CrearGastoScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nombreGastoController = TextEditingController();
  final TextEditingController _cantidadController = TextEditingController();
  final TextEditingController _descripcionController = TextEditingController();
  DateTime? _selectedDate;


  @override
  void dispose() {
    _nombreGastoController.dispose();
    _cantidadController.dispose();
    _descripcionController.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    final nombreGasto = _nombreGastoController.text.trim();
    final cantidad = double.tryParse(_cantidadController.text.replaceAll(',', '.'));
    final descripcion = _descripcionController.text.trim();
    final fecha = _selectedDate ?? DateTime.now();

    if (cantidad == null || cantidad <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cantidad inválida')),
      );
      return;
    }

    final firestore = FirebaseFirestore.instance;

    try {
      // 1. Crear el gasto en la colección anidada de gastos del grupo
      await firestore
          .collection('groups')
          .doc(widget.groupId)
          .collection('gastos')
          .add({
        'nombre': nombreGasto,
        'cantidad': cantidad,
        'descripcion': descripcion,
        'fecha': fecha,
        'created': FieldValue.serverTimestamp(),
        'pagadoPor': widget.currentdeviceId,
      });

      
      /*
      // 2. Dividir el gasto en partes iguales
      final cantidadPorPersona = cantidad / widget.groupMembers.length;

      // 3. Crear los splits en una colección global
      final batch = firestore.batch();

      for (final miembroId in widget.groupMembers) {
        final splitRef = firestore.collection('splits').doc();
        batch.set(splitRef, {
          'userId': miembroId,
          'gastoId': gastoId,
          'groupId': widget.groupId,
          'amount': cantidadPorPersona,
          'pagadoPor': widget.currentUserId,
          'created': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();
      */

      // Mensaje de éxito
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gasto creado exitosamente')),
      );

      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al crear gasto: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Crear Gasto')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _nombreGastoController,
                decoration: const InputDecoration(labelText: 'Nombre del Gasto'),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Por favor ingresa un nombre';
                  }
                  return null;
                },
              ),
              TextFormField(
                controller: _cantidadController,
                decoration: const InputDecoration(labelText: 'Importe'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')), // Permite hasta 2 decimales
                ],
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Por favor ingresa un importe';
                  }
                  final number = double.tryParse(value.replaceAll(',', '.'));
                  if (number == null) {
                    return 'Importe no válido';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),
              TextFormField(
                readOnly: true,
                controller: TextEditingController(
                  text: _selectedDate != null
                      ? DateFormat('yyyy-MM-dd').format(_selectedDate!)
                      : '',
                ),
                decoration: const InputDecoration(
                  labelText: 'Fecha del gasto',
                  border: OutlineInputBorder(),
                  suffixIcon: Icon(Icons.calendar_today),
                ),
                onTap: () async {
                  final pickedDate = await showDatePicker(
                    context: context,
                    initialDate: DateTime.now(),
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (pickedDate != null) {
                    setState(() {
                      _selectedDate = pickedDate;
                    });
                  }
                },
              ),
              TextFormField(
                controller: _descripcionController,
                decoration: const InputDecoration(labelText: 'Descripción (opcional)'),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _onSubmit,
                child: const Text('Crear Gasto'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}