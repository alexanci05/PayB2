import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:payb2/domain/expense_split.dart';

class CrearGastoScreen extends StatefulWidget {
  final String groupId;
  final String currentMemberId;

  const CrearGastoScreen({
    super.key,
    required this.groupId,
    required this.currentMemberId,
  });

  @override
  CrearGastoScreenState createState() => CrearGastoScreenState();
}

class CrearGastoScreenState extends State<CrearGastoScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nombreGastoController = TextEditingController();
  final _cantidadController = TextEditingController();
  final _descripcionController = TextEditingController();

  DateTime? _selectedDate;
  List<Map<String, dynamic>> _usuarios = [];
  Set<String> _selectedParticipants = {};
  bool _selectAll = false;
  bool _esPeriodico = false;
  String? _frecuenciaSeleccionada;

  static const _frecuencias = [
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
    _selectedDate = DateTime.now();
    _cargarUsuarios();
  }

  Future<void> _cargarUsuarios() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .collection('members')
        .get();

    if (!mounted) return;
    setState(() {
      _usuarios = snapshot.docs
          .map(
            (doc) => {
              'id': doc.id,
              'nombre': doc.data()['name'] as String? ?? doc.id,
            },
          )
          .toList();
      _syncSelectAll();
    });
  }

  void _onToggleSelectAll(bool? value) {
    setState(() {
      _selectAll = value ?? false;
      if (_selectAll) {
        _selectedParticipants = _usuarios
            .map((user) => user['id'] as String)
            .where((id) => id != widget.currentMemberId)
            .toSet();
      } else {
        _selectedParticipants.clear();
      }
    });
  }

  void _onToggleParticipant(String id, bool? value) {
    setState(() {
      if (value == true) {
        _selectedParticipants.add(id);
      } else {
        _selectedParticipants.remove(id);
      }
      _syncSelectAll();
    });
  }

  void _syncSelectAll() {
    final eligibleIds = _usuarios
        .map((user) => user['id'] as String)
        .where((id) => id != widget.currentMemberId)
        .toList();
    _selectAll =
        eligibleIds.isNotEmpty &&
        eligibleIds.every(_selectedParticipants.contains);
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

    final nombre = _nombreGastoController.text.trim();
    final cantidadCentimos = parseAmountCents(_cantidadController.text);
    final descripcion = _descripcionController.text.trim();
    final selectedDate = _selectedDate ?? DateTime.now();
    final fecha = DateTime.utc(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      12,
    );
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final isFutureDate = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
    ).isAfter(todayDate);
    final pagadoPor = widget.currentMemberId;
    final createdByUid = FirebaseAuth.instance.currentUser?.uid;

    if (cantidadCentimos == null || cantidadCentimos <= 0) {
      _showError('Cantidad inválida');
      return;
    }
    if (createdByUid == null) {
      _showError('Usuario no autenticado');
      return;
    }

    final participantes =
        _selectedParticipants
            .where((memberId) => memberId != pagadoPor)
            .toList()
          ..sort();
    if (participantes.isEmpty) {
      _showError('Selecciona al menos un participante');
      return;
    }
    if (cantidadCentimos < participantes.length + 1) {
      _showError('El importe debe permitir al menos un céntimo por persona');
      return;
    }

    try {
      final shares = splitExpenseCents(
        totalCents: cantidadCentimos,
        payerId: pagadoPor,
        participantIds: participantes,
      );
      final firestore = FirebaseFirestore.instance;
      final groupRef = firestore.collection('groups').doc(widget.groupId);
      final batch = firestore.batch();

      if (isFutureDate) {
        final scheduleRef = groupRef.collection('gastosProgramados').doc();
        batch.set(
          scheduleRef,
          _scheduleData(
            nombre: nombre,
            descripcion: descripcion,
            cantidadCentimos: cantidadCentimos,
            pagadoPor: pagadoPor,
            participantes: participantes,
            frecuencia: _esPeriodico ? _frecuenciaSeleccionada : null,
            proximaFecha: fecha,
            createdByUid: createdByUid,
          ),
        );
      } else if (_esPeriodico) {
        final frecuencia = _frecuenciaSeleccionada!;
        final proximaFecha = nextOccurrenceDate(fecha, frecuencia);
        if (proximaFecha == null) {
          throw StateError('Frecuencia no válida');
        }
        final scheduleRef = groupRef.collection('gastosProgramados').doc();
        final occurrenceKey = scheduledOccurrenceId(scheduleRef.id, fecha);
        batch.set(
          scheduleRef,
          _scheduleData(
            nombre: nombre,
            descripcion: descripcion,
            cantidadCentimos: cantidadCentimos,
            pagadoPor: pagadoPor,
            participantes: participantes,
            frecuencia: frecuencia,
            proximaFecha: proximaFecha,
            createdByUid: createdByUid,
          ),
        );
        _addOccurrenceAndDivisions(
          batch: batch,
          occurrenceRef: groupRef.collection('gastos').doc(occurrenceKey),
          shares: shares,
          nombre: nombre,
          descripcion: descripcion,
          cantidadCentimos: cantidadCentimos,
          fecha: fecha,
          pagadoPor: pagadoPor,
          scheduleId: scheduleRef.id,
          occurrenceKey: occurrenceKey,
          createdByUid: createdByUid,
        );
      } else {
        _addOccurrenceAndDivisions(
          batch: batch,
          occurrenceRef: groupRef.collection('gastos').doc(),
          shares: shares,
          nombre: nombre,
          descripcion: descripcion,
          cantidadCentimos: cantidadCentimos,
          fecha: fecha,
          pagadoPor: pagadoPor,
          scheduleId: null,
          occurrenceKey: null,
          createdByUid: createdByUid,
        );
      }

      await batch.commit();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gasto creado exitosamente')),
      );
      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      _showError('Error al crear gasto: $error');
    }
  }

  Map<String, dynamic> _scheduleData({
    required String nombre,
    required String descripcion,
    required int cantidadCentimos,
    required String pagadoPor,
    required List<String> participantes,
    required String? frecuencia,
    required DateTime proximaFecha,
    required String createdByUid,
  }) {
    return {
      'nombre': nombre,
      'descripcion': descripcion,
      'cantidad': cantidadCentimos / 100,
      'cantidadCentimos': cantidadCentimos,
      'pagadoPor': pagadoPor,
      'participantes': participantes,
      'frecuencia': frecuencia,
      'proximaFecha': proximaFecha,
      'created': FieldValue.serverTimestamp(),
      'createdByMemberId': widget.currentMemberId,
      'createdByUid': createdByUid,
    };
  }

  void _addOccurrenceAndDivisions({
    required WriteBatch batch,
    required DocumentReference<Map<String, dynamic>> occurrenceRef,
    required List<ExpenseShare> shares,
    required String nombre,
    required String descripcion,
    required int cantidadCentimos,
    required DateTime fecha,
    required String pagadoPor,
    required String? scheduleId,
    required String? occurrenceKey,
    required String createdByUid,
  }) {
    batch.set(occurrenceRef, {
      'nombre': nombre,
      'descripcion': descripcion,
      'cantidad': cantidadCentimos / 100,
      'cantidadCentimos': cantidadCentimos,
      'fecha': fecha,
      'created': FieldValue.serverTimestamp(),
      'pagadoPor': pagadoPor,
      'scheduleId': scheduleId,
      'occurrenceKey': occurrenceKey,
      'createdByMemberId': widget.currentMemberId,
      'createdByUid': createdByUid,
    });

    for (final share in shares) {
      final isPayer = share.memberId == pagadoPor;
      batch.set(occurrenceRef.collection('divisiones').doc(share.memberId), {
        'memberId': share.memberId,
        'groupId': widget.groupId,
        'cantidad': share.amountCents / 100,
        'cantidadCentimos': share.amountCents,
        'pagado': isPayer,
        'pagadoEn': isPayer ? FieldValue.serverTimestamp() : null,
        'created': FieldValue.serverTimestamp(),
        'fecha': fecha,
        'nombre': nombre,
        'pagadoPor': pagadoPor,
      });
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String get _currentMemberName {
    for (final user in _usuarios) {
      if (user['id'] == widget.currentMemberId) {
        return user['nombre'] as String;
      }
    }
    return 'Tu identidad del grupo';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Crear Gasto')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextFormField(
                    controller: _nombreGastoController,
                    decoration: const InputDecoration(
                      labelText: 'Nombre del gasto',
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Por favor ingresa un nombre';
                      }
                      return null;
                    },
                  ),
                  TextFormField(
                    controller: _cantidadController,
                    decoration: const InputDecoration(labelText: 'Importe'),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'^\d*[\.,]?\d{0,2}$'),
                      ),
                    ],
                    validator: (value) {
                      final cents = value == null
                          ? null
                          : parseAmountCents(value);
                      if (cents == null || cents <= 0) {
                        return 'Importe no válido';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    readOnly: true,
                    controller: TextEditingController(
                      text: _selectedDate == null
                          ? ''
                          : DateFormat('yyyy-MM-dd').format(_selectedDate!),
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Fecha del gasto',
                      border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.calendar_today),
                    ),
                    onTap: () async {
                      final pickedDate = await showDatePicker(
                        context: context,
                        initialDate: _selectedDate ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (pickedDate != null) {
                        setState(() => _selectedDate = pickedDate);
                      }
                    },
                  ),
                  const SizedBox(height: 20),
                  CheckboxListTile(
                    title: const Text('¿Es un gasto periódico?'),
                    value: _esPeriodico,
                    onChanged: (value) {
                      setState(() {
                        _esPeriodico = value ?? false;
                        if (!_esPeriodico) {
                          _frecuenciaSeleccionada = null;
                        }
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
                          .map(
                            (frequency) => DropdownMenuItem(
                              value: frequency,
                              child: Text(frequency),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        setState(() => _frecuenciaSeleccionada = value);
                      },
                      validator: (value) {
                        if (_esPeriodico && value == null) {
                          return 'Selecciona una frecuencia';
                        }
                        return null;
                      },
                    ),
                  TextFormField(
                    controller: _descripcionController,
                    decoration: const InputDecoration(
                      labelText: 'Descripción (opcional)',
                    ),
                  ),
                  const SizedBox(height: 16),
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Pagado por',
                      border: OutlineInputBorder(),
                    ),
                    child: Text(_currentMemberName),
                  ),
                  const SizedBox(height: 20),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('¿Entre quiénes se divide?'),
                  ),
                  CheckboxListTile(
                    title: const Text('Todos los miembros'),
                    value: _selectAll,
                    onChanged: _onToggleSelectAll,
                  ),
                  ..._usuarios
                      .where((user) => user['id'] != widget.currentMemberId)
                      .map((user) {
                        final id = user['id'] as String;
                        return CheckboxListTile(
                          title: Text(user['nombre'] as String),
                          value: _selectedParticipants.contains(id),
                          onChanged: (value) => _onToggleParticipant(id, value),
                        );
                      }),
                  const SizedBox(height: 20),
                  Center(
                    child: ElevatedButton(
                      onPressed: _onSubmit,
                      child: const Text('Crear gasto'),
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
