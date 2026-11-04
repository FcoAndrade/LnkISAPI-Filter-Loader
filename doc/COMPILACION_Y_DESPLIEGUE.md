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
==== Cargador de fecha 2026-11-04 23:35:59 ====
Proceso ejecutandose como usuario "MiGrupo" ...
ReloadDLL: ShouldReload=True (hijo cargado=False, .upd existe=True, .upd bloqueado=False)
ReloadDLL: aplicando actualizacion (.upd -> .run, .run -> .bak)
ReloadDLL: LoadLibrary("...MiServicio.run") correcto
ReloadDLL: exportaciones de extension del hijo: GetExtensionVersion=True HttpExtensionProc=True TerminateExtension=True
ReloadDLL: GetExtensionVersion del hijo -> True
```

y, por cada petición, `LOAD_HttpExtensionProc`, `entrada, llamando al hijo` y `atendida por el hijo -> resultado=... en ... ms`.

La línea `====` indica la fecha de la DLL del cargador, así que sirve para saber qué compilación está desplegada. La línea del usuario indica la cuenta con la que corre el proceso: es la que necesita el permiso.

## 7. Actualizar

Para desplegar una versión nueva de tu DLL real:

1. Cópiala como `MiServicio.upd` en la misma carpeta.
2. En la siguiente petición pasado el intervalo de comprobación (10 s en Release, 500 ms en Debug), el cargador espera a poder abrir el fichero en exclusiva (para no cargar uno a medio copiar), descarga la versión actual, renombra `.run` a `.bak` y `.upd` a `.run`, y la carga.
3. Las peticiones que llegan mientras tanto esperan y las atiende la versión nueva.

Para volver a la versión anterior, para el grupo, renombra `MiServicio.bak` a `MiServicio.upd` (o a `.run`) y arráncalo de nuevo.

**Importante sobre la actualización en caliente.** Descargar una DLL que tiene hilos propios (DMVCFramework, por ejemplo) puede provocar un interbloqueo de Windows: la DLL real espera a sus hilos, y esos hilos necesitan el bloqueo del cargador de Windows que la descarga tiene tomado. Se observó al **parar IIS** y se corrigió no descargando la DLL real al apagar. La actualización **con el grupo en marcha** sí descarga la DLL real y **no se ha comprobado** con una DLL así. Pruébala antes en un servidor de pruebas donde puedas matar `w3wp.exe`. Si se cuelga, la alternativa segura es actualizar parando y arrancando el grupo.

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
| `RenameFile ... error de Windows 5 - Acceso denegado` en el log | La identidad del grupo no tiene permiso de Modificar en la carpeta. | Apartado 4.2. Sin él, el cargador sigue con el `.run` actual, anota `ACTUALIZACION BLOQUEADA` una vez e ignora ese `.upd` hasta que cambie. |
| El sitio se queda colgado («no responde») | Bucle de recarga, o la DLL real tarda en arrancar (conexión a la base de datos...). | Abre el log: `descargando el hijo actual` repetido indica un bucle; revisa los permisos. |
| No hay carpeta `logs` ni log | Has desplegado una compilación Release, o la identidad no puede escribir en la carpeta. | Despliega la compilación Debug y revisa el permiso. |
| El `.upd` nunca se aplica | El fichero aún se está copiando (no se puede abrir en exclusiva), o la actualización está bloqueada. | Busca `CanAccessDLL` y `.upd bloqueado=True` en el log. |
| `w3wp.exe` no termina al parar | Interbloqueo al descargar la DLL real. | Usa la compilación actual, que no la descarga al apagar. Si persiste, haz un volcado. |
| Tras reiniciar IIS no carga nada y solo existe un `.run` | Corregido: una compilación antigua exigía un `.upd`. | Usa la compilación actual. |

## 10. Lista de comprobación

- [ ] Compilada la **configuración correcta** (Debug para diagnosticar, Release para el servidor) para **Win32**.
- [ ] La carpeta tiene el cargador renombrado a `MiServicio.dll` y la DLL real como `MiServicio.upd` o `MiServicio.run`.
- [ ] La identidad del grupo tiene **Modificar** sobre la carpeta.
- [ ] El grupo tiene **Habilitar aplicaciones de 32 bits = True**.
- [ ] Extensión: aplicación creada, permiso *Ejecutar* en la asignación de controlador y DLL permitida en *Restricciones ISAPI y CGI*. Filtro: agregado en *Filtros ISAPI* del sitio.
- [ ] Tras la primera petición, el `.upd` se ha convertido en `.run` y, con Debug, el log muestra `GetExtensionVersion del hijo -> True`.
- [ ] La actualización en caliente se ha probado en un servidor de pruebas antes de usarla en producción.
