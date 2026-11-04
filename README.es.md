# LnkISAPI-Filter-Loader

[English](README.md) | **Español**

ISAPI Filter Loader (carga una DLL ISAPI en caliente).
Código original de Daniel "sakura" Wischnewski

Cargador escrito en Delphi que funciona tanto como **filtro** ISAPI de IIS como **extensión** ISAPI, y que carga y descarga **otro filtro o extensión ISAPI en caliente**, de modo que se puede desplegar una versión nueva sin parar ni reiniciar IIS.

## Descripción

¿Cómo funciona? (traducción de la descripción original del autor; el texto original, en inglés, está en [README.md](README.md))

Al configurar el filtro ISAPI de tu sitio web, en lugar de desplegar tu extensión ISAPI despliegas la mía. Renombra mi extensión para que coincida con el nombre de tu DLL. Si tu DLL se llama `AlgunaExtensionISAPI.dll`, la mía también debe llamarse `AlgunaExtensionISAPI.dll`.

Ahora renombra tu extensión ISAPI a `AlgunaExtensionISAPI.upd` (de *update*, actualización). Cuando IIS envíe la siguiente petición a mi extensión, buscará tu actualización. La renombrará a `AlgunaExtensionISAPI.run`, la cargará en memoria y le pasará todas las peticiones.

Cuando tengas otra actualización, cópiala como `AlgunaExtensionISAPI.upd` en el mismo directorio. En menos de 10 segundos (por defecto, o 500 ms en modo depuración) mi extensión buscará la actualización. Si la encuentra, descargará la extensión actual y la renombrará a `AlgunaExtensionISAPI.bak`, renombrará la tuya a `AlgunaExtensionISAPI.run` y la cargará. Desde ese momento tu versión nueva atenderá todas las peticiones. NOTA: este proceso puede tardar hasta un minuto. Todas las llamadas entrantes se encolan y se pasan a la versión nueva en cuanto está cargada.

Creé esta pequeña herramienta como ocurrencia de última hora. Resultó que Egg-Loader sirve para extensiones y no para filtros. Espero que también te guste. Hay cosas que se pueden mejorar para depurar, y ¡no está pensada para servicios en producción!

## El problema que resuelve

IIS carga un filtro ISAPI una sola vez y mantiene bloqueado su fichero DLL. Para sustituirlo hay que parar el sitio o el grupo de aplicaciones, copiar la DLL y volver a arrancar. Durante el desarrollo esto es muy incómodo. Este cargador se instala en IIS como si fuera el filtro y es él quien carga el filtro real, así que el fichero que IIS tiene bloqueado nunca cambia.

## Ciclo de vida de los ficheros

Todos los ficheros están en la misma carpeta y comparten el nombre base del cargador (`MiFiltro` en el ejemplo).

| Fichero | Qué es |
|---|---|
| `MiFiltro.dll` | El cargador (este proyecto), renombrado. Es lo que registra IIS. |
| `MiFiltro.upd` | Tu filtro real, pendiente de activar. Es lo que tú copias. |
| `MiFiltro.run` | Tu filtro real en ejecución, cargado en memoria. |
| `MiFiltro.bak` | Copia de la versión anterior (se sobrescribe en cada actualización). |

Cuando aparece un `.upd`, el cargador hace esto:

1. Espera a poder abrir el `.upd` en exclusiva, para no cargarlo mientras aún se está copiando.
2. Si ya había un filtro cargado, llama a su `TerminateFilter` y lo descarga con `FreeLibrary`.
3. Borra el `.bak` anterior, renombra `.run` a `.bak` y `.upd` a `.run`.
4. Carga el `.run` con `LoadLibrary`, localiza `GetFilterVersion`, `HttpFilterProc` y `TerminateFilter`, y guarda los flags de notificación que pide el filtro.

## Instalación y uso

