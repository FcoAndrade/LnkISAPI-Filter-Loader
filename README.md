# LnkISAPI-Filter-Loader

**English** | [Español](README.es.md)

ISAPI Filter Loader (Load DLL ISAPI on fly).
Source Daniel "sakura" Wischnewski

An IIS ISAPI filter written in Delphi that loads and unloads **another ISAPI filter on the fly**, so you can deploy a new version without stopping or restarting IIS.

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

1. Build the loader (see below) or use [bin/FilterLoader.dll](bin/FilterLoader.dll).
2. Copy it to the site folder with **the same name as your filter**, for example `MyFilter.dll`.
3. Register `MyFilter.dll` as an ISAPI filter in IIS, as you would the real filter.
4. Copy your real filter as `MyFilter.upd` into the same folder.
5. On the next request the loader activates it.
6. For every new version, copy another `MyFilter.upd`.

## Repository layout

| Path | Contents |
|---|---|
| [src/FilterLoader.dpr](src/FilterLoader.dpr) | `library` project. Exports the three ISAPI entry points and delegates to the loader, catching any exception. |
| [src/uLoader.pas](src/uLoader.pas) | The `IFilterLoader` interface and the `TFilterLoader` class with all the reload logic. |
| [src/uLog.pas](src/uLog.pas) | Debug log (only active in the Debug configuration). |
| `src/FilterLoader.dproj`, `.bdsproj`, `.res`, `.ico` | Delphi project files, resources and icon. |
| [bin/FilterLoader.dll](bin/FilterLoader.dll) | Prebuilt DLL (32-bit). |
| [Tareas.md](Tareas.md) | Pending and completed tasks (in Spanish). |

## How it works internally

- **Entry points:** `GetFilterVersion`, `HttpFilterProc` and `TerminateFilter`, the three of the ISAPI contract. The loader exposes them and forwards them to the loaded filter.
- **Concurrency:** two `TMultiReadExclusiveWriteSynchronizer`.
  - `FDLLSync` protects the pointers to the loaded filter. Every request takes a read lock and the reload takes a write lock, so nobody uses the DLL while it is being unloaded.
  - `FCheckSync` prevents several threads from checking for the `.upd` at the same time.
- **Check frequency:** `DoUpdateIfNeeded` runs on every request, but it only looks for the `.upd` once `WAIT_BEFORE_CHECK` milliseconds have passed since the last check: 10,000 by default and 500 when compiled with `DEBUG`.
- **Notification filtering:** after loading the child filter its `dwFlags` are read. `HttpFilterProc` only passes it the notifications it asked for and returns `SF_STATUS_REQ_NEXT_NOTIFICATION` for the rest.
- **File paths:** derived from the name of the module itself (`GetModuleFileNameW`) by changing the extension.
- **Fault tolerance:** if the child filter raises an exception, the loader catches it and lets the request through.

## Building

- **Delphi** project: open [src/FilterLoader.dproj](src/FilterLoader.dproj) in the IDE and build.
- It uses the `ISAPI2` unit that ships with Delphi.
- The **Debug** configuration defines the `DEBUG` symbol: it reduces the check interval to 500 ms and enables the log (see below). The **Release** configuration includes neither.
- **Bitness:** the project currently builds **32-bit only** (`Win32` is enabled and `Win64` is not; the prebuilt DLL is x86). A 64-bit IIS application pool only loads 64-bit ISAPI filters, so with this DLL you must enable "Enable 32-Bit Applications" on the pool. The loader and the child filter must have the same bitness. A 64-bit build is planned (see [Tareas.md](Tareas.md)).

## Debug log

With the Debug configuration, the loader writes a log in the same folder as the DLL, with the same base name and a `.log` extension (for example `MyFilter.log`). Every line has the date and time, the process and thread ids, and the message:

```
2026-11-04 22:10:31.532 [4128:5512] ReloadDLL: ShouldReload=True (hijo cargado=False, .upd existe=True)
```

The log records the creation and destruction of the loader, every reload decision, the result of the renames, `LoadLibrary` with its Windows error, the exports and flags of the child filter, exceptions, and every notification (whether it was forwarded to the child or not) with its result. The messages themselves are written in Spanish.

- The IIS application pool identity needs **write permission** on the filter folder. If it does not have it, the file is not created (and no error is raised).
- The file rotates to `.log.old` when it exceeds 2 MB.
- The same messages are sent to `OutputDebugString`, so they can also be seen with DebugView.
- In Release the log does not exist: the routines are empty.
- Logging every notification is very noisy: it is for debugging only.

## Limitations

- **Not designed for production**, only for development and debugging, as the original author warns.
- IIS calls `GetFilterVersion` only once. If the new version of the filter changes its flags or its initial configuration, IIS must be restarted. The loader does update internally the flags it uses for filtering.
- If the `.upd` cannot be loaded, or the `.run` does not exist, the filter stays inactive and lets every request through without any warning (the log shows why in Debug builds).
- The `.bak` only keeps the immediately previous version.

## Known issues and proposed improvements

Result of a code review. Tracking is in [Tareas.md](Tareas.md). Nothing below is fixed yet, except the debug log.

### Bugs

1. **Buffer overflow in the paths** ([src/uLoader.pas](src/uLoader.pas), `GetLongFileName` and `GetModuleName`): `SizeOf(Buffer)` (bytes) is passed where the Windows APIs expect the size in characters, and the buffer in `GetLongFileName` is not initialised.
2. **`TerminateFilter` does not release the loader** ([src/FilterLoader.dpr](src/FilterLoader.dpr)): `gFilterLoader` stays alive, and the child's `FreeLibrary` runs when the DLL is unloaded, inside the Windows loader lock.
3. **It may fail to load if IIS starts right after the machine boots**: with less than 10 s of uptime the quick check returns `False`, the child is not loaded and IIS never retries.
4. **Uninitialised `pVer` when calling the child**: `ReloadDLL` uses a local variable with garbage, and on the first load the child receives `GetFilterVersion` twice.
5. **A faulty new version leaves the filter inactive without warning**: the result of the renames is not checked and, if `LoadLibrary` fails, the `.bak` is not restored.
6. **With only a `.run` (no `.upd`) the filter is never loaded**: `CanAccessDLL` tries to open the `.upd` even when it does not exist, so after restarting IIS, with the version already in `.run`, `ReloadDLL` loads nothing.

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

## Web

http://delphi-notes.blogspot.com/
