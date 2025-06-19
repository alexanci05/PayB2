import 'package:flutter/material.dart';
import 'package:payb2/screens/crear_gasto/crear_gasto.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart'; // << Import Firebase Auth
import 'package:fl_chart/fl_chart.dart';

class GrupoDetalleScreen extends StatefulWidget {
  final String groupId;
  final String groupName;
  // Ya no se recibe currentDeviceId aquí

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

  // Guarda el uid del usuario
  late final String _uid;

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser!.uid; // obtenemos el uid aquí

    _miembroYMapa = _obtenerMiembroYMapa();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkOrAskMember();
    });
  }

  Future<Map<String, dynamic>> _obtenerMiembroYMapa() async {
    final snap = await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .collection('members')
        .get();

    final members = snap.docs;

    final memberMap = {
      for (var m in members)
        m.id: {
          'name': m['name'],
          'reclamadoPor': m['reclamadoPor'],
        }
    };

    return {
      'memberMap': memberMap,
    };
  }

  Future<void> _checkOrAskMember() async {
    final db = FirebaseFirestore.instance;

    // 1) ¿Ya reclamado?
    final snapReclamado = await db
        .collection('groups')
        .doc(widget.groupId)
        .collection('members')
        .where('reclamadoPor', isEqualTo: _uid) // aquí usamos _uid
        .limit(1)
        .get();

    if (snapReclamado.docs.isNotEmpty) {
      _myMemberId = snapReclamado.docs.first.id;
      setState(() {});
      return;
    }

    // 2) Carga miembros fantasma libres
    final snap = await db
        .collection('groups')
        .doc(widget.groupId)
        .collection('members')
        .where('reclamadoPor', isNull: true)
        .get();

    _members = snap.docs
        .map((d) => {
              'id': d.id,
              'name': d['name'] as String,
            })
        .toList();

    if (_members.isEmpty) return;

    if (!mounted) return;

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

    await db
        .collection('groups')
        .doc(widget.groupId)
        .collection('members')
        .doc(chosen)
        .update({'reclamadoPor': _uid}); // aquí también _uid

    setState(() => _myMemberId = chosen);
  }

  void _onCrearGasto(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CrearGastoScreen(
          groupId: widget.groupId,
          uid: _uid, // Pasamos el uid aquí, no currentDeviceId
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _miembroYMapa,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final memberMap =
            snapshot.data!['memberMap'] as Map<String, Map<String, dynamic>>;

        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: Text(widget.groupName),
              bottom: const TabBar(tabs: [
                Tab(text: 'Gastos'),
                Tab(text: 'Saldos'),
                Tab(text: 'Estadísticas'),
              ]),
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
                  child: TabBarView(children: [
                    GastosView(
                      groupId: widget.groupId,
                      memberMap: memberMap,
                      myMemberId: _myMemberId,
                    ),
                    SaldosView(
                      groupId: widget.groupId,
                      memberMap: memberMap,
                      myMemberId: _myMemberId,
                    ),
                    EstadisticasView(
                      groupId: widget.groupId,
                    ),
                  ]),
                ),
              ],
            ),
            floatingActionButton: FloatingActionButton(
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

  const GastosView({
    super.key,
    required this.groupId,
    required this.memberMap,
    this.myMemberId,
  });

  @override
  State<GastosView> createState() => _GastosViewState();
}

