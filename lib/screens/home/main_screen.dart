import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';  // Biblioteca para el botón flotante con múltiples opciones
import 'package:payb2/screens/grupo_detalles/grupo_detalle_screen.dart';
import 'package:payb2/notifications.dart';
import 'package:provider/provider.dart';
import 'package:payb2/providers/theme_provider.dart';
import 'package:collection/collection.dart'; // para firstWhereOrNull
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

// Pantalla principal cuando se pertenece a un grupo

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;

  static const List<Widget> _widgetOptions = <Widget>[
    GroupsScreen(),
    WalletScreen(),
    SettingsScreen(),
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  void _onCrearGrupo(BuildContext context) {
    
    Navigator.pushNamed(context, '/crearGrupo');
  }

  void _onUnirseAGrupo(BuildContext context) {
    
    Navigator.pushNamed(context, '/unirseGrupo');
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PayB2'),
        centerTitle: true,
      ),
      body: Center(
        child: _widgetOptions.elementAt(_selectedIndex),
      ),
      floatingActionButton: SpeedDial(
        icon: Icons.add,
        activeIcon: Icons.close,
        backgroundColor: Colors.blue,
        spacing: 12,
        spaceBetweenChildren: 8,
        children: [
          SpeedDialChild(
            child: const Icon(Icons.group_add),
            label: 'Crear Grupo',
            onTap: () => _onCrearGrupo(context),
          ),
          SpeedDialChild(
            child: const Icon(Icons.input),
            label: 'Unirse a Grupo',
            onTap: () => _onUnirseAGrupo(context),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.group),
            label: 'Grupos',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.account_balance_wallet),
            label: 'Cartera',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings),
            label: 'Ajustes',
          ),
        ],
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
      ),
    );
  }
}

