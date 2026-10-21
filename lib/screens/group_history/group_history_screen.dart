import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:payb2/domain/group_balances.dart';
import 'package:payb2/domain/calendar_date.dart';
import 'package:payb2/services/debts/debt_payments.dart';
import 'package:payb2/services/debts/debt_queries.dart';

class GroupHistoryScreen extends StatefulWidget {
  const GroupHistoryScreen({
    super.key,
    required this.groupId,
    required this.memberNames,
    required this.myMemberIds,
    this.queries,
    this.payments,
  });

  final String groupId;
  final Map<String, String> memberNames;
  final Set<String> myMemberIds;
  final DebtQueries? queries;
  final DebtPayments? payments;

  @override
  State<GroupHistoryScreen> createState() => _GroupHistoryScreenState();
}

class _GroupHistoryScreenState extends State<GroupHistoryScreen> {
  late Stream<QuerySnapshot<Map<String, dynamic>>> _settled;
  late final DebtPayments _payments;
  final Set<String> _reopening = {};

  @override
  void initState() {
    super.initState();
    _payments = widget.payments ?? DebtPayments();
    _watchHistory();
  }

  void _watchHistory() {
    _settled = (widget.queries ?? DebtQueries()).watchSettledGroupDivisions(
      widget.groupId,
    );
  }

  Future<void> _confirmReopen(
    QueryDocumentSnapshot<Map<String, dynamic>> division,
  ) async {
    if (_reopening.contains(division.reference.path)) return;
    final data = division.data();
    final debtor = widget.memberNames[data['memberId']] ?? 'Miembro';
    final expense = data['nombre'] as String? ?? 'Gasto';
    final amount = (divisionAmountCents(data) / 100).toStringAsFixed(2);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Marcar pago como pendiente'),
        content: Text(
          '$expense (${formatCalendarDate(data['fecha'] as String)}): $debtor volverá a deber $amount €.',
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
    if (confirmed != true || !mounted) return;

    setState(() => _reopening.add(division.reference.path));
    try {
      await _payments.reopen(division);
    } catch (error) {
      if (!mounted) return;
      final message = error is DebtPaymentConflict
          ? error.message
          : 'No se pudo reabrir el pago. Comprueba la conexión e inténtalo de nuevo.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _reopening.remove(division.reference.path));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Historial de pagos')),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _settled,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('No se pudo actualizar el historial.'),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () => setState(_watchHistory),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reintentar'),
                  ),
                ],
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final debts = snapshot.data!.docs.where((doc) {
            final data = doc.data();
            return data['memberId'] != data['pagadoPor'];
          }).toList();
          debts.sort((a, b) {
            final aTime = a.data()['pagadoEn'] as Timestamp?;
            final bTime = b.data()['pagadoEn'] as Timestamp?;
            final byTime = (bTime?.microsecondsSinceEpoch ?? 0).compareTo(
              aTime?.microsecondsSinceEpoch ?? 0,
            );
            return byTime != 0
                ? byTime
                : a.reference.path.compareTo(b.reference.path);
          });
          if (debts.isEmpty) {
            return const Center(child: Text('No hay deudas saldadas.'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: debts.length,
            itemBuilder: (context, index) {
              final division = debts[index];
              final data = division.data();
              final debtor = widget.memberNames[data['memberId']] ?? 'Miembro';
              final creditor =
                  widget.memberNames[data['pagadoPor']] ?? 'Miembro';
              final registeredBy =
                  widget.memberNames[data['pagoRegistradoPor']];
              final amount = (divisionAmountCents(data) / 100).toStringAsFixed(
                2,
              );
              final canReopen = widget.myMemberIds.contains(data['pagadoPor']);
              final busy = _reopening.contains(division.reference.path);
              return Card(
                key: ValueKey(division.reference.path),
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: ListTile(
                  title: Text(data['nombre'] as String? ?? 'Gasto'),
                  subtitle: Text(
                    [
                      '$debtor a $creditor: $amount €',
                      'Gasto: ${formatCalendarDate(data['fecha'] as String)}',
                      if (data['pagadoEn'] != null)
                        'Saldado: ${DateFormat('dd/MM/yyyy').format((data['pagadoEn'] as Timestamp).toDate().toLocal())}',
                      if (registeredBy != null) 'Registrado por $registeredBy',
                    ].join('\n'),
                  ),
                  trailing: canReopen
                      ? IconButton(
                          tooltip: 'Volver a marcar como pendiente',
                          onPressed: busy || division.metadata.hasPendingWrites
                              ? null
                              : () => _confirmReopen(division),
                          icon: busy
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.undo),
                        )
                      : null,
                ),
              );
            },
          );
        },
      ),
    );
  }
}
