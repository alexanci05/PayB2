# Pruebas de Functions y Firestore

Desde la carpeta `functions`:

```bash
npm test
```

Comprueba el reparto, las recurrencias, las notificaciones, los límites de uso, la ventana de recordatorios y el descarte de eventos de más de 24 horas.

```bash
npm run test:demo
```

Levanta Auth, Firestore y Functions para `demo-payb2` y verifica por HTTP el inicio anónimo, la creación de un grupo y las reglas de lectura. No usa cuentas ni credenciales reales. La CLI fijada es 15.34.1, compatible con Functions v7; necesita Node.js 22 y Java 21. La CLI 13 anterior fallaba al invocar las funciones porque intentaba acceder a `functions.config()`.

```bash
npm run test:rules
```

Levanta temporalmente el emulador de Firestore y verifica los permisos basicos de grupos y deudas. No usa datos de produccion.

```bash
npm run test:integration
```

Ejecuta los handlers funcionales contra Firestore emulado y prueba las cuotas, los permisos de pago y reapertura, los turnos de programaciones, la fusión, su reserva exclusiva y el bloqueo de escrituras por ejecuciones sustituidas, y el límite de dispositivos. Comprueba también renombrado por callable, paginación y reservas de presupuesto del recordatorio, continuación tras fallos parciales y recuperación de su lease. También comprueba el transporte de Firestore Admin: lecturas, escrituras, timestamps, batch, query/count, transacciones, stream, listener y cierre. La entrega FCM se sustituye por un espia local porque no hay emulador de Firebase Cloud Messaging.

Las llamadas directas `.run` de las pruebas representan solicitudes cuyo App Check ya verificó el SDK. No comprueban criptográficamente la acreditación real de Android/iOS; los casos sin sesión o contexto de App Check sí deben rechazarse antes de consultar la base de datos.

La prueba HTTP demo utiliza la excepción local restringida a los tres emuladores y al proyecto `demo-payb2`. No modifica el requisito de App Check del proyecto real. Los emuladores escuchan solo en `127.0.0.1` y no deben exponerse a Internet.

La entrega a un token FCM real y el disparo gestionado de las programaciones de Cloud Scheduler/PubSub siguen requiriendo un entorno desplegado; estas pruebas invocan los handlers directamente.

`npm run check:deploy` ejecuta sintaxis, unitarias y auditoría de dependencias de producción. Firebase lo ejecuta automáticamente antes del despliegue de Functions; no sustituye las suites de reglas, integración y HTTP.
