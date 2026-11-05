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
  // Resultado de intentar aplicar la actualizacion pendiente
  TUpdateOutcome = (uoUpdated, uoNone, uoNotApplied, uoBlocked, uoError);

  TUpdateResult = record
    Outcome: TUpdateOutcome;
    FileName: string;     // nombre del .upd, sin ruta
    ElapsedMs: DWORD;     // solo si uoUpdated
    ChildReady: Boolean;  // solo si uoUpdated: la version nueva se inicializo
  end;

  // Aplica la actualizacion pendiente (si la hay) sin esperar al intervalo de
  // comprobacion. El texto lo compone uTest segun el idioma.
  TForceUpdateEvent = function: TUpdateResult of object;

// True si la peticion es la de autocomprobacion (PATH_INFO = /test)
function IsTestRequest(pECB: PEXTENSION_CONTROL_BLOCK): Boolean;
// Ejecuta la comprobacion y responde a IIS. Devuelve el resultado de HttpExtensionProc.
// Ademas informa de si hay una actualizacion (.upd) pendiente; /test NO la aplica.
function RunTest(pECB: PEXTENSION_CONTROL_BLOCK; const ModuleFile: string;
  CheckIntervalMs: DWORD): DWORD;

// True si la peticion es la de actualizacion bajo demanda (PATH_INFO = /update)
function IsUpdateRequest(pECB: PEXTENSION_CONTROL_BLOCK): Boolean;
// Aplica el .upd si existe (sin esperar al intervalo) y responde a IIS en texto plano.
function RunUpdate(pECB: PEXTENSION_CONTROL_BLOCK; ForceUpdate: TForceUpdateEvent): DWORD;

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

function SendBody(pECB: PEXTENSION_CONTROL_BLOCK; const Status, ContentType, Extra, Text: string): DWORD;
var
  Body: UTF8String;
  Headers, StatusA: AnsiString;
  Bytes: DWORD;
