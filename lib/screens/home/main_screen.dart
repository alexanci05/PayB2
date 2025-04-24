import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';

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
    // Aquí luego navegarás a CrearGrupoScreen
    Navigator.pushNamed(context, '/crearGrupo');
  }

  void _onUnirseAGrupo(BuildContext context) {
    // Aquí luego navegarás a UnirseGrupoScreen
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
    final info = DeviceInfoPlugin();
    final android = await info.androidInfo;
    final id = android.id;

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

class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});
  

  @override
  Widget build(BuildContext context) {
    return Center(   
      child: Column(
        children: [
          Text('Pantalla Cartera - en construcción'),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: () async {
              final ref = FirebaseFirestore.instance.collection('groups').doc();
              await ref.set({
                'name': 'Grupo desde APP 3 ',
                'groupCode': 'X1Y2Z3',
                'createdAt': FieldValue.serverTimestamp(),
              });
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Grupo creado en Firebase')),
                );
              }
            },
            child: const Text('🚀 Test Firebase'),
          ),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('Pantalla Ajustes - en construcción'),
    );
  }
}

Future<String> getDeviceId() async {
  final deviceInfo = DeviceInfoPlugin();
  final androidInfo = await deviceInfo.androidInfo;
  return androidInfo.id; // Este es único por instalación
}