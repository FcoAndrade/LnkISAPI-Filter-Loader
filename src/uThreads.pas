(*
  uThreads - Hilos de un modulo (DLL) dentro del proceso.

  Sirve para descargar un hijo con hilos propios sin interbloqueo. FreeLibrary
  toma el bloqueo del cargador de Windows mientras se ejecuta el DllMain(DETACH)
  del hijo; si en ese momento queda un hilo del hijo terminando (necesita ese
  mismo bloqueo para salir) y el hijo espera a ese hilo en su cierre, ambos se
  esperan para siempre. La solucion es esperar a que los hilos del hijo
  terminen ANTES de llamar a FreeLibrary, sin tener el bloqueo tomado.

  Un hilo "es del hijo" si su funcion de arranque esta dentro de la imagen del
  modulo (se mantiene mientras el hilo no haya terminado del todo).
*)
unit uThreads;

interface

uses
  Windows;

// Numero de hilos (distintos del actual) que arrancaron dentro del modulo
function CountModuleThreads(ModuleBase: HMODULE): Integer;

// Espera hasta TimeoutMs a que no quede ningun hilo del modulo. Si aun quedan,
// y KillRemaining es True, los termina a la fuerza (ultimo recurso).
// Devuelve cuantos hilos del modulo quedan al final.
function WaitForModuleThreads(ModuleBase: HMODULE; TimeoutMs: DWORD;
  KillRemaining: Boolean): Integer;

implementation

uses
  SysUtils,
  TlHelp32,
  uLog;

const
  THR_TERMINATE = $0001;
  THR_QUERY_INFORMATION = $0040;
  ThreadQuerySetWin32StartAddress = 9;

function OpenThread(dwDesiredAccess: DWORD; bInheritHandle: BOOL;
  dwThreadId: DWORD): THandle; stdcall; external kernel32 name 'OpenThread';

function NtQueryInformationThread(ThreadHandle: THandle; ThreadInformationClass: ULONG;
  ThreadInformation: Pointer; ThreadInformationLength: ULONG;
  ReturnLength: PULONG): LongInt; stdcall; external 'ntdll.dll';

type
  TThreadIds = array of DWORD;

function ModuleImageSize(ModuleBase: HMODULE): NativeUInt;
var
  Dos: PImageDosHeader;
  Nt: PImageNtHeaders;
begin
  Result := 0;
  Dos := PImageDosHeader(ModuleBase);
  if (Dos = nil) or (Dos^.e_magic <> IMAGE_DOS_SIGNATURE) then
    Exit;
  Nt := PImageNtHeaders(NativeUInt(ModuleBase) + NativeUInt(Dos^._lfanew));
  if Nt^.Signature <> IMAGE_NT_SIGNATURE then
    Exit;
  Result := Nt^.OptionalHeader.SizeOfImage;
end;

function ThreadsOfModule(ModuleBase: HMODULE): TThreadIds;
var
  Snap, H: THandle;
  TE: TThreadEntry32;
  Start: Pointer;
  Lo, Hi: NativeUInt;
  Cur, Pid: DWORD;
begin
  SetLength(Result, 0);
  Lo := NativeUInt(ModuleBase);
  Hi := Lo + ModuleImageSize(ModuleBase);
  if Hi = Lo then
    Exit;
  Cur := GetCurrentThreadId;
  Pid := GetCurrentProcessId;
  Snap := CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
  if Snap = INVALID_HANDLE_VALUE then
    Exit;
  try
    TE.dwSize := SizeOf(TE);
    if Thread32First(Snap, TE) then
      repeat
        if (TE.th32OwnerProcessID = Pid) and (TE.th32ThreadID <> Cur) then
        begin
          H := OpenThread(THR_QUERY_INFORMATION, False, TE.th32ThreadID);
          if H <> 0 then
          try
            Start := nil;
            if (NtQueryInformationThread(H, ThreadQuerySetWin32StartAddress,
                 @Start, SizeOf(Start), nil) >= 0) and
               (NativeUInt(Start) >= Lo) and (NativeUInt(Start) < Hi) then
            begin
              SetLength(Result, Length(Result) + 1);
              Result[High(Result)] := TE.th32ThreadID;
            end;
          finally
            CloseHandle(H);
          end;
        end;
        TE.dwSize := SizeOf(TE);
      until not Thread32Next(Snap, TE);
  finally
    CloseHandle(Snap);
  end;
end;

function CountModuleThreads(ModuleBase: HMODULE): Integer;
begin
  try
    Result := Length(ThreadsOfModule(ModuleBase));
  except
    Result := 0;
  end;
end;

function WaitForModuleThreads(ModuleBase: HMODULE; TimeoutMs: DWORD;
  KillRemaining: Boolean): Integer;
var
  T0: DWORD;
  Ids: TThreadIds;
  I: Integer;
  H: THandle;
begin
  Result := 0;
  try
    T0 := GetTickCount;
    repeat
      Ids := ThreadsOfModule(ModuleBase);
      if Length(Ids) = 0 then
      begin
        Log('uThreads: ningun hilo del modulo $%x (esperado %d ms)', [ModuleBase, GetTickCount - T0]);
        Exit;
      end;
      Sleep(25);
    until (GetTickCount - T0) >= TimeoutMs;

    Result := Length(Ids);
    Log('uThreads: tras %d ms siguen %d hilo(s) del modulo $%x', [TimeoutMs, Result, ModuleBase]);
    if not KillRemaining then
      Exit;

    for I := 0 to High(Ids) do
    begin
      H := OpenThread(THR_TERMINATE, False, Ids[I]);
      if H <> 0 then
      try
        Log('uThreads: terminando a la fuerza el hilo %d', [Ids[I]]);
        TerminateThread(H, 0);
      finally
        CloseHandle(H);
      end
      else
        LogWinError(Format('uThreads: OpenThread(%d)', [Ids[I]]), GetLastError);
    end;

    // Un momento para que Windows de por terminados esos hilos
    T0 := GetTickCount;
    repeat
      Result := Length(ThreadsOfModule(ModuleBase));
      if Result = 0 then
        Break;
      Sleep(25);
    until (GetTickCount - T0) >= 1000;
    Log('uThreads: tras terminarlos a la fuerza quedan %d hilo(s)', [Result]);
  except
    LogException('WaitForModuleThreads');
  end;
end;

end.
