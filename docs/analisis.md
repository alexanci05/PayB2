# Analisis actual de PayB2

Este documento recoge los problemas encontrados al revisar el proyecto tal y como esta ahora. No pretende decir que toda la aplicacion este mal: sirve como una lista de trabajo para arreglar primero lo que puede afectar a los gastos, las deudas, los usuarios o los datos.

## Estado tras las correcciones

Actualizado el 17 de septiembre de 2026. El inventario detallado que aparece despues de esta seccion describe el estado inicial y se conserva para poder estudiar el origen de cada fallo.

Se han resuelto los problemas **1-18, 20-22, 25-28, 30-33**. En concreto, el proyecto usa ahora un reparto exacto en centimos, ocurrencias recurrentes idempotentes, pagos que conservan el importe historico, escrituras atomicas, reclamacion transaccional de identidades, reglas de Firestore versionadas, Callables para crear y unirse a grupos, renovacion de tokens FCM y vistas que se refrescan tras los cambios.

La recurrencia tiene tres reintentos con espera progresiva y no duplica datos al repetirse. Los recordatorios tienen cinco reintentos; se acepta que un fallo parcial pueda producir algun aviso duplicado porque se prioriza no olvidar una deuda. Las reglas de Firestore se han compilado en el emulador. `flutter analyze` termina sin avisos, pasan 8 pruebas Flutter y 8 pruebas de Functions, y Android genera correctamente el APK debug.

Decisiones de producto adoptadas:

- Quien crea un gasto debe constar como la persona que adelanto el importe. Cada participante solo puede confirmar el pago de su propia division. El acreedor puede devolver a pendiente un pago que no haya recibido; esa transicion vuelve a notificar al deudor.
- Los datos creados durante el desarrollo se consideran descartables. No se mantiene compatibilidad ni se crea una migracion para recurrencias del modelo anterior.
- La prioridad actual es una aplicacion solida, util, cuidada y adecuada como proyecto de portfolio.
- **Problema 19:** la optimizacion para grandes volumenes se pospone hasta conocer la escala real del producto.
- **Problemas 23 y 24:** plataformas definitivas, identificadores, firma y publicacion quedan para una fase posterior.
- **Problema 29:** las actualizaciones mayores restantes se haran por bloques cuando aporten una mejora funcional o de mantenimiento concreta.

Limitaciones externas conocidas:

- Las dos alertas moderadas restantes de `npm audit` proceden de `firebase-admin` a traves de dependencias actuales de Google; `npm audit fix --dry-run` no ofrece una actualizacion compatible adicional.
- La compilacion iOS no puede completarse en este equipo hasta instalar una plataforma de simulador desde Xcode. La resolucion de pods si finaliza correctamente.

## Diagnostico inicial

La prioridad significa:

- **Critica:** puede generar datos economicos incorrectos o dejar una parte central inutilizable.
- **Alta:** puede provocar errores visibles, perdida de datos o problemas de seguridad.
- **Media:** afecta a la fiabilidad, el mantenimiento o la experiencia de uso.
- **Baja:** no rompe la aplicacion, pero conviene limpiarlo.

## Resumen rapido

Lo mas delicado esta en los gastos periodicos y futuros. En este momento pueden no crear ninguna deuda, copiar deudas antiguas de forma incorrecta o conservar el estado de una deuda ya pagada. Tambien hay problemas al marcar pagos desde la cartera, al identificar a los miembros de un grupo y al mantener actualizadas algunas pantallas.

La aplicacion pasa `flutter analyze` sin diagnosticos de error, aunque muestra dos avisos menores. Esto no sustituye una compilacion completa. `flutter test` falla porque el unico test sigue siendo el contador de ejemplo de Flutter. La compilacion Android tampoco se pudo completar en este equipo porque macOS tiene `android/gradlew` bloqueado con una marca de cuarentena.

## Problemas criticos

### 1. Los gastos periodicos reutilizan deudas antiguas de forma incorrecta

