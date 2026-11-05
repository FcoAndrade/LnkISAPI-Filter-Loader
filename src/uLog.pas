(*
  uLog - Log de depuracion del cargador de filtros ISAPI.

  Solo esta activo al compilar con el simbolo DEBUG (configuracion "Debug" del
  proyecto). En Release todas las rutinas estan vacias y no generan codigo
  de escritura ni ficheros.

  Cuando esta activo escribe:
    - En la carpeta "logs" que cuelga de la carpeta de la DLL, con el nombre
      completo de la DLL mas .log (p. ej. logs\MiFiltro.dll.log). Se crea si no
      existe; si no se puede crear, se usa la carpeta de la DLL. La identidad
      del grupo de aplicaciones de IIS necesita permiso de escritura ahi. Al
      pasar de 2 MB el fichero se renombra a .log.old (se sobrescribe el
      anterior).
    - En OutputDebugString, para verlo con DebugView o en el IDE.

  Un fallo al escribir el log nunca se propaga: no puede romper una peticion.
*)
unit uLog;

interface

procedure Log(const Msg: string); overload;
procedure Log(const Fmt: string; const Args: array of const); overload;
// Llamar solo desde dentro de un bloque except: registra la excepcion actual.
procedure LogException(const Context: string);
// Registra un codigo de error de Windows (p. ej. GetLastError) con su texto.
procedure LogWinError(const Context: string; ErrorCode: Cardinal);

implementation

{$IFDEF DEBUG}

uses
  Windows,
  SysUtils,
  uIdentity;

const
  MAX_LOG_SIZE = 2 * 1024 * 1024;
  LOG_APPEND_DATA = $0004; // FILE_APPEND_DATA: escribe siempre al final

var
  GLock: TRTLCriticalSection;
  GLogFile: string;
  GLogReady: Boolean = False;

function ModuleFileName: string;
var
  Buffer: array[0..1023] of WideChar;
  Len: DWORD;
begin
  Len := GetModuleFileNameW(HInstance, Buffer, Length(Buffer));
  if Len = 0 then
    Result := ''
  else
    SetString(Result, Buffer, Len);
end;

// <carpeta de la DLL>\logs\<nombre de la DLL>.log. Si no se puede crear la
// carpeta logs, se usa la carpeta de la DLL.
function LogFileName: string;
var
  Module, Dir: string;
begin
  Module := ModuleFileName;
  if Module = '' then
  begin
    Result := '';
    Exit;
  end;
  Dir := ExtractFilePath(Module) + 'logs\';
  if not DirectoryExists(Dir) and not ForceDirectories(Dir) then
    Dir := ExtractFilePath(Module);
  Result := Dir + ExtractFileName(Module) + '.log';
end;

function OpenLogFile: THandle;
begin
  Result := CreateFile(PChar(GLogFile), LOG_APPEND_DATA,
    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_ALWAYS,
    FILE_ATTRIBUTE_NORMAL, 0);
end;

procedure WriteToFile(const Line: string);
var
  H: THandle;
  Info: TWin32FileAttributeData;
  Data: UTF8String;
  Written: DWORD;
begin
  if GLogFile = '' then
    Exit;
  // Rotacion simple: si el fichero es demasiado grande, pasa a .log.old
  if GetFileAttributesEx(PChar(GLogFile), GetFileExInfoStandard, @Info) and
     (Info.nFileSizeHigh = 0) and (Info.nFileSizeLow > MAX_LOG_SIZE) then
    MoveFileEx(PChar(GLogFile), PChar(GLogFile + '.old'), MOVEFILE_REPLACE_EXISTING);
  H := OpenLogFile;
  if H = INVALID_HANDLE_VALUE then
    Exit;
  try
    Data := UTF8Encode(Line + #13#10);
    if Length(Data) > 0 then
      WriteFile(H, Data[1], Length(Data), Written, nil);
  finally
    CloseHandle(H);
  end;
end;

procedure Log(const Msg: string);
var
  Line: string;
  Tok: THandle;
begin
  try
    Line := Format('%s [%d:%d] %s',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now),
       GetCurrentProcessId, GetCurrentThreadId, Msg]);
    EnterCriticalSection(GLock);
    try
      // Los hilos de peticion de IIS suplantan a otro usuario, que no puede
      // escribir en la carpeta: se escribe con la identidad del proceso.
      Tok := RevertToProcessIdentity;
      try
        if not GLogReady then
        begin
          GLogFile := LogFileName;
          GLogReady := True;
        end;
        WriteToFile(Line);
      finally
        RestoreIdentity(Tok);
      end;
    finally
      LeaveCriticalSection(GLock);
    end;
    OutputDebugString(PChar('[FilterLoader] ' + Line));
  except
    // el log nunca debe romper el filtro
  end;
end;

procedure Log(const Fmt: string; const Args: array of const);
begin
  try
    Log(Format(Fmt, Args));
  except
    Log(Fmt);
  end;
end;

procedure LogException(const Context: string);
var
  Obj: TObject;
begin
  Obj := ExceptObject;
  if Obj is Exception then
    Log('EXCEPCION en %s: %s: %s', [Context, Obj.ClassName, Exception(Obj).Message])
  else
    Log('EXCEPCION en %s: (objeto de excepcion desconocido)', [Context]);
end;

procedure LogWinError(const Context: string; ErrorCode: Cardinal);
begin
  Log('%s: error de Windows %d - %s', [Context, ErrorCode, SysErrorMessage(ErrorCode)]);
end;

initialization
  InitializeCriticalSection(GLock);

finalization
  DeleteCriticalSection(GLock);

{$ELSE}

procedure Log(const Msg: string);
begin
end;

procedure Log(const Fmt: string; const Args: array of const);
begin
end;

procedure LogException(const Context: string);
begin
end;

procedure LogWinError(const Context: string; ErrorCode: Cardinal);
begin
end;

{$ENDIF}

end.
