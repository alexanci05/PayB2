import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:payb2/domain/calendar_date.dart';
import 'package:payb2/domain/expense_split.dart';
import 'package:payb2/services/auth/identity_mutation_tracker.dart';
import 'package:payb2/services/network/connection_status.dart';

class CrearGastoScreen extends StatefulWidget {
  final String groupId;
  final String? initialPayerId;
  final FirebaseFirestore? firestore;

  const CrearGastoScreen({
    super.key,
    required this.groupId,
    this.initialPayerId,
    this.firestore,
  });

  @override
  CrearGastoScreenState createState() => CrearGastoScreenState();
}

class CrearGastoScreenState extends State<CrearGastoScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nombreGastoController = TextEditingController();
  final _cantidadController = TextEditingController();
  final _descripcionController = TextEditingController();
  final _dateController = TextEditingController();

  DateTime? _selectedDate;
  String? _payerId;
  List<Map<String, dynamic>> _usuarios = [];
  Set<String> _selectedParticipants = {};
  bool _selectAll = false;
  bool _esPeriodico = false;
  String? _frecuenciaSeleccionada;
  bool _isSubmitting = false;
  String? _requestPayload;
  String? _requestId;
  bool _isLoadingUsers = true;
  String? _loadUsersError;
  FirebaseFirestore get _firestore =>
      widget.firestore ?? FirebaseFirestore.instance;

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
    _payerId = widget.initialPayerId;
    _cargarUsuarios();
  }

  Future<void> _cargarUsuarios() async {
    if (mounted) {
      setState(() {
        _isLoadingUsers = true;
        _loadUsersError = null;
      });
    }
    try {
      final group = await _firestore
          .collection('groups')
          .doc(widget.groupId)
          .get();
      final today = todayInTimeZone(group.data()!['timeZone'] as String);
      final snapshot = await _firestore
          .collection('groups')
          .doc(widget.groupId)
          .collection('members')
          .get();
      if (!mounted) return;
      setState(() {
        _selectedDate ??= today;
        _dateController.text = calendarDateString(_selectedDate!);
        _usuarios = snapshot.docs
            .map(
              (doc) => {
                'id': doc.id,
                'nombre': doc.data()['name'] as String? ?? doc.id,
              },
            )
            .toList();
        final ids = _usuarios.map((user) => user['id'] as String).toSet();
        if (!ids.contains(_payerId)) _payerId = null;
        _selectedParticipants.retainAll(ids);
        _selectedParticipants.remove(_payerId);
        _isLoadingUsers = false;
        _syncSelectAll();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoadingUsers = false;
        _loadUsersError =
            'No se pudieron cargar los miembros o la zona horaria del grupo';
      });
    }
  }

  void _onToggleSelectAll(bool? value) {
    setState(() {
      _selectAll = value ?? false;
      if (_selectAll) {
        _selectedParticipants = _usuarios
            .map((user) => user['id'] as String)
            .where((id) => id != _payerId)
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

  void _onPayerChanged(String? id) {
    setState(() {
      final selectedAll = _selectAll;
      _payerId = id;
      _selectedParticipants.remove(id);
      if (selectedAll) {
        _selectedParticipants = _usuarios
            .map((user) => user['id'] as String)
            .where((memberId) => memberId != id)
            .toSet();
      }
      _syncSelectAll();
    });
  }

  void _syncSelectAll() {
    final eligibleIds = _usuarios
        .map((user) => user['id'] as String)
        .where((id) => id != _payerId)
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
    _dateController.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    if (_isSubmitting || _isLoadingUsers || _loadUsersError != null) return;
    if (!_formKey.currentState!.validate()) return;

    final nombre = _nombreGastoController.text.trim();
    final cantidadCentimos = parseAmountCents(_cantidadController.text);
    final descripcion = _descripcionController.text.trim();
    final selectedDate = _selectedDate!;
    final pagadoPor = _payerId;

    if (pagadoPor == null) {
      _showError('Selecciona quién pagó el gasto');
      return;
    }

    if (cantidadCentimos == null || cantidadCentimos <= 0) {
      _showError('Cantidad inválida');
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

    final payload = <String, dynamic>{
      'groupId': widget.groupId,
      'nombre': nombre,
      'descripcion': descripcion,
      'cantidadCentimos': cantidadCentimos,
      'fecha': calendarDateString(selectedDate),
      'pagadoPor': pagadoPor,
      'participantes': participantes,
      'frecuencia': _esPeriodico ? _frecuenciaSeleccionada : null,
    };
    final encodedPayload = jsonEncode(payload);
    if (_requestPayload != encodedPayload) {
      _requestPayload = encodedPayload;
      _requestId = _firestore.collection('groups').doc().id;
    }

    setState(() => _isSubmitting = true);
    try {
      await IdentityMutationTracker.shared.track(
        () => FirebaseFunctions.instance
            .httpsCallable('crearGasto')
            .callObserved({...payload, 'requestId': _requestId}),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gasto creado exitosamente')),
      );
      Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      _showError('Error al crear gasto: $error');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Crear Gasto')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: _isLoadingUsers
              ? const Center(child: CircularProgressIndicator())
              : _loadUsersError != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_loadUsersError!),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: _cargarUsuarios,
                        child: const Text('Reintentar'),
                      ),
                    ],
                  ),
                )
              : SingleChildScrollView(
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
                          decoration: const InputDecoration(
                            labelText: 'Importe',
                          ),
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
                          controller: _dateController,
                          decoration: const InputDecoration(
                            labelText: 'Fecha del gasto',
                            border: OutlineInputBorder(),
                            suffixIcon: Icon(Icons.calendar_today),
                          ),
                          onTap: () async {
                            final pickedDate = await showDatePicker(
                              context: context,
                              initialDate: _selectedDate!,
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2100),
                            );
                            if (pickedDate != null && mounted) {
                              setState(() {
                                _selectedDate = pickedDate;
                                _dateController.text = calendarDateString(
                                  pickedDate,
                                );
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
                              _esPeriodico = value ?? false;
                              if (!_esPeriodico) {
                                _frecuenciaSeleccionada = null;
                              }
                            });
                          },
                        ),
                        if (_esPeriodico)
                          DropdownButtonFormField<String>(
                            isExpanded: true,
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
                        DropdownButtonFormField<String>(
                          key: const ValueKey('expense-payer'),
                          value: _payerId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Pagado por',
                            border: OutlineInputBorder(),
                          ),
                          items: _usuarios
                              .map(
                                (user) => DropdownMenuItem<String>(
                                  value: user['id'] as String,
                                  child: Text(
                                    user['nombre'] as String,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: _isSubmitting ? null : _onPayerChanged,
                          validator: (value) => value == null
                              ? 'Selecciona quién pagó el gasto'
                              : null,
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
                            .where((user) => user['id'] != _payerId)
                            .map((user) {
                              final id = user['id'] as String;
                              return CheckboxListTile(
                                title: Text(user['nombre'] as String),
                                value: _selectedParticipants.contains(id),
                                onChanged: (value) =>
                                    _onToggleParticipant(id, value),
                              );
                            }),
                        const SizedBox(height: 20),
                        Center(
                          child: ElevatedButton(
                            onPressed: _isSubmitting ? null : _onSubmit,
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
