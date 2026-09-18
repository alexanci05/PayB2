# Estado del analisis de PayB2

Actualizado el 18 de septiembre de 2026.

Este documento mantiene los problemas de la revision inicial, pero refleja su estado actual. Los titulos tachados estan solucionados. Los puntos sin tachar siguen pendientes o necesitan validacion adicional.

La prioridad actual es consolidar una aplicacion movil útil, fiable y presentable como proyecto solido. La publicacion, la firma definitiva y las optimizaciones para una escala todavia desconocida se abordaran en el futuro.

## Problemas criticos

No quedan problemas criticos conocidos.

### ~~1. Los gastos periodicos reutilizaban deudas antiguas~~

**Resuelto.** Las recurrencias parten de una programacion inmutable y crean ocurrencias y divisiones independientes con identificadores deterministas. Un reintento no duplica el periodo.

### ~~2. Los gastos futuros podian no generar deudas~~

**Resuelto.** Los gastos futuros, sean puntuales o periodicos, se guardan en `gastosProgramados`. La Function crea sus divisiones correctamente cuando llega `proximaFecha`.

### ~~3. Cartera podia pagar varias divisiones y borrar el importe~~

**Resuelto.** Cada accion conserva el identificador exacto de la division. Pagar solo cambia su estado y mantiene el importe historico.

### ~~4. El reparto podia producir importes incorrectos~~

**Resuelto.** El reparto trabaja con centimos enteros, distribuye el residuo de forma determinista y rechaza importes que no permiten asignar al menos un centimo por persona.

## Problemas de prioridad alta

No quedan problemas de prioridad alta conocidos.

### ~~5. Un usuario podia registrar como pagador a otra persona~~

**Resuelto.** Quien crea el gasto queda como pagador mediante su identidad reclamada. Esta relacion se valida tambien en las reglas.

### ~~6. Se podia crear un grupo sin miembros~~

**Resuelto.** Cliente y Callable exigen al menos un miembro y rechazan nombres vacios o duplicados.

### ~~7. La creacion de grupos y gastos no era atomica~~

**Resuelto.** Los documentos relacionados se escriben mediante transacciones o batches atomicos.

### ~~8. Las reglas de Firestore no estaban versionadas~~

**Resuelto.** `firestore.rules` forma parte del repositorio y `firebase.json` apunta a ese archivo.

### ~~9. Cualquier miembro podia intentar borrar cualquier gasto~~

**Resuelto.** La interfaz limita la accion al propietario del grupo o creador del gasto, pide confirmacion y las reglas aplican la misma autorizacion.

### ~~10. El token FCM no se renovaba~~

**Resuelto.** El token se registra en cada arranque autenticado y se actualiza mediante `onTokenRefresh` sin bloquear el inicio de la aplicacion.

### ~~11. Las notificaciones en primer plano no funcionaban en iOS~~

**Resuelto en codigo.** El listener acepta notificaciones de ambas plataformas y configura `DarwinNotificationDetails`. Queda incluida en la validacion pendiente con dispositivo real.

### ~~12. Functions acumulaba vulnerabilidades criticas y altas~~

**Resuelto el riesgo grave.** Firebase Admin y Firebase Functions se actualizaron. El audit paso de 21 vulnerabilidades a 2 moderadas transitivas, recogidas como pendiente de prioridad media.

### ~~13. Dos usuarios podian reclamar simultaneamente la misma identidad~~

**Resuelto.** La reclamacion usa una transaccion que vuelve a comprobar `reclamadoPor` antes de escribir.

## Problemas de prioridad media

### Validacion real de notificaciones pendiente

La seleccion del destinatario y los reintentos estan probados como logica, pero falta verificar en dispositivos reales Android e iOS el ciclo completo FCM/APNs: renovacion del token, recepcion en primer plano y segundo plano, pago, reapertura y tokens invalidos.

### 19. Las Functions realizan demasiadas lecturas en serie

Los recordatorios siguen recorriendo usuarios, grupos, gastos y divisiones mediante consultas anidadas. Es correcto para la escala actual de desarrollo, pero aumentara el coste y el tiempo de ejecucion si crece el numero de datos.

**Decision actual:** posponer una coleccion derivada o indices de deudas pendientes hasta conocer la escala real del proyecto.

### 29. Dependencias Flutter pendientes de actualizaciones mayores

El proyecto conserva varias versiones anteriores a las ultimas disponibles. No existe ahora un fallo funcional asociado que justifique una migracion masiva.

**Decision actual:** actualizar por bloques cuando exista una mejora concreta y ejecutar las pruebas despues de cada bloque.

### Dependencias transitivas con dos avisos moderados

`npm audit --omit=dev` mantiene dos avisos moderados procedentes de `firebase-admin`, `@google-cloud/storage`, `gaxios` y `uuid`. `npm audit fix --dry-run` no encuentra una actualizacion compatible adicional. No se aplicara un override inseguro.

### Compilacion y pruebas iOS pendientes

CocoaPods resuelve correctamente, pero este equipo no tiene instalada la plataforma iOS 26.2 para el simulador. Falta compilar y probar la aplicacion cuando esa plataforma este disponible.

### ~~14. Saldos, Estadisticas y Cartera mostraban datos antiguos~~

**Resuelto.** Las vistas derivadas se invalidan tras crear, borrar, pagar o reabrir una deuda, y Cartera se reconstruye al seleccionarla.

