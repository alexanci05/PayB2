# Auditoría actual de PayB2

Actualizado el 22 de septiembre de 2026.

Este documento contiene solo problemas presentes en el código actual. Los errores ya corregidos se han eliminado del historial.

## Problemas críticos

### 1. Un usuario puede apropiarse de varias identidades del mismo grupo

**Dónde:** `firestore.rules:62-70` y `lib/screens/grupo_detalles/grupo_detalle_screen.dart:60-151`.

La interfaz deja de preguntar cuando encuentra una identidad reclamada por el UID, pero las reglas solo comprueban que la identidad concreta elegida esté libre. Un cliente directo puede repetir la escritura sobre todas las identidades que sigan a `null`.

**Consecuencia:** una persona puede convertirse a efectos de autorización en varios deudores o acreedores y confirmar pagos ajenos. La transacción impide que dos usuarios reclamen a la vez la misma identidad, pero no que un UID reclame identidades distintas.

**Solución lógica:** convertir la reclamación en una operación de servidor y mantener una relación única y atómica `grupo + UID -> memberId`. Se debe verificar tanto que la identidad esté libre como que el UID no tenga otra.

## Prioridad alta

### 2. Un doble toque puede duplicar gastos, recurrencias y grupos

**Dónde:** `lib/screens/crear_gasto/crear_gasto.dart`, `functions/index.js` (`crearGasto`) y `lib/screens/crear_grupo/crear_grupo_screen.dart`.

Los botones continúan activos mientras la operación está en curso. Cada envío crea referencias nuevas, por lo que dos pulsaciones rápidas producen dos operaciones válidas. En un gasto periódico quedan dos series generando deudas futuras.

**Solución lógica:** representar el estado de envío, aceptar una sola acción hasta recibir respuesta y usar una clave idempotente estable en servidor. Desactivar el botón evita el doble toque normal; la idempotencia cubre también reintentos de red.

### 3. Las recurrencias de fin de mes pierden su día original

**Dónde:** `functions/lib/scheduled-occurrences.js:60-77`, `functions/lib/scheduled-occurrences.js:97-124`, `functions/index.js:260-305` y `lib/domain/expense_split.dart:70-118`.

Cada fecha se calcula desde la anterior ya ajustada. Una serie mensual del 31 de enero pasa al 28 de febrero y continúa el 28 de marzo. Una serie anual del 29 de febrero queda fijada al 28 incluso cuando vuelve a existir un año bisiesto.

**Solución lógica:** guardar el día de anclaje original. Cada nueva ocurrencia debe calcularse para su periodo objetivo usando ese anclaje; solo se recorta cuando ese mes concreto no contiene el día original.

### 4. La identidad anónima no se recupera tras reinstalar o cambiar de dispositivo

**Dónde:** `lib/main.dart:18`, `lib/main.dart:39-45`, `lib/screens/grupo_detalles/grupo_detalle_screen.dart:60-151` y `firestore.rules:66-70`.

`reclamadoPor` queda unido al UID anónimo del dispositivo. Al borrar los datos, reinstalar o usar otro teléfono, Firebase crea otro UID. El usuario puede volver a unirse si conserva el código, pero su identidad sigue ocupada por el UID antiguo. Si era propietario, también pierde esos permisos.

**Solución lógica:** definir una identidad recuperable, mediante una cuenta enlazada o una transferencia controlada y verificable. El UID temporal del dispositivo no debe ser la única llave permanente.

### 5. Los permisos del propietario permiten romper la identidad del grupo

**Dónde:** `firestore.rules:57-70` y `functions/index.js:42-69`.

El propietario puede modificar cualquier campo de `groups`, incluidos `groupCode` y `ownerDeviceId`, y cualquier campo de un miembro, incluido `reclamadoPor`. La reserva en `groupCodes` no cambia si se altera el código directamente y el propietario puede reasignar identidades reclamadas.

**Solución lógica:** permitir solo campos con un flujo definido. Cambiar código, propietario o identidad requiere una operación específica y atómica; mientras no exista, esas actualizaciones deben estar cerradas.

### 6. Los borrados directos pueden dejar datos huérfanos

**Dónde:** `firestore.rules` (borrados de grupos y gastos) y `lib/screens/grupo_detalles/grupo_detalle_screen.dart:939-976`.

