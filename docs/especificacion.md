# Especificación de PayB2

Actualizada el 25 de septiembre de 2026.

## Producto

PayB2 es una aplicación móvil para registrar gastos compartidos, repartirlos entre los miembros de un grupo y recordar las deudas pendientes. Su objetivo es reducir el trabajo de quien adelanta el dinero sin obligar a todos los miembros a instalar la aplicación.

La versión actual está orientada a Android e iOS y se mantiene como proyecto personal preparado para portfolio. La publicación y la operación en producción son una fase posterior.

## Personas y conceptos

- **Usuario:** instalación o cuenta autenticada que utiliza PayB2.
- **Miembro:** persona representada dentro de un grupo. Puede no tener la aplicación.
- **Identidad reclamada:** miembro que un usuario reconoce como propio dentro de un grupo.
- **Pagador o acreedor:** miembro que adelanta el importe de un gasto.
- **Deudor:** miembro al que corresponde una parte pendiente de ese gasto.
- **Propietario del grupo:** usuario que creó el grupo y conserva permisos administrativos.

Un usuario y un miembro no son el mismo concepto. El UID identifica una cuenta de Firebase; el `memberId` representa a una persona dentro de un grupo.

## Requisitos funcionales actuales

Estos requisitos están implementados en el código. El acceso con Google y Apple todavía necesita la configuración externa descrita en `docs/analisis.md` antes de poder validarse en dispositivos reales.

### Acceso y continuidad

- **RF-01.** La aplicación crea automáticamente una sesión anónima cuando no existe otra sesión.
- **RF-02.** Un usuario puede usar grupos y gastos sin iniciar sesión con Google o Apple.
- **RF-03.** La interfaz presenta la acción como `Iniciar sesión`; la vinculación o fusión interna no requiere decisiones adicionales del usuario.
- **RF-04.** Si el proveedor todavía no tiene una cuenta, se vincula a la sesión anónima y se conserva el UID.
- **RF-05.** Si la cuenta ya existe, los grupos y relaciones de la sesión anónima se fusionan automáticamente con la cuenta recuperada.
- **RF-06.** Una fusión interrumpida se reanuda al volver a abrir la aplicación.
- **RF-07.** Una cuenta autenticada conserva sus datos tras reinstalar la aplicación. Una sesión anónima no ofrece recuperación después de borrar la aplicación o sus datos.

### Grupos e identidades

- **RF-08.** Un usuario puede crear un grupo indicando su nombre y entre 1 y 50 miembros con nombres únicos.
- **RF-09.** Cada grupo dispone de un código alfanumérico de ocho caracteres para invitar a otros usuarios.
- **RF-10.** Un usuario puede unirse a un grupo mediante su código y repetir la operación sin crear membresías duplicadas.
- **RF-11.** Al entrar en un grupo, el usuario puede reclamar una identidad que todavía esté libre.
- **RF-12.** Una identidad solo puede ser reclamada por una cuenta a la vez.
- **RF-13.** Si una fusión reúne dos identidades del mismo grupo, ambas se conservan bajo la cuenta final y una permanece como identidad principal.
- **RF-14.** Un grupo puede contener miembros que nunca instalen PayB2.

### Gastos y repartos

- **RF-15.** Un usuario con identidad reclamada puede crear un gasto indicando nombre, descripción opcional, importe, fecha y participantes.
- **RF-16.** El creador actúa como pagador mediante su identidad principal del grupo.
- **RF-17.** El importe se divide por igual entre pagador y participantes, en céntimos enteros y sin perder el total por redondeo.
- **RF-18.** Un gasto necesita al menos un participante además del pagador y debe asignar como mínimo un céntimo a cada persona incluida.
- **RF-19.** Una solicitud repetida con el mismo identificador y contenido no crea gastos duplicados.
- **RF-20.** El creador del gasto o el propietario del grupo puede eliminarlo.
- **RF-21.** Al eliminar una ocurrencia periódica se puede conservar o eliminar también su programación.

### Gastos futuros y periódicos

- **RF-22.** Un gasto con fecha futura se guarda como programación y se crea cuando llega su fecha.
- **RF-23.** Se admiten intervalos de 7, 15, 30 y 365 días, además de recurrencias mensuales, trimestrales y anuales de calendario.
- **RF-24.** Las recurrencias de calendario ajustan el día al final del mes cuando sea necesario y recuperan el día original en meses posteriores.
- **RF-25.** Una ejecución repetida del proceso programado no duplica ocurrencias.

### Deudas y pagos