> Para la guía completa paso a paso (compilación, configuración de IIS, permisos, comprobaciones y solución de problemas) consulta el **[manual de compilación y despliegue](doc/COMPILACION_Y_DESPLIEGUE.md)** ([English](doc/BUILD_AND_DEPLOY.md)). Lo que sigue es un resumen.

1. Compila el cargador (ver más abajo) o usa [bin/FilterLoader.dll](bin/FilterLoader.dll).
2. Cópialo a la carpeta del sitio con **el mismo nombre que tu filtro**, por ejemplo `MiFiltro.dll`.
3. Registra `MiFiltro.dll` en IIS igual que registrarías la DLL real:
   - **Filtro:** añádelo en *Filtros ISAPI* del sitio.
   - **Extensión:** no hay nada que registrar; se llama por URL (por ejemplo `http://servidor/WebService/MiFiltro.dll/estado`), con la asignación de controlador y la restricción ISAPI que ya necesitara tu DLL real.

   El cargador exporta los dos conjuntos de puntos de entrada, así que la misma DLL sirve en cualquiera de los dos papeles. Lo que importa es qué es tu DLL real.
4. Copia tu filtro o extensión real como `MiFiltro.upd` en la misma carpeta. Si ya hay un `MiFiltro.run` (por ejemplo, tras reiniciar IIS), se carga sin necesidad de un `.upd`.
5. En la siguiente petición, el cargador lo activará. **La identidad del grupo de aplicaciones (`IIS AppPool\<nombre del grupo>`) necesita permiso de *Modificar* en esa carpeta**, porque el cargador renombra y borra ficheros ahí. Sin él, los renombrados fallan con «Acceso denegado» (error 5); el cargador sigue entonces con el `.run` actual, lo anota una vez en el log e ignora ese `.upd` hasta que cambie.
6. Para cada versión nueva, copia otra vez un `MiFiltro.upd`.

## Estructura del repositorio

| Ruta | Contenido |
|---|---|
| [src/FilterLoader.dpr](src/FilterLoader.dpr) | Proyecto `library`. Exporta los tres puntos de entrada ISAPI y delega en el cargador, capturando cualquier excepción. |
| [src/uLoader.pas](src/uLoader.pas) | Interfaz `IFilterLoader` y clase `TFilterLoader` con toda la lógica de recarga. |
| [src/uLog.pas](src/uLog.pas) | Log de depuración (solo activo en la configuración Debug). |
| `src/FilterLoader.dproj`, `.bdsproj`, `.res`, `.ico` | Ficheros de proyecto de Delphi, recursos e icono. |
| [bin/FilterLoader.dll](bin/FilterLoader.dll) | DLL ya compilada (32 bits). |
| [doc/COMPILACION_Y_DESPLIEGUE.md](doc/COMPILACION_Y_DESPLIEGUE.md) | Manual de compilación y despliegue en IIS ([versión en inglés](doc/BUILD_AND_DEPLOY.md)). |
| [Tareas.md](Tareas.md) | Tareas pendientes y realizadas. |

## Cómo funciona por dentro

- **Puntos de entrada:** `GetFilterVersion`, `HttpFilterProc` y `TerminateFilter` (contrato de filtro), y `GetExtensionVersion`, `HttpExtensionProc` y `TerminateExtension` (contrato de extensión). El cargador expone los seis y los reenvía a la DLL cargada, sea del tipo que sea.
- **Extensiones:** cuando el hijo es una extensión, el cargador llama una sola vez a su `GetExtensionVersion`, justo al cargarlo, y guarda la información de versión. Cuando IIS llama al `GetExtensionVersion` del cargador, se le devuelve esa información guardada sin volver a llamar al hijo, porque algunas extensiones (WebBroker, DMVCFramework) se inicializan ahí. `HttpExtensionProc` mantiene el bloqueo de lectura durante toda la llamada, así que una recarga espera a las peticiones en curso. Al descargar, el hijo recibe `TerminateExtension(HSE_TERM_MUST_UNLOAD)`.
- **Concurrencia:** dos `TMultiReadExclusiveWriteSynchronizer`.
  - `FDLLSync` protege los punteros al filtro cargado. Cada petición toma lectura y la recarga toma escritura, así que nadie usa la DLL mientras se descarga.
  - `FCheckSync` evita que varios hilos comprueben el `.upd` a la vez.
