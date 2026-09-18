import 'package:flutter/material.dart';
import 'package:payb2/screens/crear_gasto/crear_gasto.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fl_chart/fl_chart.dart';

class GrupoDetalleScreen extends StatefulWidget {
  final String groupId;
  final String groupName;
  const GrupoDetalleScreen({
    super.key,
    required this.groupId,
    required this.groupName,
  });

  @override
  State<GrupoDetalleScreen> createState() => _GrupoDetalleScreenState();
}

class _GrupoDetalleScreenState extends State<GrupoDetalleScreen> {
  String? _myMemberId;
  List<Map<String, String>> _members = [];
  late Future<Map<String, dynamic>> _miembroYMapa;
  int _dataRevision = 0;

  late final String _uid;

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser!.uid;

    _miembroYMapa = _obtenerMiembroYMapa();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkOrAskMember();
    });
  }

  Future<Map<String, dynamic>> _obtenerMiembroYMapa() async {
    final groupRef = FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId);
    final groupSnapshot = await groupRef.get();
    final snap = await groupRef.collection('members').get();

    final members = snap.docs;

    final memberMap = {
      for (var m in members)
        m.id: {'name': m['name'], 'reclamadoPor': m['reclamadoPor']},
    };

    return {
      'memberMap': memberMap,
      'ownerUid': groupSnapshot.data()?['ownerDeviceId'] as String?,
    };
  }

  Future<void> _checkOrAskMember() async {
    final db = FirebaseFirestore.instance;

    final snapReclamado = await db
        .collection('groups')
        .doc(widget.groupId)
        .collection('members')
        .where('reclamadoPor', isEqualTo: _uid)
        .limit(1)
        .get();

    if (snapReclamado.docs.isNotEmpty) {
      if (!mounted) return;
      setState(() => _myMemberId = snapReclamado.docs.first.id);
      return;
    }

    final snap = await db
        .collection('groups')
        .doc(widget.groupId)
        .collection('members')
        .where('reclamadoPor', isNull: true)
        .get();

    _members = snap.docs
        .map((d) => {'id': d.id, 'name': d['name'] as String})
        .toList();

    if (!mounted) return;
    if (_members.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No quedan identidades libres en este grupo'),
        ),
      );
      return;
    }

    final chosen = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => SimpleDialog(
        title: const Text('¿Quién eres en este grupo?'),
        children: [
          for (var m in _members)
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(ctx, m['id']);
              },
              child: Text(m['name']!),
            ),
          SimpleDialogOption(
            onPressed: () {
              Navigator.pop(ctx, null);
            },
            child: const Text('Cancelar', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (chosen == null) return;

    final memberRef = db
        .collection('groups')
        .doc(widget.groupId)
        .collection('members')
        .doc(chosen);

    final claimed = await db.runTransaction((transaction) async {
      final memberSnapshot = await transaction.get(memberRef);
      if (!memberSnapshot.exists) return false;

      final claimedBy = memberSnapshot.data()?['reclamadoPor'] as String?;
      if (claimedBy != null && claimedBy != _uid) return false;

      transaction.update(memberRef, {'reclamadoPor': _uid});
      return true;
    });

    if (!mounted) return;
    if (!claimed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Otro usuario acaba de reclamar ese miembro'),
        ),
      );
      await _checkOrAskMember();
      return;
    }

    setState(() => _myMemberId = chosen);
  }

  void _refreshDerivedViews() {
    if (!mounted) return;
    setState(() => _dataRevision++);
  }

  Future<void> _onCrearGasto(BuildContext context) async {
    final memberId = _myMemberId;
    if (memberId == null) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CrearGastoScreen(
          groupId: widget.groupId,
          currentMemberId: memberId,
        ),
      ),
    );
    _refreshDerivedViews();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _miembroYMapa,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: Text(widget.groupName)),
            body: Center(
              child: Text('No se pudo cargar el grupo: ${snapshot.error}'),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final memberMap =
            snapshot.data!['memberMap'] as Map<String, Map<String, dynamic>>;
        final ownerUid = snapshot.data!['ownerUid'] as String?;

        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: Text(widget.groupName),
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'Gastos'),
                  Tab(text: 'Saldos'),
                  Tab(text: 'Estadísticas'),
                ],
              ),
            ),
            body: Column(
              children: [
                if (_myMemberId != null)
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      'Eres: ${memberMap[_myMemberId]?['name'] ?? 'Miembro desconocido'}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                Expanded(
                  child: TabBarView(
                    children: [
                      GastosView(
                        groupId: widget.groupId,
                        memberMap: memberMap,
                        myMemberId: _myMemberId,
                        currentUid: _uid,
                        ownerUid: ownerUid,
                        onChanged: _refreshDerivedViews,
                      ),
                      SaldosView(
                        key: ValueKey('saldos-$_dataRevision'),
                        groupId: widget.groupId,
                        memberMap: memberMap,
                        myMemberId: _myMemberId,
                      ),
                      EstadisticasView(
                        key: ValueKey('estadisticas-$_dataRevision'),
                        groupId: widget.groupId,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            floatingActionButton: _myMemberId == null
                ? null
                : FloatingActionButton(
                    onPressed: () => _onCrearGasto(context),
                    child: const Icon(Icons.add),
                  ),
          ),
        );
      },
    );
  }
}