begin
  Body := UTF8Encode(Text);
  StatusA := AnsiString(Status);
  Headers := AnsiString('Content-Type: ' + ContentType + #13#10 + Extra +
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

function SendText(pECB: PEXTENSION_CONTROL_BLOCK; const Status, Text: string): DWORD;
begin
  Result := SendBody(pECB, Status, 'text/plain; charset=utf-8', '', Text);
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

// ---------------------------------------------------------------------------
// Idioma: ingles (por defecto) o castellano
// ---------------------------------------------------------------------------

type
  TLang = (lgEn, lgEs);

function Tx(L: TLang; const En, Es: string): string;
begin
  if L = lgEs then
    Result := Es
  else
    Result := En;
end;

// Idioma de la respuesta: ?lang=es o ?lang=en si se indica; si no, el de
// Accept-Language (gana el de mayor prioridad entre es y en); si no se sabe, ingles.
function PickLang(pECB: PEXTENSION_CONTROL_BLOCK): TLang;
var
  Q, Part, Tag: string;
  Items: TStringList;
  I, P: Integer;
  QVal, BestEs, BestEn: Double;
  FS: TFormatSettings;
begin
  Result := lgEn;
  try
    Q := LowerCase(ServerVar(pECB, 'QUERY_STRING'));
    if Pos('lang=es', Q) > 0 then
    begin
      Result := lgEs;
      Exit;
    end;
    if Pos('lang=en', Q) > 0 then
      Exit;

    FS := TFormatSettings.Create;
    FS.DecimalSeparator := '.';
    BestEs := -1;
    BestEn := -1;
    Items := TStringList.Create;
    try
      Items.StrictDelimiter := True;
      Items.Delimiter := ',';
      Items.DelimitedText := LowerCase(ServerVar(pECB, 'HTTP_ACCEPT_LANGUAGE'));
      for I := 0 to Items.Count - 1 do
      begin
        Part := Trim(Items[I]);
        Tag := Part;
        QVal := 1.0;
        P := Pos(';', Part);
        if P > 0 then
        begin
          Tag := Trim(Copy(Part, 1, P - 1));
          QVal := StrToFloatDef(Trim(StringReplace(Copy(Part, P + 1, MaxInt), 'q=', '', [])), 1.0, FS);
        end;
        if (Copy(Tag, 1, 2) = 'es') and (QVal > BestEs) then BestEs := QVal;
        if (Copy(Tag, 1, 2) = 'en') and (QVal > BestEn) then BestEn := QVal;
      end;
    finally
      Items.Free;
    end;
    if BestEs > BestEn then
      Result := lgEs;
  except
    Result := lgEn;
  end;
end;

// ---------------------------------------------------------------------------
// Salida: texto plano (scripts, Postman) o pagina HTML (navegador)
// ---------------------------------------------------------------------------

type
  TProbeState = (psOk, psDanger, psReview, psUnchecked);

  TProbeItem = record
    Ext: string;
    State: TProbeState;
    Detail: string;
  end;

  TPendingInfo = record
    Found: Boolean;
    Name: string;
    Size: Int64;
    Stamp: TDateTime;
  end;

const
  PAGE_CSS =
    ':root{--bg:#f1f5f9;--card:#ffffff;--tx:#0f172a;--mut:#64748b;--line:#e2e8f0;' +
    '--ok:#15803d;--okbg:#dcfce7;--bad:#b91c1c;--badbg:#fee2e2;--warn:#b45309;--warnbg:#fef3c7;' +
    '--info:#1d4ed8;--infobg:#dbeafe}' +
    '@media (prefers-color-scheme:dark){:root{--bg:#0b1220;--card:#162033;--tx:#e2e8f0;--mut:#94a3b8;' +
    '--line:#2a3a55;--ok:#4ade80;--okbg:#14391f;--bad:#f87171;--badbg:#431515;--warn:#fbbf24;' +
    '--warnbg:#3f2a0a;--info:#60a5fa;--infobg:#14284f}}' +
    '*{box-sizing:border-box}' +
    'body{margin:0;background:var(--bg);color:var(--tx);font:15px/1.5 "Segoe UI",system-ui,-apple-system,sans-serif}' +
    'main{max-width:860px;margin:0 auto;padding:24px 16px 40px}' +
    'header h1{margin:0;font-size:26px;letter-spacing:.2px}header .sub{margin:2px 0 18px;color:var(--mut)}' +
    '.banner{display:flex;gap:16px;align-items:center;padding:18px 20px;border-radius:14px;' +
    'border:1px solid var(--line);margin-bottom:16px}' +
    '.banner .ic{font-size:30px;width:56px;height:56px;border-radius:50%;flex:none;display:flex;' +
    'align-items:center;justify-content:center;background:var(--card)}' +
    '.banner h2{margin:0;font-size:22px}.banner p{margin:2px 0 0;color:var(--tx)}' +
    '.banner.ok{background:var(--okbg);color:var(--ok)}.banner.bad{background:var(--badbg);color:var(--bad)}' +
    '.banner.warn{background:var(--warnbg);color:var(--warn)}.banner.info{background:var(--infobg);color:var(--info)}' +
    '.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 20px;' +
    'margin-bottom:16px;box-shadow:0 1px 2px rgba(0,0,0,.04)}' +
    '.card h3{margin:0 0 10px;font-size:16px}.mut{color:var(--mut)}' +
    'table{width:100%;border-collapse:collapse}' +
    'th,td{text-align:left;padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:top}' +
    'th{font-size:12px;text-transform:uppercase;letter-spacing:.6px;color:var(--mut)}tr:last-child td{border-bottom:0}' +
    'code{background:var(--bg);padding:1px 6px;border-radius:6px;font-family:Consolas,monospace}' +
    '.badge{display:inline-block;padding:2px 10px;border-radius:999px;font-size:13px;font-weight:600;white-space:nowrap}' +
    '.badge.ok{background:var(--okbg);color:var(--ok)}.badge.bad{background:var(--badbg);color:var(--bad)}' +
    '.badge.warn{background:var(--warnbg);color:var(--warn)}' +
    '.btn{display:inline-block;margin:6px 8px 0 0;padding:9px 16px;border-radius:10px;background:var(--info);' +
    'color:#fff;text-decoration:none;font-weight:600}' +
    '.btn.sec{background:transparent;color:var(--info);border:1px solid var(--info)}' +
    'footer{margin-top:22px;color:var(--mut);font-size:13px;text-align:center}';

function HtmlEsc(const S: string): string;
begin
  Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

// HTML si el cliente lo pide (navegador); texto plano en caso contrario. Se puede
// forzar con ?format=text o ?format=html.
function WantsHtml(pECB: PEXTENSION_CONTROL_BLOCK): Boolean;
var
  Q: string;
begin
  Q := LowerCase(ServerVar(pECB, 'QUERY_STRING'));
  if Pos('format=text', Q) > 0 then
    Result := False
  else if Pos('format=html', Q) > 0 then
    Result := True
  else
    Result := Pos('text/html', LowerCase(ServerVar(pECB, 'HTTP_ACCEPT'))) > 0;
end;

// Responde en HTML o en texto plano. Extra son cabeceras HTTP adicionales: las
// X-FilterLoader-* llevan un codigo estable en ingles, igual en todos los idiomas,
// para que los scripts no dependan del texto traducido.
function Reply(pECB: PEXTENSION_CONTROL_BLOCK; const Status: string; AsHtml: Boolean;
  const Body, Extra: string): DWORD;
begin
  if AsHtml then
    Result := SendBody(pECB, Status, 'text/html; charset=utf-8', Extra, Body)
  else
    Result := SendBody(pECB, Status, 'text/plain; charset=utf-8', Extra, Body);
end;

function HtmlPage(L: TLang; const Subtitle, Kind, Headline, Lead, Body: string): string;
var
  Icon: string;
begin
  if Kind = 'ok' then
    Icon := '&#10004;'
  else if Kind = 'bad' then
    Icon := '&#10006;'
  else if Kind = 'warn' then
    Icon := '&#9888;'
  else
    Icon := '&#8505;';
  Result :=
    '<!doctype html><html lang="' + Tx(L, 'en', 'es') + '"><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width,initial-scale=1">' +
    '<title>FilterLoader</title><style>' + PAGE_CSS + '</style></head><body><main>' +
    '<header><h1>&#128260; FilterLoader</h1><p class="sub">' + Subtitle + '</p></header>' +
    '<section class="banner ' + Kind + '"><div class="ic">' + Icon + '</div><div><h2>' +
    HtmlEsc(Headline) + '</h2><p>' + HtmlEsc(Lead) + '</p></div></section>' +
    Body +
    '<footer>' + Tx(L, 'Generated on ', 'Generado el ') + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) +
    Tx(L, ' (server time)', ' (hora del servidor)') + '</footer>' +
    '</main></body></html>';