- **Frecuencia de comprobación:** `DoUpdateIfNeeded` se ejecuta en cada petición, pero solo mira si existe el `.upd` cuando han pasado `WAIT_BEFORE_CHECK` milisegundos desde la última vez: 10.000 por defecto y 500 si se compila con `DEBUG`.
- **Filtrado de notificaciones:** tras cargar el filtro hijo se leen sus `dwFlags`. `HttpFilterProc` solo le pasa las notificaciones que él pidió y, para el resto, devuelve `SF_STATUS_REQ_NEXT_NOTIFICATION`.
- **Rutas de los ficheros:** se obtienen del nombre del propio módulo (`GetModuleFileNameW`) cambiando la extensión.
- **Tolerancia a fallos:** si el filtro hijo lanza una excepción, el cargador la captura y deja pasar la petición.

## Compilación

Instrucciones completas, con la línea de comandos y el despliegue en IIS: [manual de compilación y despliegue](doc/COMPILACION_Y_DESPLIEGUE.md) ([English](doc/BUILD_AND_DEPLOY.md)).

- Proyecto de **Delphi**: abre [src/FilterLoader.dproj](src/FilterLoader.dproj) en el IDE y compila.
- Usa la unidad `ISAPI2`, que trae Delphi.
- La configuración **Debug** define el símbolo `DEBUG`: reduce el intervalo de comprobación a 500 ms y activa el log (ver abajo). Además compila con información de depuración completa (símbolos locales, referencias de símbolos, DCU de depuración), un fichero de mapa detallado (`FilterLoader.map`, útil para resolver direcciones de fallo en `w3wp.exe` con WinDbg) y aserciones en ejecución, con la optimización desactivada y los marcos de pila activados. La configuración **Release** no incluye nada de esto.
- **Carpetas de salida:** cada configuración tiene la suya: la DLL va a `bin\Debug\` o `bin\Release\` (la de Debug lleva además su `.map`), y los `.dcu` a `src\Win32\Debug\` o `src\Win32\Release\`. Ya no se pisan entre sí.
- **Bits:** hoy el proyecto compila **solo en 32 bits** (`Win32` está activa y `Win64` no; la DLL ya compilada es x86). Un grupo de aplicaciones de IIS de 64 bits solo carga filtros ISAPI de 64 bits, así que con esta DLL hay que activar «Habilitar aplicaciones de 32 bits» en el grupo. El cargador y el filtro hijo deben tener los mismos bits. Hay prevista una versión de 64 bits (ver [Tareas.md](Tareas.md)).

## Log de depuración

Con la configuración Debug, el cargador escribe un log en la carpeta `logs` que cuelga de la de la DLL, con el mismo nombre que la DLL más `.log` (por ejemplo `logs\MiFiltro.dll.log`). La carpeta se crea si no existe; si no se puede crear, el log va a la propia carpeta de la DLL. Cada línea lleva fecha y hora, el identificador de proceso y de hilo, y el mensaje:

```
2026-11-04 22:10:31.532 [4128:5512] ReloadDLL: ShouldReload=True (hijo cargado=False, .upd existe=True)
```

Se registra la creación y destrucción del cargador, cada decisión de recarga, el resultado de los renombrados, `LoadLibrary` con su error de Windows, las exportaciones y los flags del filtro hijo, las excepciones, y cada notificación (si se reenvió al hijo o no) con su resultado. Los mensajes están escritos en castellano.

- La identidad del grupo de aplicaciones de IIS necesita **permiso de escritura** en la carpeta del filtro (para crear `logs` y escribir en ella). Si no lo tiene, no se crea el fichero (no da error).
- El fichero rota a `.log.old` al pasar de 2 MB.
- Los mismos mensajes salen por `OutputDebugString`, así que también se ven con DebugView.
- En Release el log no existe: las rutinas están vacías.
- El log por notificación hace mucho ruido: es solo para depurar.

## Limitaciones

- **No está pensado para producción**, solo para desarrollo y depuración, como avisa el autor original.
- IIS llama a `GetFilterVersion` una sola vez. Si la versión nueva del filtro cambia sus flags o su configuración inicial, hay que reiniciar IIS. El cargador sí actualiza internamente los flags que usa para filtrar.
- Si el `.upd` no se puede cargar, o no existe el `.run`, el filtro queda inactivo y deja pasar todas las peticiones sin avisar (en compilaciones Debug, el log indica el motivo).
- El `.bak` solo guarda la versión inmediatamente anterior.
- Las extensiones que responden de forma asíncrona (`HSE_STATUS_PENDING`) pueden seguir ejecutándose cuando una recarga las descarga. El cargador solo protege la duración de la propia llamada a `HttpExtensionProc`.
- Los nombres de fichero son `.upd`, `.run` y `.bak`. Otros cargadores usan nombres distintos (por ejemplo `.new`, `.update` o `.backup`), así que este ignora los ficheros con esos nombres.

## Problemas conocidos y mejoras propuestas

Resultado de revisar el código. El seguimiento está en [Tareas.md](Tareas.md). Nada de lo siguiente está corregido todavía, salvo el log de depuración.

### Errores

1. **Desbordamiento de búfer en las rutas** ([src/uLoader.pas](src/uLoader.pas), `GetLongFileName` y `GetModuleName`): se pasa `SizeOf(Buffer)` (bytes) donde las API de Windows esperan el tamaño en caracteres, y el búfer de `GetLongFileName` no se inicializa.
2. **`TerminateFilter` no libera el cargador** ([src/FilterLoader.dpr](src/FilterLoader.dpr)): `gFilterLoader` sigue vivo, y el `FreeLibrary` del filtro hijo se ejecuta al descargarse la DLL, dentro del bloqueo del cargador de Windows.
3. **`pVer` sin inicializar al llamar al hijo (filtros)**: `ReloadDLL` usa una variable local con basura, y en la primera carga el hijo recibe `GetFilterVersion` dos veces. (Las extensiones no tienen este problema: ver «Cómo funciona por dentro».)
4. **Una versión nueva defectuosa deja el filtro inactivo sin aviso**: no se comprueba el resultado de los renombrados y, si `LoadLibrary` falla, no se restaura el `.bak`.

### Mejoras

1. Devolver a IIS todas las notificaciones y filtrar en el cargador, para no tener que reiniciar IIS cuando la versión nueva pide otras.
2. Documentar que las conexiones keep-alive pueden conservar un contexto (`pFilterContext`) creado por la versión anterior.
3. Documentar que varios procesos de trabajo (web garden o reciclado solapado) bloquean el `.run` y el renombrado falla.
4. Menores: usar `GetTickCount64`, evitar los dos bloqueos por petición en la comprobación rápida, sustituir `TFileStream` por `CreateFile` en `CanAccessDLL` y quitar la directiva `export` obsoleta.
5. Crear una versión de 64 bits del cargador (ver [Compilación](#compilación)).

### Seguridad

Quien pueda escribir en la carpeta del filtro puede ejecutar código dentro de `w3wp.exe` dejando un `.upd`. Es aceptable para desarrollo, no para producción.

## Licencia y créditos

Código original de Daniel "sakura" Wischnewski (25 de agosto de 2006), publicado bajo la **GNU Lesser General Public License** versión 2.1 o posterior. Ver http://www.gnu.org/copyleft/lgpl.html.

## Web

http://delphi-notes.blogspot.com/
