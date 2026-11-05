(*
  uIdentity - Identidad con la que se ejecuta el hilo actual.

  IIS ejecuta HttpExtensionProc en hilos que suplantan a otro usuario (con
  autenticacion anonima, normalmente IUSR o el usuario autenticado), mientras
  que GetExtensionVersion y TerminateExtension corren con la identidad del grupo
  de aplicaciones. El cargador necesita siempre la del grupo de aplicaciones
  (la que tiene permiso de Modificar sobre la carpeta) para renombrar ficheros,
  escribir el log y abrir los hilos del hijo; con la suplantacion fallan en
  silencio.

  RevertToProcessIdentity quita la suplantacion del hilo y devuelve el token
  que habia (o 0 si no suplantaba). RestoreIdentity lo vuelve a poner, para que
  el codigo que sigue (el hijo, IIS) encuentre el hilo como lo dejo IIS.
*)
unit uIdentity;

interface

uses
  Windows;

// Devuelve el token de suplantacion que tenia el hilo (0 si no suplantaba) y
// deja el hilo con la identidad del proceso.
function RevertToProcessIdentity: THandle;

// Vuelve a suplantar con el token devuelto por RevertToProcessIdentity y lo
// cierra. Con 0 no hace nada.
procedure RestoreIdentity(Token: THandle);

implementation

const
  TOKEN_IMPERSONATE_ACCESS = $0004;
  TOKEN_QUERY_ACCESS = $0008;

function ApiOpenThreadToken(ThreadHandle: THandle; DesiredAccess: DWORD;
  OpenAsSelf: BOOL; var TokenHandle: THandle): BOOL; stdcall;
  external advapi32 name 'OpenThreadToken';

function ApiSetThreadToken(Thread: PHandle; Token: THandle): BOOL; stdcall;
  external advapi32 name 'SetThreadToken';

function ApiRevertToSelf: BOOL; stdcall;
  external advapi32 name 'RevertToSelf';

function RevertToProcessIdentity: THandle;
var
  Tok: THandle;
begin
  Result := 0;
  Tok := 0;
  // OpenAsSelf = True: el acceso al token se comprueba con la identidad del
  // proceso, no con la del usuario suplantado
  if ApiOpenThreadToken(GetCurrentThread, TOKEN_IMPERSONATE_ACCESS or TOKEN_QUERY_ACCESS,
       True, Tok) then
  begin
    Result := Tok;
    ApiRevertToSelf;
  end;
end;

procedure RestoreIdentity(Token: THandle);
begin
  if Token <> 0 then
  begin
    ApiSetThreadToken(nil, Token);
    CloseHandle(Token);
  end;
end;

end.