Firestore no elimina subcolecciones al borrar el padre. La interfaz borra las divisiones junto con el gasto, pero las reglas permiten borrar directamente solo el gasto o el grupo. Pueden quedar divisiones, miembros, programaciones, pertenencias y reservas de código sin padre. Una división individual ya no puede borrarse mientras permanezca su gasto.

**Solución lógica:** centralizar los borrados compuestos en servidor y eliminar todos los documentos relacionados. Si se conserva historial, usar cancelación lógica y excluir esos documentos de las consultas.

## Prioridad media

### 7. Una recurrencia atrasada solo recupera una ocurrencia al día

**Dónde:** `functions/index.js:203-233` y `functions/index.js:244-306`.

El planificador obtiene la programación vencida una vez, crea una ocurrencia y avanza un intervalo. Aunque la nueva fecha siga vencida, no vuelve a procesarla hasta el día siguiente. Una serie semanal atrasada cuatro semanas tarda cuatro días en ponerse al día.

**Solución lógica:** decidir una política explícita. Si deben conservarse todos los vencimientos, generar los atrasados hasta el presente con un límite seguro y continuación controlada. Si no, saltar expresamente a la primera fecha futura.

### 8. Saldos y estadísticas no reaccionan a cambios de otros dispositivos

**Dónde:** `lib/screens/grupo_detalles/grupo_detalle_screen.dart:452-480`, `lib/screens/grupo_detalles/grupo_detalle_screen.dart:578-766` y `lib/screens/grupo_detalles/grupo_detalle_screen.dart:780-808`.

Estas vistas usan un `Future` cargado una vez. Se actualizan tras determinadas acciones locales, pero no cuando otro miembro crea, paga, reabre o elimina datos mientras la pantalla sigue abierta.

**Solución lógica:** observar una fuente que cambie con escrituras remotas o invalidar las vistas derivadas al cambiar gastos y divisiones.

### 9. Cartera, saldos y recordatorios recorren jerarquías completas en serie

**Dónde:** `lib/screens/home/main_screen.dart:212-311`, `lib/screens/grupo_detalles/grupo_detalle_screen.dart:462-480` y `functions/index.js:324-423`.

Para encontrar deudas se leen grupos, miembros, todos los gastos y después divisiones gasto por gasto. El recordatorio repite ese árbol para cada usuario. El coste crece con todos los datos históricos, no solo con las deudas pendientes.

**Solución lógica:** consultar deudas pendientes por deudor y estado desde una estructura indexable. No exige una migración inmediata en esta fase, pero conviene no construir flujos nuevos sobre recorridos completos.

### 10. Los dos trabajos diarios compiten a la misma hora

**Dónde:** `functions/index.js:185-193` y `functions/index.js:310-318`.

La generación de recurrencias y el recordatorio están programados para las 15:00. No hay orden garantizado: el recordatorio puede terminar antes de crear la deuda periódica del día y avisarla un día tarde.

**Solución lógica:** generar primero las recurrencias y programar después los recordatorios con margen, o encadenar ambos pasos bajo una coordinación común.

### 11. La lista de pagos atribuye al deudor cobros registrados por el acreedor

**Dónde:** `lib/screens/grupo_detalles/grupo_detalle_screen.dart:592-597` y `lib/screens/grupo_detalles/grupo_detalle_screen.dart:630-649`.

`Pagos que te han marcado` incluye todas las divisiones pagadas a favor del usuario, sin comprobar `pagoRegistradoPor`. Si el acreedor registró el cobro de alguien sin app, la interfaz afirma igualmente que esa persona indicó que pagó.

**Solución lógica:** distinguir quién cerró la deuda. La revisión y reapertura por pago declarado debe mostrarse para confirmaciones del deudor; un cobro registrado por el acreedor necesita otro texto o no debe entrar en esa lista.

### 12. La configuración de notificaciones no es coherente

**Dónde:** `ios/Runner/Info.plist:49-53`, `android/app/src/main/AndroidManifest.xml:30-32` y `lib/app.dart:30-49`.

iOS declara el modo de notificaciones remotas, pero el proyecto no contiene entitlements con la capacidad Push Notifications. En Android, el manifiesto indica `default_channel`, mientras las notificaciones en primer plano usan `canal_notificaciones`, y no se crea un canal común explícitamente.

**Solución lógica:** completar la capacidad push de iOS y verificar APNs en un dispositivo real. En Android se debe crear un único canal estable y usar su ID en el manifiesto y en las notificaciones locales.

