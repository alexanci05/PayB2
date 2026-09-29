import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:payb2/services/auth/identity_mutation_tracker.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AccountProvider { google, apple }

class AccountAuthFailure implements Exception {
  const AccountAuthFailure(this.message, {this.wasCanceled = false});

  final String message;
  final bool wasCanceled;

  @override
  String toString() => message;
}

class AccountAuthService {
  AccountAuthService({FirebaseAuth? auth, FirebaseFunctions? functions})
    : _auth = auth ?? FirebaseAuth.instance,
      _functions = functions ?? FirebaseFunctions.instance;

  static final AccountAuthService shared = AccountAuthService();
  static const _pendingMergeTicketKey = 'pendingAccountMergeTicket';

  final FirebaseAuth _auth;
  final FirebaseFunctions _functions;
  Future<void>? _googleInitialization;

  Future<User> signIn(AccountProvider provider) async {
    final sourceUser = _auth.currentUser;
    if (sourceUser == null) {
      throw const AccountAuthFailure(
        'No hay una sesión activa. Cierra y vuelve a abrir la aplicación.',
      );
    }
    if (!sourceUser.isAnonymous) {
      throw const AccountAuthFailure('Ya has iniciado sesión.');
    }

    try {
      return await IdentityMutationTracker.shared.runExclusively(() async {
        final credential = await _linkOrGetExistingCredential(
          sourceUser,
          provider,
        );
        if (credential == null) {
          return _auth.currentUser!;
        }

        final ticket = await _prepareMerge();
        final preferences = await SharedPreferences.getInstance();
        final ticketPersisted = await preferences.setString(
          _pendingMergeTicketKey,
          ticket,
        );
        if (!ticketPersisted) {
          await _cancelMerge(ticket);
          throw const AccountAuthFailure(
            'No se pudo guardar el inicio de sesión de forma segura.',
          );
        }
        try {
          await _activateMerge(ticket);
        } catch (_) {
          await _cancelMerge(ticket);
          await preferences.remove(_pendingMergeTicketKey);
          rethrow;
        }

        UserCredential targetSession;
        try {
          targetSession = await _auth.signInWithCredential(credential);
        } catch (_) {
          if (_auth.currentUser?.uid == sourceUser.uid) {
            await _cancelMerge(ticket);
            await preferences.remove(_pendingMergeTicketKey);
          }
          rethrow;
        }
        final targetUser = targetSession.user;
        if (targetUser == null || targetUser.isAnonymous) {
          throw const AccountAuthFailure(
            'No se pudo verificar la cuenta seleccionada.',
          );
        }

        await _completeMerge(ticket);
        await preferences.remove(_pendingMergeTicketKey);
        return targetUser;
      });
    } on GoogleSignInException catch (error) {
      throw _mapGoogleError(error);
    } on FirebaseFunctionsException catch (error) {
      throw _mapFunctionsError(error);
    } on FirebaseAuthException catch (error) {
      throw _mapFirebaseError(error);
    }
  }

  Future<void> resumePendingMerge() async {
    final preferences = await SharedPreferences.getInstance();
    final ticket = preferences.getString(_pendingMergeTicketKey);
    if (ticket == null) return;

    final user = _auth.currentUser;
    if (user == null) return;
    if (user.isAnonymous) {
      await _functions.httpsCallable('cancelarFusionCuenta').call<void>({
        'mergeTicket': ticket,
      });
    } else {
      await _completeMerge(ticket);
    }
    await preferences.remove(_pendingMergeTicketKey);
  }

  Future<AuthCredential?> _linkOrGetExistingCredential(
    User sourceUser,
    AccountProvider provider,
  ) async {
    try {
      final result = switch (provider) {
        AccountProvider.google => await sourceUser.linkWithCredential(
          await _googleCredential(),
        ),
        AccountProvider.apple => await sourceUser.linkWithProvider(
          _appleProvider(),
        ),
      };
      if (result.user == null) {
        throw const AccountAuthFailure(
          'No se pudo completar el inicio de sesión.',
        );
      }
      return null;
    } on FirebaseAuthException catch (error) {
      if (error.code != 'credential-already-in-use') {
        rethrow;
      }
      final credential = error.credential;
      if (credential == null) {
        throw const AccountAuthFailure(
          'No se pudo recuperar la cuenta existente. Inténtalo de nuevo.',
        );
      }
      return credential;
    }
  }