- **RF-26.** Cada participante puede consultar cuánto debe, a quién y en qué gasto se originó la deuda.
- **RF-27.** El deudor puede marcar su propia parte como pagada.
- **RF-28.** El acreedor puede marcar como cobrada cualquier parte que se le deba, aunque el deudor no utilice la aplicación.
- **RF-29.** El acreedor puede devolver una parte pagada al estado pendiente cuando el pago no se haya recibido realmente.
- **RF-30.** Ningún otro miembro puede cerrar o reabrir una deuda ajena.
- **RF-31.** La vista de cartera reúne las deudas pendientes del usuario en todos sus grupos e identidades.
- **RF-32.** La pestaña de saldos muestra deuda bruta por miembro; actualmente no compensa deudas opuestas.

### Notificaciones y consulta

- **RF-33.** Cuando un deudor marca una parte como pagada, el acreedor recibe una notificación.
- **RF-34.** Cuando el acreedor reabre una deuda, el deudor recibe una notificación.
- **RF-35.** Los usuarios con deudas pendientes reciben recordatorios programados si tienen un token válido.
- **RF-36.** Los recordatorios enviados se registran por usuario y día; un reintento omite los envíos ya confirmados y vuelve a intentar los fallidos.
- **RF-37.** La aplicación solicita una sola vez el permiso de notificaciones durante el primer inicio y permite activar o desactivar sus avisos desde Ajustes.
- **RF-38.** El detalle del grupo permite consultar gastos, saldos y estadísticas.
- **RF-39.** La aplicación dispone de tema claro y oscuro.

## Requisitos funcionales objetivo

- **RFO-01.** Permitir repartos personalizados sin que la suma de las partes supere ni quede por debajo del importe del gasto.
- **RFO-02.** Permitir repartir un gasto por porcentajes con una interfaz sencilla y validación exacta del total.
- **RFO-03.** Definir y mostrar de forma inequívoca si los saldos representan deuda bruta o saldo neto compensado.

Estos objetivos no se consideran implementados hasta que el código y sus pruebas demuestren el comportamiento descrito.

## Casos de uso principales

### CU-01. Crear un grupo

1. El usuario introduce el nombre del grupo y sus miembros.
2. El servidor valida nombres, reserva un código único y crea grupo, miembros y membresía de forma atómica.
3. El usuario comparte el código con quien quiera usar la aplicación.

### CU-02. Unirse y reclamar identidad

1. El usuario introduce el código del grupo.
2. El servidor crea su membresía si todavía no existe.
3. El usuario elige quién es entre las identidades libres.
4. El servidor confirma la reclamación o informa de que otra cuenta se adelantó.

### CU-03. Registrar un gasto

1. El pagador indica importe, fecha y participantes.
2. El servidor valida que pertenece al grupo y controla la identidad del pagador.
3. El importe se reparte en céntimos y se crean el gasto y sus divisiones en una única transacción.
4. Si la fecha es futura o existe recurrencia, se crea también la programación correspondiente.

### CU-04. Confirmar o corregir un pago

1. El deudor marca su parte como pagada o el acreedor la marca como cobrada.
2. El sistema registra quién confirmó el cambio y cuándo ocurrió.
3. Si el deudor confirmó el pago, se avisa al acreedor.
4. Si el acreedor no recibió el dinero, reabre la deuda y el sistema vuelve a avisar al deudor.

### CU-05. Iniciar sesión por primera vez

1. El usuario pulsa `Iniciar sesión` y elige Google o Apple.
2. Firebase vincula el proveedor a la cuenta anónima.
3. El UID y todos los datos existentes se conservan.

### CU-06. Recuperar una cuenta existente

1. La instalación nueva puede haber creado grupos antes de iniciar sesión.
2. El sistema guarda un ticket recuperable y bloquea temporalmente las escrituras de la sesión anónima.
3. El usuario inicia sesión en su cuenta existente.
4. El servidor traslada y combina membresías, identidades, propiedad, autorías y registro de notificaciones.
5. La cuenta final conserva tanto sus grupos anteriores como los creados en la instalación nueva.

### CU-07. Representar a un miembro sin aplicación

1. El miembro existe dentro del grupo sin reclamar una cuenta.
2. Puede participar en gastos y acumular partes pendientes.
3. El acreedor registra el cobro cuando recibe el dinero por otro medio.

## Requisitos no funcionales actuales

### Integridad

- **RNF-01.** Los importes monetarios se calculan y almacenan en céntimos enteros; los campos decimales antiguos solo se mantienen por compatibilidad temporal.
- **RNF-02.** Las operaciones que crean varias relaciones deben ser atómicas o reintentables sin duplicar datos.
- **RNF-03.** Una migración de cuenta debe ser idempotente, conservar la unión de datos y rechazar un destino diferente una vez fijado.
- **RNF-04.** Durante una migración, las escrituras del UID de origen deben quedar bloqueadas tanto en Functions como en reglas de Firestore.