La funcion periodica lee todas las divisiones existentes y las vuelve a copiar completas en cada ejecucion (`functions/index.js:118-146`). Esto incluye su cantidad y su estado `pagado`.

En la practica pueden ocurrir dos cosas:

- Si una deuda anterior ya se pago, la siguiente puede nacer con cantidad `0` y como pagada.
- Si sigue pendiente, cada ejecucion copia tambien las copias anteriores. La cantidad de divisiones puede crecer de forma multiplicativa: `N -> 2N -> 4N`, mezclando periodos diferentes y aumentando lecturas y deudas.

La recurrencia necesita una plantilla inmutable del reparto y cada periodo deberia crear sus propias divisiones con un identificador o fecha de periodo, siempre empezando con `pagado: false`.

### 2. Los gastos con fecha futura pueden no generar ninguna deuda

Al crear un gasto futuro no se crean divisiones (`lib/screens/crear_gasto/crear_gasto.dart:163-192`). En un gasto periodico, `proximaFecha` se calcula sumando un intervalo a la fecha elegida, por lo que ni siquiera se procesa en su primera fecha. Cuando finalmente entra en la Cloud Function, esta solo intenta copiar divisiones existentes (`functions/index.js:101-146`); como la lista esta vacia, no crea ninguna deuda y vuelve a avanzar la fecha.

Esto afecta especialmente a los gastos periodicos futuros, pero un gasto futuro no periodico tampoco tiene ningun proceso que cree sus divisiones al llegar el dia.

### 3. Marcar una deuda como pagada desde Cartera puede pagar varias a la vez

Cada tarjeta de la cartera representa una division, pero no guarda su `divisionId`. Al pulsar "Marcar pagado", se buscan todas las divisiones del mismo miembro dentro del gasto y se ponen a cero (`lib/screens/home/main_screen.dart:348-367`).

En un gasto periodico esto puede liquidar varias cuotas con un solo boton. Ademas, las llamadas `update` del bucle no se esperan de forma individual, por lo que el refresco puede ejecutarse antes de que Firestore haya terminado y la deuda puede seguir apareciendo durante un momento.

Tanto esta pantalla como la vista de Saldos marcan un pago sobrescribiendo `cantidad` con `0` (`lib/screens/home/main_screen.dart:359-361` y `lib/screens/grupo_detalles/grupo_detalle_screen.dart:377-388`). Asi se pierde el importe historico original y ese cero tambien se copia en las recurrencias. El estado de pago y la cantidad original deben guardarse por separado.

### 4. El reparto puede generar importes economicos incorrectos

Si se seleccionan participantes y despues se cambia el pagador, el nuevo pagador desaparece visualmente de la lista, pero su identificador puede seguir dentro de `_selectedParticipants` (`lib/screens/crear_gasto/crear_gasto.dart:329-332`). Al guardar, se crea una division para esa misma persona.

Tampoco se exige seleccionar participantes, de modo que se puede guardar un gasto actual sin ninguna division ni deuda (`lib/screens/crear_gasto/crear_gasto.dart:131-171`). Cuando si hay participantes, cada cuota se redondea por separado a dos decimales y el residuo no se asigna a nadie. El total repartido puede diferir del importe original y, en cantidades pequenas, una cuota puede redondearse a `0.00`.

Antes de guardar hay que validar el reparto completo, eliminar siempre al pagador actual y distribuir los centimos restantes de forma determinista.

## Problemas de prioridad alta

### 5. Cualquier usuario del formulario puede indicar que pago otra persona

En el formulario se cargan todos los miembros y cualquier usuario puede elegir a cualquiera como pagador (`lib/screens/crear_gasto/crear_gasto.dart:57-68` y `:317-340`). El `uid` recibido por `CrearGastoScreen` no se usa para validar quien esta realizando la operacion.