  Future<String> _prepareMerge() async {
    final result = await _functions
        .httpsCallable('prepararFusionCuenta')
        .call<Map<String, dynamic>>();
    final ticket = result.data['mergeTicket'];
    if (ticket is! String || ticket.isEmpty) {
      throw const AccountAuthFailure(
        'El servidor no pudo preparar el inicio de sesión.',
      );
    }
    return ticket;
  }

  Future<void> _completeMerge(String ticket) async {
    await _functions.httpsCallable('fusionarCuentaAnonima').call<void>({
      'mergeTicket': ticket,
    });
  }

  Future<void> _activateMerge(String ticket) async {
    await _functions.httpsCallable('bloquearFusionCuenta').call<void>({
      'mergeTicket': ticket,
    });
  }

  Future<void> _cancelMerge(String ticket) async {
    await _functions.httpsCallable('cancelarFusionCuenta').call<void>({
      'mergeTicket': ticket,
    });
  }

  Future<AuthCredential> _googleCredential() async {
    _googleInitialization ??= GoogleSignIn.instance.initialize();
    await _googleInitialization;
    await GoogleSignIn.instance.signOut();

    final googleUser = await GoogleSignIn.instance.authenticate();
    final idToken = googleUser.authentication.idToken;
    if (idToken == null) {
      throw const AccountAuthFailure(
        'Google no devolvió una credencial válida. Revisa la configuración de acceso.',
      );
    }
    return GoogleAuthProvider.credential(idToken: idToken);
  }

  AppleAuthProvider _appleProvider() {
    return AppleAuthProvider()
      ..addScope('email')
      ..addScope('name');
  }

  AccountAuthFailure _mapGoogleError(GoogleSignInException error) {
    if (error.code == GoogleSignInExceptionCode.canceled) {
      return const AccountAuthFailure('', wasCanceled: true);
    }
    if (error.code == GoogleSignInExceptionCode.clientConfigurationError ||
        error.code == GoogleSignInExceptionCode.providerConfigurationError) {
      return const AccountAuthFailure(
        'El acceso con Google todavía no está configurado correctamente.',
      );
    }
    return const AccountAuthFailure(
      'No se pudo acceder con Google. Inténtalo de nuevo.',
    );
  }

  AccountAuthFailure _mapFirebaseError(FirebaseAuthException error) {
    if (error.code == 'web-context-cancelled' || error.code == 'canceled') {
      return const AccountAuthFailure('', wasCanceled: true);
    }
    return switch (error.code) {
      'network-request-failed' => const AccountAuthFailure(
        'No hay conexión. Comprueba la red e inténtalo de nuevo.',
      ),
      'operation-not-allowed' => const AccountAuthFailure(
        'Este método de acceso no está habilitado en Firebase.',
      ),
      'account-exists-with-different-credential' => const AccountAuthFailure(
        'Esta cuenta utiliza otro proveedor de inicio de sesión.',
      ),
      _ => const AccountAuthFailure(
        'No se pudo iniciar sesión. Comprueba la cuenta e inténtalo de nuevo.',
      ),
    };
  }

  AccountAuthFailure _mapFunctionsError(FirebaseFunctionsException error) {
    return switch (error.code) {
      'unauthenticated' => const AccountAuthFailure(
        'La sesión ha caducado. Cierra y vuelve a abrir la aplicación.',
      ),
      'failed-precondition' => const AccountAuthFailure(
        'No se pudieron combinar los datos de las dos sesiones.',
      ),
      'unavailable' => const AccountAuthFailure(
        'El servidor no está disponible. Inténtalo de nuevo.',
      ),
      _ => const AccountAuthFailure(
        'No se pudieron conservar tus datos al iniciar sesión. Inténtalo de nuevo.',
      ),
    };
  }
}
