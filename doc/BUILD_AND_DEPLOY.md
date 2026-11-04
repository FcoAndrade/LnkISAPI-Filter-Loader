# Build and IIS deployment manual

**English** | [Español](COMPILACION_Y_DESPLIEGUE.md)

How to build the loader with Delphi and deploy it on IIS, either as an ISAPI **extension** (called by URL) or as an ISAPI **filter** (registered on the site). For what the loader is and how it works, see the [README](../README.md).

## 1. Before you start

### 1.1 Which role do you need?

The same DLL exports the entry points of both roles. What decides how you use it is **what your real DLL is**:

| Your real DLL is... | You use the loader as... | How IIS reaches it |
|---|---|---|
| An ISAPI **extension** (a web service, a WebBroker or DMVCFramework application...) | Extension | By URL, e.g. `http://server/WebService/MyService.dll/status` |
| An ISAPI **filter** | Filter | Registered in *ISAPI Filters* of the site; it is not opened in a browser |

If you open a filter's URL in the browser, or register an extension as a filter, IIS fails. A frequent symptom is HTTP 500.0 with error `0x8007007f` ("procedure not found"): the DLL does not export what IIS asks for in that role.

### 1.2 The names in this manual

All files live in the same folder and share the base name of the loader. This manual uses `MyService`:

| File | What it is | Who puts it there |
|---|---|---|
| `MyService.dll` | The loader, renamed | You, once |
| `MyService.upd` | Your real DLL, waiting to be activated | You, on every update |
| `MyService.run` | Your real DLL, running | The loader |
| `MyService.bak` | The previous version | The loader |
| `logs\MyService.dll.log` | The debug log (Debug build only) | The loader |

The loader only understands `.upd`, `.run` and `.bak`. Files with other names used by other loaders (`.new`, `.update`, `.backup`) are ignored.

## 2. Requirements

