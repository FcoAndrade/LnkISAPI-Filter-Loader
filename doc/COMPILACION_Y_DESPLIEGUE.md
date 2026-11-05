# Manual de compilación y despliegue en IIS

[English](BUILD_AND_DEPLOY.md) | **Español**

Cómo compilar el cargador con Delphi y desplegarlo en IIS, ya sea como **extensión** ISAPI (se llama por URL) o como **filtro** ISAPI (se registra en el sitio). Para saber qué es el cargador y cómo funciona, consulta el [README](../README.es.md).

## 1. Antes de empezar

### 1.1 ¿Qué papel necesitas?

La misma DLL exporta los puntos de entrada de los dos papeles. Lo que decide cómo la usas es **qué es tu DLL real**:

| Tu DLL real es... | Usas el cargador como... | Cómo llega IIS a ella |
|---|---|---|
| Una **extensión** ISAPI (un servicio web, una aplicación WebBroker o DMVCFramework...) | Extensión | Por URL, p. ej. `http://servidor/WebService/MiServicio.dll/estado` |
| Un **filtro** ISAPI | Filtro | Registrado en *Filtros ISAPI* del sitio; no se abre en el navegador |

Si abres en el navegador la URL de un filtro, o registras una extensión como filtro, IIS falla. Un síntoma frecuente es HTTP 500.0 con el error `0x8007007f` («no se encontró el procedimiento»): la DLL no exporta lo que IIS le pide en ese papel.

### 1.2 Los nombres de este manual

Todos los ficheros están en la misma carpeta y comparten el nombre base del cargador. Este manual usa `MiServicio`:

| Fichero | Qué es | Quién lo pone |
|---|---|---|
| `MiServicio.dll` | El cargador, renombrado | Tú, una vez |
| `MiServicio.upd` | Tu DLL real, pendiente de activar | Tú, en cada actualización |
| `MiServicio.run` | Tu DLL real, en ejecución | El cargador |
| `MiServicio.bak` | La versión anterior | El cargador |
| `logs\MiServicio.dll.log` | El log de depuración (solo build Debug) | El cargador |

El cargador solo entiende `.upd`, `.run` y `.bak`. Ignora los ficheros con otros nombres que usan otros cargadores (`.new`, `.update`, `.backup`).

## 2. Requisitos

