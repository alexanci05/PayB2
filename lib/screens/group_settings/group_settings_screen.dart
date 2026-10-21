import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:payb2/services/groups/group_management.dart';

class GroupSettingsScreen extends StatefulWidget {
  const GroupSettingsScreen({super.key, required this.groupId});

  final String groupId;

  @override
  State<GroupSettingsScreen> createState() => _GroupSettingsScreenState();
}

class _GroupSettingsScreenState extends State<GroupSettingsScreen> {
  late Stream<User?> _users;

  @override
  void initState() {
    super.initState();
    _users = FirebaseAuth.instance.authStateChanges();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Ajustes del grupo')),
    body: StreamBuilder<User?>(
      stream: _users,
      initialData: FirebaseAuth.instance.currentUser,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _LoadError(
            onRetry: () => setState(() {
              _users = FirebaseAuth.instance.authStateChanges();
            }),
          );
        }
        final uid = snapshot.data?.uid;
        if (uid == null) {
          return const Center(child: Text('Usuario no autenticado'));
        }
        return _GroupSettingsForm(
          key: ValueKey((widget.groupId, uid)),
          groupId: widget.groupId,
          uid: uid,
        );
      },
    ),
  );
}

class _GroupSettingsForm extends StatefulWidget {
  const _GroupSettingsForm({
    super.key,
    required this.groupId,
    required this.uid,
  });

  final String groupId;
  final String uid;

  @override
  State<_GroupSettingsForm> createState() => _GroupSettingsFormState();
}

class _GroupSettingsFormState extends State<_GroupSettingsForm> {
  final _name = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _management = GroupManagement();
  final _requestsByName = <String, String>{};
  late Stream<DocumentSnapshot<Map<String, dynamic>>> _group;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _members;
  late Stream<QuerySnapshot<Map<String, dynamic>>> _membership;
  int _revision = 0;
  bool _saving = false;
  bool _adding = false;
  bool _renaming = false;

  bool get _busy => _saving || _adding || _renaming;

  @override
  void initState() {
    super.initState();
    _watch();
  }

  void _watch() {
    final db = FirebaseFirestore.instance;
    final group = db.collection('groups').doc(widget.groupId);
    _group = group.snapshots();
    _members = group.collection('members').snapshots();
    _membership = db
        .collection('groupMembers')
        .where('deviceId', isEqualTo: widget.uid)
        .where('groupId', isEqualTo: widget.groupId)
        .snapshots();
  }

