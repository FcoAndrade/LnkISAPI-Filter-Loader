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
  uLoader in 'uLoader.pas';

{$R *.res}

var
  gFilterLoader: IFilterLoader = nil;

function LOAD_GetFilterVersion(var pVer: HTTP_FILTER_VERSION): BOOL; export; stdcall;
begin
  try
    gFilterLoader := nil;
    gFilterLoader := CoCreateFilterLoader;
    Result := gFilterLoader.GetFilterVersion(pVer);
  except
    Result := False;
  end;
end;

function LOAD_HttpFilterProc(var pfc: THTTP_FILTER_CONTEXT; NotificationType: DWORD; pvNotification: Pointer): DWORD; export; stdcall;
begin
  try
    Result:= gFilterLoader.HttpFilterProc(pfc, NotificationType, pvNotification);
  except 
    Result:= SF_STATUS_REQ_NEXT_NOTIFICATION;
  end;
end;

function LOAD_TerminateFilter(dwFlags: DWORD): BOOL; export; stdcall;
begin
  try
    Result:= gFilterLoader.TerminateFilter(dwFlags);
  except
    Result:= True;
  end;
end;

exports
  LOAD_GetFilterVersion name 'GetFilterVersion',
  LOAD_HttpFilterProc name 'HttpFilterProc',
  LOAD_TerminateFilter name 'TerminateFilter';

begin
  IsMultiThread := True;
end.

