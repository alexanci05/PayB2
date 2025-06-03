import 'package:flutter/material.dart';
import 'package:payb2/screens/crear_gasto/crear_gasto.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

class GrupoDetalleScreen extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String currentDeviceId;

  const GrupoDetalleScreen({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.currentDeviceId,
  });

  @override
  State<GrupoDetalleScreen> createState() => _GrupoDetalleScreenState();
}


class _GrupoDetalleScreenState extends State<GrupoDetalleScreen> {
  String? _myMemberId;
  List<Map<String,String>> _members = [];
  late Future<Map<String, dynamic>> _miembroYMapa;

  @override
  void initState() {
    super.initState();
    _miembroYMapa = _obtenerMiembroYMapa();
    // esperamos a que termine el primer frame
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

    // Mapa ID → nombre
    final memberMap = {
      for (var m in members) m.id: {
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
    final snapReclamado = await FirebaseFirestore.instance
    .collection('groups')
    .doc(widget.groupId)
    .collection('members')
    .where('reclamadoPor', isEqualTo: widget.currentDeviceId)
    .limit(1)
    .get();

    if (snapReclamado.docs.isNotEmpty) {
      // Ya hay un miembro al que he reclamado
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

    _members = snap.docs.map((d) => {
      'id': d.id,
      'name': d['name'] as String,
    }).toList();



    if (_members.isEmpty) return; // nada que reclamar

    // 3) Abrir diálogo
    final chosen = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => SimpleDialog(
        title: const Text('¿Quién eres en este grupo?'),
        children: [
          // Opción para cada miembro
          for (var m in _members)
            SimpleDialogOption(
              onPressed: () {
                // ¡Usa el ctx aquí, no el contexto externo!
                Navigator.pop(ctx, m['id']);
              },
              child: Text(m['name']!),
            ),

          // Opción Cancelar
          SimpleDialogOption(
            onPressed: () {
              Navigator.pop(ctx, null);
            },
            child: const Text('Cancelar', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );


    if (chosen == null) return; // si canceló

    // 4) Marcar phantom como reclamado
    await FirebaseFirestore.instance
      .collection('groups')
      .doc(widget.groupId)
      .collection('members')
      .doc(chosen)
      .update({ 'reclamadoPor': widget.currentDeviceId });


    setState(() => _myMemberId = chosen);
  }

  void _onCrearGasto(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CrearGastoScreen(
          groupId: widget.groupId,
          currentdeviceId: widget.currentDeviceId,
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

        final memberMap = snapshot.data!['memberMap'] as Map<String, Map<String, dynamic>>;

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
            body: TabBarView(children: [
              GastosView(
                groupId: widget.groupId,
                memberMap: memberMap,
              ),
              SaldosView(
                groupId: widget.groupId,
                currentDeviceId: widget.currentDeviceId,
                memberMap: memberMap,
              ),
              const EstadisticasView(),
            ]),
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

  const GastosView({super.key, required this.groupId, required this.memberMap});

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
            'pagadoPor' : data['pagadoPor']
          };
        }).toList();

        return ListView.builder(
          itemCount: gastos.length,
          itemBuilder: (context, index) {
            final gasto = gastos[index];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
                          Text(gasto['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(gasto['description'] ?? ''),
                          const SizedBox(height: 4),
                          Text(DateFormat('dd/MM/yyyy').format(gasto['date']), style: const TextStyle(fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                    ),
                    // Parte derecha (cantidad + botón)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('${gasto['amount'].toStringAsFixed(2)} €', style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text(widget.memberMap[gasto['pagadoPor']]?['name']),
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


class SaldosView extends StatelessWidget {
  final String groupId;
  final String currentDeviceId;
  final Map<String, Map<String, dynamic>> memberMap;

  const SaldosView({
    super.key,
    required this.groupId,
    required this.currentDeviceId,
    required this.memberMap,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collectionGroup('divisiones')
          .where('groupId', isEqualTo: groupId)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Error: \${snap.error}'));
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final divisiones = snap.data!.docs;

        // 1) Agrupa y suma los splits por memberId
        final totals = <String, double>{};
        for (var doc in divisiones) {
          final data = doc.data()! as Map<String, dynamic>;
          final memberId = data['memberId'] as String;
          final amount = (data['cantidad'] as num).toDouble();
          totals[memberId] = (totals[memberId] ?? 0) + amount;
        }

        // 2) Recupera miembros
        return FutureBuilder<QuerySnapshot>(
          future: FirebaseFirestore.instance
              .collection('groups')
              .doc(groupId)
              .collection('members')
              .get(),
          builder: (context, membersSnap) {
            if (membersSnap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            final members = membersSnap.data!.docs;
            final memberMap = {
              for (var m in members) m.id: m.data() as Map<String, dynamic>,
            };

            String? myMemberId;
            try {
              final myMember = members.firstWhere((m) => m['reclamadoPor'] == currentDeviceId);
              myMemberId = myMember.id;
            } catch (e) {
              myMemberId = null;
            }

            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: members.length,
              itemBuilder: (context, i) {
                final m = members[i];
                final name = m['name'] as String;
                final memberId = m.id;
                final balance = totals[memberId] ?? 0.0;
                final isMe = m['reclamadoPor'] == currentDeviceId;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      leading: CircleAvatar(child: Text(name[0])),
                      title: Text(
                        name,
                        style: TextStyle(
                          fontWeight:
                              isMe ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                      trailing: Text(
                        '${balance.toStringAsFixed(2)} €',
                        style: TextStyle(
                          color: balance <= 0 ? Colors.green : Colors.red,
                          fontWeight:
                              isMe ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                    if (isMe && balance > 0)
                      ...divisiones.where((d) => d['memberId'] == myMemberId).map((d) {
                        final data = d.data()! as Map<String, dynamic>;
                        final cantidad = (data['cantidad'] as num).toDouble();
                        final gastoNombre = data['nombre'] ?? 'Gasto';
                        final pagadoPor = data['pagadoPor'] ?? '';
                        final nombrePagador = memberMap[pagadoPor]?['name'] ?? 'Otro';

                        return ListTile(
                          title: Text(gastoNombre),
                          subtitle: Text('Debes a $nombrePagador'),
                          trailing: Text('${cantidad.toStringAsFixed(2)} €'),
                          onTap: () {
                            // Aquí un diálogo para cambiar estado de la deuda
                          },
                        );
                      }).toList(),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}



class EstadisticasView extends StatelessWidget {
  const EstadisticasView({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text('Estadísticas del grupo'), 
    );
  }
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

