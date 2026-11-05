# LnkISAPI-Filter-Loader

**English** | [Español](README.es.md)

ISAPI Filter Loader (Load DLL ISAPI on fly).
Source Daniel "sakura" Wischnewski

A loader written in Delphi that works both as an IIS ISAPI **filter** and as an ISAPI **extension**, and loads and unloads **another ISAPI filter or extension on the fly**, so you can deploy a new version without stopping or restarting IIS.

## Description

How does it work?

When you setup the ISAPI Filter for your web site, instead of deploying your ISAPI extension, you will deploy mine. Rename my ISAPI extension so, that it matches the name of your DLL. So, if your DLL is called SomeISAPIExtension.dll, name mine SomeISAPIExtension.dll, too.

Now rename your ISAPI extension to SomeISAPIExtension.upd, short for update. ;-) When the IIS sends the next request to my ISAPI extension, it will look for your update. It will then rename it to SomeISAPIExtension.run and load it into memory and pass all requests along.

When you have another update, copy it as SomeISAPIExtension.upd into the same directory. Within 10 seconds (default, or 500ms debug-mode) my ISAPI extension will look for the update. Finding one, it will unload the current extension and rename it to SomeISAPIExtension.bak, rename yours to SomeISAPIExtension.run and load it. Then, your new version will start to handle all requests. NOTE: This process can take upto one minute. All incoming calls are pooled and passed to the new version as soon as it is loaded.

I created this little tool as an afterthought just now. As it turned out, Egg-Loader is for those extensions and not for filters. I hope you enjoy it, too. There are some things that can be done to enhance it for debugging, and it is not designed for live services!

## The problem it solves

IIS loads an ISAPI filter only once and keeps its DLL file locked. To replace it you normally have to stop the site or the application pool, copy the DLL and start it again. During development this is very inconvenient. This loader is installed in IIS as if it were the filter, and it is the loader that loads the real filter, so the file IIS has locked never changes.

## File lifecycle

All files live in the same folder and share the base name of the loader (`MyFilter` in the example).

| File | What it is |
|---|---|
| `MyFilter.dll` | The loader (this project), renamed. This is what IIS registers. |
| `MyFilter.upd` | Your real filter, waiting to be activated. This is what you copy. |
| `MyFilter.run` | Your real filter, running (loaded in memory). |
| `MyFilter.bak` | Copy of the previous version (overwritten on every update). |

When a `.upd` appears, the loader does the following:

1. Waits until it can open the `.upd` exclusively, so it does not load it while it is still being copied.
2. If a filter was already loaded, calls its `TerminateFilter` and unloads it with `FreeLibrary`.
3. Deletes the previous `.bak`, renames `.run` to `.bak` and `.upd` to `.run`.
4. Loads the `.run` with `LoadLibrary`, looks up `GetFilterVersion`, `HttpFilterProc` and `TerminateFilter`, and stores the notification flags the filter asks for.

## Installation and usage

> For the complete step-by-step guide (building, IIS configuration, permissions, checks and troubleshooting) see the **[build and deployment manual](doc/BUILD_AND_DEPLOY.md)** ([Español](doc/COMPILACION_Y_DESPLIEGUE.md)). What follows is a summary.

1. Build the loader (see below) or use [bin/FilterLoader.dll](bin/FilterLoader.dll).
2. Copy it to the site folder with **the same name as your filter**, for example `MyFilter.dll`.
3. Register `MyFilter.dll` in IIS the same way you would register the real one:
   - **Filter:** add it under *ISAPI Filters* of the site.
   - **Extension:** nothing to register; it is called by URL (for example `http://server/WebService/MyFilter.dll/status`), with the handler mapping and ISAPI restriction your real DLL already needed.

   The loader exports both sets of entry points, so the same DLL works in either role. What matters is what your real DLL is.