El caso es aun mas claro cuando no queda ningun miembro libre: `_myMemberId` permanece vacio (`lib/screens/grupo_detalles/grupo_detalle_screen.dart:82-99`), pero el boton para crear gastos sigue habilitado. El cliente permite registrar un gasto en nombre de otra persona; que Firestore acepte finalmente la escritura depende de unas reglas desplegadas que no estan disponibles en el repositorio. La identidad deberia ser obligatoria y validarse tambien en servidor.

### 6. Se puede crear un grupo sin miembros y dejarlo inutilizable

La pantalla indica "minimo 1", pero la lista empieza vacia y no existe una validacion que obligue a añadir a alguien (`lib/screens/crear_grupo/crear_grupo_screen.dart:18` y `:140-155`). El creador se añade a `groupMembers`, pero no se crea automaticamente como miembro interno del grupo.

El resultado es un grupo que aparece en la lista, pero no tiene identidad que reclamar ni pagador que seleccionar al crear un gasto.

### 7. La creacion de grupos y gastos no es atomica

Al crear un gasto primero se guarda el documento principal y despues se guardan las divisiones en otro batch (`lib/screens/crear_gasto/crear_gasto.dart:142-191`). Si falla el segundo paso, queda un gasto visible sin deudas.

La creacion de grupos tiene el mismo tipo de riesgo: grupo, pertenencia y miembros se escriben por separado (`lib/screens/crear_grupo/crear_grupo_screen.dart:53-94`). Un corte de red puede dejar datos incompletos.

Estas escrituras relacionadas deberian realizarse en un unico `WriteBatch` o en una transaccion.

### 8. Las reglas de seguridad de Firestore no estan en el repositorio

No existe `firestore.rules` ni una entrada de Firestore en `firebase.json`. Esto no demuestra que la base de datos publicada este abierta, porque puede haber reglas configuradas directamente en Firebase, pero ahora mismo no se pueden revisar, reproducir ni versionar junto al codigo.

Es especialmente importante porque el cliente puede crear grupos, reclamar identidades, marcar pagos y borrar gastos directamente. Las reglas desplegadas deberian comprobar la pertenencia al grupo, la identidad reclamada y que cada usuario solo pueda modificar lo que le corresponde.

### 9. Cualquier miembro ve la opcion de borrar cualquier gasto

El boton de borrar aparece en todos los gastos y no comprueba autor ni propietario, tampoco pide confirmacion (`lib/screens/grupo_detalles/grupo_detalle_screen.dart:307-314`). El borrado elimina el gasto y sus divisiones.

Aunque las reglas de Firestore podrian bloquearlo, esas reglas no estan disponibles en el repositorio. La interfaz deberia limitar esta accion y pedir confirmacion para evitar borrados accidentales.

### 10. Las notificaciones pueden dejar de llegar cuando cambia el token

El token FCM se registra una sola vez y despues se guarda la bandera local `userRegistered` (`lib/controladores/registrar_usuario.dart:6-33`). Esa funcion solo se llama desde la pantalla inicial, que se muestra en la primera apertura (`lib/screens/home/home_screen.dart:13-18`).

Los tokens pueden renovarse. Como no se escucha `FirebaseMessaging.instance.onTokenRefresh`, Firestore puede conservar un token caducado y las notificaciones dejaran de llegar. El registro deberia revisarse en cada arranque autenticado y actualizarse cuando cambie el token.

### 11. Las notificaciones en primer plano no se muestran en iOS

El listener solo muestra la notificacion local cuando existe `notification.android` (`lib/app.dart:31-49`). En un mensaje recibido por iOS ese campo no existe, por lo que el aviso se ignora aunque `message.notification` sea valido.

La condicion debe aceptar iOS y configurar tambien los detalles Darwin de la notificacion local.

### 12. Las dependencias de Cloud Functions tienen vulnerabilidades conocidas

`npm audit --omit=dev`, ejecutado dentro de `functions/`, informa de **21 vulnerabilidades**: 4 criticas, 5 altas, 11 moderadas y 1 baja. Son dependencias transitivas de versiones antiguas de Firebase Admin y Firebase Functions, entre otras.