### Seguridad y privacidad

- **RNF-05.** Solo los miembros de un grupo pueden leer sus datos.
- **RNF-06.** La creación de grupos y gastos, la unión y la reclamación de identidades se validan en servidor.
- **RNF-07.** Los cambios de pago se limitan al deudor y al acreedor afectados.
- **RNF-08.** Los tickets de fusión son aleatorios, caducan, quedan ligados al UID de origen y solo pueden completarse hacia un destino.
- **RNF-09.** La aplicación no promete recuperar una cuenta anónima después de perder la instalación.

### Fiabilidad y mantenimiento

- **RNF-10.** Los errores de red deben dejar las operaciones importantes en un estado reintentable.
- **RNF-11.** Los procesos programados deben reintentarse cuando fallen y no duplicar gastos ya creados.
- **RNF-12.** Las reglas esenciales deben disponer de pruebas automáticas sencillas y legibles.
- **RNF-13.** Los errores pendientes se mantienen en `docs/analisis.md`; una vez corregidos se eliminan de ese documento.

### Rendimiento y compatibilidad

- **RNF-14.** La interfaz debe permanecer utilizable durante cargas y mostrar una opción de reintento ante errores recuperables.
- **RNF-15.** Android e iOS son las plataformas objetivo actuales. Web y escritorio quedan fuera del alcance presente.

## Requisitos no funcionales objetivo

- **RNFO-01.** Evitar recorridos completos de datos cuando una consulta indexable pueda resolver el mismo caso.
- **RNFO-02.** Mantener tiempos de carga y respuesta adecuados para el volumen que se defina antes de una publicación real.
- **RNFO-03.** Validar autenticación, notificaciones y procesos programados en dispositivos y servicios Firebase reales antes de publicar.
- **RNFO-04.** Registrar fallos del servidor con contexto suficiente para identificar la operación sin exponer datos personales innecesarios.
- **RNFO-05.** Mantener una interfaz coherente, legible y adaptable a los tamaños de pantalla admitidos.
- **RNFO-06.** Actualizar dependencias por bloques comprobables, sin migraciones masivas que impidan localizar regresiones.

## Decisiones técnicas vigentes

### Autenticación anónima como punto de entrada

La aplicación empieza con Firebase Authentication anónimo para que crear o unirse a un grupo no dependa de registrar una cuenta. Google y Apple sirven para dar continuidad entre instalaciones.

### Fusión automática de cuentas

La interfaz no ofrece `Proteger cuenta` ni pregunta si se desean combinar datos. Primero se intenta vincular el proveedor conservando el UID. Solo cuando la credencial pertenece a otra cuenta se ejecuta la fusión automática mediante un ticket persistido antes de bloquear el origen.

### Identidades independientes del UID

Los gastos y divisiones utilizan `memberId`; los permisos y la sincronización utilizan UID. Esta separación permite incluir personas sin aplicación y conservar varias identidades cuando dos sesiones del mismo usuario coinciden en un grupo.

### Escrituras sensibles en servidor

Cloud Functions crea grupos y gastos, gestiona membresías, reclama identidades y elimina gastos. Firestore permite al cliente modificar directamente una división únicamente para los cambios de pago autorizados por las reglas.

### Dinero en céntimos

`cantidadCentimos` es la fuente de verdad. El reparto ordena las identidades y asigna los céntimos sobrantes de forma determinista para que la suma coincida siempre con el total.

### Gastos programados deterministas

Cada ocurrencia y cada división obtiene un identificador reproducible. El proceso diario puede repetirse sin crear copias y las recurrencias de calendario conservan su día de anclaje.

### Notificaciones con prioridad de entrega

Los avisos se reintentan cuando una Function falla. Cada entrega correcta se registra por usuario y día para que los reintentos omitan destinatarios ya confirmados. Si FCM acepta un mensaje y falla el registro posterior, se prefiere el posible duplicado antes que omitir el recordatorio.

## Decisiones pendientes

- **DP-01.** Elegir entre deuda bruta y saldo neto compensado para la presentación definitiva de `Saldos`.
- **DP-02.** Diseñar el reparto personalizado y por porcentajes antes de fijar su modelo de datos.
- **DP-03.** Definir límites y estrategia de consultas si el proyecto pasa de portfolio a servicio publicado.
- **DP-04.** Completar configuración, costes y operación de Google, Apple, APNs, FCM y Cloud Scheduler antes de publicar.

## Fuera del alcance actual

- Pagos bancarios o movimiento real de dinero.
- Recuperación de sesiones anónimas eliminadas.
- Publicación comercial, soporte operativo y compromisos de disponibilidad.
- Cliente web o de escritorio.
