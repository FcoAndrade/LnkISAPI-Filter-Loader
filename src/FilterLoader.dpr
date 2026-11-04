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

library FilterLoader;

uses
  ISAPI2,
  Windows,
  uLog in 'uLog.pas',
  uLoader in 'uLoader.pas';

{$R *.res}

var
  gFilterLoader: IFilterLoader = nil;

function LOAD_GetFilterVersion(var pVer: HTTP_FILTER_VERSION): BOOL; export; stdcall;
begin
  try
    Log('--- LOAD_GetFilterVersion (IIS carga el filtro) ---');
    if gFilterLoader = nil then
      gFilterLoader := CoCreateFilterLoader;
    Result := gFilterLoader.GetFilterVersion(pVer);
  except
    LogException('LOAD_GetFilterVersion');
    Result := False;
  end;
end;

function LOAD_HttpFilterProc(var pfc: THTTP_FILTER_CONTEXT; NotificationType: DWORD; pvNotification: Pointer): DWORD; export; stdcall;
begin
  try
    Result:= gFilterLoader.HttpFilterProc(pfc, NotificationType, pvNotification);
  except
    LogException('LOAD_HttpFilterProc');
    Result:= SF_STATUS_REQ_NEXT_NOTIFICATION;
  end;
end;

function LOAD_TerminateFilter(dwFlags: DWORD): BOOL; export; stdcall;
begin
  try
    Log('--- LOAD_TerminateFilter (flags=$%x) ---', [dwFlags]);
    Result:= gFilterLoader.TerminateFilter(dwFlags);
    // IIS va a descargar la DLL: se libera aqui el cargador (y con el el hijo)
    // y no al finalizar las unidades, ya dentro del bloqueo del cargador de Windows.
    gFilterLoader := nil;
  except
    LogException('LOAD_TerminateFilter');
    Result:= True;
  end;
end;

// ---- Extension ISAPI (se invoca por URL, p. ej. /WebService/MiDll.dll/ruta) ----
// pVer es un HSE_VERSION_INFO y pECB un EXTENSION_CONTROL_BLOCK; se pasan como
// Pointer (misma convencion stdcall que un parametro var).

function LOAD_GetExtensionVersion(pVer: Pointer): BOOL; export; stdcall;
begin
  try
    Log('--- LOAD_GetExtensionVersion (IIS carga la extension) ---');
    // No se recrea el cargador si ya existe (filtro y extension pueden convivir)
    if gFilterLoader = nil then
      gFilterLoader := CoCreateFilterLoader;
    Result := gFilterLoader.GetExtensionVersion(pVer);
  except
    LogException('LOAD_GetExtensionVersion');
    Result := False;
  end;
end;

function LOAD_HttpExtensionProc(pECB: Pointer): DWORD; export; stdcall;
begin
  try
    Log('--- LOAD_HttpExtensionProc (IIS manda una peticion) ---');
    Result := gFilterLoader.HttpExtensionProc(pECB);
  except
    LogException('LOAD_HttpExtensionProc');
    Result := 4; // HSE_STATUS_ERROR
  end;
end;

function LOAD_TerminateExtension(dwFlags: DWORD): BOOL; export; stdcall;
begin
  try
    Log('--- LOAD_TerminateExtension (flags=$%x) ---', [dwFlags]);
    Result := gFilterLoader.TerminateExtension(dwFlags);
    // Si el hijo acepta (TRUE), IIS descargara esta DLL: se libera aqui el
    // cargador (y con el el hijo), fuera del bloqueo del cargador de Windows.
    // Si responde FALSE a un aviso, IIS la mantiene y no se toca nada.
    if Result then
      gFilterLoader := nil;
  except
    LogException('LOAD_TerminateExtension');
    Result := True;
  end;
end;

exports
  LOAD_GetFilterVersion name 'GetFilterVersion',
  LOAD_HttpFilterProc name 'HttpFilterProc',
  LOAD_TerminateFilter name 'TerminateFilter',
  LOAD_GetExtensionVersion name 'GetExtensionVersion',
  LOAD_HttpExtensionProc name 'HttpExtensionProc',
  LOAD_TerminateExtension name 'TerminateExtension';

begin
  IsMultiThread := True;
end.