end;

// URL de una peticion especial de esta misma DLL, p. ej. /WebService/Mi.dll/update
function SpecialUrl(pECB: PEXTENSION_CONTROL_BLOCK; const Path: string): string;
begin
  Result := ServerVar(pECB, 'SCRIPT_NAME') + Path;
  // se conserva el idioma si se forzo en la URL
  if Pos('lang=es', LowerCase(ServerVar(pECB, 'QUERY_STRING'))) > 0 then
    Result := Result + '?lang=es'
  else if Pos('lang=en', LowerCase(ServerVar(pECB, 'QUERY_STRING'))) > 0 then
    Result := Result + '?lang=en';
end;

function GetPendingInfo(const ModuleFile: string): TPendingInfo;
var
  UpdFile: string;
  SR: TSearchRec;
  Tok: THandle;
begin
  Result.Found := False;
  Result.Size := 0;
  Result.Stamp := 0;
  UpdFile := ChangeFileExt(ModuleFile, '.upd');
  Result.Name := ExtractFileName(UpdFile);
  // Los hilos de peticion suplantan a otro usuario: se mira con la identidad del proceso
  Tok := RevertToProcessIdentity;
  try
    if FindFirst(UpdFile, faAnyFile, SR) = 0 then
    try
      Result.Found := True;
      Result.Size := SR.Size;
      Result.Stamp := SR.TimeStamp;
    finally
      FindClose(SR);
    end;
  finally
    RestoreIdentity(Tok);
  end;
end;

// Texto sobre si hay un .upd esperando. No cambia nada: solo informa.
function PendingText(L: TLang; const Info: TPendingInfo; CheckIntervalMs: DWORD): string;
begin
  if Info.Found then
    Result := Format(Tx(L, 'Pending update: YES - %s exists (%d bytes, %s).',
        'Actualizacion pendiente: SI - existe %s (%d bytes, %s).'),
      [Info.Name, Info.Size, FormatDateTime('yyyy-mm-dd hh:nn:ss', Info.Stamp)]) + #13#10 +
      Tx(L, '  To apply it now, call /update.', '  Para aplicarla ahora, llama a /update.') + #13#10 +
      Tx(L, '  This /test request only reports, it does not apply it. If you do not call /update, it will be applied by the first',
            '  Esta peticion /test solo informa, no la aplica. Si no llamas a /update, se aplicara en la') + #13#10 +
      Format(Tx(L, '  normal request (not /test or /update) once the check interval has passed (%d ms).',
                   '  primera peticion normal (que no sea /test ni /update) pasado el intervalo de comprobacion (%d ms).'),
        [CheckIntervalMs])
  else
    Result := Format(Tx(L, 'Pending update: no (%s does not exist).', 'Actualizacion pendiente: no (no existe %s).'),
      [Info.Name]) + #13#10 +
      Tx(L, '  When there is a .upd, call /update to apply it.', '  Cuando haya un .upd, llama a /update para aplicarlo.');
