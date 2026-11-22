unit scope_gui;

{ Editor window: class, WGL setup, mouse input, Gui* entry points (main thread) }

{$mode objfpc}{$H+}
{$pointermath on}

interface

uses
  Windows, scope_state;

function GuiCreate(inst: PScopeInstance): Boolean;
procedure GuiDestroy(inst: PScopeInstance);
function GuiSetParent(inst: PScopeInstance; parentHandle: Pointer): Boolean;
function GuiGetSize(inst: PScopeInstance; outW, outH: PUInt32): Boolean;
function GuiSetSize(inst: PScopeInstance; w, h: UInt32): Boolean;
function GuiSetScale(inst: PScopeInstance; scale: Double): Boolean;
{ clamps to what the editor can show at its UI scale }
procedure GuiAdjustSize(inst: PScopeInstance; var w, h: UInt32);
function GuiShow(inst: PScopeInstance): Boolean;
function GuiHide(inst: PScopeInstance): Boolean;
procedure GuiGlobalCleanup;

implementation

uses
  clap_api, gl_min, scope_view, scope_gui_types, scope_gui_render;

const
  WND_CLASS_NAME: PWideChar = 'lzScopeCLAPWnd';
  GUI_PROP: PWideChar = 'lzScopeGuiPtr';
  { per wheel unit; one notch = ~21% }
  WHEEL_ZOOM_RATE = 0.002;

var
  ClassRegistered: Boolean = False;

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

procedure StepSyncLen(g: PScopeGui; delta: Integer);
begin
  g^.zoomStart := 0;
  g^.zoomSpan := 0;
  ApplyGuiParam(g^.inst, PARAM_SYNC_LEN,
    Round(GetParam(g^.inst, PARAM_SYNC_LEN)) + delta);
end;

{ turns accumulated movement into whole steps of the sync length }
procedure StepSyncBy(g: PScopeGui; var accum: Integer; unitSize: Integer);
begin
  while accum >= unitSize do
  begin
    StepSyncLen(g, 1);
    Dec(accum, unitSize);
  end;
  while accum <= -unitSize do
  begin
    StepSyncLen(g, -1);
    Inc(accum, unitSize);
  end;
end;

{ synced cycle: zoom around the cursor, out to the whole cycle at most }
procedure ZoomSync(g: PScopeGui; delta: Integer; fx: Double);
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
  if (delta < 0) and (span >= 1 - 1e-9) then
    Exit;
  minSpan := 1;
  if g^.viewInfo.viewSamples > 0 then
    minSpan := SYNC_MIN_SAMPLES / g^.viewInfo.viewSamples;
  newSpan := span * Exp(-delta * WHEEL_ZOOM_RATE);
  if newSpan < minSpan then newSpan := minSpan;
  if newSpan > 1 - 1e-9 then newSpan := 1;
  under := start + fx * span;
  start := under - fx * newSpan;
  if start < 0 then start := 0;
  if start > 1 - newSpan then start := 1 - newSpan;
  g^.zoomStart := start;
  g^.zoomSpan := newSpan;
end;

{ up = larger value }
procedure HandleStatusDrag(g: PScopeGui; y: Integer);
const
  LEN_RATE = 0.01;    { x2.7 per 100 px }
  RANGE_DB = 0.25;    { dB per px }
  SYNC_STEP_PX = 18;
var
  dy: Integer;
begin
  dy := g^.statusLastY - y;
  if dy = 0 then Exit;
  g^.statusLastY := y;
  case g^.statusDrag of
    ST_LEN:
      if SyncOn(g) then
      begin
        Inc(g^.statusAccum, dy);
        StepSyncBy(g, g^.statusAccum, SYNC_STEP_PX);
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
    SetCapture(g^.wnd);
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
  if Abs(x - g^.pressX) > 2 then
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

procedure HandleWheel(g: PScopeGui; wp: WPARAM; lp: LPARAM);
var
  inst: PScopeInstance;
  delta: Integer;
  pt: TPoint;
  frac, oldVs, newVs, cursorOffs, maxOffs, newMs: Double;