  void _retry() => setState(() {
    _revision++;
    _watch();
  });

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _feedback(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _errorMessage(Object error, String fallback) {
    if (error is FirebaseFunctionsException) {
      return switch (error.code) {
        'permission-denied' => 'No tienes permiso para realizar esta acción.',
        'unauthenticated' => 'Usuario no autenticado',
        'already-exists' => 'Ya existe un miembro con ese nombre.',
        'resource-exhausted' => 'El grupo ya tiene el máximo de 50 miembros.',
        'invalid-argument' => 'Revisa el nombre del miembro.',
        _ => fallback,
      };
    }
    return fallback;
  }

  Future<void> _configure(bool value) async {
    if (_busy) return;
    setState(() => _saving = true);
    try {
      await _management.configureAdministration(
        groupId: widget.groupId,
        allMembersAreAdmins: value,
      );
    } catch (error) {
      if (!mounted) return;
      _feedback(
        _errorMessage(error, 'No se pudo guardar. Inténtalo de nuevo.'),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _rename(String currentName) async {
    if (_busy) return;
    setState(() => _renaming = true);
    try {
      final renamed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _RenameGroupDialog(
          initialName: currentName,
          onSave: (name) =>
              _management.renameGroup(groupId: widget.groupId, nombre: name),
        ),
      );
      if (mounted && renamed == true) _feedback('Nombre del grupo actualizado');
    } finally {
      if (mounted) setState(() => _renaming = false);
    }
  }

  Future<void> _addMember() async {
    if (_busy || _formKey.currentState?.validate() != true) return;
    final name = _name.text.trim();
    // Retain uncertain requests even when the user tries another name first.
    final requestId = _requestsByName.putIfAbsent(
      name,
      () => FirebaseFirestore.instance.collection('groups').doc().id,
    );
    setState(() => _adding = true);
    try {
      await _management.addMember(
        groupId: widget.groupId,
        nombre: name,
        requestId: requestId,
      );
      _requestsByName.remove(name);
      if (!mounted) return;
      _name.clear();
      _feedback('Miembro añadido');
    } catch (error) {
      if (!mounted) return;
      _feedback(
        _errorMessage(
          error,
          'No se pudo añadir el miembro. Inténtalo de nuevo.',
        ),
      );
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      key: ValueKey(_revision),
      stream: _group,
      builder: (context, groupSnapshot) {
        if (groupSnapshot.hasError) return _LoadError(onRetry: _retry);
        if (!groupSnapshot.hasData) return const _Loading();
        final group = groupSnapshot.data!.data();
        if (group == null) {
          return _LoadError(onRetry: _retry);
        }
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _members,
          builder: (context, membersSnapshot) {
            if (membersSnapshot.hasError) return _LoadError(onRetry: _retry);
            if (!membersSnapshot.hasData) return const _Loading();
            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _membership,
              builder: (context, membershipSnapshot) {
                final isOwner = group['ownerDeviceId'] == widget.uid;
                if (membershipSnapshot.hasError && !isOwner) {
                  return _LoadError(onRetry: _retry);
                }
                if (!membershipSnapshot.hasData && !isOwner) {
                  return const _Loading();
                }
                final isMember =
                    membershipSnapshot.data?.docs.isNotEmpty == true;
                if (!isOwner && !isMember) {
                  return const Center(
                    child: Text('Ya no perteneces al grupo.'),
                  );
                }
                return _content(
                  group,
                  membersSnapshot.data!.docs,
                  isOwner: isOwner,
                  isMember: isMember,
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _content(
    Map<String, dynamic> group,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> members, {
    required bool isOwner,
    required bool isMember,
  }) {
    final allAdmins = group['allMembersAreAdmins'] == true;
    final canAdmin = isOwner || (allAdmins && isMember);
    final groupName = group['name'] as String? ?? 'Grupo';
    final sorted = [...members]
      ..sort(
        (a, b) => (a.data()['name'] as String? ?? '').toLowerCase().compareTo(
          (b.data()['name'] as String? ?? '').toLowerCase(),
        ),
      );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                groupName,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (canAdmin)
              IconButton(
                tooltip: 'Renombrar grupo',
                onPressed: _busy ? null : () => _rename(groupName),
                icon: const Icon(Icons.edit_outlined),
              ),
          ],
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Todos administradores'),
          value: allAdmins,
          secondary: _saving
              ? const _Pending()
              : const Icon(Icons.admin_panel_settings_outlined),
          onChanged: isOwner && !_busy ? _configure : null,
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'Miembros',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (canAdmin)
          Form(
            key: _formKey,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _name,
                    enabled: !_busy,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Nombre',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      final name = value?.trim() ?? '';
                      if (name.isEmpty) return 'Introduce un nombre';
                      if (name.length > 50) {
                        return 'El nombre no puede superar los 50 caracteres.';
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) {
                      if (canAdmin && !_busy) _addMember();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox.square(
                  dimension: 56,
                  child: IconButton(
                    tooltip: 'Añadir miembro',
                    onPressed: _busy ? null : _addMember,
                    icon: _adding
                        ? const _Pending()
                        : const Icon(Icons.person_add),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (sorted.isEmpty) const Text('No hay miembros.'),
        for (final member in sorted)
          ListTile(
            key: ValueKey(member.id),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_outline),
            title: Text(member.data()['name'] as String? ?? 'Miembro'),
          ),
      ],
    );
  }
}

class _RenameGroupDialog extends StatefulWidget {
  const _RenameGroupDialog({required this.initialName, required this.onSave});

  final String initialName;
  final Future<void> Function(String name) onSave;

  @override
  State<_RenameGroupDialog> createState() => _RenameGroupDialogState();
}

class _RenameGroupDialogState extends State<_RenameGroupDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving || _formKey.currentState?.validate() != true) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(_name.text.trim());
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is FirebaseException && error.code == 'permission-denied'
            ? 'No tienes permiso para renombrar el grupo.'
            : 'No se pudo guardar el nombre. Inténtalo de nuevo.';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      scrollable: true,
      title: const Text('Renombrar grupo'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _name,
              autofocus: true,
              enabled: !_saving,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: 'Nombre del grupo'),
              validator: (value) {
                final name = value?.trim() ?? '';
                if (name.isEmpty) return 'Introduce un nombre';
                if (name.length > 80) {
                  return 'El nombre no puede superar los 80 caracteres.';
                }
                return null;
              },
              onFieldSubmitted: (_) => _submit(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: SizedBox.square(
            dimension: 20,
            child: _saving
                ? const _Pending()
                : const Icon(Icons.check, size: 20),
          ),
          label: const Text('Guardar'),
        ),
      ],
    ),
  );
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('No se pudo cargar el grupo.'),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Reintentar'),
        ),
      ],
    ),
  );
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator());
}

class _Pending extends StatelessWidget {
  const _Pending();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 20,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