// Pantalla de Gastos ------------------------------------------
class GastosView extends StatefulWidget {
  final String groupId;
  final Map<String, Map<String, dynamic>> memberMap;
  final String? myMemberId;
  final String currentUid;
  final String? ownerUid;
  final VoidCallback onChanged;

  const GastosView({
    super.key,
    required this.groupId,
    required this.memberMap,
    required this.currentUid,
    required this.ownerUid,
    required this.onChanged,
    this.myMemberId,
  });

  @override
  State<GastosView> createState() => _GastosViewState();
}

class _GastosViewState extends State<GastosView> {
  Future<void> _confirmAndDelete(String gastoId, String? scheduleId) async {
    final choice = await showDialog<_DeleteChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar gasto'),
        content: const Text(
          'El gasto y sus divisiones se eliminarán definitivamente.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          if (scheduleId != null)
            TextButton(
              onPressed: () => Navigator.pop(context, _DeleteChoice.series),
              child: const Text('Eliminar también futuras'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _DeleteChoice.occurrence),
            child: const Text('Eliminar este gasto'),
          ),
        ],
      ),
    );

    if (choice == null) return;
    await deleteGastoConSplits(
      groupId: widget.groupId,
      gastoId: gastoId,
      scheduleId: choice == _DeleteChoice.series ? scheduleId : null,
    );
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('groups')
          .doc(widget.groupId)
          .collection('gastos')
          .orderBy('fecha', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const Center(child: Text('No hay gastos registrados.'));
        }

        final gastos = snapshot.data!.docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>;
          return {
            'id': doc.id,
            'name': data['nombre'],
            'amount': data['cantidad'],
            'date': (data['fecha'] as Timestamp).toDate(),
            'description': data['descripcion'],
            'pagadoPor': data['pagadoPor'],
            'scheduleId': data['scheduleId'],
            'createdByUid': data['createdByUid'],
          };
        }).toList();

        return ListView.builder(
          itemCount: gastos.length,
          itemBuilder: (context, index) {
            final gasto = gastos[index];
            final isMyGasto = gasto['pagadoPor'] == widget.myMemberId;
            final canDelete =
                widget.ownerUid == widget.currentUid ||
                gasto['createdByUid'] == widget.currentUid;

            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              color: isMyGasto
                  ? const Color.fromARGB(255, 192, 192, 192)
                  : null, // color distinto si es tu gasto
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Parte izquierda (nombre, descripción, fecha)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            gasto['name'],
                            style: TextStyle(
                              fontWeight: isMyGasto
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isMyGasto ? Colors.green[800] : null,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(gasto['description'] ?? ''),
                          const SizedBox(height: 4),
                          Text(
                            DateFormat('dd/MM/yyyy').format(gasto['date']),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Parte derecha (cantidad + botón)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${gasto['amount'].toStringAsFixed(2)} €',
                          style: TextStyle(
                            fontWeight: isMyGasto
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: isMyGasto ? Colors.green[800] : null,
                          ),
                        ),
                        Text(
                          widget.memberMap[gasto['pagadoPor']]?['name'] ?? '',
                        ),
                        if (canDelete)
                          IconButton(
                            icon: const Icon(Icons.delete, color: Colors.red),
                            onPressed: () => _confirmAndDelete(
                              gasto['id'],
                              gasto['scheduleId'] as String?,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

enum _DeleteChoice { occurrence, series }

class SaldosView extends StatefulWidget {
  final String groupId;
  final String? myMemberId;
  final Map<String, Map<String, dynamic>> memberMap;

  const SaldosView({
    super.key,
    required this.groupId,
    required this.memberMap,
    this.myMemberId,
  });

  @override
  State<SaldosView> createState() => _SaldosViewState();
}

class _SaldosViewState extends State<SaldosView> {
  late Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  _futureDivisiones;

  @override
  void initState() {
    super.initState();
    _futureDivisiones = _loadDivisiones();
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  _loadDivisiones() async {
    final gastosSnap = await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .collection('gastos')
        .get();

    final List<QueryDocumentSnapshot<Map<String, dynamic>>> divisiones = [];

    for (final gastoDoc in gastosSnap.docs) {
      final divisionesSnap = await gastoDoc.reference
          .collection('divisiones')
          .get();

      divisiones.addAll(divisionesSnap.docs);
    }

    return divisiones;
  }

  Future<void> _marcarPagado(
    QueryDocumentSnapshot<Map<String, dynamic>> division,
  ) async {
    final currentMemberId = widget.myMemberId;
    if (currentMemberId == null) return;

    try {
      await division.reference.update({
        'pagado': true,
        'pagadoEn': FieldValue.serverTimestamp(),
        'pagoRegistradoPor': currentMemberId,
      });

      if (!mounted) return;
      setState(() {
        _futureDivisiones = _loadDivisiones();
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo confirmar el pago')),
      );
    }
  }

  Future<void> _confirmarReapertura(
    QueryDocumentSnapshot<Map<String, dynamic>> division,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Marcar pago como pendiente'),
        content: const Text(
          'El deudor volverá a recibir este pago como pendiente.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Marcar pendiente'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await division.reference.update({
        'pagado': false,
        'pagadoEn': FieldValue.delete(),
        'pagoRegistradoPor': FieldValue.delete(),
      });

      if (!mounted) return;
      setState(() {
        _futureDivisiones = _loadDivisiones();
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo reabrir el pago')),
      );
    }
  }

  Future<void> _confirmarCobro(
    QueryDocumentSnapshot<Map<String, dynamic>> division,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Registrar deuda como cobrada'),
        content: const Text(
          'La deuda dejará de aparecer como pendiente para este miembro.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirmar cobro'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _marcarPagado(division);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
      future: _futureDivisiones,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }

        final divisiones = snap.data!;
        final pendientes = divisiones
            .where((division) => division.data()['pagado'] != true)
            .toList();
        final pagosRecibidos = divisiones.where((division) {
          final data = division.data();
          return data['pagado'] == true &&
              data['pagadoPor'] == widget.myMemberId &&
              data['memberId'] != widget.myMemberId;
        }).toList();

        if (pendientes.isEmpty && pagosRecibidos.isEmpty) {
          return const Center(child: Text('No tienes deudas pendientes.'));
        }

        // Agrupar sumas por miembro
        final totals = <String, double>{};
        for (var d in pendientes) {
          final data = d.data();
          final memberId = data['memberId'] as String;
          final amount = (data['cantidad'] as num).toDouble();
          totals[memberId] = (totals[memberId] ?? 0) + amount;
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: widget.memberMap.length + (pagosRecibidos.isEmpty ? 0 : 1),
          itemBuilder: (context, i) {
            if (i == widget.memberMap.length) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 20, bottom: 8),
                    child: Text(
                      'Pagos que te han marcado',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  ...pagosRecibidos.map((division) {
                    final data = division.data();
                    final memberId = data['memberId'] as String;
                    final memberName =
                        widget.memberMap[memberId]?['name'] ?? 'Miembro';
                    final amount = (data['cantidad'] as num).toDouble();
                    final expenseName = data['nombre'] as String? ?? 'Gasto';

                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      child: ListTile(
                        title: Text(expenseName),
                        subtitle: Text(
                          '$memberName ha indicado que pagó ${amount.toStringAsFixed(2)} €',
                        ),
                        trailing: IconButton(
                          tooltip: 'Volver a marcar como pendiente',
                          icon: const Icon(Icons.undo),
                          onPressed: () => _confirmarReapertura(division),
                        ),
                      ),
                    );
                  }),
                ],
              );
            }

            final memberIds = widget.memberMap.keys.toList();
            final memberId = memberIds[i];
            final name = widget.memberMap[memberId]?['name'] ?? 'Sin nombre';
            final balance = totals[memberId] ?? 0.0;
            final isMe = memberId == widget.myMemberId;
            final ownPendingDebts = pendientes.where((division) {
              final data = division.data();
              return data['memberId'] == widget.myMemberId;
            });
            final debtsOwedToMe = pendientes.where((division) {
              final data = division.data();
              return data['memberId'] == memberId &&
                  data['pagadoPor'] == widget.myMemberId &&
                  memberId != widget.myMemberId;
            });

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  leading: CircleAvatar(child: Text(name[0])),
                  title: Text(
                    name,
                    style: TextStyle(
                      fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  trailing: Text(
                    '${balance.toStringAsFixed(2)} €',
                    style: TextStyle(
                      color: balance <= 0 ? Colors.green : Colors.red,
                      fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
                if (isMe)
                  ...ownPendingDebts.map((d) {
                    final data = d.data();
                    final cantidad = (data['cantidad'] as num).toDouble();
                    final gastoNombre = data['nombre'] ?? 'Gasto';
                    final pagadoPor = data['pagadoPor'] ?? '';
                    final nombrePagador =
                        widget.memberMap[pagadoPor]?['name'] ?? 'Otro';
                    final timestamp = data['fecha'] as Timestamp?;
                    final fecha = timestamp != null
                        ? DateFormat('dd/MM/yyyy').format(timestamp.toDate())
                        : 'Sin fecha';

                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      child: ListTile(
                        title: Text('$gastoNombre'),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Debes ${cantidad.toStringAsFixed(2)}€ a $nombrePagador',
                            ),
                            const SizedBox(height: 4),
                            // Fecha en un texto pequeño y sutil
                            Text(
                              fecha,
                              style: TextStyle(
                                fontSize: 12, // Tamaño pequeño para la fecha
                                color: Colors
                                    .grey, // Color gris para que no resalte tanto
                              ),
                            ),
                          ],
                        ),
                        trailing: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            ElevatedButton(
                              onPressed: () => _marcarPagado(d),
                              child: const Text('Pagado'),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                if (!isMe)
                  ...debtsOwedToMe.map((division) {
                    final data = division.data();
                    final amount = (data['cantidad'] as num).toDouble();
                    final expenseName = data['nombre'] as String? ?? 'Gasto';

                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      child: ListTile(
                        title: Text(expenseName),
                        subtitle: Text(
                          '$name te debe ${amount.toStringAsFixed(2)} €',
                        ),
                        trailing: IconButton(
                          tooltip: 'Registrar como cobrado',
                          icon: const Icon(Icons.check_circle_outline),
                          onPressed: () => _confirmarCobro(division),
                        ),
                      ),
                    );
                  }),
              ],
            );
          },
        );
      },
    );
  }
}

class EstadisticasView extends StatefulWidget {
  final String groupId;

  const EstadisticasView({super.key, required this.groupId});

  @override
  State<EstadisticasView> createState() => _EstadisticasViewState();
}

class _EstadisticasViewState extends State<EstadisticasView> {
  late Future<List<_GastoEntry>> _futureGastos;

  @override
  void initState() {
    super.initState();
    _futureGastos = _loadGastos();
  }

  Future<List<_GastoEntry>> _loadGastos() async {
    final gastosSnap = await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .collection('gastos')
        .get();

    final List<_GastoEntry> entries = [];

    for (final doc in gastosSnap.docs) {
      final data = doc.data();
      final nombre = data['nombre'] as String? ?? 'Gasto';
      final importe = (data['cantidad'] as num?)?.toDouble() ?? 0.0;

      if (importe > 0) {
        entries.add(_GastoEntry(nombre, importe));
      }
    }

    return entries;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_GastoEntry>>(
      future: _futureGastos,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        final gastos = snapshot.data!;
        final total = gastos.fold(
          0.0,
          (amount, entry) => amount + entry.importe,
        );

        if (gastos.isEmpty || total == 0) {
          return const Center(child: Text('No hay datos para mostrar.'));
        }

        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              const Text(
                'Distribución de Gastos',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              AspectRatio(
                aspectRatio: 1.3,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    PieChart(
                      PieChartData(
                        sectionsSpace: 4,
                        centerSpaceRadius: 60,
                        sections: gastos.map((e) {
                          final porcentaje = (e.importe / total) * 100;
                          return PieChartSectionData(
                            value: e.importe,
                            title: '${porcentaje.toStringAsFixed(1)}%',
                            color: _getColorForGasto(e.nombre),
                            radius: 100,
                            titleStyle: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    // Total en el centro
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Total',
                          style: TextStyle(fontSize: 14, color: Colors.grey),
                        ),
                        Text(
                          '€${total.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: ListView.builder(
                  itemCount: gastos.length,
                  itemBuilder: (context, i) {
                    final gasto = gastos[i];
                    final porcentaje = (gasto.importe / total) * 100;

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: _getColorForGasto(gasto.nombre),
                      ),
                      title: Text(gasto.nombre),
                      trailing: Text(
                        '${porcentaje.toStringAsFixed(1)}%  (€${gasto.importe.toStringAsFixed(2)})',
                        style: const TextStyle(fontSize: 16),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _GastoEntry {
  final String nombre;
  final double importe;

  _GastoEntry(this.nombre, this.importe);
}

Color _getColorForGasto(String nombre) {
  final colors = [
    Colors.blue,
    Colors.red,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.cyan,
    Colors.teal,
    Colors.brown,
    Colors.pink,
    Colors.amber,
  ];
  final index = nombre.hashCode % colors.length;
  return colors[index];
}

Future<void> deleteGastoConSplits({
  required String groupId,
  required String gastoId,
  String? scheduleId,
}) async {
  final firestore = FirebaseFirestore.instance;
  final gastoDocRef = firestore
      .collection('groups')
      .doc(groupId)
      .collection('gastos')
      .doc(gastoId);

  // 1) Obtén todos los splits
  final splitsSnap = await gastoDocRef.collection('divisiones').get();

  // 2) Prepara un batch
  final batch = firestore.batch();

  // 3) Marca cada split para borrado
  for (var splitDoc in splitsSnap.docs) {
    batch.delete(splitDoc.reference);
  }

  // 4) Marca el gasto para borrado
  batch.delete(gastoDocRef);

  if (scheduleId != null) {
    batch.delete(
      firestore
          .collection('groups')
          .doc(groupId)
          .collection('gastosProgramados')
          .doc(scheduleId),
    );
  }

  // 5) Ejecuta todo en una sola operación atómica
  await batch.commit();
}
