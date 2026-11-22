unit scope_gui_input;

{ Mouse input, main thread. The platform view translates its events into
  these calls; x, y are px from the top-left of the editor. }

{$mode objfpc}{$H+}

interface

uses
  scope_gui_types;

type
  TEditorCursor = (ecArrow, ecResizeV, ecHand);

{ dbl: second press of a double click }
procedure InputPress(g: PScopeGui; x, y: Integer; dbl: Boolean);
{ with the button down }
procedure InputMove(g: PScopeGui; x, y: Integer);
procedure InputRelease(g: PScopeGui; x, y: Integer);
{ the press ended without a release, e.g. capture lost }
procedure InputCancel(g: PScopeGui);
{ a press is in progress: moves and the release belong to it }
function InputActive(g: PScopeGui): Boolean;
{ right click }
procedure InputSecondaryPress(g: PScopeGui);
{ notches: +1 = one step away from the user; vzoom: the v-zoom modifier }
procedure InputWheel(g: PScopeGui; x, y: Integer; notches: Double; vzoom: Boolean);
function InputCursor(g: PScopeGui; x, y: Integer): TEditorCursor;

implementation

uses
  SysUtils, clap_api, scope_state, scope_view, scope_gui_os;

const
  { per wheel notch: ~21% }
  WHEEL_ZOOM_RATE = 0.24;

{ apply and report to the host }
procedure ApplyGuiParam(inst: PScopeInstance; id: TClapId; v: Double);
begin
  v := ClampParam(ParamIndex(id), v);
  SetParam(inst, Integer(id), v);
  MarkParamDirty(inst, Integer(id));
  RequestHostFlush(inst);
  MarkHostStateDirty(inst);
end;

{ wheel steps stop at 0 dB instead of jumping over it }
procedure ApplyVZoom(inst: PScopeInstance; v: Double);
var
  old, def: Double;
begin
  old := GetParam(inst, PARAM_VZOOM_DB);
  def := ParamDefs[PARAM_VZOOM_DB].defV;
  if ((old < def) and (v > def)) or ((old > def) and (v < def)) then
    v := def;
  ApplyGuiParam(inst, PARAM_VZOOM_DB, v);
end;

procedure CycleTrigger(inst: PScopeInstance);
begin
  ApplyGuiParam(inst, PARAM_RETRIG,
    (Round(GetParam(inst, PARAM_RETRIG)) + 1) mod RETRIG_COUNT);
end;

{ a new cycle length starts unzoomed }
function SyncOn(g: PScopeGui): Boolean;
begin
  Result := GetParam(g^.inst, PARAM_SYNC) >= 0.5;
end;

procedure ToggleSync(g: PScopeGui);
begin
  g^.zoomStart := 0;
  g^.zoomSpan := 0;
  if GetParam(g^.inst, PARAM_SYNC) >= 0.5 then
    ApplyGuiParam(g^.inst, PARAM_SYNC, 0.0)
  else
    ApplyGuiParam(g^.inst, PARAM_SYNC, 1.0);
end;

procedure ToggleSplit(g: PScopeGui);
begin
  if GetParam(g^.inst, PARAM_SPLIT) >= 0.5 then
    ApplyGuiParam(g^.inst, PARAM_SPLIT, 0.0)
  else
    ApplyGuiParam(g^.inst, PARAM_SPLIT, 1.0);
end;

procedure StepSyncLen(g: PScopeGui; delta: Integer);
begin
  g^.zoomStart := 0;
  g^.zoomSpan := 0;
  ApplyGuiParam(g^.inst, PARAM_SYNC_LEN,
    Round(GetParam(g^.inst, PARAM_SYNC_LEN)) + delta);
end;

{ turns accumulated movement into whole steps of the sync length }
procedure StepSyncBy(g: PScopeGui; var accum: Double; unitSize: Double);
begin
  while accum >= unitSize do
  begin
    StepSyncLen(g, 1);
    accum := accum - unitSize;
  end;
  while accum <= -unitSize do
  begin
    StepSyncLen(g, -1);
    accum := accum + unitSize;
  end;
end;

{ synced cycle: zoom around the cursor, out to the whole cycle at most }
procedure ZoomSync(g: PScopeGui; notches: Double; fx: Double);
var
  span, start, newSpan, minSpan, under: Double;