### ~~15. Habia `setState` despues de operaciones asincronas sin comprobar `mounted`~~

**Resuelto en los flujos detectados.** Las operaciones modificadas comprueban `mounted` antes de actualizar la interfaz.

### ~~16. Las recurrencias calculaban mal los finales de mes~~

**Resuelto.** Las frecuencias mensuales, trimestrales y anuales usan el ultimo dia valido del mes de destino.

### ~~17. Un token invalido podia detener todos los recordatorios~~

**Resuelto.** Los tokens invalidos se eliminan y el procesamiento continua con el resto de usuarios.

### ~~18. Las Functions ocultaban errores y no reintentaban~~

**Resuelto.** La recurrencia es idempotente y tiene tres reintentos. Los recordatorios tienen dos reintentos para limitar duplicados. Los cambios de estado de las deudas tambien habilitan reintentos.

### ~~20. El codigo de grupo y el bloqueo se protegian solo en cliente~~

**Resuelto.** Crear y unirse a grupos pasa por Callables. Los codigos se generan criptograficamente y el limite de intentos se persiste en servidor.

### ~~21. El token FCM completo aparecia en los logs~~

**Resuelto.** Los logs usan identificadores internos y no imprimen el token.

### ~~22. Un error al cargar el detalle dejaba un spinner permanente~~

**Resuelto.** El `FutureBuilder` muestra un estado de error explicito.

### ~~25. El SDK declarado no reproducia el lockfile~~

**Resuelto.** `pubspec.yaml` declara Dart 3.8 y Flutter 3.27.4 como minimos coherentes con el lockfile actual.

### ~~26. El minimo de iOS diferia entre CocoaPods y Xcode~~

**Resuelto.** Ambos usan iOS 13.

## Problemas de prioridad baja o pospuestos

### ~~Pruebas basicas de permisos de Firestore pendientes~~

**Resuelto.** `npm run test:rules` levanta un proyecto de emulador aislado y ejecuta cinco comprobaciones sencillas: lectura del grupo, pago por el deudor, cobro por el acreedor, rechazo de un tercero y reapertura por el acreedor.

### 23. Firebase no esta configurado para web y escritorio

Las carpetas de plataforma existen, pero Firebase solo esta configurado para Android e iOS.

**Decision actual:** mantener esas plataformas fuera del alcance hasta decidir si PayB2 dejara de ser exclusivamente movil.

### 24. Identificadores y firma de desarrollo

Android e iOS conservan identificadores de ejemplo y Android usa firma de desarrollo.

**Decision actual:** resolverlo en la fase de publicacion, no durante la consolidacion funcional.

### ~~27. El unico test automatico era el contador roto de Flutter~~

**Resuelto.** El test de plantilla fue sustituido. Actualmente pasan 8 pruebas Flutter, 9 pruebas de Functions y 5 pruebas de reglas sobre los permisos esenciales.

### ~~28. La compilacion Android estaba bloqueada por cuarentena~~

**Resuelto.** Se retiro la marca local de cuarentena de `android/gradlew` y el APK debug se genera correctamente.

### ~~30. El README tenia bloques Markdown incompletos~~

**Resuelto.** Los bloques de comandos y el paso de configuracion Firebase estan corregidos.

### ~~31. El runtime y el lock de Functions estaban desalineados~~

**Resuelto.** Functions declara Node 20, existe `.nvmrc`, el lockfile fue regenerado y las pruebas se ejecutaron con Node 20.

### ~~32. Habia archivos, dependencias y codigo duplicado sin uso~~

**Resuelto.** Se eliminaron la instancia duplicada de notificaciones, el tema vacio, `device_info_plus` y el lock npm raiz sin proyecto asociado.

### ~~33. Quedaban dos avisos del analizador~~

**Resuelto.** `flutter analyze` termina sin diagnosticos.

## Flujo de pagos consolidado

- Quien crea un gasto es quien adelanto el importe y queda registrado como acreedor.
- Cada division conserva siempre su importe original.
- El deudor puede marcar su propia parte como pagada.
- El acreedor puede registrar como cobradas exclusivamente las deudas que se le deben, aunque el miembro nunca instale la aplicacion.
- Se guarda `pagoRegistradoPor` para distinguir quien cerro la deuda.
- Si el deudor confirma el pago, se notifica al acreedor.
- Si el acreedor registra directamente el cobro, no recibe una notificacion redundante.
- El acreedor puede reabrir un pago no recibido; si el deudor tiene cuenta, vuelve a recibir la notificacion.

## Verificacion actual

- `flutter analyze`: sin diagnosticos.
- `flutter test`: 8 pruebas superadas.
- Tests de Functions con Node 20: 9 pruebas superadas.
- Reglas de Firestore: 5 pruebas de permisos superadas en el emulador.
- Configuracion de reintentos de Functions: comprobada al cargar los triggers.
- Android: APK debug generado correctamente.
- iOS: resolucion de pods correcta; compilacion bloqueada por falta de plataforma de simulador en Xcode.
- `npm audit --omit=dev`: 2 vulnerabilidades moderadas transitivas.

## Orden de trabajo restante

1. Validar notificaciones y flujo de pagos en dispositivos Android e iOS.
2. Revisar dependencias por bloques, sin actualizaciones masivas.
3. Evaluar el coste de las consultas solo cuando exista una escala de uso representativa.
4. Dejar identificadores, firma y preparacion de tiendas para la futura fase de publicacion.