4. Copy your real filter or extension as `MyFilter.upd` into the same folder. If a `MyFilter.run` is already there (for example after restarting IIS), it is loaded without needing a `.upd`.
5. On the next request the loader activates it. **The application pool identity (`IIS AppPool\<pool name>`) needs *Modify* permission on that folder**, because the loader renames and deletes files there. Without it the renames fail with "Access denied" (error 5); the loader then keeps running the current `.run`, logs the problem once and ignores that `.upd` until it changes.
6. For every new version, copy another `MyFilter.upd`.

### Checking that IIS does not serve the files

If you use the loader as an extension, open `http://localhost/…/MyService.dll/test` **from the server itself**. The loader creates three harmless probe files (`.run`, `.upd` and `.bak`), requests them from IIS over HTTP, deletes them and answers in plain text whether IIS does not serve them (good) or downloads them (danger). It also reports whether a `.upd` is waiting. Both answer in **English by default** (Spanish with `?lang=es` or a Spanish browser). **`/test` never applies an update**: a pending `.upd` is applied by the first *normal* request once the check interval has passed (10 s in Release, 500 ms in Debug), or immediately by calling `…/MyService.dll/update` from the server itself. A [Postman collection](doc/FilterLoader.postman_collection.json) with these requests is included. Details in the [manual](doc/BUILD_AND_DEPLOY.md).

## Repository layout

| Path | Contents |
|---|---|
| [src/FilterLoader.dpr](src/FilterLoader.dpr) | `library` project. Exports the three ISAPI entry points and delegates to the loader, catching any exception. |
| [src/uLoader.pas](src/uLoader.pas) | The `IFilterLoader` interface and the `TFilterLoader` class with all the reload logic. |
| [src/uLog.pas](src/uLog.pas) | Debug log (only active in the Debug configuration). |
| [src/uTest.pas](src/uTest.pas) | `/test` self-check (IIS does not serve `.run`, `.upd` and `.bak`; reports a pending `.upd`) and `/update` (applies the `.upd` now). |
| [doc/FilterLoader.postman_collection.json](doc/FilterLoader.postman_collection.json) | Postman collection with the normal request, `/test` and `/update`. |
| `src/FilterLoader.dproj`, `.bdsproj`, `.res`, `.ico` | Delphi project files, resources and icon. |
| [bin/FilterLoader.dll](bin/FilterLoader.dll) | Prebuilt DLL (32-bit). |
| [doc/BUILD_AND_DEPLOY.md](doc/BUILD_AND_DEPLOY.md) | Build and IIS deployment manual ([Spanish version](doc/COMPILACION_Y_DESPLIEGUE.md)). |
| [Tareas.md](Tareas.md) | Pending and completed tasks (in Spanish). |

## How it works internally

- **Entry points:** `GetFilterVersion`, `HttpFilterProc` and `TerminateFilter` (filter contract), and `GetExtensionVersion`, `HttpExtensionProc` and `TerminateExtension` (extension contract). The loader exposes all six and forwards them to the loaded DLL, whichever kind it is.
- **Extensions:** when the child is an extension, the loader calls its `GetExtensionVersion` once, right after loading it, and keeps the version information. When IIS calls the loader's `GetExtensionVersion`, that stored information is returned without calling the child a second time, because some extensions (WebBroker, DMVCFramework) initialise themselves there. `HttpExtensionProc` holds the read lock for the whole call, so a reload waits for the requests in progress. On unload the child receives `TerminateExtension(HSE_TERM_MUST_UNLOAD)`.
- **Concurrency:** two `TMultiReadExclusiveWriteSynchronizer`.
  - `FDLLSync` protects the pointers to the loaded filter. Every request takes a read lock and the reload takes a write lock, so nobody uses the DLL while it is being unloaded.
  - `FCheckSync` prevents several threads from checking for the `.upd` at the same time.
