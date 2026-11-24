import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart'; // Biblioteca para el botón flotante con múltiples opciones
import 'package:payb2/screens/grupo_detalles/grupo_detalle_screen.dart';
import 'package:payb2/screens/settings/settings_screen.dart';
import 'package:payb2/services/debts/debt_payments.dart';
import 'package:payb2/domain/calendar_date.dart';
import 'package:payb2/domain/group_balances.dart';
import 'package:payb2/services/debts/wallet_debts.dart';
import 'package:payb2/services/groups/groups_list.dart';

// Pantalla principal cuando se pertenece a un grupo

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;

  void _onAccountRestored() {
    setState(() {
      _selectedIndex = 0;
    });
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  Widget _selectedScreen() {
    return switch (_selectedIndex) {
      0 => const GroupsScreen(),
      1 => const WalletScreen(),
      _ => SettingsScreen(onAccountRestored: _onAccountRestored),
    };
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
      appBar: AppBar(title: const Text('PayB2'), centerTitle: true),
      body: Center(child: _selectedScreen()),
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
          BottomNavigationBarItem(icon: Icon(Icons.group), label: 'Grupos'),
          BottomNavigationBarItem(
            icon: Icon(Icons.account_balance_wallet),
            label: 'Cartera',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Ajustes'),
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
  late final GroupsList _groups;

  @override
  void initState() {
    super.initState();
    _groups = GroupsList()..addListener(_onGroupsChanged);
  }

  void _onGroupsChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _groups.removeListener(_onGroupsChanged);
    _groups.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_groups.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final docs = _groups.groups;
    final error = _groups.error;
    return Column(
      children: [
        if (error != null)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('No se pudieron actualizar los grupos'),
                  ),
                  IconButton(
                    onPressed: _groups.refresh,
                    tooltip: 'Reintentar',
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: docs.isEmpty
              ? Center(
                  child: Text(
                    error == null
                        ? 'No perteneces a ningún grupo.'
                        : 'No se pudieron cargar los grupos.',
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  itemBuilder: (_, i) {
                    final data = docs[i].data()!;
                    return Card(
                      key: ValueKey(docs[i].id),
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
                ),
        ),
      ],
    );
  }
}

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  late final WalletDebts _wallet;

  @override
  void initState() {
    super.initState();
    _wallet = WalletDebts()..addListener(_onWalletChanged);
  }

  void _onWalletChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _wallet.removeListener(_onWalletChanged);
    _wallet.dispose();
    super.dispose();
  }

  double _readDebtAmount(Map<String, dynamic> splitData) =>
      divisionAmountCents(splitData) / 100;

  List<_DebtItem> _visibleDebts() {
    final debts = <_DebtItem>[];
    for (final group in _wallet.groups) {
      final gid = group.id;
      final groupName = group.name;
      final memberMap = group.memberNames;
      final pendingDivisions = group.pending;

      for (final splitDoc in pendingDivisions) {
        final splitData = splitDoc.data();
        final memberId = splitData['memberId'] as String?;
        final payerId = splitData['pagadoPor'] as String? ?? '';
        final amount = _readDebtAmount(splitData);
        final expenseRef = splitDoc.reference.parent.parent;
        if (memberId == null ||
            expenseRef == null ||
            amount <= 0 ||
            payerId == memberId) {
          continue;
        }

        debts.add(
          _DebtItem(
            groupId: gid,
            groupName: groupName,
            gastoId: expenseRef.id,
            splitDocId: splitDoc.id,
            gastoName: splitData['nombre'] as String? ?? 'Gasto',
            amount: amount,
            pagadoPorId: payerId,
            pagadoPorName: memberMap[payerId] ?? 'Otro',
            myPhantomId: memberId,
            fecha: formatCalendarDate(splitData['fecha'] as String),
          ),
        );
      }
    }

    return debts;
  }

  Future<void> _markDebtPaid(_DebtItem debt) async {
    try {
      await DebtPayments().markPaid(
        FirebaseFirestore.instance
            .collection('groups')
            .doc(debt.groupId)
            .collection('gastos')
            .doc(debt.gastoId)
            .collection('divisiones')
            .doc(debt.splitDocId),
        debt.myPhantomId,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No se pudo marcar la deuda como pagada: $error'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_wallet.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final debts = _visibleDebts();
    final error = _wallet.error;
    return Column(
      children: [
        if (error != null)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'No se pudieron actualizar las deudas: $error',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        Expanded(
          child: debts.isEmpty
              ? Center(
                  child: Text(
                    error == null
                        ? 'No tienes deudas pendientes.'
                        : 'No se pudieron cargar las deudas pendientes.',
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: debts.length,
                  itemBuilder: (context, i) {
                    final d = debts[i];
                    return Card(
                      key: ValueKey(
                        '${d.groupId}/${d.gastoId}/${d.splitDocId}',
                      ),
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      child: ListTile(
                        title: Text(d.gastoName),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${d.groupName}\nDebes €${d.amount.toStringAsFixed(2)} a ${d.pagadoPorName}',
                            ),
                            const SizedBox(height: 4),
                            Text(
                              d.fecha,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                        isThreeLine: true,
                        trailing: ElevatedButton(
                          onPressed: () => _markDebtPaid(d),
                          child: const Text('Marcar pagado'),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Clase interna para representar cada deuda
class _DebtItem {
  final String groupId;
  final String groupName;
  final String gastoId;
  final String splitDocId;
  final String gastoName;
  final double amount;
  final String pagadoPorId;
  final String pagadoPorName;
  final String myPhantomId;
  final String fecha;

  _DebtItem({
    required this.groupId,
    required this.groupName,
    required this.gastoId,
    required this.splitDocId,
    required this.gastoName,
    required this.amount,
    required this.pagadoPorId,
    required this.pagadoPorName,
    required this.myPhantomId,
    required this.fecha,
  });
}
