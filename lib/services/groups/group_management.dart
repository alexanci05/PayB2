import 'package:cloud_functions/cloud_functions.dart';
import 'package:payb2/services/auth/identity_mutation_tracker.dart';
import 'package:payb2/services/network/connection_status.dart';

class GroupManagement {
  GroupManagement({FirebaseFunctions? functions})
    : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<void> renameGroup({required String groupId, required String nombre}) =>
      IdentityMutationTracker.shared.track(() async {
        await _functions.httpsCallable('renombrarGrupo').callObserved<void>({
          'groupId': groupId,
          'nombre': nombre.trim(),
        });
      });

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