No se ha aplicado `npm audit fix` automaticamente porque parte de la solucion puede actualizar versiones mayores. Hay que actualizar de forma controlada, volver a ejecutar el audit y probar las Functions en emulador antes de desplegar.

### 13. Dos usuarios pueden reclamar al mismo miembro simultaneamente

Primero se consultan los miembros libres y despues se actualiza el elegido, sin transaccion (`lib/screens/grupo_detalles/grupo_detalle_screen.dart:82-131`). Dos dispositivos pueden ver el mismo miembro libre y reclamarlo casi a la vez; la ultima escritura gana. Esto puede asignar la identidad y los permisos de una persona al usuario equivocado.

La reclamacion debe hacerse con una transaccion que compruebe que `reclamadoPor` sigue siendo `null`.

## Problemas de prioridad media

### 14. Saldos, Estadisticas y Cartera muestran datos antiguos

La lista de gastos usa un stream en tiempo real, pero Saldos y Estadisticas cargan su `Future` solo una vez en `initState` (`lib/screens/grupo_detalles/grupo_detalle_screen.dart:347-375` y `:522-550`). La cartera hace lo mismo (`lib/screens/home/main_screen.dart:196-203`).

Despues de crear, borrar o pagar un gasto, distintas pantallas pueden mostrar cifras contradictorias hasta que se reconstruyan o se reinicie la aplicacion.

### 15. Algunas operaciones asincronas pueden llamar a `setState` tras cerrar la pantalla

Hay varios `setState` despues de un `await` sin comprobar `mounted`, por ejemplo al cargar miembros de un gasto (`lib/screens/crear_gasto/crear_gasto.dart:57-69`), reclamar una identidad (`lib/screens/grupo_detalles/grupo_detalle_screen.dart:64-79`) o refrescar la cartera (`lib/screens/home/main_screen.dart:348-367`).

Si el usuario sale mientras espera la red, Flutter puede lanzar `setState() called after dispose()`.

### 16. Algunas recurrencias pueden calcular una fecha incorrecta

La aplicacion construye la siguiente fecha usando el mismo numero de dia en el mes o ano siguiente (`lib/screens/crear_gasto/crear_gasto.dart:393-398`) y JavaScript usa `setMonth` o `setFullYear` en el servidor (`functions/index.js:172-179`). Fechas como el 31 de enero pueden desbordarse a marzo; ocurre tambien en recurrencias trimestrales y con el 29 de febrero en una recurrencia anual.

Hay que decidir una regla clara para finales de mes, por ejemplo usar el ultimo dia disponible.

### 17. Un token invalido puede detener todos los recordatorios del dia

`recordatorioDeudas` procesa todos los usuarios dentro de un unico `try`. Si el envio a un token falla, salta al `catch` general y deja sin procesar a los usuarios restantes (`functions/index.js:201-288`).

Cada envio deberia tener su propio control de errores, eliminar tokens invalidos y permitir que el bucle continue.

### 18. Las Cloud Functions ocultan errores que deberian reintentarse

Las funciones capturan errores, los escriben en consola y terminan normalmente (`functions/index.js:78-80`, `:152-154` y `:286-288`). Firebase interpreta que la ejecucion termino correctamente, por lo que un fallo temporal puede perder una notificacion o una recurrencia sin reintento.

La solucion necesita idempotencia y una politica explicita de reintentos, no solo volver a lanzar todos los errores sin control.

### 19. Las Functions realizan muchas lecturas en serie

Los recordatorios recorren usuarios, grupos, gastos y divisiones con consultas anidadas (`functions/index.js:194-265`). La recurrencia tambien recorre todos los grupos (`functions/index.js:96-150`). Al crecer los datos aumentaran el coste, el tiempo de ejecucion y el riesgo de alcanzar limites.

Conviene guardar indices o referencias directas a las deudas pendientes y procesar por lotes o mediante eventos.

### 20. El codigo de grupo y su bloqueo se protegen solo en el cliente