begin
  span := g^.zoomSpan;
  start := g^.zoomStart;
  if (span <= 0) or (span > 1) then
  begin
    span := 1;
    start := 0;
  end;
  if (notches < 0) and (span >= 1 - 1e-9) then
    Exit;
  minSpan := 1;
  if g^.viewInfo.viewSamples > 0 then
    minSpan := SYNC_MIN_SAMPLES / g^.viewInfo.viewSamples;
  newSpan := span * Exp(-notches * WHEEL_ZOOM_RATE);
  if newSpan < minSpan then newSpan := minSpan;
  if newSpan > 1 - 1e-9 then newSpan := 1;
  under := start + fx * span;
  start := under - fx * newSpan;
  if start < 0 then start := 0;
  if start > 1 - newSpan then start := 1 - newSpan;
  g^.zoomStart := start;
  g^.zoomSpan := newSpan;
end;

{ up = larger value; rates are per host unit, so they feel the same at any
  scale the host's sizes are in }
procedure HandleStatusDrag(g: PScopeGui; y: Integer);
const
  LEN_RATE = 0.01;    { x2.7 per 100 units }
  RANGE_DB = 0.25;    { dB per unit }
  SYNC_STEP = 18;
var
  dy: Double;
begin
  if y = g^.statusLastY then Exit;
  dy := (g^.statusLastY - y) / OsPixelsPerUnit(g);
  g^.statusLastY := y;
  case g^.statusDrag of
    ST_LEN:
      if SyncOn(g) then
      begin
        g^.statusAccum := g^.statusAccum + dy;
        StepSyncBy(g, g^.statusAccum, SYNC_STEP);
      end
      else
        ApplyGuiParam(g^.inst, PARAM_VIEW_MS,
          GetParam(g^.inst, PARAM_VIEW_MS) * Exp(dy * LEN_RATE));
    ST_RANGE:
      ApplyGuiParam(g^.inst, PARAM_VZOOM_DB,
        GetParam(g^.inst, PARAM_VZOOM_DB) + dy * RANGE_DB);
  end;
end;

procedure HandleStatusPress(g: PScopeGui; item, y: Integer; dbl: Boolean);
begin
  g^.statusAccum := 0;
  if dbl and (item = ST_LEN) and SyncOn(g) then
  begin
    g^.zoomStart := 0;
    g^.zoomSpan := 0;
    ApplyGuiParam(g^.inst, PARAM_SYNC_LEN, ParamDefs[PARAM_SYNC_LEN].defV);
  end
  else if dbl and (item = ST_LEN) then
    ApplyGuiParam(g^.inst, PARAM_VIEW_MS, ParamDefs[PARAM_VIEW_MS].defV)
  else if dbl and (item = ST_RANGE) then
    ApplyGuiParam(g^.inst, PARAM_VZOOM_DB, ParamDefs[PARAM_VZOOM_DB].defV)
  else
  begin
    { len/range: drag; trig: wait for release }
    g^.statusDrag := item;
    g^.statusLastY := y;
  end;
end;

function InAboutButton(g: PScopeGui; x, y: Integer): Boolean;
var
  px: Single;
begin
  px := g^.scale;
  if px < 1 then px := 1;
  Result := (x >= g^.w - Round(26 * px)) and (x <= g^.w - Round(4 * px)) and
    (y >= Round(4 * px)) and (y <= Round(26 * px));
end;

{ drag while holding scrubs; right = older }
procedure HandleDrag(g: PScopeGui; x: Integer);
var
  inst: PScopeInstance;
  dx, vs: Integer;
  perPixel, maxOffs: Double;
begin
  inst := g^.inst;
  if Abs(x - g^.pressX) > 2 * OsPixelsPerUnit(g) then
    g^.moved := True;
  dx := x - g^.dragLastX;
  g^.dragLastX := x;
  if (dx = 0) or (g^.w < 1) then
    Exit;
  if g^.viewInfo.sweep then
  begin
    { synced cycle: drag moves the zoomed part }
    if (g^.zoomSpan > 0) and (g^.zoomSpan < 1) then
    begin
      g^.zoomStart := g^.zoomStart - dx / g^.w * g^.zoomSpan;
      if g^.zoomStart < 0 then g^.zoomStart := 0;
      if g^.zoomStart > 1 - g^.zoomSpan then g^.zoomStart := 1 - g^.zoomSpan;
    end;
    Exit;
  end;
  if GetParam(inst, PARAM_HOLD) < 0.5 then
    Exit;
  vs := g^.viewInfo.viewSamples;
  if vs <= 0 then vs := ViewSampleCount(inst);
  perPixel := vs / g^.w;
  maxOffs := HoldReach(inst, vs, g^.w);
  g^.holdOffs := g^.holdOffs + dx * perPixel;
  if g^.holdOffs < 0 then g^.holdOffs := 0;
  if g^.holdOffs > maxOffs then g^.holdOffs := maxOffs;
end;

{ click: close about / open about / toggle hold }
procedure HandleClick(g: PScopeGui);
begin
  if g^.aboutOpen then
    g^.aboutOpen := False
  else if InAboutButton(g, g^.pressX, g^.pressY) then
  begin
    g^.aboutOpen := True;
    g^.aboutT0 := GetTickCount64;
  end
  else if GetParam(g^.inst, PARAM_HOLD) >= 0.5 then
  begin
    g^.holdOffs := 0;
    ApplyGuiParam(g^.inst, PARAM_HOLD, 0.0);
  end
  else
  begin
    { freeze exactly what is on screen }
    g^.holdOffs := g^.lastAnchorOffs;
    ApplyGuiParam(g^.inst, PARAM_HOLD, 1.0);
  end;
end;

procedure InputPress(g: PScopeGui; x, y: Integer; dbl: Boolean);
var
  item: Integer;
begin
  item := StatusItemAt(g, x, y);
  if item <> ST_NONE then
  begin
    HandleStatusPress(g, item, y, dbl);
    Exit;
  end;
  g^.pressed := True;
  g^.moved := False;
  g^.pressX := x;
  g^.pressY := y;
  g^.dragLastX := x;
end;

procedure InputMove(g: PScopeGui; x, y: Integer);
begin
  if g^.statusDrag <> ST_NONE then
    HandleStatusDrag(g, y)
  else if g^.pressed then
    HandleDrag(g, x);
end;

procedure InputRelease(g: PScopeGui; x, y: Integer);
var
  item: Integer;
begin
  if g^.statusDrag <> ST_NONE then
  begin
    item := g^.statusDrag;
    g^.statusDrag := ST_NONE;
    { the rest act on a click: released on the same item }
    if StatusItemAt(g, x, y) = item then
      case item of
        ST_TRIG: CycleTrigger(g^.inst);
        ST_SYNC: ToggleSync(g);
        ST_SPLIT: ToggleSplit(g);
      end;
  end
  else if g^.pressed then
  begin
    g^.pressed := False;
    if not g^.moved then
      HandleClick(g);
  end;
end;

procedure InputCancel(g: PScopeGui);
begin
  g^.statusDrag := ST_NONE;
  g^.pressed := False;
end;

function InputActive(g: PScopeGui): Boolean;
begin
  Result := (g^.statusDrag <> ST_NONE) or g^.pressed;
end;

procedure InputSecondaryPress(g: PScopeGui);
begin
  CycleTrigger(g^.inst);
end;

procedure InputWheel(g: PScopeGui; x, y: Integer; notches: Double; vzoom: Boolean);
var
  inst: PScopeInstance;
  frac, oldVs, newVs, cursorOffs, maxOffs, newMs: Double;
begin
  inst := g^.inst;
  if vzoom then
    ApplyVZoom(inst, GetParam(inst, PARAM_VZOOM_DB) - notches * 3.0)
  else if g^.viewInfo.sweep and (g^.w > 0) then
  begin
    frac := x / g^.w;
    if frac < 0 then frac := 0;
    if frac > 1 then frac := 1;
    ZoomSync(g, notches, frac);
  end
  else if SyncOn(g) then
    { no cycle on screen to zoom into; the length is set with len }
  else
  begin
    newMs := ClampParam(PARAM_VIEW_MS,
      GetParam(inst, PARAM_VIEW_MS) * Exp(-notches * WHEEL_ZOOM_RATE));

    { holding: zoom around the cursor }
    if (GetParam(inst, PARAM_HOLD) >= 0.5) and (g^.w > 0) then
    begin
      frac := (g^.w - x) / g^.w;   { 0 = right edge }
      if frac < 0 then frac := 0;
      if frac > 1 then frac := 1;
      oldVs := ClampParam(PARAM_VIEW_MS, GetParam(inst, PARAM_VIEW_MS)) *
        0.001 * inst^.srate;
      newVs := newMs * 0.001 * inst^.srate;
      cursorOffs := g^.holdOffs + frac * oldVs;
      g^.holdOffs := cursorOffs - frac * newVs;
      maxOffs := HoldReach(inst, Round(newVs), g^.w);
      if g^.holdOffs < 0 then g^.holdOffs := 0;
      if g^.holdOffs > maxOffs then g^.holdOffs := maxOffs;
    end;

    ApplyGuiParam(inst, PARAM_VIEW_MS, newMs);
  end;
end;

function InputCursor(g: PScopeGui; x, y: Integer): TEditorCursor;
begin
  case StatusItemAt(g, x, y) of
    ST_LEN, ST_RANGE: Result := ecResizeV;
    ST_TRIG, ST_SYNC, ST_SPLIT: Result := ecHand;
  else
    Result := ecArrow;
  end;
end;

end.