end;

function PendingHtml(L: TLang; pECB: PEXTENSION_CONTROL_BLOCK; const Info: TPendingInfo;
  CheckIntervalMs: DWORD): string;
begin
  Result := '<section class="card"><h3>' + Tx(L, 'Pending update', 'Actualizaci&oacute;n pendiente') + '</h3>';
  if Info.Found then
    Result := Result +
      '<p><span class="badge warn">&#9203; ' + Tx(L, 'PENDING', 'PENDIENTE') + '</span> &nbsp;<code>' +
      HtmlEsc(Info.Name) + '</code> &middot; ' + FormatFloat('#,##0', Info.Size) + ' bytes &middot; ' +
      FormatDateTime('yyyy-mm-dd hh:nn:ss', Info.Stamp) + '</p>' +
      '<p>' + Tx(L, 'To apply it now, call <code>/update</code>.', 'Para aplicarla ahora, llama a <code>/update</code>.') + '</p>' +
      '<a class="btn" href="' + HtmlEsc(SpecialUrl(pECB, '/update')) + '">&#128260; ' +
      Tx(L, 'Apply now (/update)', 'Aplicar ahora (/update)') + '</a>' +
      '<p class="mut">' +
      Tx(L, 'This page (<code>/test</code>) only reports, it does not apply the update. If you do not call <code>/update</code>, ' +
            'it will be applied by the first normal request (not <code>/test</code> or <code>/update</code>) once the check ' +
            'interval has passed (',
            'Esta p&aacute;gina (<code>/test</code>) solo informa, no aplica la actualizaci&oacute;n. Si no llamas a ' +
            '<code>/update</code>, se aplicar&aacute; en la primera petici&oacute;n normal (que no sea <code>/test</code> ni ' +
            '<code>/update</code>) pasado el intervalo de comprobaci&oacute;n (') +
      IntToStr(CheckIntervalMs) + ' ms).</p>'
  else
    Result := Result +
      '<p><span class="badge ok">&#10004; ' + Tx(L, 'NONE', 'NINGUNA') + '</span> &nbsp;' +
      Tx(L, 'There is no <code>', 'No existe <code>') + HtmlEsc(Info.Name) + '</code>.</p>' +
      '<p class="mut">' + Tx(L, 'When there is a <code>.upd</code>, call <code>/update</code> to apply it.',
        'Cuando haya un <code>.upd</code>, llama a <code>/update</code> para aplicarlo.') + '</p>';
  Result := Result + '</section>';
end;

function ProbeStateLabel(L: TLang; S: TProbeState): string;
begin
  case S of
    psOk: Result := Tx(L, 'ok', 'correcto');
    psDanger: Result := Tx(L, 'DANGER', 'PELIGRO');
    psReview: Result := Tx(L, 'CHECK', 'REVISAR');
  else
    Result := Tx(L, 'NOT CHECKED', 'NO COMPROBADO');
  end;
end;

function ProbeRowsHtml(L: TLang; const Items: array of TProbeItem): string;
var
  I: Integer;
  Cls, Txt: string;
begin
  Result := '';
  for I := 0 to High(Items) do
  begin
    case Items[I].State of
      psOk: begin Cls := 'ok'; Txt := '&#10004; ' + Tx(L, 'OK', 'Correcto'); end;
      psDanger: begin Cls := 'bad'; Txt := '&#9888; ' + Tx(L, 'DANGER', 'PELIGRO'); end;
      psReview: begin Cls := 'warn'; Txt := '&#9888; ' + Tx(L, 'Check', 'Revisar'); end;
    else
      begin Cls := 'warn'; Txt := '? ' + Tx(L, 'Not checked', 'No comprobado'); end;
    end;
    Result := Result + '<tr><td><code>' + HtmlEsc(Items[I].Ext) + '</code></td>' +
      '<td><span class="badge ' + Cls + '">' + Txt + '</span></td><td>' +
      HtmlEsc(Items[I].Detail) + '</td></tr>';
  end;