Los codigos se generan con `Random` y se consultan directamente en Firestore (`lib/screens/crear_grupo/crear_grupo_screen.dart:188-209`). El limite de tres intentos vive solo en memoria (`lib/screens/unirse_grupo/unirse_grupo_screen.dart:17-32` y `:58-70`), de modo que se reinicia al cerrar la pantalla y puede evitarse fuera de la app.

Si el codigo debe ser privado, la union al grupo deberia pasar por una Callable Function con limitacion de intentos en servidor.

### 21. Se escribe el token FCM completo en los logs

`functions/index.js:74` registra el token al enviar una notificacion. Es un identificador sensible y no hace falta mostrarlo completo para diagnosticar errores. Se deberia registrar un identificador interno o una version truncada.

### 22. Una carga fallida del detalle puede quedarse mostrando un spinner

El `FutureBuilder` principal del detalle solo comprueba `snapshot.hasData` y no trata `snapshot.hasError` (`lib/screens/grupo_detalles/grupo_detalle_screen.dart:148-160`). Si Firestore devuelve un error, el usuario puede quedarse viendo el indicador de carga indefinidamente.

### 23. Firebase no esta configurado para todas las plataformas incluidas

Existen carpetas para web, macOS, Windows y Linux, pero `DefaultFirebaseOptions` lanza `UnsupportedError` en todas ellas (`lib/firebase_options.dart:18-48`). Si PayB2 solo se publica en Android e iOS no es un bug funcional, pero esas plataformas no se pueden ejecutar tal como estan y conviene dejarlo claro o eliminarlas del alcance.

### 24. Android todavia usa identificadores y firma de desarrollo

El `applicationId` sigue siendo `com.example.payb2` y la compilacion release usa la clave de debug (`android/app/build.gradle.kts:26-42`). Esto sirve durante el desarrollo, pero debe cambiarse antes de publicar en Play Store. iOS tambien usa `com.example.payb2` en la configuracion Firebase.

### 25. La version de Dart declarada no reproduce el lockfile

`pubspec.yaml` permite usar Dart desde la version 3.7.2, pero `pubspec.lock:696-698` exige Dart 3.8.0 o superior y Flutter 3.29.0 o superior. Por tanto, un entorno que cumple aparentemente el manifiesto puede no ser capaz de instalar exactamente las dependencias bloqueadas.

El rango del SDK debe reflejar la version minima que realmente requiere el lockfile, o se deben regenerar las dependencias con la version minima que se quiera soportar.

### 26. El minimo de iOS no coincide entre CocoaPods y Xcode

`ios/Podfile:2` declara iOS 13, mientras que el proyecto Xcode conserva `IPHONEOS_DEPLOYMENT_TARGET = 12.0` en Debug, Profile y Release. Esta diferencia puede producir avisos o incompatibilidades al resolver pods y compilar.

Ambas configuraciones deberian usar el mismo minimo soportado.

## Pruebas, herramientas y mantenimiento

### 27. El unico test automatico esta roto y no prueba PayB2

`test/widget_test.dart` conserva el test de contador generado por Flutter. Busca los textos `0` y `1` y un boton de suma que ya no existen. Por eso `flutter test` falla.

Ahora mismo no hay cobertura automatica para reparto de importes, gastos periodicos, reclamacion de miembros, pagos, notificaciones ni reglas de Firestore. Estos son precisamente los flujos con mayor riesgo.

### 28. La compilacion Android esta bloqueada en esta copia local

`flutter build apk --debug` no consigue ejecutar `android/gradlew`. El archivo tiene permisos de ejecucion, pero macOS le ha añadido `com.apple.quarantine` con procedencia de WhatsApp. Es un problema local de esta copia, no necesariamente del repositorio.

Antes de validar Android hay que quitar esa cuarentena de forma consciente o volver a obtener el archivo desde una fuente fiable, y despues repetir la compilacion.

### 29. Hay bastantes dependencias Flutter pendientes de actualizar

