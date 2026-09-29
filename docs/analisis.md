# Auditoría actual de PayB2

Actualizado el 29 de septiembre de 2026.

Este documento contiene solo problemas presentes en el código actual. Los errores ya corregidos se han eliminado del historial.

## Prioridad alta

### 1. Falta habilitar y configurar los proveedores de acceso externos

**Dónde:** Firebase Authentication, `android/app/google-services.json`, configuración nativa de iOS y `lib/services/auth/account_auth_service.dart`.

La aplicación ya ofrece un único inicio de sesión con Google o Apple. Si el proveedor es nuevo, se vincula directamente y conserva el UID. Si la cuenta ya existía, el servidor bloquea temporalmente las escrituras del UID anónimo, emite un ticket de un solo uso y fusiona automáticamente grupos, propiedades, identidades y autorías al iniciar la cuenta destino. El proceso se reanuda al arrancar si la aplicación se cerró a mitad. Sin embargo, el archivo de Android todavía no contiene clientes OAuth e iOS no tiene configurados los datos de Google. Los proveedores tampoco se pueden verificar localmente sin habilitarlos en Firebase Authentication y completar sus credenciales externas.

**Solución lógica:** habilitar Google y Apple en Firebase Authentication, registrar SHA-1/SHA-256 para Android, regenerar `google-services.json`, incorporar la configuración de Google para iOS y completar las credenciales de Sign in with Apple. Después debe probarse el inicio de sesión y la fusión en dispositivos reales.

## Prioridad media

### 2. Falta completar la configuración de notificaciones de iOS

**Dónde:** `ios/Runner/Info.plist:49-53`, `android/app/src/main/AndroidManifest.xml:30-32` y `lib/services/notifications/notification_service.dart`.

iOS declara el modo de notificaciones remotas y ya tiene un archivo de entitlements para Sign in with Apple, pero ese archivo todavía no incluye la capacidad Push Notifications. Android ya crea y utiliza un único canal estable para mensajes en primer plano y segundo plano.

**Solución lógica:** completar la capacidad push de iOS y verificar APNs en un dispositivo real durante la fase de publicación.

### 3. Una cuenta solo conserva el token de notificaciones de un dispositivo

**Dónde:** `lib/controladores/registrar_usuario.dart` y los envíos de `functions/index.js`.

Cada registro de `usuarios/{uid}` contiene un único `fcmToken`. Si la misma cuenta inicia sesión en dos dispositivos, el último token guardado sustituye al anterior y solo ese dispositivo recibe los avisos. El interruptor de Ajustes ya elimina únicamente el token del dispositivo actual cuando coincide, pero el modelo del servidor todavía no admite varios tokens simultáneos.

**Solución lógica:** almacenar los tokens por dispositivo dentro de cada cuenta, enviar a todos los tokens activos y eliminar solo los que FCM marque como inválidos o el usuario desactive localmente.

## Prioridad baja o trabajo posterior

### 4. Dependencias pendientes

`flutter pub outdated` muestra varias versiones principales posteriores. `npm audit --omit=dev` informa de dos vulnerabilidades moderadas en `uuid` y `gaxios`, arrastradas por `@google-cloud/storage` desde la versión actual de `firebase-admin`. PayB2 no utiliza Firebase Storage y `npm audit fix --omit=dev` no ofrece una actualización compatible.

**Decisión recomendada:** no forzar un `override` transitorio ni hacer una actualización masiva. Revisar el aviso cuando `firebase-admin` actualice esa rama y actualizar Flutter por bloques con pruebas entre cada uno.

### 5. Configuración de publicación y plataformas fuera del alcance actual

Android e iOS conservan identificadores `com.example.payb2`, Android usa firma de desarrollo y Firebase no está configurado para web o escritorio. Son tareas necesarias antes de publicar o ampliar plataformas, pero no bloquean el trabajo funcional móvil actual.

Al desplegar las reglas nuevas, una versión anterior de la app que escriba gastos o reclame identidades directamente recibirá `PERMISSION_DENIED`. No hay usuarios publicados hoy, pero antes de distribuir clientes habrá que coordinar la actualización de la app y las reglas o aceptar expresamente que las versiones antiguas dejen de funcionar.

## Ambigüedad funcional pendiente

La pestaña `Saldos` suma la deuda bruta de cada miembro frente a todos los acreedores (`grupo_detalle_screen.dart:603-610`). No compensa deudas opuestas. Antes de cambiarla hay que decidir si representa deuda bruta o saldo neto; ambos modelos son válidos, pero el nombre debe dejarlo claro. En ambos casos, el cálculo debe usar `cantidadCentimos` como fuente única.

## Huecos de prueba relevantes

- Probar dos clientes simultáneos para pagos, reaperturas y refresco de vistas.

## Verificación de esta revisión

- `flutter analyze`: sin diagnósticos.
- `flutter test`: 15 pruebas superadas.
- `flutter build apk --debug`: compilación Android completada.
- Tests unitarios de Functions con Node 22: 13 pruebas superadas.
- Tests de Functions con Firestore emulado: 38 pruebas superadas, incluidas las validaciones de límites sin escrituras parciales, la unión de grupos, el ciclo del ticket, la conservación de identidades y el bloqueo de escrituras funcionales o programadas durante la migración; FCM está simulado.
- Reglas de Firestore en emulador: 15 pruebas superadas, incluidos el bloqueo de escrituras durante una fusión y el acceso controlado a consultas globales de divisiones.
- Las pruebas de integración invocan los handlers funcionales y ejercitan el protocolo de migración usado por `fusionarCuentaAnonima`, con Node 22 y Firestore emulado.
- `npm audit --omit=dev`: 2 vulnerabilidades moderadas transitivas.

Las pruebas actuales confirman el reparto básico, la reclamación única de identidad, la creación atómica e idempotente de gastos y grupos, los permisos de pago, las consultas indexadas de deuda y la ejecución local de los handlers. No cubren todavía FCM/APNs reales, los disparos programados en Firebase ni todos los escenarios de concurrencia descritos arriba.
