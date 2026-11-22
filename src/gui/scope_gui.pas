unit scope_gui;

{ Editor lifecycle and sizing: the Gui* entry points (main thread) }

{$mode objfpc}{$H+}

interface

uses
  scope_state;

function GuiCreate(inst: PScopeInstance): Boolean;
procedure GuiDestroy(inst: PScopeInstance);
function GuiSetParent(inst: PScopeInstance; parentHandle: Pointer): Boolean;
{ sizes are in host units: px on Windows, points on macOS }
function GuiGetSize(inst: PScopeInstance; outW, outH: PUInt32): Boolean;
function GuiSetSize(inst: PScopeInstance; w, h: UInt32): Boolean;
{ False where the host does not scale the editor }
function GuiSetScale(inst: PScopeInstance; scale: Double): Boolean;
{ clamps to what the editor can show at its UI scale }
procedure GuiAdjustSize(inst: PScopeInstance; var w, h: UInt32);
function GuiShow(inst: PScopeInstance): Boolean;
function GuiHide(inst: PScopeInstance): Boolean;
procedure GuiGlobalCleanup;

implementation

uses
  scope_gui_types, scope_gui_os, scope_gui_render;

function ToHost(g: PScopeGui; px: Integer): UInt32;
begin
  Result := Round(px / OsPixelsPerUnit(g));
end;

function FromHost(g: PScopeGui; units: UInt32): Integer;
begin
  Result := Round(units * OsPixelsPerUnit(g));
end;

procedure SetDefaultSize(g: PScopeGui);
begin
  g^.scale := EffectiveScale(g^.inst, g);
  g^.w := Round(DEFAULT_GUI_W * g^.scale);
  g^.h := Round(DEFAULT_GUI_H * g^.scale);
end;

function GuiCreate(inst: PScopeInstance): Boolean;
var
  g: PScopeGui;
begin
  Result := False;
  if inst^.gui <> nil then
    Exit(True);

  New(g);
  if g = nil then Exit;
  FillChar(g^, SizeOf(g^), 0);
  g^.statusDrag := ST_NONE;
  g^.inst := inst;
  SetDefaultSize(g);

  if not OsViewCreate(g) then
  begin
    Dispose(g);
    Exit;
  end;

  g^.stop := False;
  g^.thread := BeginThread(@RenderThreadProc, g);
  if g^.thread = TThreadID(0) then
  begin
    OsViewDestroy(g);
    Dispose(g);
    Exit;
  end;

  inst^.gui := g;
  Result := True;
end;

{ No timeout: freeing while the thread runs is a use-after-free }
procedure GuiDestroy(inst: PScopeInstance);
var
  g: PScopeGui;
begin
  g := PScopeGui(inst^.gui);
  if g = nil then Exit;
  inst^.gui := nil;

  g^.stop := True;
  OsJoinRenderThread(g);
  OsViewDestroy(g);
  Dispose(g);
end;

function GuiSetParent(inst: PScopeInstance; parentHandle: Pointer): Boolean;
var
  g: PScopeGui;
begin
  Result := False;
  g := PScopeGui(inst^.gui);
  if (g = nil) or (parentHandle = nil) then Exit;
  Result := OsViewAttach(g, parentHandle);
end;

function GuiGetSize(inst: PScopeInstance; outW, outH: PUInt32): Boolean;
var
  g: PScopeGui;
  sc: Single;
begin
  g := PScopeGui(inst^.gui);
  if g <> nil then
  begin
    outW^ := ToHost(g, g^.w);
    outH^ := ToHost(g, g^.h);
  end
  else
  begin
    sc := EffectiveScale(inst, nil);
    outW^ := ToHost(nil, Round(DEFAULT_GUI_W * sc));
    outH^ := ToHost(nil, Round(DEFAULT_GUI_H * sc));
  end;
  Result := True;
end;

function GuiSetSize(inst: PScopeInstance; w, h: UInt32): Boolean;
var
  g: PScopeGui;
begin
  Result := False;
  g := PScopeGui(inst^.gui);
  if g = nil then Exit;
  g^.w := FromHost(g, w);
  g^.h := FromHost(g, h);
  g^.sized := True;
  OsViewResize(g);
  Result := True;
end;

function GuiSetScale(inst: PScopeInstance; scale: Double): Boolean;
var
  g: PScopeGui;
begin
  Result := OS_HOST_SCALE;
  if not Result then Exit;
  inst^.guiScale := scale;
  g := PScopeGui(inst^.gui);
  { hosts set the scale after create: redo the default size for it }
  if (g <> nil) and (not g^.sized) then
  begin
    SetDefaultSize(g);
    OsViewResize(g);
  end;
end;

procedure GuiAdjustSize(inst: PScopeInstance; var w, h: UInt32);
var
  g: PScopeGui;
  sc: Single;
  minW, minH: Integer;
begin
  g := PScopeGui(inst^.gui);
  sc := EffectiveScale(inst, g);
  minW := Round(MIN_GUI_W * sc);
  if (g <> nil) and (g^.minW > 0) then
    minW := g^.minW;
  minH := Round(MIN_GUI_H * sc);
  if GetParam(inst, PARAM_SPLIT) >= 0.5 then
    minH := Round(MIN_GUI_H_SPLIT * sc);
  if w < ToHost(g, minW) then w := ToHost(g, minW);
  if h < ToHost(g, minH) then h := ToHost(g, minH);
  if w > MAX_GUI_W then w := MAX_GUI_W;
  if h > MAX_GUI_H then h := MAX_GUI_H;
end;

function GuiShow(inst: PScopeInstance): Boolean;
var
  g: PScopeGui;
begin
  Result := False;
  g := PScopeGui(inst^.gui);
  if g = nil then Exit;
  OsViewSetVisible(g, True);
  Result := True;
end;

function GuiHide(inst: PScopeInstance): Boolean;
var
  g: PScopeGui;
begin
  Result := False;
  g := PScopeGui(inst^.gui);
  if g = nil then Exit;
  OsViewSetVisible(g, False);
  Result := True;
end;

procedure GuiGlobalCleanup;
begin
  OsGlobalCleanup;
end;

end.