`flutter pub outdated` informa de 31 dependencias bloqueadas con versiones actualizables y 26 restricciones que impiden resolver versiones mas nuevas. No significa que todas deban actualizarse inmediatamente, pero aumenta la distancia respecto a correcciones y versiones soportadas.

Conviene hacerlo por bloques, empezando por Firebase y notificaciones, con pruebas despues de cada grupo de cambios.

### 30. La documentacion de instalacion tiene Markdown incompleto

Los bloques de comandos de `README.md` empiezan con ```` ``bash ```` pero no se cierran. Ademas, el tercer paso repite el titulo "Instala dependencias" aunque realmente explica la configuracion de Firebase. Esto hace que la guia se renderice mal y resulte confusa.

### 31. El entorno y el lock de Cloud Functions estan desalineados

Cloud Functions declara Node 20, pero el entorno local usa Node 22.17.1. Ademas, `functions/package.json` pide `firebase-admin ^12.7.0` y `firebase-functions ^4.9.0`, mientras que la entrada raiz de `functions/package-lock.json` todavia conserva los rangos anteriores `^12.6.0` y `^4.4.1`.

Las versiones instaladas siguen siendo compatibles, pero esta diferencia dificulta reproducir con claridad el entorno. Conviene usar Node 20 para el desarrollo de Functions y regenerar el lockfile de forma controlada al actualizar dependencias.

### 32. Hay archivos y codigo sobrantes o duplicados

- `lib/config/theme.dart` esta vacio.
- `lib/notifications.dart` crea una segunda instancia de `FlutterLocalNotificationsPlugin`, pero no se usa.
- `FirebaseFunctions.instance` se declara en la cartera y no se utiliza (`lib/screens/home/main_screen.dart:206`).
- `device_info_plus` y `cloud_functions` parecen no utilizarse realmente en la aplicacion.
- El `package-lock.json` de la raiz no contiene dependencias y no hay un `package.json` raiz.

No es urgente, pero dificulta saber que partes siguen activas y cuales son restos de pruebas anteriores.

### 33. Quedan dos avisos menores del analizador

`flutter analyze` no encuentra errores, pero marca:

- Un parametro llamado `sum` que coincide con un nombre de tipo visible en `grupo_detalle_screen.dart:566`.
- Una interpolacion de texto innecesaria en `main_screen.dart:335`.

Son detalles sencillos y no causan los fallos principales.

## Orden recomendado

1. Corregir el modelo de gastos futuros y periodicos antes de seguir creando datos reales.
2. Corregir el pago individual de divisiones, la seleccion del pagador y la identidad de los miembros.
3. Versionar y revisar las reglas de Firestore; hacer atomicas las escrituras relacionadas.
4. Arreglar el registro FCM y el tratamiento de errores de las Cloud Functions.
5. Sustituir el test de plantilla por pruebas del reparto, recurrencias, pagos e identidad.
6. Resolver la compilacion local y validar Android e iOS en dispositivos o emuladores.
7. Actualizar dependencias y preparar identificadores, firma y documentacion de publicacion.

## Comprobaciones realizadas en el analisis inicial

- Revision estatica del codigo Flutter y de `functions/index.js`.
- `flutter analyze`: termina con 2 avisos informativos y sin errores.
- `flutter test`: falla el test de contador de la plantilla.
- `flutter pub outdated`: detecta dependencias pendientes de actualizar.
- `npm audit --omit=dev` en `functions/`: 21 vulnerabilidades.
- `npm audit --omit=dev` en la raiz: 0 vulnerabilidades; el lockfile raiz esta vacio.
- `flutter build apk --debug`: bloqueado antes de compilar por la cuarentena local de `android/gradlew`.

Este analisis no comprueba el estado real de las reglas desplegadas en Firebase, los indices existentes, la configuracion de APNs ni el comportamiento en dispositivos fisicos. Esos puntos necesitan acceso al proyecto Firebase y pruebas manuales.