end;

function RunTest(pECB: PEXTENSION_CONTROL_BLOCK; const ModuleFile: string;
  CheckIntervalMs: DWORD): DWORD;
var
  Remote, ScriptName, HostHdr, Host, FolderUrl, Id, Token, FileName, Url, Body, Err: string;
  Port: Word;
  Secure: Boolean;
  I, P, Code: Integer;
  Lines: TStringList;
  Items: array[0..High(PROBE_EXTS)] of TProbeItem;
  Dangerous, Failed, AsHtml: Boolean;
  SchemeName, SiteText, Kind, Headline, Lead, Final, Code2, Extra, LogText: string;
  Pending: TPendingInfo;
  L: TLang;
begin
  L := PickLang(pECB);
  AsHtml := WantsHtml(pECB);
  if not IsLocalRequest(pECB, Remote) then
  begin
    Log('Test: rejected, the request does not come from the server itself (REMOTE_ADDR=%s)', [Remote]);
    Result := SendText(pECB, '403 Forbidden', Tx(L,
      'The /test check is only available from the server itself.',
      'La comprobacion /test solo esta disponible desde el propio servidor.') + #13#10);
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
  SiteText := Format('%s://%s:%d%s', [SchemeName, Host, Port, FolderUrl]);
  Dangerous := False;
  Failed := False;

  // 1. Comprobacion de cada extension (no se muestra la ruta de la DLL: no hace
  //    falta y no conviene revelarla)
  for I := Low(PROBE_EXTS) to High(PROBE_EXTS) do
  begin
    Items[I].Ext := PROBE_EXTS[I];
    FileName := ExtractFilePath(ModuleFile) + '__probe_' + Id + PROBE_EXTS[I];
    Url := FolderUrl + '__probe_' + Id + PROBE_EXTS[I];
    if not WriteProbe(FileName, Token) then
    begin
      Items[I].State := psUnchecked;
      Items[I].Detail := Tx(L, 'could not create the probe file in the folder (write permission)',
        'no se pudo crear el fichero de prueba en la carpeta (permiso de escritura)');
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
      Items[I].State := psUnchecked;
      Items[I].Detail := Err;
      Failed := True;
    end
    else if (Code = 200) and (Pos(Token, Body) > 0) then
    begin
      Items[I].State := psDanger;
      Items[I].Detail := Tx(L, 'IIS DOWNLOADS it (HTTP 200). A MIME type or handler serves this extension.',
        'IIS lo DESCARGA (HTTP 200). Hay un tipo MIME o manejador que sirve esta extension.');
      Dangerous := True;
    end
    else if Code = 200 then
    begin
      Items[I].State := psReview;
      Items[I].Detail := Tx(L, 'HTTP 200 but without the probe content (custom error page or default document).',
        'HTTP 200 pero sin el contenido de prueba (pagina de error personalizada o documento por defecto).');
      Failed := True;
    end
    else
    begin
      Items[I].State := psOk;
      Items[I].Detail := Format(Tx(L, 'IIS does not serve it (HTTP %d).', 'IIS no lo sirve (HTTP %d).'), [Code]);
    end;
  end;

  // 2. Resultado global; Code2 es el codigo estable (ingles) de la cabecera
  if Dangerous then
  begin
    Kind := 'bad';
    Code2 := 'UNSAFE';
    Headline := Tx(L, 'UNSAFE', 'INSEGURO');
    Lead := Tx(L, 'remove the MIME type or handler that serves those extensions in this folder.',
      'quita el tipo MIME o el manejador que sirve esas extensiones en esta carpeta.');
    LogText := 'UNSAFE - a MIME type or handler serves some of the probe files';
  end
  else if Failed then
  begin
    Kind := 'warn';
    Code2 := 'INCOMPLETE';
    Headline := Tx(L, 'INCOMPLETE', 'INCOMPLETO');
    Lead := Tx(L, 'some extension could not be checked, see the detail.',
      'alguna extension no se pudo comprobar, ver el detalle.');
    LogText := 'INCOMPLETE - some extension could not be checked';
  end
  else
  begin
    Kind := 'ok';
    Code2 := 'OK';
    Headline := Tx(L, 'OK', 'CORRECTO');
    Lead := Tx(L, 'IIS does not serve any of the three files.', 'IIS no sirve ninguno de los tres ficheros.');
    LogText := 'OK - IIS does not serve any of the three probe files';
  end;
  Final := Tx(L, 'RESULT: ', 'RESULTADO: ') + Headline + ' - ' + Lead;
  Log('Test: RESULT: %s', [LogText]);

  Pending := GetPendingInfo(ModuleFile);
  Extra := 'X-FilterLoader-Result: ' + Code2 + #13#10;
  if Pending.Found then
    Extra := Extra + 'X-FilterLoader-Pending: yes' + #13#10
  else
    Extra := Extra + 'X-FilterLoader-Pending: no' + #13#10;

  // 3. Salida: HTML para el navegador, texto plano para scripts y Postman
  if AsHtml then
  begin
    Result := Reply(pECB, '200 OK', True, HtmlPage(L,
      Tx(L, 'Loader self-check', 'Autocomprobaci&oacute;n del cargador'), Kind, Headline, Lead,
      '<section class="card"><h3>' + Tx(L, 'Probe files .run / .upd / .bak', 'Ficheros de prueba .run / .upd / .bak') +
      '</h3><p class="mut">' + Tx(L, 'Site: ', 'Sitio: ') + '<code>' + HtmlEsc(SiteText) + '</code>. ' +
      Tx(L, 'Three harmless files are created, requested from IIS over HTTP and deleted; the real DLL is not used.',
            'Se crean tres ficheros inofensivos, se piden a IIS por HTTP y se borran; no se usa la DLL real.') + '</p>' +
      '<table><thead><tr><th>' + Tx(L, 'Extension', 'Extensi&oacute;n') + '</th><th>' + Tx(L, 'Status', 'Estado') +
      '</th><th>' + Tx(L, 'Detail', 'Detalle') + '</th></tr></thead><tbody>' +
      ProbeRowsHtml(L, Items) + '</tbody></table></section>' +
      PendingHtml(L, pECB, Pending, CheckIntervalMs)), Extra);
    Exit;
  end;

  Lines := TStringList.Create;
  try
    Lines.Add(Tx(L, 'FilterLoader - check of the .run / .upd / .bak files',
      'FilterLoader - comprobacion de ficheros .run / .upd / .bak'));
    Lines.Add(Tx(L, 'Site: ', 'Sitio: ') + SiteText);
    Lines.Add('');
    for I := Low(Items) to High(Items) do
      Lines.Add(Format('%s: %s - %s', [Items[I].Ext, ProbeStateLabel(L, Items[I].State), Items[I].Detail]));
    Lines.Add('');
    Lines.Add(PendingText(L, Pending, CheckIntervalMs));
    Lines.Add('');
    Lines.Add(Final);
    Result := Reply(pECB, '200 OK', False, Lines.Text, Extra);
  finally
    Lines.Free;
  end;
end;

function RunUpdate(pECB: PEXTENSION_CONTROL_BLOCK; ForceUpdate: TForceUpdateEvent): DWORD;
var
  Remote, Status, Key, Code2, Msg, Kind, Body, LogText, Extra: string;
  R: TUpdateResult;
  L: TLang;
  AsHtml: Boolean;
begin
  L := PickLang(pECB);
  AsHtml := WantsHtml(pECB);
  if not IsLocalRequest(pECB, Remote) then
  begin
    Log('Update: rejected, the request does not come from the server itself (REMOTE_ADDR=%s)', [Remote]);
    Result := SendText(pECB, '403 Forbidden', Tx(L,
      'The /update request is only available from the server itself.',
      'La actualizacion /update solo esta disponible desde el propio servidor.') + #13#10);
    Exit;
  end;

  R.Outcome := uoError;
  R.FileName := '';
  R.ElapsedMs := 0;
  R.ChildReady := False;
  try
    R := ForceUpdate();
  except
    LogException('RunUpdate');
    R.Outcome := uoError;
  end;

  // Codigo estable (ingles) para la cabecera y el log, y texto segun el idioma.
  // 200 si no hay nada pendiente o se aplico; 409 si hay un .upd que no se pudo aplicar.
  case R.Outcome of
    uoUpdated:
      begin
        Status := '200 OK'; Kind := 'ok'; Code2 := 'UPDATED';
        Key := Tx(L, 'UPDATED', 'ACTUALIZADO');
        Msg := Format(Tx(L, '%s was applied in %d ms. ', '%s aplicado en %d ms. '), [R.FileName, R.ElapsedMs]);
        if R.ChildReady then
          Msg := Msg + Tx(L, 'The new version is loaded and ready.', 'La nueva version esta cargada y lista.')
        else
          Msg := Msg + Tx(L, 'WARNING: the new version could not be initialised; see the log (Debug build).',
            'ATENCION: la nueva version no se pudo inicializar; ver el log (compilacion Debug).');
        LogText := Format('UPDATED - %s applied in %d ms (child ready: %s)', [R.FileName, R.ElapsedMs, BoolToStr(R.ChildReady, True)]);
      end;
    uoNone:
      begin
        Status := '200 OK'; Kind := 'info'; Code2 := 'NONE';
        Key := Tx(L, 'NO UPDATE', 'SIN ACTUALIZACION');
        Msg := Format(Tx(L, 'There is no %s, nothing to apply.', 'No existe %s, no hay nada que aplicar.'), [R.FileName]);
        LogText := 'NONE - there is no .upd, nothing to apply';
      end;
    uoNotApplied:
      begin
        Status := '409 Conflict'; Kind := 'warn'; Code2 := 'NOT_APPLIED';
        Key := Tx(L, 'NOT APPLIED', 'NO APLICADA');
        Msg := Format(Tx(L, '%s is still there: it may still be being copied or be open in another program. ' +
            'Call /update again when it finishes.',
          '%s sigue ahi: puede estar copiandose todavia o abierto por otro programa. ' +
            'Vuelve a llamar a /update cuando termine.'), [R.FileName]);
        LogText := 'NOT_APPLIED - the .upd is still there (being copied or open in another program)';
      end;
    uoBlocked:
      begin
        Status := '409 Conflict'; Kind := 'bad'; Code2 := 'BLOCKED';
        Key := Tx(L, 'BLOCKED', 'BLOQUEADA');
        Msg := Format(Tx(L, 'Could not rename %s (usually the application pool identity lacks Modify permission ' +
            'on the folder). The current version keeps running.',
          'No se pudo renombrar %s (suele ser falta de permiso de Modificar para la identidad del grupo de ' +
            'aplicaciones en la carpeta). Se sigue con la version actual.'), [R.FileName]);
        LogText := 'BLOCKED - the .upd could not be renamed (check Modify permission); the current version keeps running';
      end;
  else
    begin
      Status := '409 Conflict'; Kind := 'bad'; Code2 := 'ERROR';
      Key := 'ERROR';
      Msg := Tx(L, 'Unexpected failure while updating; see the log (Debug build).',
        'Fallo inesperado al actualizar; ver el log (compilacion Debug).');
      LogText := 'ERROR - unexpected failure while updating';
    end;
  end;
  Log('Update: %s', [LogText]);
  Extra := 'X-FilterLoader-Result: ' + Code2 + #13#10;

  if AsHtml then
  begin
    Body :=
      '<section class="card"><h3>' + Tx(L, 'What next?', '&iquest;Qu&eacute; hacer ahora?') + '</h3>' +
      '<a class="btn" href="' + HtmlEsc(SpecialUrl(pECB, '/test')) + '">&#128269; ' +
      Tx(L, 'Check status (/test)', 'Comprobar estado (/test)') + '</a>';
    if R.Outcome <> uoUpdated then
      Body := Body + '<a class="btn sec" href="' + HtmlEsc(SpecialUrl(pECB, '/update')) + '">&#128260; ' +
        Tx(L, 'Retry (/update)', 'Reintentar (/update)') + '</a>';
    Body := Body + '</section>';
    Result := Reply(pECB, Status, True, HtmlPage(L,
      Tx(L, 'On-demand update', 'Actualizaci&oacute;n bajo demanda'), Kind, Key, Msg, Body), Extra);
    Exit;
  end;

  // No se muestra la ruta de la DLL: no hace falta y no conviene revelarla
  Result := Reply(pECB, Status, False,
    Tx(L, 'FilterLoader - on-demand update', 'FilterLoader - actualizacion bajo demanda') + #13#10#13#10 +
    Tx(L, 'RESULT: ', 'RESULTADO: ') + Key + ' - ' + Msg + #13#10, Extra);
end;

end.
