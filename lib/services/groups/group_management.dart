import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:payb2/services/auth/identity_mutation_tracker.dart';
import 'package:payb2/services/network/connection_status.dart';

class GroupManagement {
  GroupManagement({FirebaseFunctions? functions})
    : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<void> renameGroup({required String groupId, required String nombre}) =>
      IdentityMutationTracker.shared.track(
        () => runBackendRequest(() {
          final firestore = FirebaseFirestore.instance;
          final group = firestore.collection('groups').doc(groupId);
          return firestore.runTransaction<void>((transaction) async {
            final snapshot = await transaction.get(group);
            if (!snapshot.exists) {
              throw FirebaseException(
                plugin: 'cloud_firestore',
                code: 'not-found',
                message: 'El grupo ya no existe.',
              );
            }
            transaction.update(group, {'name': nombre.trim()});
          });
        }),
      );

  Future<void> configureAdministration({
    required String groupId,
    required bool allMembersAreAdmins,
  }) => IdentityMutationTracker.shared.track(() async {
    await _functions
        .httpsCallable('configurarAdministracionGrupo')
        .callObserved<void>({
          'groupId': groupId,
          'allMembersAreAdmins': allMembersAreAdmins,
        });
  });

  Future<String> addMember({
    required String groupId,
    required String nombre,
    required String requestId,
  }) => IdentityMutationTracker.shared.track(() async {
    final result = await _functions
        .httpsCallable('agregarMiembroGrupo')
        .callObserved<Map<String, dynamic>>({
          'groupId': groupId,
          'nombre': nombre.trim(),
          'requestId': requestId,
        });
    return result.data['memberId'] as String;
  });
}
