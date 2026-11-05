(*
  uTest - Autocomprobacion del cargador: comprueba si IIS sirve los ficheros .run, .upd y .bak.

  Se activa llamando a la extension con PATH_INFO = /test, p. ej.
      http://localhost/WebService/MiServicio.dll/test
  El cargador atiende esta peticion el mismo cargador, sin pasarsela al hijo.

  Como funciona:
    1. Crea en la carpeta de la DLL tres ficheros centinela inofensivos
       (__probe_<id>.run, .upd y .bak) con un texto fijo. NO se usa la DLL real.
    2. Pide cada uno a IIS por HTTP (WinHTTP, al mismo servidor y puerto) y mira
       el codigo de estado y si llega el texto del centinela.
    3. Borra los centinelas y responde en texto plano con el resultado.

  Solo responde a peticiones del propio servidor (127.0.0.1 o ::1).
*)
unit uTest;

interface

uses
  ISAPI2,
  Windows;

type
  // Aplica la actualizacion pendiente (si la hay) sin esperar al intervalo de
  // comprobacion y devuelve el texto del resultado, que empieza por ACTUALIZADO,
  // SIN ACTUALIZACION, BLOQUEADA o NO APLICADA.
  TForceUpdateEvent = function: string of object;

// True si la peticion es la de autocomprobacion (PATH_INFO = /test)
function IsTestRequest(pECB: PEXTENSION_CONTROL_BLOCK): Boolean;
// Ejecuta la comprobacion y responde a IIS. Devuelve el resultado de HttpExtensionProc.
// Ademas informa de si hay una actualizacion (.upd) pendiente; /test NO la aplica.
function RunTest(pECB: PEXTENSION_CONTROL_BLOCK; const ModuleFile: string;
  CheckIntervalMs: DWORD): DWORD;

// True si la peticion es la de actualizacion bajo demanda (PATH_INFO = /update)
function IsUpdateRequest(pECB: PEXTENSION_CONTROL_BLOCK): Boolean;
// Aplica el .upd si existe (sin esperar al intervalo) y responde a IIS en texto plano.
function RunUpdate(pECB: PEXTENSION_CONTROL_BLOCK; const ModuleFile: string;
  ForceUpdate: TForceUpdateEvent): DWORD;

implementation

uses
  Classes,
  SysUtils,
  uIdentity,
  uLog;

const
  TEST_PATH = '/test';
  UPDATE_PATH = '/update';
  PROBE_EXTS: array[0..2] of string = ('.run', '.upd', '.bak');

  HSE_STATUS_OK = 1;     // HSE_STATUS_SUCCESS
  HSE_STATUS_ERR = 4;    // HSE_STATUS_ERROR

  WINHTTP_ACCESS_TYPE_NO_PROXY = 1;
  WINHTTP_FLAG_SECURE = $00800000;
  WINHTTP_OPTION_REDIRECT_POLICY = 88;
  WINHTTP_OPTION_REDIRECT_POLICY_NEVER = 0;
  WINHTTP_OPTION_SECURITY_FLAGS = 31;
  // Ignora certificado desconocido, fecha, nombre y uso incorrectos: solo
  // interesa el codigo de estado, no la validez del certificado.
  WINHTTP_SECURITY_IGNORE_ALL = $3300;
  WINHTTP_QUERY_STATUS_CODE = 19;
  WINHTTP_QUERY_FLAG_NUMBER = $20000000;

type
  HINTERNET = Pointer;

function WinHttpOpen(pwszUserAgent: PWideChar; dwAccessType: DWORD; pwszProxyName,
  pwszProxyBypass: PWideChar; dwFlags: DWORD): HINTERNET; stdcall; external 'winhttp.dll';
function WinHttpConnect(hSession: HINTERNET; pswzServerName: PWideChar;
  nServerPort: Word; dwReserved: DWORD): HINTERNET; stdcall; external 'winhttp.dll';
function WinHttpOpenRequest(hConnect: HINTERNET; pwszVerb, pwszObjectName, pwszVersion,
  pwszReferrer: PWideChar; ppwszAcceptTypes: Pointer; dwFlags: DWORD): HINTERNET; stdcall; external 'winhttp.dll';
function WinHttpSetOption(hInternet: HINTERNET; dwOption: DWORD; lpBuffer: Pointer;
  dwBufferLength: DWORD): BOOL; stdcall; external 'winhttp.dll';
function WinHttpSetTimeouts(hInternet: HINTERNET; nResolveTimeout, nConnectTimeout,
  nSendTimeout, nReceiveTimeout: Integer): BOOL; stdcall; external 'winhttp.dll';
function WinHttpSendRequest(hRequest: HINTERNET; pwszHeaders: PWideChar; dwHeadersLength: DWORD;
  lpOptional: Pointer; dwOptionalLength, dwTotalLength: DWORD; dwContext: NativeUInt): BOOL; stdcall; external 'winhttp.dll';