### 13. Los reintentos de recordatorios repiten también los envíos correctos

**Dónde:** `functions/index.js:310-318` y `functions/index.js:397-432`.

Si un envío falla, la Function termina con error y el reintento recorre el lote completo. Quienes ya recibieron el aviso pueden recibirlo otra vez. Esto respeta la decisión de priorizar que no falten recordatorios, pero no distingue qué destinatario falló.

**Solución lógica:** conservar los reintentos, pero identificar cada recordatorio por usuario y periodo para omitir los envíos ya registrados como correctos.

## Prioridad baja o trabajo posterior

### 14. Algunas cargas pueden quedarse sin recuperación visible

**Dónde:** `lib/screens/home/main_screen.dart:105-120` y `lib/screens/crear_gasto/crear_gasto.dart:52-70`.

Si falla `loadGroups`, `deviceId` no se asigna y la pantalla mantiene el indicador de carga. Si falla la carga de miembros al crear un gasto, el formulario queda vacío sin explicar el error ni ofrecer reintento.

**Solución lógica:** representar explícitamente `cargando`, `error` y `contenido`, con una acción de reintento.

### 15. El arranque depende de permisos y servicios no esenciales

**Dónde:** `lib/main.dart:13-27` y `lib/main.dart:51-83`.

Antes de mostrar la interfaz se esperan Firebase, el login, la inicialización de notificaciones y sus permisos. Un fallo de notificaciones puede impedir abrir funciones que no las necesitan y los permisos se solicitan sin contexto nada más iniciar.

**Solución lógica:** bloquear el arranque solo por los servicios imprescindibles. Las notificaciones deben inicializarse con manejo de error y solicitarse cuando el usuario entienda su utilidad.

### 16. Dependencias pendientes

`flutter pub outdated` muestra varias versiones principales posteriores. `npm audit --omit=dev` informa de dos vulnerabilidades moderadas transitivas relacionadas con `uuid` y `gaxios`.

**Decisión recomendada:** no hacer una actualización masiva mientras se corrigen los contratos anteriores. Actualizar por bloques y ejecutar las pruebas tras cada bloque.

### 17. Configuración de publicación y plataformas fuera del alcance actual

Android e iOS conservan identificadores `com.example.payb2`, Android usa firma de desarrollo y Firebase no está configurado para web o escritorio. Son tareas necesarias antes de publicar o ampliar plataformas, pero no bloquean el trabajo funcional móvil actual.

## Ambigüedad funcional pendiente

La pestaña `Saldos` suma la deuda bruta de cada miembro frente a todos los acreedores (`grupo_detalle_screen.dart:603-610`). No compensa deudas opuestas. Antes de cambiarla hay que decidir si representa deuda bruta o saldo neto; ambos modelos son válidos, pero el nombre debe dejarlo claro. En ambos casos, el cálculo debe usar `cantidadCentimos` como fuente única.

## Huecos de prueba relevantes

- Rechazar con reglas una segunda identidad para el mismo UID.
- Comprobar solicitudes inválidas y creación atómica de gastos y programaciones desde la Callable, incluyendo el límite de 50 miembros.
- Probar una serie completa: 31 de enero, febrero y 31 de marzo; también el 29 de febrero al siguiente año bisiesto.
- Probar doble envío e idempotencia en gasto, recurrencia y grupo.
- Probar varias ocurrencias vencidas y la política elegida para recuperarlas.
- Probar dos clientes simultáneos para pagos, reaperturas y refresco de vistas.

## Verificación de esta revisión

- `flutter analyze`: sin diagnósticos.
- `flutter test`: 8 pruebas superadas.
- Tests unitarios de Functions con Node 22: 9 pruebas superadas.
- Tests de los seis handlers de Functions con Firestore emulado: 10 pruebas superadas; FCM está simulado.
- Reglas de Firestore en emulador: 7 pruebas superadas.
- El emulador de Functions carga los cinco exports con Node 22.
- `npm audit --omit=dev`: 2 vulnerabilidades moderadas transitivas.

Las pruebas actuales confirman el reparto básico, la creación atómica del gasto, los permisos de pago y la ejecución local de los handlers. No cubren todavía FCM/APNs reales, los disparos programados en Firebase ni la concurrencia descrita arriba.
