# Auditoría actual de PayB2

Actualizado el 22 de septiembre de 2026.

Este documento contiene solo problemas presentes en el código actual. Los errores ya corregidos se han eliminado del historial.

## Prioridad alta

### 1. La identidad anónima no se recupera tras reinstalar o cambiar de dispositivo

**Dónde:** `lib/main.dart:18`, `lib/main.dart:39-45`, `lib/screens/grupo_detalles/grupo_detalle_screen.dart:60-151` y `firestore.rules:66-70`.

`reclamadoPor` queda unido al UID anónimo del dispositivo. Al borrar los datos, reinstalar o usar otro teléfono, Firebase crea otro UID. El usuario puede volver a unirse si conserva el código, pero su identidad sigue ocupada por el UID antiguo. Si era propietario, también pierde esos permisos.

**Solución lógica:** definir una identidad recuperable, mediante una cuenta enlazada o una transferencia controlada y verificable. El UID temporal del dispositivo no debe ser la única llave permanente.

## Prioridad media

### 2. Cartera, saldos y recordatorios recorren jerarquías completas en serie

**Dónde:** `lib/screens/home/main_screen.dart:212-311`, `lib/screens/grupo_detalles/grupo_detalle_screen.dart:462-480` y `functions/index.js:324-423`.

Para encontrar deudas se leen grupos, miembros, todos los gastos y después divisiones gasto por gasto. El recordatorio repite ese árbol para cada usuario. El coste crece con todos los datos históricos, no solo con las deudas pendientes.

**Solución lógica:** consultar deudas pendientes por deudor y estado desde una estructura indexable. No exige una migración inmediata en esta fase, pero conviene no construir flujos nuevos sobre recorridos completos.

### 3. Falta completar la configuración de notificaciones de iOS

**Dónde:** `ios/Runner/Info.plist:49-53`, `android/app/src/main/AndroidManifest.xml:30-32` y `lib/app.dart:30-49`.

iOS declara el modo de notificaciones remotas, pero el proyecto no contiene entitlements con la capacidad Push Notifications. Android ya crea y utiliza un único canal estable para mensajes en primer plano y segundo plano.

**Solución lógica:** completar la capacidad push de iOS y verificar APNs en un dispositivo real durante la fase de publicación.

### 4. Los reintentos de recordatorios repiten también los envíos correctos

**Dónde:** `functions/index.js:310-318` y `functions/index.js:397-432`.

Si un envío falla, la Function termina con error y el reintento recorre el lote completo. Quienes ya recibieron el aviso pueden recibirlo otra vez. Esto respeta la decisión de priorizar que no falten recordatorios, pero no distingue qué destinatario falló.

**Solución lógica:** conservar los reintentos, pero identificar cada recordatorio por usuario y periodo para omitir los envíos ya registrados como correctos.

## Prioridad baja o trabajo posterior

### 5. Los permisos de notificaciones se solicitan sin contexto

**Dónde:** `lib/main.dart:13-27` y `lib/main.dart:51-83`.

La aplicación ya arranca aunque falle la inicialización de notificaciones, pero sigue solicitando sus permisos nada más abrirse por primera vez, antes de explicar para qué se utilizarán.

**Solución lógica:** solicitar los permisos después de una acción donde el usuario entienda que recibirá recordatorios, sin volver a convertir las notificaciones en requisito de arranque.

### 6. Dependencias pendientes

`flutter pub outdated` muestra varias versiones principales posteriores. `npm audit --omit=dev` informa de dos vulnerabilidades moderadas transitivas relacionadas con `uuid` y `gaxios`.

**Decisión recomendada:** no hacer una actualización masiva mientras se corrigen los contratos anteriores. Actualizar por bloques y ejecutar las pruebas tras cada bloque.

### 7. Configuración de publicación y plataformas fuera del alcance actual

Android e iOS conservan identificadores `com.example.payb2`, Android usa firma de desarrollo y Firebase no está configurado para web o escritorio. Son tareas necesarias antes de publicar o ampliar plataformas, pero no bloquean el trabajo funcional móvil actual.

Al desplegar las reglas nuevas, una versión anterior de la app que escriba gastos o reclame identidades directamente recibirá `PERMISSION_DENIED`. No hay usuarios publicados hoy, pero antes de distribuir clientes habrá que coordinar la actualización de la app y las reglas o aceptar expresamente que las versiones antiguas dejen de funcionar.

## Ambigüedad funcional pendiente

La pestaña `Saldos` suma la deuda bruta de cada miembro frente a todos los acreedores (`grupo_detalle_screen.dart:603-610`). No compensa deudas opuestas. Antes de cambiarla hay que decidir si representa deuda bruta o saldo neto; ambos modelos son válidos, pero el nombre debe dejarlo claro. En ambos casos, el cálculo debe usar `cantidadCentimos` como fuente única.

## Huecos de prueba relevantes

- Comprobar solicitudes inválidas y creación atómica de gastos y programaciones desde la Callable, incluyendo el límite de 50 miembros.
- Probar dos clientes simultáneos para pagos, reaperturas y refresco de vistas.

## Verificación de esta revisión

- `flutter analyze`: sin diagnósticos.
- `flutter test`: 13 pruebas superadas.
- Tests unitarios de Functions con Node 22: 13 pruebas superadas.
- Tests de los ocho handlers de Functions con Firestore emulado: 30 pruebas superadas; FCM está simulado.
- Reglas de Firestore en emulador: 13 pruebas superadas.
- Las pruebas de integración invocan los ocho handlers con Node 22 y Firestore emulado.
- `npm audit --omit=dev`: 2 vulnerabilidades moderadas transitivas.

Las pruebas actuales confirman el reparto básico, la reclamación única de identidad, la creación atómica e idempotente de gastos y grupos, los permisos de pago y la ejecución local de los handlers. No cubren todavía FCM/APNs reales, los disparos programados en Firebase ni todos los escenarios de concurrencia descritos arriba.
