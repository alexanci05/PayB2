import 'dart:async';

import 'package:flutter/material.dart';
import 'package:payb2/screens/crear_gasto/crear_gasto.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:payb2/services/auth/identity_mutation_tracker.dart';
import 'package:payb2/services/debts/debt_queries.dart';
import 'package:payb2/domain/group_balances.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:payb2/services/network/connection_status.dart';

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
  List<String> _myMemberIds = [];
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
    final membershipFuture = db
        .collection('groupMembers')
        .doc('${widget.groupId}_$_uid')
        .get();

    final snapReclamado = await db
        .collection('groups')
        .doc(widget.groupId)
        .collection('members')
        .where('reclamadoPor', isEqualTo: _uid)
        .get();

    if (snapReclamado.docs.isNotEmpty) {
      final membership = await membershipFuture;
      final primaryMemberId = membership.data()?['memberId'] as String?;
      if (!mounted) return;
      setState(() {
        _myMemberIds = snapReclamado.docs.map((doc) => doc.id).toList()..sort();
        if (primaryMemberId != null && _myMemberIds.remove(primaryMemberId)) {
          _myMemberIds.insert(0, primaryMemberId);
        }
      });
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

    try {
      final result = await IdentityMutationTracker.shared.track(
        () => FirebaseFunctions.instance
            .httpsCallable('reclamarMiembro')
            .callObserved({'groupId': widget.groupId, 'memberId': chosen}),
      );
      if (!mounted) return;
      setState(() => _myMemberIds = [result.data['memberId'] as String]);
    } on FirebaseFunctionsException catch (error) {
      if (!mounted) return;
      if (error.code == 'failed-precondition') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Otro usuario acaba de reclamar ese miembro'),
          ),
        );
        await _checkOrAskMember();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo reclamar la identidad')),
        );
      }
    }
  }

  void _refreshDerivedViews() {
    if (!mounted) return;
    setState(() => _dataRevision++);
  }

  Future<void> _onCrearGasto(BuildContext context) async {
    final memberId = _myMemberIds.firstOrNull;
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
                if (_myMemberIds.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      'Eres: ${_myMemberIds.map((id) => memberMap[id]?['name'] ?? 'Miembro desconocido').join(', ')}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                Expanded(
                  child: TabBarView(
                    children: [
                      GastosView(
                        groupId: widget.groupId,
                        memberMap: memberMap,
                        myMemberIds: _myMemberIds.toSet(),
                        currentUid: _uid,
                        ownerUid: ownerUid,
                        onChanged: _refreshDerivedViews,
                      ),
                      SaldosView(
                        key: ValueKey('saldos-${widget.groupId}'),
                        groupId: widget.groupId,
                        memberMap: memberMap,
                        myMemberIds: _myMemberIds.toSet(),
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
            floatingActionButton: _myMemberIds.isEmpty
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
  final Set<String> myMemberIds;
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
    final groupRef = FirebaseFirestore.instance
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
    Timestamp scheduledFor,
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
              'scheduledForMillis': scheduledFor.millisecondsSinceEpoch,
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

            return ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                if (schedules.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      'Gastos programados',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  ...schedules.map((schedule) {
                    final data = schedule.data();
                    final cents = data['cantidadCentimos'] as num?;
                    final amount = cents != null
                        ? cents.toDouble() / 100
                        : (data['cantidad'] as num?)?.toDouble() ?? 0;
                    final scheduledAt = data['proximaFecha'] as Timestamp?;
                    final canDelete =
                        widget.ownerUid == widget.currentUid ||
                        data['createdByUid'] == widget.currentUid;
                    final isDeleting = _deletingSchedules.contains(schedule.id);

                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      child: ListTile(
                        leading: const Icon(Icons.schedule),
                        title: Text(data['nombre'] as String? ?? 'Gasto'),
                        subtitle: Text(
                          scheduledAt == null
                              ? 'Fecha pendiente'
                              : DateFormat(
                                  'dd/MM/yyyy',
                                ).format(scheduledAt.toDate()),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('${amount.toStringAsFixed(2)} €'),
                            if (canDelete)
                              IconButton(
                                tooltip: 'Cancelar gasto programado',
                                onPressed: isDeleting || scheduledAt == null
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
                  }),
                ],
                if (expenses.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'Gastos registrados',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  ...expenses.map((expense) {
                    final data = expense.data();
                    final payerId = data['pagadoPor'] as String? ?? '';
                    final cents = data['cantidadCentimos'] as num?;
                    final amount = cents != null
                        ? cents.toDouble() / 100
                        : (data['cantidad'] as num?)?.toDouble() ?? 0;
                    final date = (data['fecha'] as Timestamp).toDate();
                    final isMyGasto = widget.myMemberIds.contains(payerId);
                    final canDelete =
                        widget.ownerUid == widget.currentUid ||
                        data['createdByUid'] == widget.currentUid;

                    return Card(
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
                                      color: isMyGasto
                                          ? Colors.green[800]
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(data['descripcion'] as String? ?? ''),
                                  const SizedBox(height: 4),
                                  Text(
                                    DateFormat('dd/MM/yyyy').format(date),
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
                  }),
                ],
              ],
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
      await IdentityMutationTracker.shared.track(
        () => division.reference.update({
          'pagado': true,
          'pagadoEn': FieldValue.serverTimestamp(),
          'pagoRegistradoPor': currentMemberId,
        }),
      );
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
      await IdentityMutationTracker.shared.track(
        () => division.reference.update({
          'pagado': false,
          'pagadoEn': FieldValue.delete(),
          'pagoRegistradoPor': FieldValue.delete(),
        }),
      );
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
        final pagosRecibidos = divisiones.where((division) {
          final data = division.data();
          return data['pagado'] == true &&
              widget.myMemberIds.contains(data['pagadoPor']) &&
              !widget.myMemberIds.contains(data['memberId']) &&
              data['pagoRegistradoPor'] == data['memberId'];
        }).toList();

        final balances = GroupBalances(divisiones.map((d) => d.data()));
        final showNet = _balanceMode == _BalanceMode.net;

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount:
              1 + widget.memberMap.length + (pagosRecibidos.isEmpty ? 0 : 1),
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
                    if (pendientes.isEmpty && pagosRecibidos.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 16),
                        child: Text('No tienes deudas pendientes.'),
                      ),
                  ],
                ),
              );
            }
            i -= 1;
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
                    final amount = _amount(data);
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
                    final amount = _amount(data);
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
                (data['cantidad'] as num?)?.toDouble() ?? 0,
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