begin
  inst := g^.inst;
  delta := SmallInt((wp shr 16) and $FFFF);
  if (wp and MK_CONTROL) <> 0 then
    ApplyVZoom(inst, GetParam(inst, PARAM_VZOOM_DB) - delta * (3.0 / 120.0))
  else if g^.viewInfo.sweep and (g^.w > 0) then
  begin
    pt.x := SmallInt(lp and $FFFF);
    pt.y := SmallInt((lp shr 16) and $FFFF);
    ScreenToClient(g^.wnd, pt);
    frac := pt.x / g^.w;
    if frac < 0 then frac := 0;
    if frac > 1 then frac := 1;
    ZoomSync(g, delta, frac);
  end
  else if SyncOn(g) then
    { no cycle on screen to zoom into; the length is set with len }
  else
  begin
    newMs := ClampParam(PARAM_VIEW_MS,
      GetParam(inst, PARAM_VIEW_MS) * Exp(-delta * WHEEL_ZOOM_RATE));

    { holding: zoom around the cursor }
    if (GetParam(inst, PARAM_HOLD) >= 0.5) and (g^.w > 0) then
    begin
      pt.x := SmallInt(lp and $FFFF);
      pt.y := SmallInt((lp shr 16) and $FFFF);
      ScreenToClient(g^.wnd, pt);
      frac := (g^.w - pt.x) / g^.w;   { 0 = right edge }
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