function WinHttpReceiveResponse(hRequest: HINTERNET; lpReserved: Pointer): BOOL; stdcall; external 'winhttp.dll';
function WinHttpQueryHeaders(hRequest: HINTERNET; dwInfoLevel: DWORD; pwszName: PWideChar;
  lpBuffer: Pointer; var lpdwBufferLength: DWORD; lpdwIndex: Pointer): BOOL; stdcall; external 'winhttp.dll';
function WinHttpReadData(hRequest: HINTERNET; lpBuffer: Pointer; dwNumberOfBytesToRead: DWORD;
  var lpdwNumberOfBytesRead: DWORD): BOOL; stdcall; external 'winhttp.dll';
function WinHttpCloseHandle(hInternet: HINTERNET): BOOL; stdcall; external 'winhttp.dll';

function ServerVar(pECB: PEXTENSION_CONTROL_BLOCK; const Name: AnsiString): string;
var
  Buf: array[0..2047] of AnsiChar;
  Size: DWORD;
begin
  Result := '';
  Size := SizeOf(Buf);
  FillChar(Buf, SizeOf(Buf), 0);
  if pECB^.GetServerVariable(pECB^.ConnID, PUTF8Char(Name), @Buf, Size) then
    Result := string(AnsiString(PAnsiChar(@Buf)));
end;

function PathInfoIs(pECB: PEXTENSION_CONTROL_BLOCK; const Path: string): Boolean;
begin
  Result := (pECB <> nil) and (pECB^.lpszPathInfo <> nil) and
    SameText(string(AnsiString(PAnsiChar(pECB^.lpszPathInfo))), Path);
end;

function IsTestRequest(pECB: PEXTENSION_CONTROL_BLOCK): Boolean;
begin
  Result := PathInfoIs(pECB, TEST_PATH);
end;

function IsUpdateRequest(pECB: PEXTENSION_CONTROL_BLOCK): Boolean;
begin
  Result := PathInfoIs(pECB, UPDATE_PATH);
end;

// Las peticiones especiales solo se atienden desde el propio servidor
function IsLocalRequest(pECB: PEXTENSION_CONTROL_BLOCK; out Remote: string): Boolean;
begin
  Remote := ServerVar(pECB, 'REMOTE_ADDR');
  Result := (Remote = '127.0.0.1') or (Remote = '::1');
end;

function SendText(pECB: PEXTENSION_CONTROL_BLOCK; const Status, Text: string): DWORD;
var
  Body: UTF8String;
  Headers, StatusA: AnsiString;
  Bytes: DWORD;
