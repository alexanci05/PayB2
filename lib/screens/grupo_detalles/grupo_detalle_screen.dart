import 'package:flutter/material.dart';
import 'package:payb2/screens/crear_gasto/crear_gasto.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

class GrupoDetalleScreen extends StatelessWidget {
  final String groupId;
  final String groupName;
  final String currentdeviceId; // ID del dispositivo actual

  const GrupoDetalleScreen({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.currentdeviceId,
  });

  void _onCrearGasto(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CrearGastoScreen(
          groupId: groupId,
          currentdeviceId: currentdeviceId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3, // Gastos, Saldos, Estadísticas
      child: Scaffold(
        appBar: AppBar(
          title: Text(groupName),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Gastos'),
              Tab(text: 'Saldos'),
              Tab(text: 'Estadísticas'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            GastosView(groupId: groupId),      
            SaldosView(),
            EstadisticasView(),
          ],
        ),
        floatingActionButton: FloatingActionButton(
        onPressed: () => _onCrearGasto(context),
        backgroundColor: Colors.blue,       
        tooltip: 'Añadir gasto',
        child: const Icon(Icons.add),
      ),
      ),
    );
  }
}

// Pantalla de Gastos ------------------------------------------
class GastosView extends StatefulWidget {
  final String groupId;

  const GastosView({super.key, required this.groupId});

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
                        IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () async {
                            await FirebaseFirestore.instance
                                .collection('groups')
                                .doc(widget.groupId)
                                .collection('gastos')
                                .doc(gasto['id'])
                                .delete();
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
  const SaldosView({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text('Saldos del grupo'), 
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