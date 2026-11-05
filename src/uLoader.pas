(*

This software is published under the terms of the GNU Lesser General
Public License (LGPL, see below). For a detailed description of this license,
see http://www.gnu.org/copyleft/lgpl.html

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This software is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this software; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA

August 25th, 2006
Daniel "sakura" Wischnewski
Authors homepage: http://delphi-notes.blogspot.com
GNU Lesser General Public License

*)

unit uLoader;

interface

uses
  ISAPI2,
  SysUtils,
  Windows;

const
  {$IFDEF DEBUG}
    WAIT_BEFORE_CHECK = 500;   // half a second
  {$ELSE}
    WAIT_BEFORE_CHECK = 10000; // 10 seconds
  {$ENDIF}

type
  IFilterLoader = interface
    ['{1FEE4F6E-C6BA-4D41-9E98-501637B8C9E6}']
    // Filtro ISAPI
    function GetFilterVersion(var pVer: HTTP_FILTER_VERSION): BOOL;
    function HttpFilterProc(var pfc: THTTP_FILTER_CONTEXT; NotificationType: DWORD; pvNotification: Pointer): DWORD;
    function TerminateFilter(dwFlags: DWORD): BOOL;
    // Extension ISAPI (pVer es un HSE_VERSION_INFO y pECB un EXTENSION_CONTROL_BLOCK)
    function GetExtensionVersion(pVer: Pointer): BOOL;
    function HttpExtensionProc(pECB: Pointer): DWORD;
    function TerminateExtension(dwFlags: DWORD): BOOL;
  end;

function CoCreateFilterLoader: IFilterLoader;

implementation

uses
  Classes,
  uLog,
  uTest,
  uThreads,
  uIdentity;

const
  // Tiempo que se espera a que los hilos del hijo terminen solos antes de
  // descargarlo; pasado ese tiempo se terminan a la fuerza.
  CHILD_THREADS_WAIT_MS = 3000;

function GetLongPathNameW(lpszShortPath: PWideChar; lpszLongPath: PWideChar; cchBuffer: DWORD): DWORD; stdcall; external kernel32 name 'GetLongPathNameW';

function GetLongFileName(FileName: WideString): WideString;
var
  Buffer: array[0..1023] of WideChar;
begin
  GetLongPathNameW(PWideChar(FileName), Buffer, SizeOf(Buffer));
  Result := Buffer;
end;

// Nombre del usuario con el que corre el proceso (solo para el log)
function CurrentUserName: string;
var
  Buffer: array[0..256] of WideChar;
  Size: DWORD;
begin
  Size := Length(Buffer);
  if GetUserNameW(Buffer, Size) then
    Result := Buffer
  else
    Result := '(desconocido)';
end;

// Fecha de modificacion de un fichero; 0 si no existe o no se puede leer
function FileStamp(const FileName: string): TDateTime;
var
  D: TDateTime;
begin
  if FileAge(FileName, D) then
    Result := D
  else
    Result := 0;
end;

function GetModuleName: WideString;
var
  TheFileName : array[0..1023] of WideChar;
