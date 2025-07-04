import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';



class CrearGastoScreen extends StatefulWidget{
  final String groupId;
  final String uid;

  const CrearGastoScreen({super.key, required this.groupId, required this.uid});

  @override
  CrearGastoScreenState createState() => CrearGastoScreenState();
}

class CrearGastoScreenState extends State<CrearGastoScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _nombreGastoController = TextEditingController();
  final TextEditingController _cantidadController = TextEditingController();
  final TextEditingController _descripcionController = TextEditingController();
  DateTime? _selectedDate;

  List<Map<String, dynamic>> _usuarios = [];
  String? _selectedPagadorId;

   // IDs de los usuarios marcados para participar (sin el pagador)
  Set<String> _selectedParticipants = {};

  // Checkbox “Seleccionar todos”
  bool _selectAll = false;

  // Para el gasto periodico
  bool _esPeriodico = false;
  String? _frecuenciaSeleccionada;
  DateTime? _proximaFecha;
  final List<String> _frecuencias = [
    'Cada 7 días',
    'Cada 15 días',
    'Cada 30 días',
    'Cada 365 días',
    'Mensual (mismo día todos los meses)',
    'Trimestral (mismo día cada 3 meses)',
    'Anual (mismo día cada año)',
  ];



  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime.now(); // valor por defecto: hoy
    _cargarUsuarios();
  }

  Future<void> _cargarUsuarios() async{
    final snapshot = await FirebaseFirestore.instance
      .collection('groups')
      .doc(widget.groupId)
      .collection('members')
      .get();

    setState(() {
      _usuarios = snapshot.docs.map((doc) => {
        'id': doc.id,
        'nombre': doc['name'],
      }).toList();
    });
  }
  
  void _onToggleSelectAll(bool? v) {
    setState(() {
      _selectAll = v ?? false;
      if (_selectAll) {
        // selecciona todos menos el pagador
        _selectedParticipants = _usuarios
            .map((u) => u['id'] as String)
            .where((id) => id != _selectedPagadorId)
            .toSet();
      } else {
        _selectedParticipants.clear();
      }
    });
  }

  void _onToggleParticipant(String id, bool? v) {
    setState(() {
      if (v == true){
        _selectedParticipants.add(id);
      }else{
        _selectedParticipants.remove(id);
      }
      // si no están todos marcados, quita selectAll
      _selectAll = _usuarios
          .where((u) => u['id'] != _selectedPagadorId)
          .every((u) => _selectedParticipants.contains(u['id']));
    });
  }

  @override
  void dispose() {
    _nombreGastoController.dispose();
    _cantidadController.dispose();
    _descripcionController.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
  if (!_formKey.currentState!.validate()) return;

  final nombreGasto   = _nombreGastoController.text.trim();
  final cantidad      = double.tryParse(_cantidadController.text.replaceAll(',', '.'));
  final descripcion   = _descripcionController.text.trim();
  final fecha         = _selectedDate ?? DateTime.now();

  if (cantidad == null || cantidad <= 0) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Cantidad inválida')),
    );
    return;
  }

  if (_selectedPagadorId == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Debes elegir quién pagó')),
    );
    return;
  }

  // Sólo los participantes distintos al pagador:
  final participants = _selectedParticipants.toList();

  final firestore = FirebaseFirestore.instance;

  if (_esPeriodico && _frecuenciaSeleccionada != null) {
    final proxima = calcularProximaFecha(fecha, _frecuenciaSeleccionada!);
    _proximaFecha = proxima;
  }


  try {
    // 1. Crear el gasto y obtener su referencia
    final gastoRef = await firestore
      .collection('groups')
      .doc(widget.groupId)
      .collection('gastos')
      .add({
        'nombre':    nombreGasto,
        'cantidad':  cantidad,
        'descripcion': descripcion,
        'fecha':     fecha,
        'created':   FieldValue.serverTimestamp(),
        'pagadoPor': _selectedPagadorId,
        'frecuencia': _frecuenciaSeleccionada,
        'proximaFecha': _proximaFecha,

      });
    

    final gastoId = gastoRef.id;

     // 2. Ahora calculamos si la fecha del gasto es de hoy o previa para no crear divisiones si la fecha aun no ha llegado
    final now = DateTime.now();
    final debeCrearDivisiones = !fecha.isAfter(now);
    if (debeCrearDivisiones) {
      final rawEach = cantidad / (participants.length + 1);
      final roundedEach = double.parse(rawEach.toStringAsFixed(2));

      final batch = firestore.batch();
      for (var memberId in participants) {
        final divisionesRef = firestore
            .collection('groups')
            .doc(widget.groupId)
            .collection('gastos')
            .doc(gastoId)
            .collection('divisiones')
            .doc();

        batch.set(divisionesRef, {
          'memberId': memberId,
          'groupId': widget.groupId,
          'cantidad': roundedEach,
          'pagado': false,
          'created': FieldValue.serverTimestamp(),
          'fecha': fecha,
          'nombre': nombreGasto,
          'pagadoPor': _selectedPagadorId,
        });
      }
      await batch.commit();
    }

    // Mensaje y volver atrás
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
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: SingleChildScrollView(
            // Para evitar que el teclado corte el contenido
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                      FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
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
                  const SizedBox(height: 20),
                  
                  CheckboxListTile(
                    title: const Text('¿Es un gasto periódico?'),
                    value: _esPeriodico,
                    onChanged: (value) {
                      setState(() {
                        _esPeriodico = value!;
                        if (!_esPeriodico) _frecuenciaSeleccionada = null;
                      });
                    },
                  ),
                  if (_esPeriodico)
                  DropdownButtonFormField<String>(
                    value: _frecuenciaSeleccionada,
                    decoration: const InputDecoration(
                      labelText: 'Frecuencia',
                      border: OutlineInputBorder(),
                    ),
                    items: _frecuencias
                        .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                        .toList(),
                    onChanged: (val) {
                      setState(() {
                        _frecuenciaSeleccionada = val;
                      });
                    },
                    validator: (val) {
                      if (_esPeriodico && val == null) {
                        return 'Selecciona una frecuencia';
                      }
                      return null;
                    },
                  ),
                  TextFormField(
                    controller: _descripcionController,
                    decoration: const InputDecoration(labelText: 'Descripción (opcional)'),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: _selectedPagadorId,
                    decoration: const InputDecoration(
                      labelText: '¿Quién pagó?',
                      border: OutlineInputBorder(),
                    ),
                    items: _usuarios.map<DropdownMenuItem<String>>((usuario) {
                      return DropdownMenuItem<String>(
                        value: usuario['id'] as String,
                        child: Text(usuario['nombre']),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedPagadorId = value;
                      });
                    },
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Por favor selecciona quién pagó';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('¿Entre quiénes se divide?'),
                  ),

                  // Checkbox “Seleccionar todos”
                  CheckboxListTile(
                    title: const Text('Todos los miembros'),
                    value: _selectAll,
                    onChanged: _selectedPagadorId == null ? null : _onToggleSelectAll,
                  ),

                  // Lista de miembros con checkbox
                  ..._usuarios
                      .where((u) => u['id'] != _selectedPagadorId) // excluye pagador
                      .map((u) {
                    final id = u['id'] as String;
                    return CheckboxListTile(
                      title: Text(u['nombre']),
                      value: _selectedParticipants.contains(id),
                      onChanged: (v) => _onToggleParticipant(id, v),
                    );
                  }),

                  const SizedBox(height: 20),
                  Center(
                    child: ElevatedButton(
                      onPressed: _onSubmit,
                      child: const Text('Crear Gasto'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

DateTime? calcularProximaFecha(DateTime fechaInicio, String frecuencia) {
  switch (frecuencia) {
    case 'Cada 7 días':
      return fechaInicio.add(const Duration(days: 7));
    case 'Cada 15 días':
      return fechaInicio.add(const Duration(days: 15));
    case 'Cada 30 días':
      return fechaInicio.add(const Duration(days: 30));
    case 'Cada 365 días':
      return fechaInicio.add(const Duration(days: 365));
    case 'Mensual (mismo día todos los meses)':
      return DateTime(fechaInicio.year, fechaInicio.month + 1, fechaInicio.day);
    case 'Trimestral (mismo día cada 3 meses)':
      return DateTime(fechaInicio.year, fechaInicio.month + 3, fechaInicio.day);
    case 'Anual (mismo día cada año)':
      return DateTime(fechaInicio.year + 1, fechaInicio.month, fechaInicio.day);
    default:
      return null;
  }
}
