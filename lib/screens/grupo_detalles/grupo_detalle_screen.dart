import 'dart:async';

import 'package:flutter/material.dart';
import 'package:payb2/screens/crear_gasto/crear_gasto.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:payb2/domain/calendar_date.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:payb2/services/auth/identity_mutation_tracker.dart';
import 'package:payb2/services/debts/debt_queries.dart';
import 'package:payb2/domain/group_balances.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:payb2/services/network/connection_status.dart';
import 'package:payb2/screens/group_history/group_history_screen.dart';
import 'package:payb2/services/debts/debt_payments.dart';
import 'package:payb2/services/groups/group_context.dart';
import 'package:payb2/screens/group_settings/group_settings_screen.dart';

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
  late final GroupContext _group;
  bool _claimingIdentity = false;
  int _dataRevision = 0;

  late final String _uid;

  @override
  void initState() {
    super.initState();
    _uid = FirebaseAuth.instance.currentUser!.uid;

    _group = GroupContext(widget.groupId, _uid)..start();
  }

  @override
  void dispose() {
    _group.dispose();
    super.dispose();
  }

  Future<void> _claimIdentity() async {
    if (_claimingIdentity || _group.myMemberIds.isNotEmpty) return;
    final available = _group.members.entries
        .where((entry) => entry.value['reclamadoPor'] == null)
        .toList();
    if (available.isEmpty) {
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
          for (final member in available)
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(ctx, member.key);
              },
              child: Text(member.value['name'] as String? ?? 'Miembro'),
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

    if (chosen == null || !mounted) return;

    setState(() => _claimingIdentity = true);
    try {
      await IdentityMutationTracker.shared.track(
        () => FirebaseFunctions.instance
            .httpsCallable('reclamarMiembro')
            .callObserved({'groupId': widget.groupId, 'memberId': chosen}),
      );
    } on FirebaseFunctionsException catch (error) {
      if (!mounted) return;
      if (error.code == 'failed-precondition') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Otro usuario acaba de reclamar ese miembro'),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo reclamar la identidad')),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo reclamar la identidad')),
      );
    } finally {
      if (mounted) setState(() => _claimingIdentity = false);
    }
  }

  void _refreshDerivedViews() {
    if (!mounted) return;
    setState(() => _dataRevision++);
  }

  Future<void> _onCrearGasto(BuildContext context) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => CrearGastoScreen(
          groupId: widget.groupId,
          initialPayerId: _group.myMemberIds.firstOrNull,
        ),
      ),
    );
    _refreshDerivedViews();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _group,
      builder: (context, _) {
        if ((!_group.ready && _group.error != null) ||
            (_group.ready && !_group.exists)) {
          return Scaffold(
            appBar: AppBar(title: Text(widget.groupName)),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('No se pudo cargar el grupo.'),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _group.start,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reintentar'),
                  ),
                ],
              ),
            ),
          );
        }
        if (!_group.ready) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final memberMap = _group.members;
        final myMemberIds = _group.myMemberIds;

        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: Text(_group.name ?? widget.groupName),
              actions: [
                IconButton(
                  tooltip: 'Ajustes del grupo',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          GroupSettingsScreen(groupId: widget.groupId),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Historial de pagos',
                  icon: const Icon(Icons.history),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => GroupHistoryScreen(
                        groupId: widget.groupId,
                        memberNames: {
                          for (final entry in memberMap.entries)
                            entry.key: entry.value['name'] as String,
                        },
                        myMemberIds: myMemberIds.toSet(),
                      ),
                    ),
                  ),
                ),
              ],
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
                if (_group.error != null)
                  Material(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: ListTile(
                      title: const Text('No se pudo actualizar el grupo'),
                      trailing: IconButton(
                        tooltip: 'Reintentar',
                        onPressed: _group.start,
                        icon: const Icon(Icons.refresh),
                      ),
                    ),
                  ),
                if (myMemberIds.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      'Eres: ${myMemberIds.map((id) => memberMap[id]?['name'] ?? 'Miembro desconocido').join(', ')}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  )
                else
                  TextButton.icon(
                    onPressed: _claimingIdentity ? null : _claimIdentity,
                    icon: const Icon(Icons.person_outline),
                    label: const Text('Identificarse'),
                  ),
                Expanded(
                  child: TabBarView(
                    children: [
                      GastosView(
                        groupId: widget.groupId,
                        memberMap: memberMap,
                        myMemberIds: myMemberIds.toSet(),
                        currentUid: _uid,
                        isAdmin: _group.isAdmin,
                        onChanged: _refreshDerivedViews,
                      ),
                      SaldosView(
                        key: ValueKey('saldos-${widget.groupId}'),
                        groupId: widget.groupId,
                        memberMap: memberMap,
                        myMemberIds: myMemberIds.toSet(),
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
  final FirebaseFirestore? firestore;
  final String groupId;
  final Map<String, Map<String, dynamic>> memberMap;
  final Set<String> myMemberIds;
  final String currentUid;
  final bool isAdmin;
  final VoidCallback onChanged;

  const GastosView({
    super.key,
    this.firestore,
    required this.groupId,
    required this.memberMap,
    required this.currentUid,
    required this.isAdmin,
    required this.onChanged,
    required this.myMemberIds,
  });

  @override
  State<GastosView> createState() => _GastosViewState();
}

class _GastosViewState extends State<GastosView> {
  final Set<String> _deletingSchedules = {};
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _expensesStream;
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _schedulesStream;

  @override
  void initState() {
    super.initState();
    final groupRef = (widget.firestore ?? FirebaseFirestore.instance)
        .collection('groups')
        .doc(widget.groupId);
    _expensesStream = groupRef
        .collection('gastos')
        .orderBy('fecha', descending: true)
        .snapshots();
    _schedulesStream = groupRef
        .collection('gastosProgramados')
        .orderBy('proximaFecha')
        .snapshots();
  }

  Future<void> _confirmAndDelete(String gastoId, String? scheduleId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar gasto'),
        content: Text(
          scheduleId == null
              ? 'El gasto y sus divisiones se eliminarán definitivamente.'
              : 'El gasto y sus divisiones se eliminarán. También dejarán de generarse gastos futuros de esta periodicidad. Los otros gastos ya generados se conservan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar gasto'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    try {
      await IdentityMutationTracker.shared.track(
        () => FirebaseFunctions.instance
            .httpsCallable('eliminarGasto')
            .callObserved({'groupId': widget.groupId, 'gastoId': gastoId}),
      );
      if (!mounted) return;
      widget.onChanged();
    } on FirebaseFunctionsException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo eliminar el gasto')),
      );
    }
  }

  Future<void> _confirmAndDeleteSchedule(
    String scheduleId,
    String scheduledFor,
    bool recurring,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancelar gasto programado'),
        content: Text(
          recurring
              ? 'Se cancelará la periodicidad. Los gastos ya generados y sus deudas se conservan.'
              : 'Se cancelará este gasto si todavía no se ha generado.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Volver'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancelar gasto'),
          ),
        ],
      ),
    );
    if (!mounted ||
        confirmed != true ||
        _deletingSchedules.contains(scheduleId)) {
      return;
    }

    setState(() => _deletingSchedules.add(scheduleId));
    try {
      final result = await IdentityMutationTracker.shared.track(
        () => FirebaseFunctions.instance
            .httpsCallable('eliminarGastoProgramado')
            .callObserved<Map<String, dynamic>>({
              'groupId': widget.groupId,
              'scheduleId': scheduleId,
              'scheduledFor': scheduledFor,
            }),
      );
      if (!mounted) return;
      widget.onChanged();
      final generated = result.data['occurrenceGenerated'] == true;
      final deleted = result.data['deleted'] == true;
      final message = generated
          ? deleted
                ? 'Periodicidad cancelada. El gasto de esa fecha ya se había generado y se conserva.'
                : 'El gasto ya se había generado y no se ha eliminado.'
          : deleted
          ? 'Gasto programado cancelado.'
          : 'La programación ya no existe.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on FirebaseFunctionsException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo cancelar el gasto')),
      );
    } finally {
      if (mounted) setState(() => _deletingSchedules.remove(scheduleId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _expensesStream,
      builder: (context, expensesSnapshot) {
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _schedulesStream,
          builder: (context, schedulesSnapshot) {
            if (expensesSnapshot.connectionState == ConnectionState.waiting ||
                schedulesSnapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (expensesSnapshot.hasError || schedulesSnapshot.hasError) {
              return const Center(
                child: Text('No se pudieron cargar los gastos.'),
              );
            }

            final expenses = expensesSnapshot.data?.docs ?? [];
            final schedules = schedulesSnapshot.data?.docs ?? [];
            if (expenses.isEmpty && schedules.isEmpty) {
              return const Center(child: Text('No hay gastos registrados.'));
            }

            final scheduleCount = schedules.isEmpty ? 0 : schedules.length + 1;
            final itemKeys = <String>[
              if (schedules.isNotEmpty) 'schedules-heading',
              for (final schedule in schedules) 'schedule/${schedule.id}',
              if (expenses.isNotEmpty) 'expenses-heading',
              for (final expense in expenses) 'expense/${expense.id}',
            ];
            final itemIndexes = <String, int>{
              for (var i = 0; i < itemKeys.length; i++) itemKeys[i]: i,
            };
            return ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: itemKeys.length,
              findChildIndexCallback: (key) =>
                  key is ValueKey<String> ? itemIndexes[key.value] : null,
              itemBuilder: (context, index) {
                final key = ValueKey(itemKeys[index]);
                if (schedules.isNotEmpty && index == 0) {
                  return Padding(
                    key: key,
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      'Gastos programados',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  );
                }
                if (index < scheduleCount) {
                  final schedule = schedules[index - 1];
                  final data = schedule.data();
                  final amount = divisionAmountCents(data) / 100;
                  final scheduledAt = data['proximaFecha'] as String;
                  final canDelete =
                      widget.isAdmin ||
                      data['createdByUid'] == widget.currentUid;
                  final isDeleting = _deletingSchedules.contains(schedule.id);

                  return Card(
                    key: key,
                    margin: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.schedule),
                      title: Text(data['nombre'] as String? ?? 'Gasto'),
                      subtitle: Text(formatCalendarDate(scheduledAt)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('${amount.toStringAsFixed(2)} €'),
                          if (canDelete)
                            IconButton(
                              tooltip: 'Cancelar gasto programado',
                              onPressed: isDeleting
                                  ? null
                                  : () => _confirmAndDeleteSchedule(
                                      schedule.id,
                                      scheduledAt,
                                      data['frecuencia'] != null,
                                    ),
                              icon: isDeleting
                                  ? const SizedBox.square(
                                      dimension: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.delete_outline),
                            ),
                        ],
                      ),
                    ),
                  );
                }
                final expenseIndex = index - scheduleCount;
                if (expenseIndex == 0) {
                  return Padding(
                    key: key,
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'Gastos registrados',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  );
                }
                final expense = expenses[expenseIndex - 1];
                final data = expense.data();
                final payerId = data['pagadoPor'] as String? ?? '';
                final amount = divisionAmountCents(data) / 100;
                final date = data['fecha'] as String;
                final isMyGasto = widget.myMemberIds.contains(payerId);
                final canDelete =
                    widget.isAdmin || data['createdByUid'] == widget.currentUid;

                return Card(
                  key: key,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
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
                                data['nombre'] as String? ?? 'Gasto',
                                style: TextStyle(
                                  fontWeight: isMyGasto
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: isMyGasto ? Colors.green[800] : null,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(data['descripcion'] as String? ?? ''),
                              const SizedBox(height: 4),
                              Text(
                                formatCalendarDate(date),
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
                              '${amount.toStringAsFixed(2)} €',
                              style: TextStyle(
                                fontWeight: isMyGasto
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                                color: isMyGasto ? Colors.green[800] : null,
                              ),
                            ),
                            Text(widget.memberMap[payerId]?['name'] ?? ''),
                            if (canDelete)
                              IconButton(
                                icon: const Icon(
                                  Icons.delete,
                                  color: Colors.red,
                                ),
                                onPressed: () => _confirmAndDelete(
                                  expense.id,
                                  data['scheduleId'] as String?,
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
      },
    );
  }
}

class SaldosView extends StatefulWidget {
  final String groupId;
  final Set<String> myMemberIds;
  final Map<String, Map<String, dynamic>> memberMap;

  const SaldosView({
    super.key,
    required this.groupId,
    required this.memberMap,
    required this.myMemberIds,
  });

  @override
  State<SaldosView> createState() => _SaldosViewState();
}

enum _BalanceMode { debts, net }

class _SaldosViewState extends State<SaldosView> {
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _divisionesStream;
  final _payments = DebtPayments();
  _BalanceMode _balanceMode = _BalanceMode.debts;
  bool _selectionChanged = false;

  String get _preferenceKey => 'group.${widget.groupId}.balances.net';

  @override
  void initState() {
    super.initState();
    _divisionesStream = DebtQueries().watchGroupDivisions(widget.groupId);
    unawaited(_loadBalanceMode());
  }

  Future<void> _loadBalanceMode() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!mounted || _selectionChanged) return;
      setState(() {
        _balanceMode = preferences.getBool(_preferenceKey) == true
            ? _BalanceMode.net
            : _BalanceMode.debts;
      });
    } catch (_) {
      // Local preferences must not prevent viewing or settling debts.
    }
  }

  Future<void> _selectBalanceMode(Set<_BalanceMode> selection) async {
    final mode = selection.single;
    setState(() {
      _selectionChanged = true;
      _balanceMode = mode;
    });
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(
        _preferenceKey,
        _balanceMode == _BalanceMode.net,
      );
    } catch (_) {
      // Keep the selection usable when local storage is unavailable.
    }
  }

  double _amount(Map<String, dynamic> data) {
    return divisionAmountCents(data) / 100;
  }

  Future<void> _marcarPagado(
    QueryDocumentSnapshot<Map<String, dynamic>> division,
  ) async {
    final data = division.data();
    final debtorId = data['memberId'] as String?;
    final payerId = data['pagadoPor'] as String?;
    final currentMemberId = widget.myMemberIds.contains(debtorId)
        ? debtorId
        : widget.myMemberIds.contains(payerId)
        ? payerId
        : null;
    if (currentMemberId == null) return;

    try {
      await _payments.markPaid(division.reference, currentMemberId);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo confirmar el pago')),
      );
    }
  }

  Future<void> _confirmarCobro(
    QueryDocumentSnapshot<Map<String, dynamic>> division,
  ) async {
    final data = division.data();
    final dateLabel = formatCalendarDate(data['fecha'] as String);
    final name = widget.memberMap[data['memberId']]?['name'] ?? 'Miembro';
    final expense = data['nombre'] as String? ?? 'Gasto';
    final amount = _amount(data).toStringAsFixed(2);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Registrar deuda como cobrada'),
        content: Text(
          '$expense ($dateLabel): se registrará el cobro de $amount € de $name.',
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
    if (confirmed == true && mounted) await _marcarPagado(division);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _divisionesStream,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Error: ${snap.error}'));
        }

        final divisiones = snap.data!.docs;
        final pendientes = divisiones.where((division) {
          final data = division.data();
          return data['pagado'] != true &&
              data['memberId'] != data['pagadoPor'];
        }).toList();
        final balances = GroupBalances(divisiones.map((d) => d.data()));
        final showNet = _balanceMode == _BalanceMode.net;

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: 1 + widget.memberMap.length,
          itemBuilder: (context, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  children: [
                    SegmentedButton<_BalanceMode>(
                      segments: const [
                        ButtonSegment(
                          value: _BalanceMode.debts,
                          label: Text('Deudas'),
                        ),
                        ButtonSegment(
                          value: _BalanceMode.net,
                          label: Text('Balance neto'),
                        ),
                      ],
                      selected: {_balanceMode},
                      onSelectionChanged: _selectBalanceMode,
                    ),
                    if (pendientes.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: Text('No tienes deudas pendientes.'),
                      ),
                  ],
                ),
              );
            }
            i -= 1;
            final memberIds = widget.memberMap.keys.toList();
            final memberId = memberIds[i];
            final name = widget.memberMap[memberId]?['name'] ?? 'Sin nombre';
            final balanceCents =
                (showNet ? balances.net : balances.debts)[memberId] ?? 0;
            final balance = balanceCents / 100;
            final sign = showNet && balanceCents > 0 ? '+' : '';
            final isMe = widget.myMemberIds.contains(memberId);
            final ownPendingDebts = pendientes.where((division) {
              final data = division.data();
              return data['memberId'] == memberId;
            });
            final debtsOwedToMe = pendientes.where((division) {
              final data = division.data();
              return data['memberId'] == memberId &&
                  widget.myMemberIds.contains(data['pagadoPor']) &&
                  !widget.myMemberIds.contains(memberId);
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
                    '$sign${balance.toStringAsFixed(2)} €',
                    style: TextStyle(
                      color: balanceCents == 0
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : (showNet ? balanceCents > 0 : balanceCents < 0)
                          ? Colors.green
                          : Colors.red,
                      fontWeight: isMe ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
                if (isMe)
                  ...ownPendingDebts.map((d) {
                    final data = d.data();
                    final cantidad = _amount(data);
                    final gastoNombre = data['nombre'] ?? 'Gasto';
                    final pagadoPor = data['pagadoPor'] ?? '';
                    final nombrePagador =
                        widget.memberMap[pagadoPor]?['name'] ?? 'Otro';
                    final fecha = formatCalendarDate(data['fecha'] as String);

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
                    final amount = _amount(data);
                    final expenseName = data['nombre'] as String? ?? 'Gasto';
                    final dateLabel = formatCalendarDate(
                      data['fecha'] as String,
                    );

                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      child: ListTile(
                        title: Text(expenseName),
                        subtitle: Text(
                          '$name te debe ${amount.toStringAsFixed(2)} €\nGasto: $dateLabel',
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

class EstadisticasView extends StatelessWidget {
  final String groupId;

  const EstadisticasView({super.key, required this.groupId});

  @override
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('groups')
          .doc(groupId)
          .collection('gastos')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        final gastos = snapshot.data!.docs
            .map((doc) {
              final data = doc.data();
              return _GastoEntry(
                data['nombre'] as String? ?? 'Gasto',
                divisionAmountCents(data) / 100,
              );
            })
            .where((entry) => entry.importe > 0)
            .toList();
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