// Placeholder screens:
class GroupsScreen extends StatefulWidget {
  const GroupsScreen({super.key});

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> {
  String? deviceId;
  late Future<List<DocumentSnapshot>> futureGroups;

  @override
  void initState() {
    super.initState();
    loadGroups();
  }

  Future<void> loadGroups() async {
    final id = await getUid();


    final memberQuery = await FirebaseFirestore.instance
        .collection('groupMembers')
        .where('deviceId', isEqualTo: id)
        .get();

    final groupIds = memberQuery.docs.map((doc) => doc['groupId']).toList();

    if (mounted) {
      setState(() {
        deviceId = id;
        futureGroups = _loadGroupDocs(groupIds);
      });
    }
  }

  Future<List<DocumentSnapshot>> _loadGroupDocs(List groupIds) async {
    if (groupIds.isEmpty) return [];
    final futures = groupIds.map((id) {
      return FirebaseFirestore.instance.collection('groups').doc(id).get();
    });
    return await Future.wait(futures);
  } 

  @override
  Widget build(BuildContext context) {
    if (deviceId == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return FutureBuilder<List<DocumentSnapshot>>(
      future: futureGroups,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('Error: ${snapshot.error}'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

        final docs = snapshot.data!;
        if (docs.isEmpty) {
          return const Center(child: Text('No perteneces a ningún grupo.'));
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: docs.length,
          itemBuilder: (_, i) {
            final data = docs[i].data()! as Map<String, dynamic>;
            return Card(
              child: ListTile(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => GrupoDetalleScreen(
                        groupId: docs[i].id,
                        groupName: data['name'] ?? 'Sin nombre',
                      ),
                    ),
                  );
                },
                title: Text(data['name'] ?? '—'),
                subtitle: Text('Código: ${data['groupCode']}'),
              ),
            );
          },
        );
      },
    );
  }
}

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  late Future<List<_DebtItem>> _futureDebts;

  @override
  void initState() {
    super.initState();
    _futureDebts = _loadDebts();
  }

  
  final functions = FirebaseFunctions.instance;

  Future<String> _loadUid() async {
    final id = await getUid();
    return id;
  }


  Future<List<_DebtItem>> _loadDebts() async {
    final uid = await _loadUid();

    // 1) Obtenemos todos los groupIds donde este
    final memberQ = await FirebaseFirestore.instance
        .collection('groupMembers')
        .where('deviceId', isEqualTo: uid)
        .get();
    final groupIds = memberQ.docs.map((d) => d['groupId'] as String).toList();

    final debts = <_DebtItem>[];

    // 2) Por cada grupo...
    for (final gid in groupIds) {
      // a) Recupera nombre de grupo
      final groupDoc = await FirebaseFirestore.instance
          .collection('groups').doc(gid).get();
      final groupName = groupDoc['name'] as String? ?? 'Grupo';

      // b) Cargamos todos los miembros de ese grupo y creamos memberMap
      final membersSnap = await FirebaseFirestore.instance
          .collection('groups').doc(gid)
          .collection('members')
          .get();
      final Map<String, String> memberMap = {
        for (var m in membersSnap.docs)
          m.id: (m.data()['name'] as String? ?? '—'),
      };

       // c) Intentamos encontrar el usuario fantasma
      final phantomSnap = membersSnap.docs.firstWhereOrNull(
        (m) => (m.data()['reclamadoPor'] as String?) == uid,
      );

      if (phantomSnap == null) {
        continue;
      }
      
      final phantomId = phantomSnap.id;

      // d) Recorre todos los gastos
      final gastosSnap = await FirebaseFirestore.instance
          .collection('groups').doc(gid)
          .collection('gastos')
          .get();

      for (final gastoDoc in gastosSnap.docs) {
        final gastoData = gastoDoc.data();
        final gastoName = gastoData['nombre'] as String? ?? 'Gasto';
        final pagadoPorId = gastoData['pagadoPor'] as String? ?? '';

        // e) Busca en splits solo tu parte
        final splitsSnap = await gastoDoc.reference
            .collection('divisiones')
            .where('memberId', isEqualTo: phantomId)
            .get();

        for (final splitDoc in splitsSnap.docs) {
          final splitData = splitDoc.data();
          final amount = (splitData['cantidad'] as num).toDouble();

          // Solo si debes y no eres tú quien pagó
          if (amount > 0 && pagadoPorId != phantomId) {
            debts.add(_DebtItem(
              groupId:     gid,
              groupName:   groupName,
              gastoId:     gastoDoc.id,
              gastoName:   gastoName,
              amount:      amount,
              pagadoPorId: pagadoPorId,
              pagadoPorName: memberMap[pagadoPorId] ?? 'Otro',
              myPhantomId: phantomId,
            ));
          }
        }
      }
    }

    return debts;
  }


  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_DebtItem>>(
      future: _futureDebts,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }
        final debts = snap.data!;
        if (debts.isEmpty) {
          return const Center(child: Text('No tienes deudas pendientes.'));
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: debts.length,
          itemBuilder: (context, i) {
            final d = debts[i];
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 6),
              child: ListTile(
                title: Text(d.gastoName),
                subtitle: Text(
                  '${d.groupName}\nDebes €${d.amount.toStringAsFixed(2)} a ${d.pagadoPorName}',
                ),
                  isThreeLine: true,
                  trailing: Row(
                  mainAxisSize: MainAxisSize.min, // para que no ocupe todo el ancho
                  children: [
                    ElevatedButton(
                      onPressed: () async {
                        // Actualizar splits a pagado
                        await FirebaseFirestore.instance
                          .collection('groups').doc(d.groupId)
                          .collection('gastos').doc(d.gastoId)
                          .collection('divisiones').where('memberId', isEqualTo: d.myPhantomId)
                          .get()
                          .then((snap) {
                            for (var doc in snap.docs) {
                              doc.reference.update({'cantidad': 0, 'pagado': true});
                            }
                          });

                        // Refrescar lista
                        setState(() {
                          _futureDebts = _loadDebts();
                        });
                      },
                      child: const Text('Marcar pagado'),
                    )
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

/// Clase interna para representar cada deuda
class _DebtItem {
  final String groupId;
  final String groupName;
  final String gastoId;
  final String gastoName;
  final double amount;
  final String pagadoPorId;
  final String pagadoPorName;  
  final String myPhantomId;

  _DebtItem({
    required this.groupId,
    required this.groupName,
    required this.gastoId,
    required this.gastoName,
    required this.amount,
    required this.pagadoPorId,
    required this.pagadoPorName, 
    required this.myPhantomId,
  });
}


class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ElevatedButton(
        onPressed: () {
          Provider.of<ThemeProvider>(context, listen: false).toggleTheme();
        },
        child: const Text('Cambiar tema'),
      ),
    );
  }
}


Future<String> getUid() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    throw Exception('Usuario no autenticado');
  }
  return user.uid;
}