begin
  FillChar(TheFileName, SizeOf(TheFileName), #0);
  GetModuleFileNameW(hInstance, TheFileName, SizeOf(TheFileName));
  Result := GetLongFileName(TheFileName);
end;

const
  // Valores de httpext.h
  EXT_STATUS_ERROR = 4;          // HSE_STATUS_ERROR
  EXT_TERM_MUST_UNLOAD = 2;      // HSE_TERM_MUST_UNLOAD (1 es HSE_TERM_ADVISORY_UNLOAD)
  EXT_VERSION_INFO_SIZE = 260;   // SizeOf(HSE_VERSION_INFO): DWORD + 256 caracteres

type
  // Punteros a las funciones de una extension ISAPI. Se declaran con Pointer
  // para no depender de los nombres de tipos de la unidad ISAPI2.
  TExtVersionProc = function(pVer: Pointer): BOOL; stdcall;
  TExtProc = function(pECB: Pointer): DWORD; stdcall;
  TExtTerminateProc = function(dwFlags: DWORD): BOOL; stdcall;

  TFilterLoader = class(TInterfacedObject, IFilterLoader)
  private
    FLastTimeCheck: LongWord;
    FCheckSync: TMultiReadExclusiveWriteSynchronizer;
    FDLLSync: TMultiReadExclusiveWriteSynchronizer;
    FDLL: HModule;
    FCallbackVersion: TGetFilterVersion;
    FCallbackProc: THttpFilterProc;
    FCallbackTerminate: TTerminateExtension;
    // Si el hijo es una extension ISAPI
    FExtVersion: TExtVersionProc;
    FExtProc: TExtProc;
    FExtTerminate: TExtTerminateProc;
    FExtReady: Boolean;
    // Fecha del .upd cuya aplicacion fallo (p. ej. por permisos); 0 = ninguno.
    // Mientras el .upd no cambie no se vuelve a intentar ni a descargar el hijo.
    FBlockedUpdateStamp: TDateTime;
    FImpersonationLogged: Boolean;
    FExtVerInfo: array[0..EXT_VERSION_INFO_SIZE - 1] of Byte;
    FBackupDLLName, FRunDLLName, FUpdateDLLName: string;
    FFilterFlags: DWord;
    procedure ReloadDLL;
    procedure DoUpdateIfNeeded;
    procedure DoUpdateIfNeededNow;
    function CanAccessDLL: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function GetFilterVersion(var pVer: HTTP_FILTER_VERSION): BOOL;
    function HttpFilterProc(var pfc: THTTP_FILTER_CONTEXT; NotificationType: DWORD; pvNotification: Pointer): DWORD;
    function TerminateFilter(dwFlags: DWORD): BOOL;
    function GetExtensionVersion(pVer: Pointer): BOOL;
    function HttpExtensionProc(pECB: Pointer): DWORD;
    function TerminateExtension(dwFlags: DWORD): BOOL;
  end;

function CoCreateFilterLoader: IFilterLoader;
begin
  Result := TFilterLoader.Create;
end;

{ TFilterLoader }

function TFilterLoader.CanAccessDLL: Boolean;
var
  FS: TFileStream;
begin
  // Sin .upd no hay nada que esperar: si ya hay un .run, se puede cargar
  if not FileExists(FUpdateDLLName) then
  begin
    Result := True;
    Exit;
  end;
  try
    FS := TFileStream.Create(FUpdateDLLName, fmOpenRead or fmShareExclusive);
    try
    finally
      FS.Free;
    end;
    Result := True;
  except
    on E: Exception do
    begin
      Log('CanAccessDLL: no se puede abrir en exclusiva "%s": %s', [FUpdateDLLName, E.Message]);
      Result := False;
    end;
  end;
end;

constructor TFilterLoader.Create;
var
  ThisModule: string;
  Age: TDateTime;
begin
  inherited Create;
  FDLLSync := TMultiReadExclusiveWriteSynchronizer.Create;
  FCheckSync := TMultiReadExclusiveWriteSynchronizer.Create;
  ThisModule := GetModuleName;
  FBackupDLLName := ChangeFileExt(ThisModule, '.bak');
  FRunDLLName := ChangeFileExt(ThisModule, '.run');
  FUpdateDLLName := ChangeFileExt(ThisModule, '.upd');
  // La fecha del fichero de la DLL es la de su compilacion: sirve para saber
  // que version esta desplegada.
  Age := FileStamp(ThisModule);
  if Age = 0 then
    Log('==== Cargador iniciado (fecha de la DLL desconocida) ====')
  else
    Log('==== Cargador de fecha %s ====', [FormatDateTime('yyyy-mm-dd hh:nn:ss', Age)]);
  Log('Proceso ejecutandose como usuario "%s" (con ApplicationPoolIdentity es el nombre del grupo de aplicaciones)', [CurrentUserName]);
  Log('TFilterLoader.Create: modulo="%s" upd="%s" run="%s" bak="%s" espera=%d ms',
    [ThisModule, FUpdateDLLName, FRunDLLName, FBackupDLLName, WAIT_BEFORE_CHECK]);
end;

destructor TFilterLoader.Destroy;
begin
  Log('TFilterLoader.Destroy (filtro hijo cargado=%s)', [BoolToStr(FDLL <> 0, True)]);
  // El hijo NO se descarga con FreeLibrary: el cargador solo se destruye al
  // apagar (IIS ya llamo a TerminateExtension/TerminateFilter), y descargar un
  // hijo con hilos propios (p. ej. DMVCFramework) se queda colgado: FreeLibrary
  // toma el bloqueo del cargador de Windows y el DllMain(DETACH) del hijo espera
  // a que terminen sus hilos, que para salir necesitan ese mismo bloqueo. Al
  // terminar el proceso, Windows ya habra matado esos hilos y lo descarga sin
  // esperar.
  if FDLL <> 0 then
    Log('TFilterLoader.Destroy: se deja el hijo cargado, lo descarga Windows al terminar el proceso');
  FDLLSync.Free;
  FCheckSync.Free;
  inherited Destroy;
end;

// IIS ejecuta HttpExtensionProc en hilos que suplantan a otro usuario (p. ej.
// IUSR), sin permiso para renombrar los ficheros, escribir el log ni abrir los
// hilos del hijo; todo eso fallaba en silencio. La comprobacion y la recarga se
// hacen con la identidad del proceso (la del grupo de aplicaciones) y despues se
// devuelve al hilo la suplantacion que tenia, para no alterar al hijo ni a IIS.
procedure TFilterLoader.DoUpdateIfNeeded;
var
  Tok: THandle;
begin
  Tok := RevertToProcessIdentity;
  try
    if (Tok <> 0) and not FImpersonationLogged then
    begin
      FImpersonationLogged := True;
      Log('AVISO: el hilo de la peticion suplantaba a otro usuario; la comprobacion y la recarga se hacen con la identidad del proceso');
    end;
    DoUpdateIfNeededNow;
  finally
    RestoreIdentity(Tok);
  end;
end;

procedure TFilterLoader.DoUpdateIfNeededNow;
var
  NeedCheck, NeedLoad: Boolean;
begin
  // Quick Check
  FCheckSync.BeginRead;
  try
    // FLastTimeCheck = 0: todavia no se ha comprobado nunca (primera peticion)
    NeedCheck := (FLastTimeCheck = 0) or ((GetTickCount - FLastTimeCheck) >= WAIT_BEFORE_CHECK);
  finally
    FCheckSync.EndRead;
  end;
  if NeedCheck then
  begin
    FCheckSync.BeginWrite;
    try
      // Recheck in case another thread has updated
      FDLLSync.BeginRead;
      try
        NeedCheck := (FLastTimeCheck = 0) or ((GetTickCount - FLastTimeCheck) >= WAIT_BEFORE_CHECK);
      finally
        FDLLSync.EndRead;
      end;

      if NeedCheck then
      begin
        FLastTimeCheck := GetTickCount;
        FDLLSync.BeginRead;
        try
          NeedLoad := (FDLL = 0) or FileExists(FUpdateDLLName);
        finally
          FDLLSync.EndRead;
        end;
        if NeedLoad then
        begin
          Log('DoUpdateIfNeeded: hay que recargar (hijo cargado=%s)', [BoolToStr(FDLL <> 0, True)]);
          ReloadDLL;
        end;
      end;
    finally
      FCheckSync.EndWrite;
    end;
  end;
end;

function TFilterLoader.GetFilterVersion(var pVer: HTTP_FILTER_VERSION): BOOL;
begin
  DoUpdateIfNeeded;
  FDLLSync.BeginRead;
  try
    // call GetFilterVersion of Filter
    // ATTN: if the filter changes this implementation, the IIS has to be
    //       restarted, as this method will be called once only!
    if Assigned(FCallbackVersion) then
    begin
      Result := FCallbackVersion(pVer);
      Log('GetFilterVersion del hijo -> %s (flags=$%x)', [BoolToStr(Result, True), pVer.dwFlags]);
    end
    else
    begin
      Result := False;
      Log('GetFilterVersion: no hay filtro hijo cargado, se devuelve False');
    end;
  finally
    FDLLSync.EndRead;
  end;
end;

function TFilterLoader.HttpFilterProc(var pfc: THTTP_FILTER_CONTEXT;
  NotificationType: DWORD; pvNotification: Pointer): DWORD;
begin
  DoUpdateIfNeeded;
  FDLLSync.BeginRead;
  try
    // Check Notification bit to make sure the DLL should be called
    if Assigned(FCallbackProc) and ((NotificationType and FFilterFlags) <> 0) then
    begin
      Result := FCallbackProc(pfc, NotificationType, pvNotification);
      Log('HttpFilterProc: notificacion=$%x reenviada al hijo -> resultado=%d', [NotificationType, Result]);
    end
    else
    begin
      Result := SF_STATUS_REQ_NEXT_NOTIFICATION;
      Log('HttpFilterProc: notificacion=$%x NO reenviada (hijo cargado=%s, flags=$%x)',
        [NotificationType, BoolToStr(Assigned(FCallbackProc), True), FFilterFlags]);
    end;
  finally
    FDLLSync.EndRead;
  end;
end;

procedure TFilterLoader.ReloadDLL;
var
  ShouldReload, UpdExists, UpdBlocked: Boolean;
  pVer: THTTP_FILTER_VERSION;
begin
  FDLLSync.BeginWrite;
  try
    // First Determine if we really should
    UpdExists := FileExists(FUpdateDLLName);
    // Un .upd cuya aplicacion ya fallo (mismo fichero, misma fecha) se ignora:
    // sin esto se descargaria y recargaria el hijo en cada comprobacion.
    UpdBlocked := UpdExists and (FBlockedUpdateStamp <> 0) and
      (FileStamp(FUpdateDLLName) = FBlockedUpdateStamp);
    // Si no hay hijo cargado se carga el .run aunque el .upd este bloqueado
    ShouldReload := ((FDLL=0) or (UpdExists and not UpdBlocked)) and
      (UpdBlocked or CanAccessDLL);
    Log('ReloadDLL: ShouldReload=%s (hijo cargado=%s, .upd existe=%s, .upd bloqueado=%s)',
      [BoolToStr(ShouldReload, True), BoolToStr(FDLL <> 0, True),
       BoolToStr(UpdExists, True), BoolToStr(UpdBlocked, True)]);
    if ShouldReload then
    begin
      // First unload the DLL
      if FDLL <> 0 then
      begin
        Log('ReloadDLL: descargando el hijo actual');
        if Assigned(FCallbackTerminate) then
        try
          FCallbackTerminate(0);
        except
          LogException('ReloadDLL: TerminateFilter del hijo');
        end;
        if Assigned(FExtTerminate) and FExtReady then
        try
          FExtTerminate(EXT_TERM_MUST_UNLOAD);
        except
          LogException('ReloadDLL: TerminateExtension del hijo');
        end;
        // Antes de FreeLibrary hay que dejar que terminen los hilos del hijo:
        // FreeLibrary toma el bloqueo del cargador de Windows, y un hilo del
        // hijo que este saliendo necesita ese bloqueo mientras el cierre del
        // hijo espera a que acabe (interbloqueo; visto en un volcado). Aqui no
        // se tiene tomado, asi que pueden salir. Si alguno no termina por si
        // solo, se termina a la fuerza como ultimo recurso.
        WaitForModuleThreads(FDLL, CHILD_THREADS_WAIT_MS, True);
        Log('ReloadDLL: FreeLibrary del hijo');
        FreeLibrary(FDLL);
        Log('ReloadDLL: FreeLibrary del hijo terminado');
        FDLL := 0;
        FCallbackVersion := nil;
        FCallbackProc := nil;
        FCallbackTerminate := nil;
        FExtVersion := nil;
        FExtProc := nil;
        FExtTerminate := nil;
        FExtReady := False;
      end;

      // check for update file, if exists then rename things;
      if UpdExists and not UpdBlocked then
      begin
        Log('ReloadDLL: aplicando actualizacion (.upd -> .run, .run -> .bak)');
        Log('ReloadDLL: atributos antes de renombrar: .run=$%x .upd=$%x .bak=$%x (-1 = no existe; $1 = solo lectura)',
          [FileGetAttr(FRunDLLName), FileGetAttr(FUpdateDLLName), FileGetAttr(FBackupDLLName)]);
        // DeleteFile da False si no habia .bak: es normal
        Log('ReloadDLL: DeleteFile(.bak) = %s', [BoolToStr(SysUtils.DeleteFile(FBackupDLLName), True)]);
        // RenameFile da False si no habia .run (primera instalacion): es normal
        if not RenameFile(FRunDLLName, FBackupDLLName) then
          LogWinError('ReloadDLL: RenameFile(.run -> .bak)', GetLastError);
        if RenameFile(FUpdateDLLName, FRunDLLName) then
          FBlockedUpdateStamp := 0
        else
        begin
          LogWinError('ReloadDLL: RenameFile(.upd -> .run)', GetLastError);
          FBlockedUpdateStamp := FileStamp(FUpdateDLLName);
          Log('ReloadDLL: ACTUALIZACION BLOQUEADA: no se pudo renombrar el .upd. Se carga el .run actual y este .upd se ignora hasta que cambie. ' +
            'Compruebe que la identidad del grupo de aplicaciones de IIS tiene permiso de Modificar en la carpeta.');
        end;
      end;

      // Now load the .run file if it exists
      if FileExists(FRunDLLName) then
      begin
        FDLL := LoadLibrary(PChar(FRunDLLName));
        if FDLL <> 0 then
        begin
          Log('ReloadDLL: LoadLibrary("%s") correcto (modulo=$%x)', [FRunDLLName, FDLL]);
          FCallbackVersion := GetProcAddress(FDLL, 'GetFilterVersion');
          FCallbackProc := GetProcAddress(FDLL, 'HttpFilterProc');
          FCallbackTerminate := GetProcAddress(FDLL, 'TerminateFilter');
          Log('ReloadDLL: exportaciones del hijo: GetFilterVersion=%s HttpFilterProc=%s TerminateFilter=%s',
            [BoolToStr(Assigned(FCallbackVersion), True),
             BoolToStr(Assigned(FCallbackProc), True),
             BoolToStr(Assigned(FCallbackTerminate), True)]);
          if Assigned(FCallbackVersion) then
          begin
            FCallbackVersion(pVer);
            FFilterFlags := pVer.dwFlags;
          end
          else
            FFilterFlags := 0;
          Log('ReloadDLL: flags de notificacion del hijo=$%x', [FFilterFlags]);

          // Si el hijo es una extension ISAPI se inicializa aqui, una sola vez,
          // y la informacion de version se guarda para devolverla a IIS sin
          // volver a llamar al hijo (algunas extensiones se inicializan ahi).
          FExtVersion := GetProcAddress(FDLL, 'GetExtensionVersion');
          FExtProc := GetProcAddress(FDLL, 'HttpExtensionProc');
          FExtTerminate := GetProcAddress(FDLL, 'TerminateExtension');
          FExtReady := False;
          Log('ReloadDLL: exportaciones de extension del hijo: GetExtensionVersion=%s HttpExtensionProc=%s TerminateExtension=%s',
            [BoolToStr(Assigned(FExtVersion), True),
             BoolToStr(Assigned(FExtProc), True),
             BoolToStr(Assigned(FExtTerminate), True)]);
          if Assigned(FExtVersion) and Assigned(FExtProc) then
          begin
            FillChar(FExtVerInfo, SizeOf(FExtVerInfo), 0);
            PDWORD(@FExtVerInfo[0])^ := $00010000; // HSE_VERSION_MAJOR 1, MINOR 0
            try
              FExtReady := FExtVersion(@FExtVerInfo[0]);
            except
              LogException('ReloadDLL: GetExtensionVersion del hijo');
              FExtReady := False;
            end;
            Log('ReloadDLL: GetExtensionVersion del hijo -> %s', [BoolToStr(FExtReady, True)]);
          end
          else if not (Assigned(FCallbackVersion) and Assigned(FCallbackProc)) then
            Log('ReloadDLL: AVISO: el hijo no exporta ni funciones de filtro ni de extension');
        end
        else
          LogWinError(Format('ReloadDLL: LoadLibrary("%s")', [FRunDLLName]), GetLastError);
      end
      else
        Log('ReloadDLL: no existe "%s", no hay nada que cargar', [FRunDLLName]);
    end;
  finally
    FDLLSync.EndWrite;
  end;
end;

function TFilterLoader.GetExtensionVersion(pVer: Pointer): BOOL;
begin
  DoUpdateIfNeeded;
  FDLLSync.BeginRead;
  try
    // IIS llama a esto una sola vez. El hijo ya se inicializo en ReloadDLL;
    // aqui solo se le devuelve a IIS la version que dio el hijo.
    if FExtReady and Assigned(pVer) then
    begin
      Move(FExtVerInfo[0], pVer^, SizeOf(FExtVerInfo));
      Result := True;
      Log('GetExtensionVersion: devuelta la version del hijo');
    end
    else
    begin
      Result := False;
      Log('GetExtensionVersion: no hay extension hija lista, se devuelve False');
    end;
  finally
    FDLLSync.EndRead;
  end;
end;

function TFilterLoader.HttpExtensionProc(pECB: Pointer): DWORD;
var
  T0: DWORD;
begin
  // Autocomprobacion del propio cargador (<dll>/test): no se pasa al hijo
  if IsTestRequest(PEXTENSION_CONTROL_BLOCK(pECB)) then
  begin
    Log('HttpExtensionProc: peticion /test, la atiende el cargador');
    Result := RunTest(PEXTENSION_CONTROL_BLOCK(pECB), GetModuleName);
    Exit;
  end;
  DoUpdateIfNeeded;
  FDLLSync.BeginRead;
  try
    // El bloqueo de lectura se mantiene durante toda la llamada: una recarga
    // espera a que terminen las peticiones en curso.
    if FExtReady and Assigned(FExtProc) then
    begin
      // Se registra la entrada antes de llamar: si el hijo se cuelga, queda rastro
      T0 := GetTickCount;
      Log('HttpExtensionProc: entrada, llamando al hijo');
      Result := FExtProc(pECB);
      Log('HttpExtensionProc: atendida por el hijo -> resultado=%d en %d ms', [Result, GetTickCount - T0]);
    end
    else
    begin
      Result := EXT_STATUS_ERROR;
      Log('HttpExtensionProc: no hay extension hija lista, se devuelve error');
    end;
  finally
    FDLLSync.EndRead;
  end;
end;

function TFilterLoader.TerminateExtension(dwFlags: DWORD): BOOL;
begin
  FDLLSync.BeginRead;
  try
    if Assigned(FExtTerminate) and FExtReady then
    begin
      Result := FExtTerminate(dwFlags);
      Log('TerminateExtension del hijo -> %s', [BoolToStr(Result, True)]);
    end
    else
    begin
      Result := True;
      Log('TerminateExtension: no hay extension hija cargada');
    end;
  finally
    FDLLSync.EndRead;
  end;
end;

function TFilterLoader.TerminateFilter(dwFlags: DWORD): BOOL;
begin
  FDLLSync.BeginRead;
  try
    // Check Notification bit to make sure the DLL should be called
    if Assigned(FCallbackTerminate) then
    begin
      Result := FCallbackTerminate(dwFlags);
      Log('TerminateFilter del hijo -> %s', [BoolToStr(Result, True)]);
    end
    else
    begin
      Result := True;
      Log('TerminateFilter: no hay filtro hijo cargado');
    end;
  finally
    FDLLSync.EndRead;
  end;
end;

end.