begin
  Body := UTF8Encode(Text);
  StatusA := AnsiString(Status);
  Headers := AnsiString('Content-Type: text/plain; charset=utf-8'#13#10 +
    'Cache-Control: no-store'#13#10#13#10);
  if pECB^.ServerSupportFunction(pECB^.ConnID, HSE_REQ_SEND_RESPONSE_HEADER,
       PAnsiChar(StatusA), nil, LPDWORD(PAnsiChar(Headers))) then
  begin
    Bytes := Length(Body);
    if Bytes <> 0 then
      pECB^.WriteClient(pECB^.ConnID, PAnsiChar(Body), Bytes, 0);
    Result := HSE_STATUS_OK;
  end
  else
    Result := HSE_STATUS_ERR;
end;

// Pide Path al servidor. Devuelve el codigo HTTP (0 si no se pudo) y el
// principio del cuerpo; en Error el motivo si no se pudo.
function HttpGet(const Host: string; Port: Word; Secure: Boolean; const Path: string;
  out Body: string; out Error: string): Integer;
var
  Session, Conn, Req: HINTERNET;
  Flags, Status, Len, Got: DWORD;
  Opt: DWORD;
  Raw: array[0..511] of AnsiChar;
begin
  Result := 0;
  Body := '';
  Error := '';
  Session := WinHttpOpen('FilterLoaderTest/1.0', WINHTTP_ACCESS_TYPE_NO_PROXY, nil, nil, 0);
  if Session = nil then
  begin
    Error := SysErrorMessage(GetLastError);
    Exit;
  end;
  Conn := nil;
  Req := nil;
  try
    WinHttpSetTimeouts(Session, 5000, 5000, 5000, 10000);
    Conn := WinHttpConnect(Session, PWideChar(WideString(Host)), Port, 0);
    if Conn = nil then
    begin
      Error := SysErrorMessage(GetLastError);
      Exit;
    end;
    Flags := 0;
    if Secure then
      Flags := WINHTTP_FLAG_SECURE;
    Req := WinHttpOpenRequest(Conn, 'GET', PWideChar(WideString(Path)), nil, nil, nil, Flags);
    if Req = nil then
    begin
      Error := SysErrorMessage(GetLastError);
      Exit;
    end;
    Opt := WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    WinHttpSetOption(Req, WINHTTP_OPTION_REDIRECT_POLICY, @Opt, SizeOf(Opt));
    if Secure then
    begin
      Opt := WINHTTP_SECURITY_IGNORE_ALL;
      WinHttpSetOption(Req, WINHTTP_OPTION_SECURITY_FLAGS, @Opt, SizeOf(Opt));
    end;
    if not (WinHttpSendRequest(Req, nil, 0, nil, 0, 0, 0) and WinHttpReceiveResponse(Req, nil)) then
    begin
      Error := SysErrorMessage(GetLastError);
      Exit;
    end;
    Len := SizeOf(Status);
    if WinHttpQueryHeaders(Req, WINHTTP_QUERY_STATUS_CODE or WINHTTP_QUERY_FLAG_NUMBER,
         nil, @Status, Len, nil) then
      Result := Status;
    Got := 0;
    FillChar(Raw, SizeOf(Raw), 0);
    if WinHttpReadData(Req, @Raw, SizeOf(Raw) - 1, Got) and (Got <> 0) then
      Body := string(AnsiString(PAnsiChar(@Raw)));
  finally
    if Req <> nil then WinHttpCloseHandle(Req);
    if Conn <> nil then WinHttpCloseHandle(Conn);
    WinHttpCloseHandle(Session);
  end;
end;

function WriteProbe(const FileName, Token: string): Boolean;
var
  FS: TFileStream;
  Data: AnsiString;
begin
  Result := False;
  try
    FS := TFileStream.Create(FileName, fmCreate);
    try
      Data := AnsiString(Token);
      FS.WriteBuffer(Data[1], Length(Data));
    finally
      FS.Free;
    end;
    Result := True;
  except
  end;
end;

// Texto sobre si hay un .upd esperando. No cambia nada: solo informa.
function PendingUpdateText(const ModuleFile: string; CheckIntervalMs: DWORD): string;
var
  UpdFile, UpdName: string;
  SR: TSearchRec;
  Tok: THandle;
  Found: Boolean;
begin
  UpdFile := ChangeFileExt(ModuleFile, '.upd');
  UpdName := ExtractFileName(UpdFile);
  Found := False;
  Result := '';
  // Los hilos de peticion suplantan a otro usuario: se mira con la identidad del proceso
  Tok := RevertToProcessIdentity;
  try
    if FindFirst(UpdFile, faAnyFile, SR) = 0 then
    try
      Found := True;
      Result := Format('Actualizacion pendiente: SI - existe %s (%d bytes, %s).',
        [UpdName, SR.Size, FormatDateTime('yyyy-mm-dd hh:nn:ss', SR.TimeStamp)]);
    finally
      FindClose(SR);
    end;
  finally
    RestoreIdentity(Tok);
  end;
  if not Found then
    Result := Format('Actualizacion pendiente: no (no existe %s).', [UpdName]);
  Result := Result + #13#10 +
    '  /test NO aplica actualizaciones. Un .upd solo se aplica en la primera peticion normal' + #13#10 +
    Format('  (que no sea /test ni /update) pasado el intervalo de comprobacion (%d ms desde la anterior),', [CheckIntervalMs]) + #13#10 +
    '  o llamando a /update.';
end;

function RunTest(pECB: PEXTENSION_CONTROL_BLOCK; const ModuleFile: string;
  CheckIntervalMs: DWORD): DWORD;
var
  Remote, ScriptName, HostHdr, Host, FolderUrl, Id, Token, FileName, Url, Body, Err: string;
  Port: Word;
  Secure: Boolean;
  I, P, Code: Integer;
  Lines: TStringList;
  Dangerous, Failed: Boolean;
  SchemeName: string;
begin
  if not IsLocalRequest(pECB, Remote) then
  begin
    Log('Test: rechazado, la peticion no viene del propio servidor (REMOTE_ADDR=%s)', [Remote]);
    Result := SendText(pECB, '403 Forbidden', 'La comprobacion /test solo esta disponible desde el propio servidor.'#13#10);
    Exit;
  end;

  ScriptName := ServerVar(pECB, 'SCRIPT_NAME');
  HostHdr := ServerVar(pECB, 'HTTP_HOST');
  Port := Word(StrToIntDef(ServerVar(pECB, 'SERVER_PORT'), 80));
  Secure := ServerVar(pECB, 'SERVER_PORT_SECURE') = '1';
  // HTTP_HOST puede traer el puerto (host:puerto) o ir entre corchetes (IPv6)
  Host := HostHdr;
  if (Host <> '') and (Host[1] = '[') then
  begin
    P := Pos(']', Host);
    if P > 0 then Host := Copy(Host, 1, P);
  end
  else
  begin
    P := Pos(':', Host);
    if P > 0 then Host := Copy(Host, 1, P - 1);
  end;
  if Host = '' then
    Host := 'localhost';
  P := LastDelimiter('/', ScriptName);
  FolderUrl := Copy(ScriptName, 1, P);   // incluye la barra final
  if FolderUrl = '' then
    FolderUrl := '/';

  Id := IntToHex(GetTickCount, 8) + IntToHex(GetCurrentProcessId, 4);
  Token := 'FILTERLOADER-PROBE-' + Id;
  if Secure then SchemeName := 'https' else SchemeName := 'http';
  Dangerous := False;
  Failed := False;

  Lines := TStringList.Create;
  try
    Lines.Add('FilterLoader - comprobacion de ficheros .run / .upd / .bak');
    Lines.Add('DLL: ' + ModuleFile);
    Lines.Add(Format('Sitio: %s://%s:%d%s', [SchemeName, Host, Port, FolderUrl]));
    Lines.Add('');
    for I := Low(PROBE_EXTS) to High(PROBE_EXTS) do
    begin
      FileName := ExtractFilePath(ModuleFile) + '__probe_' + Id + PROBE_EXTS[I];
      Url := FolderUrl + '__probe_' + Id + PROBE_EXTS[I];
      if not WriteProbe(FileName, Token) then
      begin
        Lines.Add(Format('%s: NO COMPROBADO - no se pudo crear el fichero de prueba en la carpeta (permiso de escritura)', [PROBE_EXTS[I]]));
        Failed := True;
        Continue;
      end;
      try
        Code := HttpGet(Host, Port, Secure, Url, Body, Err);
      finally
        DeleteFile(PChar(FileName));
      end;
      if Code = 0 then
      begin
        Lines.Add(Format('%s: NO COMPROBADO - %s', [PROBE_EXTS[I], Err]));
        Failed := True;
      end
      else if (Code = 200) and (Pos(Token, Body) > 0) then
      begin
        Lines.Add(Format('%s: PELIGRO - IIS lo DESCARGA (HTTP 200). Hay un tipo MIME o manejador que sirve esta extension.', [PROBE_EXTS[I]]));
        Dangerous := True;
      end
      else if Code = 200 then
      begin
        Lines.Add(Format('%s: REVISAR - HTTP 200 pero sin el contenido de prueba (pagina de error personalizada o documento por defecto).', [PROBE_EXTS[I]]));
        Failed := True;
      end
      else
        Lines.Add(Format('%s: correcto - IIS no lo sirve (HTTP %d).', [PROBE_EXTS[I], Code]));
    end;
    Lines.Add('');
    Lines.Add(PendingUpdateText(ModuleFile, CheckIntervalMs));
    Lines.Add('');
    if Dangerous then
      Lines.Add('RESULTADO: INSEGURO - quita el tipo MIME o el manejador que sirve esas extensiones en esta carpeta.')
    else if Failed then
      Lines.Add('RESULTADO: INCOMPLETO - alguna extension no se pudo comprobar, ver arriba.')
    else
      Lines.Add('RESULTADO: CORRECTO - IIS no sirve ninguno de los tres ficheros.');
    Log('Test: %s', [Lines[Lines.Count - 1]]);
    Result := SendText(pECB, '200 OK', Lines.Text);
  finally
    Lines.Free;
  end;
end;

function RunUpdate(pECB: PEXTENSION_CONTROL_BLOCK; const ModuleFile: string;
  ForceUpdate: TForceUpdateEvent): DWORD;
var
  Remote, Res, Status: string;
begin
  if not IsLocalRequest(pECB, Remote) then
  begin
    Log('Update: rechazado, la peticion no viene del propio servidor (REMOTE_ADDR=%s)', [Remote]);
    Result := SendText(pECB, '403 Forbidden', 'La actualizacion /update solo esta disponible desde el propio servidor.'#13#10);
    Exit;
  end;

  try
    Res := ForceUpdate();
  except
    LogException('RunUpdate');
    Res := 'ERROR - fallo inesperado al actualizar; ver el log (compilacion Debug).';
  end;
  Log('Update: %s', [Res]);

  // 200 si no hay nada pendiente o se aplico; 409 si hay un .upd que no se pudo aplicar
  if (Pos('ACTUALIZADO', Res) = 1) or (Pos('SIN ACTUALIZACION', Res) = 1) then
    Status := '200 OK'
  else
    Status := '409 Conflict';
  Result := SendText(pECB, Status,
    'FilterLoader - actualizacion bajo demanda'#13#10 +
    'DLL: ' + ModuleFile + #13#10#13#10 +
    'RESULTADO: ' + Res + #13#10);
end;

end.