| | |
|---|---|
| Para compilar | Delphi (RAD Studio) 10.3 o posterior, con el compilador Win32. Verificado con el compilador de la 10.3 (versión 33.0, `Studio\20.0`). |
| Para desplegar | Windows con IIS y la característica *Extensiones ISAPI* (papel de extensión) y/o *Filtros ISAPI* (papel de filtro). |
| Bits | Por ahora el cargador es **solo de 32 bits**. Ver el [apartado 5.3](#53-grupo-de-aplicaciones-de-32-bits). |

Para comprobar o instalar las características de IIS: *Panel de control > Programas > Activar o desactivar las características de Windows > Internet Information Services > Servicios World Wide Web > Características de desarrollo de aplicaciones* y marca *Extensiones ISAPI* y/o *Filtros ISAPI*.

## 3. Compilación

### 3.1 Configuraciones

El proyecto es [`src/FilterLoader.dproj`](../src/FilterLoader.dproj). Tiene dos configuraciones:

| | Debug | Release |
|---|---|---|
| Símbolo `DEBUG` | Sí | No (`RELEASE`) |
| Log de depuración (`logs\<nombre>.dll.log`) | **Sí** | No |
| Intervalo de comprobación de actualizaciones | 500 ms | 10 s |
| Información de depuración y fichero `.map` detallado | **Sí** | No |
| Aserciones en ejecución | Sí | No |
| Carpeta de salida | `bin\Debug\` | `bin\Release\` |

Usa **Debug** mientras diagnosticas un problema o desarrollas, y **Release** para un servidor estable: no escribe un log en cada petición.

Los `.dcu` van a `src\Win32\Debug\` o `src\Win32\Release\`.

### 3.2 Desde el IDE

1. Abre `src/FilterLoader.dproj`.
2. En el Gestor de proyectos, elige la **configuración** (Debug o Release) y la plataforma **Windows de 32 bits**. La configuración por defecto del proyecto puede ser Release: compruébalo antes de compilar.
3. *Proyecto > Construir FilterLoader*.
4. La DLL queda en `bin\Debug\FilterLoader.dll` o `bin\Release\FilterLoader.dll`.

### 3.3 Desde la línea de comandos

En una consola, en la raíz del repositorio (ajusta la ruta a tu versión de Studio):

```
call "C:\Program Files (x86)\Embarcadero\Studio\20.0\bin\rsvars.bat"
msbuild src\FilterLoader.dproj /t:Build /p:Config=Debug   /p:Platform=Win32
msbuild src\FilterLoader.dproj /t:Build /p:Config=Release /p:Platform=Win32
```

`rsvars.bat` prepara el entorno de Delphi. Una compilación correcta termina con algo como `NNN lines, N seconds, ... bytes code`.

### 3.4 Qué se obtiene

| Build | Ficheros en la carpeta de salida |
|---|---|
| Debug | `FilterLoader.dll`, `FilterLoader.map` (mapa detallado, útil con WinDbg para resolver direcciones de fallo), `FilterLoader.drc` |
| Release | `FilterLoader.dll` |

El repositorio versiona el contenido de `bin\` (las compilaciones), así que al recompilar Git los mostrará como modificados.

### 3.5 Versión del módulo

La información de versión de la DLL (versión del fichero y del producto) se define **una sola vez**, en la sección `Base` del `.dproj`, y por eso la comparten las dos configuraciones. Cámbiala en *Proyecto > Opciones > Información de versión* o en las claves `VerInfo_*` de `Base`.

## 4. Preparar el servidor

### 4.1 La carpeta

Crea una carpeta para la aplicación, por ejemplo `C:\ISAPI\MiServicio`, y copia en ella:

1. El cargador, **renombrado** a `MiServicio.dll` (elige la compilación Debug o Release).
2. Tu DLL real como `MiServicio.upd`.
3. Cualquier fichero que necesite tu DLL real (`.ini`, librerías cliente de la base de datos...).

Si tu DLL real trae su propio fichero de configuración con su nombre (por ejemplo `MiServicio.ini`), mantén ese nombre: se busca junto a la DLL real.

### 4.2 Permisos sobre la carpeta

El cargador renombra y borra ficheros en esa carpeta, así que la cuenta que ejecuta el grupo de aplicaciones necesita permiso de **Modificar** sobre ella. Sin él los renombrados fallan con «Acceso denegado» (error 5 de Windows).

Primero averigua el grupo de aplicaciones y su identidad (apartado 5.1). Con la habitual `ApplicationPoolIdentity`, la cuenta es `IIS AppPool\<nombre del grupo>`. En una consola de administrador:

```
icacls "C:\ISAPI\MiServicio" /grant "IIS AppPool\MiGrupo":(OI)(CI)M /T
```

`(OI)(CI)` hace que lo hereden las subcarpetas y los ficheros, y `/T` lo aplica también a lo que ya existe. Desde la interfaz gráfica: clic derecho en la carpeta > *Propiedades > Seguridad > Editar > Agregar*, elige el **nombre del equipo** en *Ubicaciones*, escribe `IIS AppPool\MiGrupo` y marca *Modificar*.

Si usas la compilación Debug, el mismo permiso deja que el cargador cree la carpeta `logs` y escriba el log.

## 5. Configuración de IIS

### 5.1 El grupo de aplicaciones

1. Abre el Administrador de IIS (`inetmgr`).
2. Ve a *Grupos de aplicaciones*. Crea uno para esta aplicación o reutiliza uno existente. Su nombre es el que va en el comando de permisos de arriba.
3. En *Configuración avanzada*, comprueba la *Identidad* (normalmente `ApplicationPoolIdentity`).

Desde la línea de comandos (administrador), `%windir%\system32\inetsrv\appcmd list app` muestra el grupo de cada aplicación y `appcmd list apppool` lista los grupos.

### 5.2 Qué grupo atiende a una aplicación

Selecciona la aplicación en *Sitios* y abre *Configuración básica...*: ahí aparece el **Grupo de aplicaciones**.

### 5.3 Grupo de aplicaciones de 32 bits

Un grupo de 64 bits (el predeterminado) solo carga DLL ISAPI de 64 bits. Como el cargador y tu DLL real son de 32 bits:

1. *Grupos de aplicaciones* > selecciona el grupo > *Configuración avanzada...*
2. Pon **Habilitar aplicaciones de 32 bits** a `True`.

El cargador y tu DLL real deben tener **los mismos bits**: una DLL de 32 bits no puede cargar una de 64, ni al revés.

### 5.4 Opción A: desplegar como extensión

1. En IIS, crea una aplicación (*Sitios > tu sitio > Agregar aplicación...*) cuya ruta física sea la carpeta del apartado 4.1, por ejemplo alias `WebService` y ruta `C:\ISAPI\MiServicio`. Asígnale el grupo del apartado 5.1.
2. Selecciona esa aplicación y abre **Asignaciones de controlador**. La asignación *ISAPI-dll* debe estar habilitada. Luego pulsa *Modificar permisos de característica...* y marca **Ejecutar** (además de *Lectura* y *Script*).
3. A nivel de servidor, abre **Restricciones ISAPI y CGI**, pulsa *Agregar...*, escribe la ruta completa del cargador (`C:\ISAPI\MiServicio\MiServicio.dll`) y marca *Permitir ruta de acceso de extensión para ejecutar*.
4. Llámala desde el navegador: `http://localhost/WebService/MiServicio.dll/estado`. Todo lo que va detrás del nombre de la DLL se lo pasa a tu extensión real.

### 5.5 Opción B: desplegar como filtro

1. Selecciona el **sitio** y abre **Filtros ISAPI**.
2. *Agregar...*, ponle un nombre y, en *Ejecutable*, escribe la ruta del cargador (`C:\ISAPI\MiServicio\MiServicio.dll`).
3. Asegúrate de que el grupo es de 32 bits (apartado 5.3).

IIS carga un filtro una sola vez, al arrancar el grupo de aplicaciones. Un filtro no tiene URL propia.

## 6. Primer arranque y comprobaciones

1. Para y arranca el grupo de aplicaciones (o ejecuta `iisreset`).
2. Si es una extensión, haz una petición a su URL.
3. Mira la carpeta: `MiServicio.upd` debe haberse convertido en `MiServicio.run` y, si había un `.run` anterior, ahora es `MiServicio.bak`.
4. Con la compilación **Debug**, abre `logs\MiServicio.dll.log`. El último arranque empieza en la última línea `====`. En orden, deberías ver:

```
==== Loader DLL dated 2026-11-04 23:35:59 ====
Process running as user "MiGrupo" ...
ReloadDLL: ShouldReload=True (child loaded=False, .upd exists=True, .upd blocked=False)
ReloadDLL: applying update (.upd -> .run, .run -> .bak)
ReloadDLL: LoadLibrary("...MiServicio.run") succeeded (module=$...)
ReloadDLL: child extension exports: GetExtensionVersion=True HttpExtensionProc=True TerminateExtension=True
ReloadDLL: child GetExtensionVersion -> True
```

y, por cada petición, `LOAD_HttpExtensionProc`, `entering, calling the child` y `served by the child -> result=... in ... ms`. Los mensajes del log están escritos en inglés.

La línea `====` indica la fecha de la DLL del cargador, así que sirve para saber qué compilación está desplegada. La línea del usuario indica la cuenta con la que corre el proceso: es la que necesita el permiso.

## 7. Actualizar

Para desplegar una versión nueva de tu DLL real:

1. Cópiala como `MiServicio.upd` en la misma carpeta.
2. En la siguiente petición pasado el intervalo de comprobación (10 s en Release, 500 ms en Debug), el cargador espera a poder abrir el fichero en exclusiva (para no cargar uno a medio copiar), descarga la versión actual, renombra `.run` a `.bak` y `.upd` a `.run`, y la carga.
3. Las peticiones que llegan mientras tanto esperan y las atiende la versión nueva.

**La actualización la aplica una petición normal, no `/test`.** La comprobación del `.upd` se hace al principio de cada petición *normal* (cualquiera que no sea `/test` ni `/update`), y solo cuando ha pasado el intervalo de comprobación desde la anterior. `/test` la atiende el cargador antes de esa comprobación, así que llamar a `/test` **nunca aplica** un `.upd` pendiente: solo avisa de que hay uno esperando. Si nadie llama a la DLL, el `.upd` espera hasta que llegue la primera petición normal (y esa petición es la que paga los ~5 segundos de la actualización).

Para aplicar un `.upd` pendiente de inmediato, sin esperar al intervalo ni a una petición normal, llama a **`/update`** desde el propio servidor (apartado «Peticiones especiales: `/test` y `/update`» más abajo).

Para volver a la versión anterior, para el grupo, renombra `MiServicio.bak` a `MiServicio.upd` (o a `.run`) y arráncalo de nuevo.

**Cómo se hace segura la descarga.** Descargar una DLL que tiene hilos propios (DMVCFramework, por ejemplo) puede provocar un interbloqueo de Windows: `FreeLibrary` toma el bloqueo del cargador de Windows mientras la DLL real se cierra, la DLL real espera a uno de sus hilos, y ese hilo, que está saliendo, necesita ese mismo bloqueo. Se vio en un volcado de `w3wp.exe`. Para evitarlo, el cargador, antes de llamar a `FreeLibrary`, llama al `TerminateExtension` de la DLL real y luego **espera hasta 3 segundos a que terminen solos los hilos que arrancaron dentro de la DLL real** (sin tener el bloqueo tomado, así que pueden salir). Solo si queda algún hilo vivo pasado ese tiempo lo termina a la fuerza, como último recurso. El log muestra líneas `uThreads: ...` con cuántos hilos quedaban y cuánto esperó.

**Qué identidad hace el trabajo.** IIS ejecuta `HttpExtensionProc` en hilos que suplantan a otro usuario (con autenticación anónima, normalmente `IUSR`), mientras que `GetExtensionVersion` y `TerminateExtension` corren con la identidad del grupo de aplicaciones. Un hilo que suplanta a `IUSR` no puede renombrar los ficheros, escribir el log ni abrir los hilos del hijo, y fallaba en silencio. Por eso el log nunca mostraba ninguna línea escrita desde una petición. El cargador hace por tanto la comprobación y la recarga **con la identidad del proceso (la del grupo)**: quita la suplantación del hilo, hace el trabajo y la vuelve a poner antes de devolver el control a IIS. Cuando tuvo que hacerlo, el log lo dice una vez con `NOTICE: the request thread was impersonating another user...`. La identidad del grupo es la que necesita *Modificar* sobre la carpeta (apartado 4.2); `IUSR` no.

Estado: la **parada** de IIS y la **actualización en caliente con IIS en marcha** están comprobadas en el servidor (2026-11-05, compilación Debug) con una DLL real de DMVCFramework que tiene hilos propios. En esa prueba, tras el `TerminateExtension` quedaban dos hilos de la DLL real vivos pasados los 3 segundos y hubo que terminarlos a la fuerza (`uThreads: forcibly terminating thread ...`); después `FreeLibrary` volvió en unos 30 ms, el `.upd` pasó a `.run`, se cargó la versión nueva y atendió la petición siguiente. La actualización completa tardó unos 5 segundos, durante los cuales las peticiones esperan. Si ves esas líneas `forcibly terminating`, avisa a quien mantenga la DLL real: debería parar esos hilos en su propio `TerminateExtension`, y entonces desaparece la espera de 3 segundos.

## 8. Parar y reiniciar

| Acción | Comando (administrador) |
|---|---|
| Parar / arrancar un grupo | `appcmd stop apppool /apppool.name:MiGrupo` y `appcmd start apppool /apppool.name:MiGrupo` |
| Reiniciar todo IIS | `iisreset` |
| Pararlo a la fuerza (último recurso) | `taskkill /F /IM w3wp.exe` |

`appcmd` está en `%windir%\system32\inetsrv`. Si `w3wp.exe` no termina, haz un volcado (Administrador de tareas > clic derecho en `w3wp.exe` > *Crear archivo de volcado*) para ver dónde se quedan sus hilos.

## 9. Solución de problemas

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| HTTP 500.0, error `0x8007007f`, controlador `ISAPI-dll` | IIS usa la DLL como extensión y no encuentra `GetExtensionVersion`. Típico al desplegar un cargador antiguo sin soporte de extensiones, o un fichero que no es el cargador. | Revisa la DLL de la carpeta: usa una compilación con soporte de extensiones. |
| HTTP 500.0, error `0x800700c1` («no es una aplicación Win32 válida») | Los bits no coinciden con el grupo. | Habilita *aplicaciones de 32 bits* en el grupo (apartado 5.3). |
| `RenameFile ... Windows error 5` (acceso denegado) en el log | La identidad del grupo no tiene permiso de Modificar en la carpeta. | Apartado 4.2. Sin él, el cargador sigue con el `.run` actual, anota `UPDATE BLOCKED` una vez e ignora ese `.upd` hasta que cambie. |
| El sitio se queda colgado («no responde») | Bucle de recarga, o la DLL real tarda en arrancar (conexión a la base de datos...). | Abre el log: `unloading the current child` repetido indica un bucle; revisa los permisos. |
| No hay carpeta `logs` ni log | Has desplegado una compilación Release, o la identidad no puede escribir en la carpeta. | Despliega la compilación Debug y revisa el permiso. |
| El `.upd` nunca se aplica | El fichero aún se está copiando (no se puede abrir en exclusiva), o la actualización está bloqueada. | Busca `CanAccessDLL` y `.upd blocked=True` en el log. |
| `w3wp.exe` no termina al parar | Interbloqueo al descargar la DLL real. | Usa la compilación actual, que no la descarga al apagar. Si persiste, haz un volcado. |
| Tras reiniciar IIS no carga nada y solo existe un `.run` | Corregido: una compilación antigua exigía un `.upd`. | Usa la compilación actual. |

## 10. Lista de comprobación

- [ ] Compilada la **configuración correcta** (Debug para diagnosticar, Release para el servidor) para **Win32**.
- [ ] La carpeta tiene el cargador renombrado a `MiServicio.dll` y la DLL real como `MiServicio.upd` o `MiServicio.run`.
- [ ] La identidad del grupo tiene **Modificar** sobre la carpeta.
- [ ] El grupo tiene **Habilitar aplicaciones de 32 bits = True**.
- [ ] Extensión: aplicación creada, permiso *Ejecutar* en la asignación de controlador y DLL permitida en *Restricciones ISAPI y CGI*. Filtro: agregado en *Filtros ISAPI* del sitio.
- [ ] Tras la primera petición, el `.upd` se ha convertido en `.run` y, con Debug, el log muestra `child GetExtensionVersion -> True`.
- [ ] La actualización en caliente se ha probado en un servidor de pruebas antes de usarla en producción.

## Peticiones especiales: `/test` y `/update`

Cuando el cargador se usa como extensión, atiende él mismo dos peticiones especiales, **sin pasárselas a tu DLL real**. Las dos solo funcionan **desde el propio servidor** (127.0.0.1 o ::1); desde otro equipo devuelven 403.

| Petición | Qué hace | ¿Aplica un `.upd` pendiente? |
|---|---|---|
| `…/MiServicio.dll/test` | Comprueba que IIS no sirve `.run`, `.upd` y `.bak`, e **informa de si hay un `.upd` pendiente** | **No** |
| `…/MiServicio.dll/update` | Aplica el `.upd` ahora, si lo hay | **Sí**, sin esperar al intervalo |
| cualquier otra petición | La atiende tu DLL real | Sí, si ha pasado el intervalo de comprobación |

**Idioma.** Las dos responden en **inglés por defecto**, y en castellano cuando la petición lo pide: según el idioma del navegador (la cabecera `Accept-Language`, si el castellano tiene prioridad sobre el inglés) o añadiendo `?lang=es` (o `?lang=en`) a la URL. Si no se puede saber el idioma, se usa el inglés. El log que escribe la compilación Debug está siempre en inglés.

**Formato de la salida.** Abiertos en un **navegador**, `/test` y `/update` responden con una página HTML con estilo (un banner de color con el resultado —verde, ámbar, rojo o azul—, una tabla con el estado de cada fichero y un botón para aplicar la actualización o para comprobar el estado). Para **scripts y Postman** responden en texto plano. El formato se elige según la cabecera `Accept` de la petición (`text/html` da la página); se puede forzar añadiendo `?format=text` o `?format=html` a la URL. Ninguno de los dos formatos muestra la ruta de la DLL en el disco.

**Leer el resultado desde un script.** El texto está traducido, así que un script no debería analizarlo. Cada respuesta lleva una cabecera con un **código estable en inglés, igual en todos los idiomas**:

| Cabecera | Valores |
|---|---|
| `X-FilterLoader-Result` | `/test`: `OK`, `UNSAFE`, `INCOMPLETE`. `/update`: `UPDATED`, `NONE`, `NOT_APPLIED`, `BLOCKED`, `ERROR` |
| `X-FilterLoader-Pending` | Solo `/test`: `yes` si hay un `.upd` esperando, `no` si no |

Se incluye una [colección de Postman](FilterLoader.postman_collection.json) con las tres peticiones: impórtala en Postman (*Import*), cambia la variable `baseUrl` por la URL de tu DLL y ejecuta Postman en el servidor.

### `/update`: aplicar la actualización ahora

```
http://localhost/WebService/MiServicio.dll/update
```

Responde con una línea `RESULTADO: ...` (`RESULT: ...` en inglés) y un estado HTTP que puede aprovechar un script de despliegue:

| `X-FilterLoader-Result` | HTTP | Texto (EN / ES) | Significado |
|---|---|---|---|
| `UPDATED` | 200 | `UPDATED` / `ACTUALIZADO` | Se aplicó el `.upd`; la versión nueva está cargada (indica cuántos ms tardó). |
| `NONE` | 200 | `NO UPDATE` / `SIN ACTUALIZACION` | No hay `.upd`; no hay nada que hacer. |
| `NOT_APPLIED` | 409 | `NOT APPLIED` / `NO APLICADA` | El `.upd` sigue ahí: aún se está copiando o está abierto en otro programa. Vuelve a llamar a `/update` más tarde. |
| `BLOCKED` | 409 | `BLOCKED` / `BLOQUEADA` | No se pudo renombrar, normalmente por falta de permiso de *Modificar* de la identidad del grupo sobre la carpeta (apartado 4.2). Se sigue con la versión actual. |
| `ERROR` | 409 | `ERROR` | Fallo inesperado; ver el log (compilación Debug). |

Un despliegue típico es, por tanto: copiar el nuevo `MiServicio.upd`, llamar a `/update` y comprobar `X-FilterLoader-Result: UPDATED` (o HTTP 200).

### `/test`: autocomprobación y actualización pendiente

Además de la comprobación de ficheros que se describe abajo, `/test` añade una línea que dice si hay una actualización pendiente. En castellano:

```
Actualizacion pendiente: SI - existe MiServicio.upd (9341952 bytes, 2026-11-05 09:00:12).
  Para aplicarla ahora, llama a /update.
  Esta peticion /test solo informa, no la aplica. Si no llamas a /update, se aplicara en la
  primera peticion normal (que no sea /test ni /update) pasado el intervalo de comprobacion (10000 ms).
```

o, cuando no hay nada esperando:

```
Actualizacion pendiente: no (no existe MiServicio.upd).
  Cuando haya un .upd, llama a /update para aplicarlo.
```

(En inglés: `Pending update: YES - ... exists` / `Pending update: no (... does not exist)`.) En resumen: **para aplicar una actualización, llama a `/update`**; `/test` solo informa.

## Comprobar que IIS no sirve los ficheros `.run`, `.upd` y `.bak`

Si el cargador se usa como extensión, llámalo con `/test` **desde el propio servidor**:

```
http://localhost/WebService/MiServicio.dll/test
```

El cargador crea en la carpeta tres ficheros de prueba inofensivos (`__probe_<id>.run`, `.upd` y `.bak`), los pide a IIS por HTTP, los borra y responde en texto plano. Por cada extensión indica si IIS no la sirve (correcto), si la **descarga** (peligro: hay un tipo MIME o manejador que la sirve) o si no se pudo comprobar. La petición no llega a la DLL hija, y las que no vienen de 127.0.0.1 o ::1 reciben 403. No se usa la DLL real.