function ScopeWndProc(hw: HWND; msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT; stdcall;
var
  g: PScopeGui;
  ps: PAINTSTRUCT;
  item, mx, my: Integer;
  pt: TPoint;
begin
  g := PScopeGui(GetPropW(hw, GUI_PROP));
  mx := SmallInt(lp and $FFFF);
  my := SmallInt((lp shr 16) and $FFFF);
  case msg of
    WM_PAINT:
      begin
        BeginPaint(hw, @ps);
        EndPaint(hw, @ps);
        if g <> nil then
          InterlockedExchange(g^.redraw, 1);
        Exit(0);
      end;
    WM_SIZE:
      if g <> nil then
      begin
        g^.w := Integer(lp and $FFFF);
        g^.h := Integer((lp shr 16) and $FFFF);
        InterlockedExchange(g^.redraw, 1);
        Exit(0);
      end;
    WM_ERASEBKGND:
      Exit(1);
    WM_MOUSEWHEEL:
      if g <> nil then
      begin
        HandleWheel(g, wp, lp);
        Exit(0);
      end;
    WM_SETCURSOR:
      if (g <> nil) and ((lp and $FFFF) = HTCLIENT) and GetCursorPos(pt{%H-}) then
      begin
        ScreenToClient(hw, pt);
        case StatusItemAt(g, pt.x, pt.y) of
          ST_LEN, ST_RANGE:
            begin
              SetCursor(LoadCursor(0, IDC_SIZENS));
              Exit(1);
            end;
          ST_TRIG, ST_SYNC:
            begin
              SetCursor(LoadCursor(0, IDC_HAND));
              Exit(1);
            end;
        end;
      end;
    WM_CAPTURECHANGED:
      if g <> nil then
      begin
        g^.statusDrag := ST_NONE;
        g^.pressed := False;
      end;
    { second click of a double click arrives as DBLCLK }
    WM_LBUTTONDOWN, WM_LBUTTONDBLCLK:
      if g <> nil then
      begin
        item := StatusItemAt(g, mx, my);
        if item <> ST_NONE then
        begin
          HandleStatusPress(g, item, my, msg = WM_LBUTTONDBLCLK);
          Exit(0);
        end;
        g^.pressed := True;
        g^.moved := False;
        g^.pressX := SmallInt(lp and $FFFF);
        g^.pressY := SmallInt((lp shr 16) and $FFFF);
        g^.dragLastX := g^.pressX;
        SetCapture(hw);
        Exit(0);
      end;
    WM_MOUSEMOVE:
      if (g <> nil) and (g^.statusDrag <> ST_NONE) then
      begin
        HandleStatusDrag(g, my);
        Exit(0);
      end
      else if (g <> nil) and g^.pressed then
      begin
        HandleDrag(g, mx);
        Exit(0);
      end;
    WM_LBUTTONUP:
      if (g <> nil) and (g^.statusDrag <> ST_NONE) then
      begin
        item := g^.statusDrag;
        g^.statusDrag := ST_NONE;
        ReleaseCapture;
        { trig and sync act on a click: released on the same item }
        if StatusItemAt(g, mx, my) = item then
          case item of
            ST_TRIG: CycleTrigger(g^.inst);
            ST_SYNC: ToggleSync(g);
          end;
        Exit(0);
      end
      else if (g <> nil) and g^.pressed then
      begin
        g^.pressed := False;
        ReleaseCapture;
        if not g^.moved then
        begin
          { click: close about / open about / toggle hold }
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
        Exit(0);
      end;
    WM_RBUTTONDOWN:
      if g <> nil then
      begin
        CycleTrigger(g^.inst);
        Exit(0);
      end;
  end;
  Result := DefWindowProcW(hw, msg, wp, lp);
end;

function EnsureClass: Boolean;
var
  wc: WNDCLASSW;
begin
  if ClassRegistered then
    Exit(True);
  FillChar(wc, SizeOf(wc), 0);
  wc.style := CS_HREDRAW or CS_VREDRAW or CS_OWNDC or CS_DBLCLKS;
  wc.lpfnWndProc := @ScopeWndProc;
  wc.hInstance := HInstance;
  wc.hCursor := LoadCursor(0, IDC_ARROW);
  wc.hbrBackground := 0;
  wc.lpszClassName := WND_CLASS_NAME;
  Result := RegisterClassW(wc) <> 0;
  if (not Result) and (GetLastError = ERROR_CLASS_ALREADY_EXISTS) then
  begin
    { stale class from a previous load of this DLL }
    UnregisterClassW(WND_CLASS_NAME, HInstance);
    Result := RegisterClassW(wc) <> 0;
  end;
  ClassRegistered := Result;
end;

procedure GuiGlobalCleanup;
begin
  if ClassRegistered then
  begin
    UnregisterClassW(WND_CLASS_NAME, HInstance);
    ClassRegistered := False;
  end;
end;

procedure FillBasicPfd(out pfd: PIXELFORMATDESCRIPTOR);
begin
  FillChar(pfd{%H-}, SizeOf(pfd), 0);
  pfd.nSize := SizeOf(pfd);
  pfd.nVersion := 1;
  pfd.dwFlags := PFD_DRAW_TO_WINDOW or PFD_SUPPORT_OPENGL or PFD_DOUBLEBUFFER;
  pfd.iPixelType := PFD_TYPE_RGBA;
  pfd.cColorBits := 32;
  pfd.iLayerType := PFD_MAIN_PLANE;
end;

{ wglChoosePixelFormatARB needs a context: probe on a throwaway window }
function ChooseMsaaFormat(samples: LongInt): Integer;
var
  dw: HWND;
  ddc: HDC;
  drc: HGLRC;
  pfd: PIXELFORMATDESCRIPTOR;
  pf: Integer;
  choose: TWglChoosePixelFormatARB;
  attribs: array[0..18] of LongInt;
  fmt: LongInt;
  num: UINT;
begin
  Result := 0;
  dw := CreateWindowExW(0, WND_CLASS_NAME, 'glprobe', WS_POPUP,
    0, 0, 8, 8, 0, 0, HInstance, nil);
  if dw = 0 then Exit;
  drc := 0;
  ddc := GetDC(dw);
  if ddc <> 0 then
  begin
    FillBasicPfd(pfd);
    pf := ChoosePixelFormat(ddc, @pfd);
    if (pf <> 0) and SetPixelFormat(ddc, pf, @pfd) then
    begin
      drc := wglCreateContext(ddc);
      if (drc <> 0) and wglMakeCurrent(ddc, drc) then
      begin
        choose := TWglChoosePixelFormatARB(
          wglGetProcAddress('wglChoosePixelFormatARB'));
        if choose <> nil then
        begin
          attribs[0] := WGL_DRAW_TO_WINDOW_ARB;  attribs[1] := 1;
          attribs[2] := WGL_SUPPORT_OPENGL_ARB;  attribs[3] := 1;
          attribs[4] := WGL_DOUBLE_BUFFER_ARB;   attribs[5] := 1;
          attribs[6] := WGL_PIXEL_TYPE_ARB;      attribs[7] := WGL_TYPE_RGBA_ARB;
          attribs[8] := WGL_COLOR_BITS_ARB;      attribs[9] := 32;
          attribs[10] := WGL_ACCELERATION_ARB;   attribs[11] := WGL_FULL_ACCELERATION_ARB;
          attribs[12] := WGL_SAMPLE_BUFFERS_ARB; attribs[13] := 1;
          attribs[14] := WGL_SAMPLES_ARB;        attribs[15] := samples;
          attribs[16] := 0;                      attribs[17] := 0;
          attribs[18] := 0;
          num := 0;
          if choose(ddc, @attribs[0], nil, 1, @fmt, @num) and (num > 0) then
            Result := fmt;
        end;
      end;
    end;
  end;
  wglMakeCurrent(0, 0);
  if drc <> 0 then wglDeleteContext(drc);
  if ddc <> 0 then ReleaseDC(dw, ddc);
  DestroyWindow(dw);
end;

function SetupGl(g: PScopeGui): Boolean;
var
  pfd: PIXELFORMATDESCRIPTOR;
  pf: Integer;
begin
  Result := False;
  g^.dc := GetDC(g^.wnd);
  if g^.dc = 0 then Exit;

  pf := ChooseMsaaFormat(4);
  g^.msaa := pf <> 0;
  FillBasicPfd(pfd);
  if g^.msaa then
    DescribePixelFormat(g^.dc, pf, SizeOf(pfd), @pfd)
  else
    pf := ChoosePixelFormat(g^.dc, @pfd);
  if pf = 0 then Exit;

  if not SetPixelFormat(g^.dc, pf, @pfd) then
  begin
    g^.msaa := False;
    FillBasicPfd(pfd);
    pf := ChoosePixelFormat(g^.dc, @pfd);
    if (pf = 0) or not SetPixelFormat(g^.dc, pf, @pfd) then Exit;
  end;
  g^.glrc := wglCreateContext(g^.dc);
  Result := g^.glrc <> 0;
end;

function GuiCreate(inst: PScopeInstance): Boolean;
var
  g: PScopeGui;
begin
  Result := False;
  if inst^.gui <> nil then
    Exit(True);
  if not EnsureClass then
    Exit;

  New(g);
  if g = nil then Exit;
  FillChar(g^, SizeOf(g^), 0);
  g^.statusDrag := ST_NONE;
  g^.inst := inst;
  g^.scale := EffectiveScale(inst, 0);
  g^.w := Round(DEFAULT_GUI_W * g^.scale);
  g^.h := Round(DEFAULT_GUI_H * g^.scale);

  { hidden and parentless; the host reparents it }
  g^.wnd := CreateWindowExW(0, WND_CLASS_NAME, 'lzScope', WS_POPUP,
    0, 0, g^.w, g^.h, 0, 0, HInstance, nil);
  if g^.wnd = 0 then
  begin
    Dispose(g);
    Exit;
  end;
  SetPropW(g^.wnd, GUI_PROP, HANDLE(g));

  if not SetupGl(g) then
  begin
    if g^.dc <> 0 then ReleaseDC(g^.wnd, g^.dc);
    DestroyWindow(g^.wnd);
    Dispose(g);
    Exit;
  end;

  g^.stop := False;
  g^.thread := BeginThread(@RenderThreadProc, g);
  if g^.thread = TThreadID(0) then
  begin
    wglDeleteContext(g^.glrc);
    ReleaseDC(g^.wnd, g^.dc);
    DestroyWindow(g^.wnd);
    Dispose(g);
    Exit;
  end;

  inst^.gui := g;
  Result := True;
end;

{ No timeout: freeing while the thread runs is a use-after-free.
  Sent messages are served to avoid a deadlock. }
procedure JoinRenderThread(g: PScopeGui);
const
  PM_QS_SENDMESSAGE = QS_SENDMESSAGE shl 16;
var
  h: HANDLE;
  mm: MSG;
begin
  h := {%H-}HANDLE(g^.thread);
  g^.stop := True;
  while MsgWaitForMultipleObjects(1, @h, False, INFINITE,
    QS_SENDMESSAGE) = WAIT_OBJECT_0 + 1 do
    PeekMessageW(@mm, 0, 0, 0, PM_NOREMOVE or PM_QS_SENDMESSAGE);
  CloseHandle(h);
end;

procedure GuiDestroy(inst: PScopeInstance);
var
  g: PScopeGui;
begin
  g := PScopeGui(inst^.gui);
  if g = nil then Exit;
  inst^.gui := nil;

  JoinRenderThread(g);

  if g^.glrc <> 0 then wglDeleteContext(g^.glrc);
  if g^.dc <> 0 then ReleaseDC(g^.wnd, g^.dc);
  RemovePropW(g^.wnd, GUI_PROP);
  DestroyWindow(g^.wnd);
  Dispose(g);
end;

function GuiSetParent(inst: PScopeInstance; parentHandle: Pointer): Boolean;
var
  g: PScopeGui;
  parent: HWND;
begin
  Result := False;
  g := PScopeGui(inst^.gui);
  parent := {%H-}HWND(parentHandle);
  if (g = nil) or (parent = 0) then Exit;
  SetWindowLongPtrW(g^.wnd, GWL_STYLE, WS_CHILD);
  Windows.SetParent(g^.wnd, parent);
  SetWindowPos(g^.wnd, 0, 0, 0, g^.w, g^.h,
    SWP_NOZORDER or SWP_NOACTIVATE or SWP_FRAMECHANGED);
  Result := True;
end;

function GuiGetSize(inst: PScopeInstance; outW, outH: PUInt32): Boolean;
var
  g: PScopeGui;
  sc: Single;
begin
  g := PScopeGui(inst^.gui);
  if g <> nil then
  begin
    outW^ := g^.w;
    outH^ := g^.h;
  end
  else
  begin
    sc := EffectiveScale(inst, 0);
    outW^ := Round(DEFAULT_GUI_W * sc);
    outH^ := Round(DEFAULT_GUI_H * sc);
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
  g^.w := Integer(w);
  g^.h := Integer(h);
  g^.sized := True;
  SetWindowPos(g^.wnd, 0, 0, 0, g^.w, g^.h,
    SWP_NOZORDER or SWP_NOACTIVATE or SWP_NOMOVE);
  Result := True;
end;

function GuiSetScale(inst: PScopeInstance; scale: Double): Boolean;
var
  g: PScopeGui;
begin
  inst^.guiScale := scale;
  g := PScopeGui(inst^.gui);
  { hosts set the scale after create: redo the default size for it }
  if (g <> nil) and (not g^.sized) then
  begin
    g^.scale := EffectiveScale(inst, g^.wnd);
    g^.w := Round(DEFAULT_GUI_W * g^.scale);
    g^.h := Round(DEFAULT_GUI_H * g^.scale);
    SetWindowPos(g^.wnd, 0, 0, 0, g^.w, g^.h,
      SWP_NOZORDER or SWP_NOACTIVATE or SWP_NOMOVE);
  end;
  Result := True;
end;

procedure GuiAdjustSize(inst: PScopeInstance; var w, h: UInt32);
var
  g: PScopeGui;
  sc: Single;
  minW, minH: UInt32;
begin
  g := PScopeGui(inst^.gui);
  if g <> nil then
    sc := EffectiveScale(inst, g^.wnd)
  else
    sc := EffectiveScale(inst, 0);
  minW := Round(MIN_GUI_W * sc);
  if (g <> nil) and (g^.minW > 0) then
    minW := g^.minW;
  minH := Round(MIN_GUI_H * sc);
  if w < minW then w := minW;
  if h < minH then h := minH;
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
  ShowWindow(g^.wnd, SW_SHOWNA);
  Result := True;
end;

function GuiHide(inst: PScopeInstance): Boolean;
var
  g: PScopeGui;
begin
  Result := False;
  g := PScopeGui(inst^.gui);
  if g = nil then Exit;
  ShowWindow(g^.wnd, SW_HIDE);
  Result := True;
end;

end.