- **Check frequency:** `DoUpdateIfNeeded` runs on every request, but it only looks for the `.upd` once `WAIT_BEFORE_CHECK` milliseconds have passed since the last check: 10,000 by default and 500 when compiled with `DEBUG`.
- **Notification filtering:** after loading the child filter its `dwFlags` are read. `HttpFilterProc` only passes it the notifications it asked for and returns `SF_STATUS_REQ_NEXT_NOTIFICATION` for the rest.
- **File paths:** derived from the name of the module itself (`GetModuleFileNameW`) by changing the extension.
- **Fault tolerance:** if the child filter raises an exception, the loader catches it and lets the request through.

## Building

Full instructions, including the command line and the IIS deployment: [build and deployment manual](doc/BUILD_AND_DEPLOY.md) ([Español](doc/COMPILACION_Y_DESPLIEGUE.md)).

- **Delphi** project: open [src/FilterLoader.dproj](src/FilterLoader.dproj) in the IDE and build.
- It uses the `ISAPI2` unit that ships with Delphi.
- The **Debug** configuration defines the `DEBUG` symbol: it reduces the check interval to 500 ms and enables the log (see below). It also builds with full debug information (local symbols, symbol references, debug DCUs), a detailed map file (`FilterLoader.map`, handy to resolve crash addresses in `w3wp.exe` with WinDbg) and runtime assertions, with optimisation off and stack frames on. The **Release** configuration includes none of this.
- **Output folders:** each configuration has its own: the DLL goes to `bin\Debug\` or `bin\Release\` (the Debug one also gets its `.map`), and the `.dcu` files to `src\Win32\Debug\` or `src\Win32\Release\`. They no longer overwrite each other.
- **Bitness:** the project currently builds **32-bit only** (`Win32` is enabled and `Win64` is not; the prebuilt DLL is x86). A 64-bit IIS application pool only loads 64-bit ISAPI filters, so with this DLL you must enable "Enable 32-Bit Applications" on the pool. The loader and the child filter must have the same bitness. A 64-bit build is planned (see [Tareas.md](Tareas.md)).

## Debug log

With the Debug configuration, the loader writes a log in the `logs` folder next to the DLL, named exactly like the DLL plus `.log` (for example `logs\MyFilter.dll.log`). The folder is created if it does not exist; if it cannot be created, the log goes in the DLL folder itself. Every line has the date and time, the process and thread ids, and the message:

```
2026-11-04 22:10:31.532 [4128:5512] ReloadDLL: ShouldReload=True (child loaded=False, .upd exists=True)
```

The log records the creation and destruction of the loader, every reload decision, the result of the renames, `LoadLibrary` with its Windows error, the exports and flags of the child filter, exceptions, and every notification (whether it was forwarded to the child or not) with its result. The messages are written in English.

- The IIS application pool identity needs **write permission** on the filter folder (to create `logs` and write in it). If it does not have it, the file is not created (and no error is raised).
- The file rotates to `.log.old` when it exceeds 2 MB.
- The same messages are sent to `OutputDebugString`, so they can also be seen with DebugView.
- In Release the log does not exist: the routines are empty.
- Logging every notification is very noisy: it is for debugging only.

## Limitations

- **Not designed for production**, only for development and debugging, as the original author warns.
- IIS calls `GetFilterVersion` only once. If the new version of the filter changes its flags or its initial configuration, IIS must be restarted. The loader does update internally the flags it uses for filtering.
- If the `.upd` cannot be loaded, or the `.run` does not exist, the filter stays inactive and lets every request through without any warning (the log shows why in Debug builds).
- The `.bak` only keeps the immediately previous version.
- Extensions that answer asynchronously (`HSE_STATUS_PENDING`) can still be running when a reload unloads them. The loader only protects the duration of the `HttpExtensionProc` call itself.
- The file names are `.upd`, `.run` and `.bak`. Other loaders use different names (for example `.new`, `.update` or `.backup`), so files named that way are ignored by this one.

## Known issues and proposed improvements

Result of a code review. Tracking is in [Tareas.md](Tareas.md). Nothing below is fixed yet, except the debug log.

### Bugs

1. **Buffer overflow in the paths** ([src/uLoader.pas](src/uLoader.pas), `GetLongFileName` and `GetModuleName`): `SizeOf(Buffer)` (bytes) is passed where the Windows APIs expect the size in characters, and the buffer in `GetLongFileName` is not initialised.
2. **`TerminateFilter` does not release the loader** ([src/FilterLoader.dpr](src/FilterLoader.dpr)): `gFilterLoader` stays alive, and the child's `FreeLibrary` runs when the DLL is unloaded, inside the Windows loader lock.
3. **Uninitialised `pVer` when calling the child (filters)**: `ReloadDLL` uses a local variable with garbage, and on the first load the child receives `GetFilterVersion` twice. (Extensions do not have this problem: see "How it works internally".)
4. **A faulty new version leaves the filter inactive without warning**: the result of the renames is not checked and, if `LoadLibrary` fails, the `.bak` is not restored.

### Improvements

1. Return all notifications to IIS and filter inside the loader, so IIS does not need restarting when the new version asks for different ones.
2. Document that keep-alive connections may hold a context (`pFilterContext`) created by the previous version.
3. Document that several worker processes (web garden or overlapped recycling) lock the `.run` and the rename fails.
4. Minor: use `GetTickCount64`, avoid the two locks per request in the quick check, replace `TFileStream` with `CreateFile` in `CanAccessDLL`, and remove the obsolete `export` directive.
5. Build a 64-bit version of the loader (see [Building](#building)).

### Security

Anyone who can write to the filter folder can run code inside `w3wp.exe` by dropping a `.upd`. This is acceptable for development, not for production.

## License and credits

Original code by Daniel "sakura" Wischnewski (August 25th, 2006), published under the **GNU Lesser General Public License** version 2.1 or later. See http://www.gnu.org/copyleft/lgpl.html.

### About the original author

Daniel "sakura" Wischnewski is a Delphi developer based in Munich, Germany. Between April 2005 and September 2007 he wrote the blog [Delphi Developer Notes](https://delphi-notes.blogspot.com/), where, in his own words, he reflected on "my experiences, adventures and my love to Delphi and the Borland Developer Studio". The blog covers BDS 2006, Win32 Delphi, C#, the VCL, action manager components and the Turbo editions, among other topics. In it he mentions giving sessions at EKON 10 (Frankfurt, 2006), publishing a sample on Borland CodeCentral about building action-based main menus in code (for Delphi 2006 and C++Builder 2006), and a "Community Welcome Page" of his. He closed the blog on 24 September 2007 and moved to a new one at http://www.gumpi.com/.

He also started a short blog in July 2006, [Project Hydra :: Content ACE v5](https://project-hydra.blogspot.com/), about the next version of the Content ACE web content management system. The version information in the original files of this project also mentioned Content ACE (gate(n)etwork GmbH); his blogs do not state what his role there was, nor any link between that product and this tool. His [Blogger profile](https://www.blogger.com/profile/13541149824714377940) lists karate, iaido, sailing, mountain biking and Delphi among his interests.

The ISAPI Filter Loader dates from that period: the header of the source code is dated August 25th, 2006. This repository preserves it and has extended it since (extension support, debug log, fixes and manuals); those later changes are not the work of the original author. His job and employer are not stated on his pages, so they are not mentioned here.

## Acknowledgements

Many thanks to **Daniel "sakura" Wischnewski** for creating the ISAPI Filter Loader and for sharing it as open source under the LGPL. His idea of letting IIS keep a stable DLL while the real filter is swapped on the fly, and the clean way he wrote it, are the foundation of everything in this repository. Thank you for your work and for making it available to the Delphi community.

## Web

http://delphi-notes.blogspot.com/