class _GastosViewState extends State<GastosView> {
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
            'pagadoPor': data['pagadoPor']
          };
        }).toList();

        return ListView.builder(
          itemCount: gastos.length,
          itemBuilder: (context, index) {
            final gasto = gastos[index];
            final isMyGasto = gasto['pagadoPor'] == widget.myMemberId;

            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              color: isMyGasto ? const Color.fromARGB(255, 192, 192, 192) : null, // color distinto si es tu gasto
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
                              fontWeight: isMyGasto ? FontWeight.bold : FontWeight.normal,
                              color: isMyGasto ? Colors.green[800] : null,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(gasto['description'] ?? ''),
                          const SizedBox(height: 4),
                          Text(
                            DateFormat('dd/MM/yyyy').format(gasto['date']),
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                    // Parte derecha (cantidad + botón)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('${gasto['amount'].toStringAsFixed(2)} €',
                            style: TextStyle(
                              fontWeight: isMyGasto ? FontWeight.bold : FontWeight.normal,
                              color: isMyGasto ? Colors.green[800] : null,
                            )),
                        Text(widget.memberMap[gasto['pagadoPor']]?['name'] ?? ''),
                        IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () async {
                            await deleteGastoConSplits(
                              groupId: widget.groupId,
                              gastoId: gasto['id'],
                            );
                          },
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
  late Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _futureDivisiones;

  @override
  void initState() {
    super.initState();
    _futureDivisiones = _loadDivisiones();
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _loadDivisiones() async {
    final gastosSnap = await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .collection('gastos')
        .get();

    final List<QueryDocumentSnapshot<Map<String, dynamic>>> divisiones = [];

    for (final gastoDoc in gastosSnap.docs) {
      final divisionesSnap = await gastoDoc.reference
          .collection('divisiones')
          .where('cantidad', isGreaterThan: 0)
          .get();

      divisiones.addAll(divisionesSnap.docs);
    }

    return divisiones;
  }

  Future<void> _marcarPagado(String gastoId, String divisionId) async {
    await FirebaseFirestore.instance
        .collection('groups')
        .doc(widget.groupId)
        .collection('gastos')
        .doc(gastoId)
        .collection('divisiones')
        .doc(divisionId)
        .update({
      'cantidad': 0,
      'pagado': true,
    });

    // Refrescar pantalla
    setState(() {
      _futureDivisiones = _loadDivisiones();
    });
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
        if (divisiones.isEmpty) {
          return const Center(child: Text('No tienes deudas pendientes.'));
        }

        // Agrupar sumas por miembro
        final totals = <String, double>{};
        for (var d in divisiones) {
          final data = d.data();
          final memberId = data['memberId'] as String;
          final amount = (data['cantidad'] as num).toDouble();
          totals[memberId] = (totals[memberId] ?? 0) + amount;
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: widget.memberMap.length,
          itemBuilder: (context, i) {
            final memberIds = widget.memberMap.keys.toList();
            final memberId = memberIds[i];
            final name = widget.memberMap[memberId]?['name'] ?? 'Sin nombre';
            final balance = totals[memberId] ?? 0.0;
            final isMe = memberId == widget.myMemberId;

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
                if (isMe && balance > 0)
                  ...divisiones.where((d) {
                    final data = d.data();
                    return data['memberId'] == widget.myMemberId;
                  }).map((d) {
                    final data = d.data();
                    final cantidad = (data['cantidad'] as num).toDouble();
                    final gastoNombre = data['nombre'] ?? 'Gasto';
                    final pagadoPor = data['pagadoPor'] ?? '';
                    final nombrePagador = widget.memberMap[pagadoPor]?['name'] ?? 'Otro';
                    final gastoId = d.reference.parent.parent!.id;
                    final divisionId = d.id;

                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      child: ListTile(
                        title: Text(gastoNombre),
                        subtitle: Text('Debes ${cantidad.toStringAsFixed(2)}€ a $nombrePagador'),
                        trailing: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            ElevatedButton(
                              onPressed: () => _marcarPagado(gastoId, divisionId),
                              child: const Text('Pagado'),
                            ),
                          ],
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
        final total = gastos.fold(0.0, (sum, e) => sum + e.importe);

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
                    )
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
}) async {
  final firestore = FirebaseFirestore.instance;
  final gastoDocRef = firestore
      .collection('groups')
      .doc(groupId)
      .collection('gastos')
      .doc(gastoId);

  // 1) Obtén todos los splits
  final splitsSnap = await gastoDocRef
      .collection('divisiones')
      .get();

  // 2) Prepara un batch
  final batch = firestore.batch();

  // 3) Marca cada split para borrado
  for (var splitDoc in splitsSnap.docs) {
    batch.delete(splitDoc.reference);
  }

  // 4) Marca el gasto para borrado
  batch.delete(gastoDocRef);

  // 5) Ejecuta todo en una sola operación atómica
  await batch.commit();
}

