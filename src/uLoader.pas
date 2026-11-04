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
    function GetFilterVersion(var pVer: HTTP_FILTER_VERSION): BOOL;
    function HttpFilterProc(var pfc: THTTP_FILTER_CONTEXT; NotificationType: DWORD; pvNotification: Pointer): DWORD;
    function TerminateFilter(dwFlags: DWORD): BOOL;
  end;

function CoCreateFilterLoader: IFilterLoader;

implementation

uses
  Classes,
  uLog;

function GetLongPathNameW(lpszShortPath: PWideChar; lpszLongPath: PWideChar; cchBuffer: DWORD): DWORD; stdcall; external kernel32 name 'GetLongPathNameW';

function GetLongFileName(FileName: WideString): WideString;
var
  Buffer: array[0..1023] of WideChar;
begin
  GetLongPathNameW(PWideChar(FileName), Buffer, SizeOf(Buffer));
  Result := Buffer;
end;

function GetModuleName: WideString;
var
  TheFileName : array[0..1023] of WideChar;
begin
  FillChar(TheFileName, SizeOf(TheFileName), #0);
  GetModuleFileNameW(hInstance, TheFileName, SizeOf(TheFileName));
  Result := GetLongFileName(TheFileName);
end;

type
  TFilterLoader = class(TInterfacedObject, IFilterLoader)
  private
    FLastTimeCheck: LongWord;
    FCheckSync: TMultiReadExclusiveWriteSynchronizer;
    FDLLSync: TMultiReadExclusiveWriteSynchronizer;
    FDLL: HModule;
    FCallbackVersion: TGetFilterVersion;
    FCallbackProc: THttpFilterProc;
    FCallbackTerminate: TTerminateExtension;
    FBackupDLLName, FRunDLLName, FUpdateDLLName: string;
    FFilterFlags: DWord;
    procedure ReloadDLL;
    procedure DoUpdateIfNeeded;
    function CanAccessDLL: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function GetFilterVersion(var pVer: HTTP_FILTER_VERSION): BOOL;
    function HttpFilterProc(var pfc: THTTP_FILTER_CONTEXT; NotificationType: DWORD; pvNotification: Pointer): DWORD;
    function TerminateFilter(dwFlags: DWORD): BOOL;
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
begin
  inherited Create;
  FDLLSync := TMultiReadExclusiveWriteSynchronizer.Create;
  FCheckSync := TMultiReadExclusiveWriteSynchronizer.Create;
  ThisModule := GetModuleName;
  FBackupDLLName := ChangeFileExt(ThisModule, '.bak');
  FRunDLLName := ChangeFileExt(ThisModule, '.run');
  FUpdateDLLName := ChangeFileExt(ThisModule, '.upd');
  Log('TFilterLoader.Create: modulo="%s" upd="%s" run="%s" bak="%s" espera=%d ms',
    [ThisModule, FUpdateDLLName, FRunDLLName, FBackupDLLName, WAIT_BEFORE_CHECK]);
end;

destructor TFilterLoader.Destroy;
begin
  Log('TFilterLoader.Destroy (filtro hijo cargado=%s)', [BoolToStr(FDLL <> 0, True)]);
  // unload DLL
  if FDLL <> 0 then
    FreeLibrary(FDLL);
  FDLLSync.Free;
  FCheckSync.Free;
  inherited Destroy;
end;

procedure TFilterLoader.DoUpdateIfNeeded;
var
  NeedCheck, NeedLoad: Boolean;
begin
  // Quick Check
  FCheckSync.BeginRead;
  try
    NeedCheck := (GetTickCount - FLastTimeCheck) >= WAIT_BEFORE_CHECK;
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
        NeedCheck := (FDLL = 0) or ((GetTickCount - FLastTimeCheck) >= WAIT_BEFORE_CHECK);
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
  ShouldReload: Boolean;
  pVer: THTTP_FILTER_VERSION;
begin
  FDLLSync.BeginWrite;
  try
    // First Determine if we really should
    ShouldReload := ((FDLL=0) or FileExists(FUpdateDLLName)) and CanAccessDLL;
    Log('ReloadDLL: ShouldReload=%s (hijo cargado=%s, .upd existe=%s)',
      [BoolToStr(ShouldReload, True), BoolToStr(FDLL <> 0, True),
       BoolToStr(FileExists(FUpdateDLLName), True)]);
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
        FreeLibrary(FDLL);
        FDLL := 0;
        FCallbackVersion := nil;
        FCallbackProc := nil;
        FCallbackTerminate := nil;
      end;

      // check for update file, if exists then rename things;
      if FileExists(FUpdateDLLName) then
      begin
        Log('ReloadDLL: aplicando actualizacion (.upd -> .run, .run -> .bak)');
        // DeleteFile da False si no habia .bak: es normal
        Log('ReloadDLL: DeleteFile(.bak) = %s', [BoolToStr(SysUtils.DeleteFile(FBackupDLLName), True)]);
        // RenameFile da False si no habia .run (primera instalacion): es normal
        if not RenameFile(FRunDLLName, FBackupDLLName) then
          LogWinError('ReloadDLL: RenameFile(.run -> .bak)', GetLastError);
        if not RenameFile(FUpdateDLLName, FRunDLLName) then
          LogWinError('ReloadDLL: RenameFile(.upd -> .run)', GetLastError);
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