| | |
|---|---|
| To build | Delphi (RAD Studio) 10.3 or later, with the Win32 compiler. Verified with the 10.3 compiler (version 33.0, `Studio\20.0`). |
| To deploy | Windows with IIS and the *ISAPI Extensions* feature (for the extension role) and/or *ISAPI Filters* (for the filter role). |
| Bitness | The loader is **32-bit only** for now. See [section 5.3](#53-32-bit-application-pool). |

To check or install the IIS features: *Control Panel > Programs > Turn Windows features on or off > Internet Information Services > World Wide Web Services > Application Development Features* and tick *ISAPI Extensions* and/or *ISAPI Filters*.

## 3. Building

### 3.1 Configurations

The project is [`src/FilterLoader.dproj`](../src/FilterLoader.dproj). It has two configurations:

| | Debug | Release |
|---|---|---|
| Symbol `DEBUG` | Yes | No (`RELEASE`) |
| Debug log (`logs\<name>.dll.log`) | **Yes** | No |
| Update check interval | 500 ms | 10 s |
| Debug information and detailed `.map` file | **Yes** | No |
| Runtime assertions | Yes | No |
| Output folder | `bin\Debug\` | `bin\Release\` |

Use **Debug** while you are diagnosing a problem or developing, and **Release** for a stable server: it does not write a log on every request.

The `.dcu` files go to `src\Win32\Debug\` or `src\Win32\Release\`.

### 3.2 From the IDE

1. Open `src/FilterLoader.dproj`.
2. In the Project Manager, select the **configuration** (Debug or Release) and the **Windows 32-bit** target. The project's default configuration may be Release: check it before building.
3. *Project > Build FilterLoader*.
4. The DLL is in `bin\Debug\FilterLoader.dll` or `bin\Release\FilterLoader.dll`.

### 3.3 From the command line

From a command prompt, in the repository root (adjust the path of your Studio version):

```
call "C:\Program Files (x86)\Embarcadero\Studio\20.0\bin\rsvars.bat"
msbuild src\FilterLoader.dproj /t:Build /p:Config=Debug   /p:Platform=Win32
msbuild src\FilterLoader.dproj /t:Build /p:Config=Release /p:Platform=Win32
```

`rsvars.bat` sets up the Delphi environment. A successful build prints something like `NNN lines, N seconds, ... bytes code`.

### 3.4 What you get

| Build | Files in the output folder |
|---|---|
| Debug | `FilterLoader.dll`, `FilterLoader.map` (detailed map, useful with WinDbg to resolve crash addresses), `FilterLoader.drc` |
| Release | `FilterLoader.dll` |

The repository versions the contents of `bin\` (the compiled builds), so after recompiling Git will show them as modified.

### 3.5 Module version

The version information of the DLL (file version and product version) is defined **once**, in the `Base` section of the `.dproj`, so both configurations share it. Change it in *Project > Options > Version Info* or in the `VerInfo_*` keys of `Base`.

## 4. Preparing the server

### 4.1 The folder

Create a folder for the application, for example `C:\ISAPI\MyService`, and copy there:

1. The loader, **renamed** to `MyService.dll` (pick the Debug or Release build).
2. Your real DLL as `MyService.upd`.
3. Any file your real DLL needs (`.ini`, database client libraries...).

If your real DLL comes with its own configuration file named after it (for example `MyService.ini`), keep that name: it is looked up next to the real DLL.

### 4.2 Permissions on the folder

The loader renames and deletes files in that folder, so the account that runs the application pool needs **Modify** permission on it. Without it the renames fail with "Access denied" (Windows error 5).

First, find out the application pool and its identity (section 5.1). With the usual `ApplicationPoolIdentity`, the account is `IIS AppPool\<pool name>`. In an administrator console:

```
icacls "C:\ISAPI\MyService" /grant "IIS AppPool\MyPool":(OI)(CI)M /T
```

`(OI)(CI)` makes subfolders and files inherit it, and `/T` applies it to what already exists. From the graphical interface: folder *Properties > Security > Edit > Add*, select the **computer name** under *Locations*, type `IIS AppPool\MyPool`, and tick *Modify*.

If you use the Debug build, the same permission lets the loader create the `logs` folder and write the log.

## 5. IIS configuration

### 5.1 The application pool

1. Open the IIS Manager (`inetmgr`).
2. Go to *Application Pools*. Create one for this application or reuse an existing one. Its name is what goes in the permission command above.
3. In *Advanced Settings*, check *Identity* (normally `ApplicationPoolIdentity`).

From the command line (administrator), `%windir%\system32\inetsrv\appcmd list app` shows the pool of each application and `appcmd list apppool` lists the pools.

### 5.2 Which pool serves an application

Select the application in *Sites* and open *Basic Settings...*: the **Application pool** is shown there.

### 5.3 32-bit application pool

A 64-bit pool (the default) only loads 64-bit ISAPI DLLs. As the loader and your real DLL are 32-bit:

1. *Application Pools* > select the pool > *Advanced Settings...*
2. Set **Enable 32-Bit Applications** to `True`.

The loader and your real DLL must have **the same bitness**: a 32-bit DLL cannot load a 64-bit one, or the other way around.

### 5.4 Option A: deploy as an extension

1. In IIS, create an application (*Sites > your site > Add Application...*) whose physical path is the folder from section 4.1, for example alias `WebService` and path `C:\ISAPI\MyService`. Assign it the pool from section 5.1.
2. Select that application and open **Handler Mappings**. The *ISAPI-dll* mapping must be enabled. Then click *Edit Feature Permissions...* and tick **Execute** (in addition to *Read* and *Script*).
3. At server level, open **ISAPI and CGI Restrictions**, click *Add...*, enter the full path to the loader (`C:\ISAPI\MyService\MyService.dll`) and tick *Allow extension path to execute*.
4. Call it from the browser: `http://localhost/WebService/MyService.dll/status`. Everything after the DLL name is passed to your real extension.

### 5.5 Option B: deploy as a filter

1. Select the **site** and open **ISAPI Filters**.
2. *Add...*, give it a name, and in *Executable* enter the path to the loader (`C:\ISAPI\MyService\MyService.dll`).
3. Make sure the pool is 32-bit (section 5.3).

IIS loads a filter once, when the application pool starts. A filter has no URL of its own.

## 6. First start and checks

1. Stop and start the application pool (or run `iisreset`).
2. For an extension, make a request to its URL.
3. Check the folder: `MyService.upd` should have turned into `MyService.run`, and if there was a previous `.run` it is now `MyService.bak`.
4. With the **Debug** build, open `logs\MyService.dll.log`. The latest start begins at the last `====` line. In order, you should see:

```
==== Cargador de fecha 2026-11-04 23:35:59 ====
Proceso ejecutandose como usuario "MyPool" ...
ReloadDLL: ShouldReload=True (hijo cargado=False, .upd existe=True, .upd bloqueado=False)
ReloadDLL: aplicando actualizacion (.upd -> .run, .run -> .bak)
ReloadDLL: LoadLibrary("...MyService.run") correcto
ReloadDLL: exportaciones de extension del hijo: GetExtensionVersion=True HttpExtensionProc=True TerminateExtension=True
ReloadDLL: GetExtensionVersion del hijo -> True
```

and, for every request, `LOAD_HttpExtensionProc`, `entrada, llamando al hijo` and `atendida por el hijo -> resultado=... en ... ms`. The messages are written in Spanish.

The `====` line shows the date of the loader DLL, so you can tell which build is deployed. The user line shows the account the process runs as: that is the one that needs the permission.

## 7. Updating

To deploy a new version of your real DLL:

1. Copy it as `MyService.upd` into the same folder.
2. On the next request after the check interval (10 s in Release, 500 ms in Debug), the loader waits until it can open the file exclusively (so it does not load a half-copied file), unloads the current version, renames `.run` to `.bak` and `.upd` to `.run`, and loads it.
3. Requests that arrive meanwhile wait and are served by the new version.

To go back to the previous version, stop the pool, rename `MyService.bak` to `MyService.upd` (or to `.run`) and start it again.

**Important about the hot update.** Unloading a DLL that has its own threads (DMVCFramework, for example) can deadlock Windows: the real DLL waits for its threads, and those threads need the Windows loader lock that the unload holds. This was seen when **stopping IIS** and fixed by not unloading the real DLL on shutdown. The update **while the pool keeps running** unloads the real DLL and has **not been proven** with such a DLL. Try it first on a test server where you can kill `w3wp.exe`. If it hangs, the safe alternative is to update by stopping and starting the pool.

## 8. Stopping and restarting

| Action | Command (administrator) |
|---|---|
| Stop / start one pool | `appcmd stop apppool /apppool.name:MyPool` and `appcmd start apppool /apppool.name:MyPool` |
| Restart all IIS | `iisreset` |
| Stop it hard (last resort) | `taskkill /F /IM w3wp.exe` |

`appcmd` is in `%windir%\system32\inetsrv`. If `w3wp.exe` does not end, make a dump (Task Manager > right-click on `w3wp.exe` > *Create dump file*) to see where its threads are stuck.

## 9. Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| HTTP 500.0, error `0x8007007f`, handler `ISAPI-dll` | IIS uses the DLL as an extension and does not find `GetExtensionVersion`. Typical when an old loader without extension support is deployed, or the file is not the loader. | Check the DLL in the folder: use a build with extension support. |
| HTTP 500.0, error `0x800700c1` ("not a valid Win32 application") | Bitness mismatch with the pool. | Enable *32-Bit Applications* on the pool (section 5.3). |
| `RenameFile ... error de Windows 5 - Acceso denegado` in the log | The pool identity lacks Modify permission on the folder. | Section 4.2. Without it the loader keeps running the current `.run`, logs `ACTUALIZACION BLOQUEADA` once, and ignores that `.upd` until it changes. |
| The site hangs ("does not respond") | Reload loop, or the real DLL is slow to start (database connection...). | Open the log: repeated `descargando el hijo actual` means a loop; check the permissions. |
| No `logs` folder or no log | You deployed a Release build, or the identity cannot write in the folder. | Deploy the Debug build and check the permission. |
| The `.upd` is never applied | The file is still being copied (it cannot be opened exclusively), or the update is blocked. | Look for `CanAccessDLL` and `.upd bloqueado=True` in the log. |
| `w3wp.exe` does not end when stopping | Deadlock when unloading the real DLL. | Use the current build, which does not unload it on shutdown. If it persists, make a dump. |
| After restarting IIS nothing loads and only a `.run` exists | Fixed: an old build needed a `.upd`. | Use the current build. |

## 10. Checklist

- [ ] Built the **right configuration** (Debug to diagnose, Release for the server) for **Win32**.
- [ ] The folder has the loader renamed to `MyService.dll` and the real DLL as `MyService.upd` or `MyService.run`.
- [ ] The pool identity has **Modify** on the folder.
- [ ] The pool has **Enable 32-Bit Applications = True**.
- [ ] Extension: application created, *Execute* permission on the handler mapping, DLL allowed in *ISAPI and CGI Restrictions*. Filter: added in *ISAPI Filters* of the site.
- [ ] After the first request, `.upd` has become `.run` and, with Debug, the log shows `GetExtensionVersion del hijo -> True`.
- [ ] The hot update has been tried on a test server before using it in production.
