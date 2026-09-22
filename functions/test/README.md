# Pruebas de Functions y Firestore

Desde la carpeta `functions`:

```bash
npm test
```

Comprueba el reparto, las recurrencias y el destinatario de las notificaciones.

```bash
npm run test:rules
```

Levanta temporalmente el emulador de Firestore y verifica los permisos basicos de grupos y deudas. No usa datos de produccion.

```bash
npm run test:integration
```

Ejecuta los handlers de `crearGrupo`, `unirseAGrupo`, `crearGasto`, `ejecutarGastosPeriodicos`, `onDeudaPagada` y `recordatorioDeudas` contra Firestore emulado. La entrega FCM se sustituye por un espia local porque no hay emulador de Firebase Cloud Messaging.

La entrega a un token FCM real y el disparo gestionado de las programaciones de Cloud Scheduler/PubSub siguen requiriendo un entorno desplegado; estas pruebas invocan los handlers directamente.
