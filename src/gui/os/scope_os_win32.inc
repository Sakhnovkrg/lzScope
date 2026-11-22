{ Win32: child HWND, WGL context, GDI text. Part of scope_gui_os. }

uses
  Windows, gl_min, scope_gui_input;

const
  WND_CLASS_NAME: PWideChar = 'lzScopeCLAPWnd';
  GUI_PROP: PWideChar = 'lzScopeGuiPtr';
  FONT_NAME: PWideChar = 'Consolas';
  FALLBACK_FRAME_MS = 12;   { no DWM, no vsync }

  { WGL_ARB_pixel_format }
  WGL_DRAW_TO_WINDOW_ARB    = $2001;
  WGL_ACCELERATION_ARB      = $2003;
  WGL_SUPPORT_OPENGL_ARB    = $2010;
  WGL_DOUBLE_BUFFER_ARB     = $2011;
  WGL_PIXEL_TYPE_ARB        = $2013;
  WGL_COLOR_BITS_ARB        = $2014;
  WGL_FULL_ACCELERATION_ARB = $2027;
  WGL_TYPE_RGBA_ARB         = $202B;
  WGL_SAMPLE_BUFFERS_ARB    = $2041;
  WGL_SAMPLES_ARB           = $2042;

function wglCreateContext(dc: HDC): HGLRC; stdcall; external GL_LIB;
function wglDeleteContext(rc: HGLRC): BOOL; stdcall; external GL_LIB;
function wglMakeCurrent(dc: HDC; rc: HGLRC): BOOL; stdcall; external GL_LIB;

type
  { WGL_EXT_swap_control }
  TWglSwapIntervalEXT = function(interval: Integer): BOOL; stdcall;
  { WGL_ARB_pixel_format }
  TWglChoosePixelFormatARB = function(dc: HDC; piAttribIList: PLongInt;
    pfAttribFList: PSingle; nMaxFormats: UINT; piFormats: PLongInt;
    nNumFormats: PUINT): BOOL; stdcall;
  TDwmFlush = function: HRESULT; stdcall;
  TGetDpiForWindow = function(wnd: HWND): UINT; stdcall;

  PWin32View = ^TWin32View;
  TWin32View = record
    wnd: HWND;
    dc: HDC;
    glrc: HGLRC;
    { render thread }
    dwmLib: HMODULE;
    dwmFlush: TDwmFlush;
    swapWaits: Boolean;
  end;

var
  ClassRegistered: Boolean = False;

function View(g: PScopeGui): PWin32View; inline;
begin
  Result := PWin32View(g^.native);
end;

{ window }

function ScopeWndProc(hw: HWND; msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT; stdcall;
var
  g: PScopeGui;
  ps: PAINTSTRUCT;
  mx, my: Integer;
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
        pt.x := mx;   { screen coordinates }
        pt.y := my;
        ScreenToClient(hw, pt);
        InputWheel(g, pt.x, pt.y, SmallInt((wp shr 16) and $FFFF) / WHEEL_DELTA,
          (wp and MK_CONTROL) <> 0);
        Exit(0);
      end;
    WM_SETCURSOR:
      if (g <> nil) and ((lp and $FFFF) = HTCLIENT) and GetCursorPos(pt{%H-}) then
      begin
        ScreenToClient(hw, pt);
        case InputCursor(g, pt.x, pt.y) of
          ecResizeV:
            begin
              SetCursor(LoadCursor(0, IDC_SIZENS));
              Exit(1);
            end;
          ecHand:
            begin
              SetCursor(LoadCursor(0, IDC_HAND));
              Exit(1);
            end;
        end;
      end;
    WM_CAPTURECHANGED:
      if g <> nil then
        InputCancel(g);
    { second click of a double click arrives as DBLCLK }
    WM_LBUTTONDOWN, WM_LBUTTONDBLCLK:
      if g <> nil then
      begin
        InputPress(g, mx, my, msg = WM_LBUTTONDBLCLK);
        SetCapture(hw);
        Exit(0);
      end;
    WM_MOUSEMOVE:
      if (g <> nil) and InputActive(g) then
      begin
        InputMove(g, mx, my);
        Exit(0);
      end;
    WM_LBUTTONUP:
      if (g <> nil) and InputActive(g) then
      begin
        { before ReleaseCapture: its WM_CAPTURECHANGED would cancel the press }
        InputRelease(g, mx, my);
        ReleaseCapture;
        Exit(0);
      end;
    WM_RBUTTONDOWN:
      if g <> nil then
      begin
        InputSecondaryPress(g);
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

procedure OsGlobalCleanup;
begin
  if ClassRegistered then
  begin
    UnregisterClassW(WND_CLASS_NAME, HInstance);
    ClassRegistered := False;
  end;
end;

{ WGL }

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
        choose := TWglChoosePixelFormatARB(GetGLProc('wglChoosePixelFormatARB'));
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

function SetupGl(g: PScopeGui; v: PWin32View): Boolean;
var
  pfd: PIXELFORMATDESCRIPTOR;
  pf: Integer;
begin
  Result := False;
  v^.dc := GetDC(v^.wnd);
  if v^.dc = 0 then Exit;

  pf := ChooseMsaaFormat(4);
  g^.msaa := pf <> 0;
  FillBasicPfd(pfd);
  if g^.msaa then
    DescribePixelFormat(v^.dc, pf, SizeOf(pfd), @pfd)
  else
    pf := ChoosePixelFormat(v^.dc, @pfd);
  if pf = 0 then Exit;

  if not SetPixelFormat(v^.dc, pf, @pfd) then
  begin
    g^.msaa := False;
    FillBasicPfd(pfd);
    pf := ChoosePixelFormat(v^.dc, @pfd);
    if (pf = 0) or not SetPixelFormat(v^.dc, pf, @pfd) then Exit;
  end;
  v^.glrc := wglCreateContext(v^.dc);
  Result := v^.glrc <> 0;
end;

{ view }

function OsViewCreate(g: PScopeGui): Boolean;
var
  v: PWin32View;
begin
  Result := False;
  if not EnsureClass then Exit;
  New(v);
  if v = nil then Exit;
  FillChar(v^, SizeOf(v^), 0);

  { hidden and parentless; the host reparents it }
  v^.wnd := CreateWindowExW(0, WND_CLASS_NAME, 'lzScope', WS_POPUP,
    0, 0, g^.w, g^.h, 0, 0, HInstance, nil);
  if v^.wnd = 0 then
  begin
    Dispose(v);
    Exit;
  end;
  if not SetupGl(g, v) then
  begin
    if v^.dc <> 0 then ReleaseDC(v^.wnd, v^.dc);
    DestroyWindow(v^.wnd);
    Dispose(v);
    Exit;
  end;
  g^.native := v;
  SetPropW(v^.wnd, GUI_PROP, HANDLE(g));
  Result := True;
end;

procedure OsViewDestroy(g: PScopeGui);
var
  v: PWin32View;
begin
  v := View(g);
  if v = nil then Exit;
  g^.native := nil;
  if v^.glrc <> 0 then wglDeleteContext(v^.glrc);
  if v^.dc <> 0 then ReleaseDC(v^.wnd, v^.dc);
  RemovePropW(v^.wnd, GUI_PROP);
  DestroyWindow(v^.wnd);
  Dispose(v);
end;

function OsViewAttach(g: PScopeGui; parent: Pointer): Boolean;
var
  wnd: HWND;
begin
  wnd := View(g)^.wnd;
  SetWindowLongPtrW(wnd, GWL_STYLE, WS_CHILD);
  Windows.SetParent(wnd, {%H-}HWND(parent));
  SetWindowPos(wnd, 0, 0, 0, g^.w, g^.h,
    SWP_NOZORDER or SWP_NOACTIVATE or SWP_FRAMECHANGED);
  Result := True;
end;

procedure OsViewResize(g: PScopeGui);
begin
  SetWindowPos(View(g)^.wnd, 0, 0, 0, g^.w, g^.h,
    SWP_NOZORDER or SWP_NOACTIVATE or SWP_NOMOVE);
end;

procedure OsViewSetVisible(g: PScopeGui; visible: Boolean);
begin
  if visible then
    ShowWindow(View(g)^.wnd, SW_SHOWNA)
  else
    ShowWindow(View(g)^.wnd, SW_HIDE);
end;

{ Sent messages are served while waiting: the render thread may be blocked
  in a call that sends one to this window }
procedure OsJoinRenderThread(g: PScopeGui);
const
  PM_QS_SENDMESSAGE = QS_SENDMESSAGE shl 16;
var
  h: HANDLE;
  mm: MSG;
begin
  h := {%H-}HANDLE(g^.thread);
  while MsgWaitForMultipleObjects(1, @h, False, INFINITE,
    QS_SENDMESSAGE) = WAIT_OBJECT_0 + 1 do
    PeekMessageW(@mm, 0, 0, 0, PM_NOREMOVE or PM_QS_SENDMESSAGE);
  CloseHandle(h);
end;

function OsDisplayScale(g: PScopeGui): Single;
var
  getDpi: TGetDpiForWindow;
  dc: HDC;
  dpi: Integer;
begin
  getDpi := TGetDpiForWindow(
    GetProcAddress(GetModuleHandleW('user32.dll'), 'GetDpiForWindow'));
  dpi := 0;
  if (g <> nil) and (g^.native <> nil) and (getDpi <> nil) then
    dpi := Integer(getDpi(View(g)^.wnd));
  if dpi <= 0 then
  begin
    dc := GetDC(0);
    if dc <> 0 then
    begin
      dpi := GetDeviceCaps(dc, LOGPIXELSX);
      ReleaseDC(0, dc);
    end;
  end;
  if dpi <= 0 then dpi := 96;
  Result := dpi / 96.0;
end;

function OsPixelsPerUnit(g: PScopeGui): Single;
begin
  Result := 1.0;
end;

{ render thread }

function OsRenderBegin(g: PScopeGui): Boolean;
var
  v: PWin32View;
  swapInterval: TWglSwapIntervalEXT;
begin
  v := View(g);
  Result := wglMakeCurrent(v^.dc, v^.glrc);
  if not Result then Exit;

  { pace with DwmFlush: some drivers spin a core waiting for vsync in SwapBuffers }
  v^.dwmFlush := nil;
  v^.dwmLib := LoadLibraryW('dwmapi.dll');
  if v^.dwmLib <> 0 then
    v^.dwmFlush := TDwmFlush(GetProcAddress(v^.dwmLib, 'DwmFlush'));
  swapInterval := TWglSwapIntervalEXT(GetGLProc('wglSwapIntervalEXT'));
  v^.swapWaits := (swapInterval <> nil) and (v^.dwmFlush = nil);
  if swapInterval <> nil then
    swapInterval(Ord(v^.swapWaits));
end;

procedure OsRenderEnd(g: PScopeGui);
var
  v: PWin32View;
begin
  v := View(g);
  wglMakeCurrent(0, 0);
  if v^.dwmLib <> 0 then
    FreeLibrary(v^.dwmLib);
  v^.dwmLib := 0;
end;

function OsViewShowing(g: PScopeGui): Boolean;
var
  root: HWND;
begin
  Result := IsWindowVisible(View(g)^.wnd);
  if not Result then Exit;
  root := GetAncestor(View(g)^.wnd, GA_ROOT);
  if (root <> 0) and IsIconic(root) then
    Result := False;
end;

function OsCursorPos(g: PScopeGui; out x, y: Integer): Boolean;
var
  cp: TPoint;
begin
  Result := GetCursorPos(cp{%H-});
  if not Result then Exit;
  ScreenToClient(View(g)^.wnd, cp);
  x := cp.x;
  y := cp.y;
end;

function OsFrameBegin(g: PScopeGui): Boolean;
begin
  Result := True;
end;

procedure OsFrameEnd(g: PScopeGui);
var
  v: PWin32View;
begin
  v := View(g);
  SwapBuffers(v^.dc);
  if not v^.swapWaits then
    if (v^.dwmFlush = nil) or (v^.dwmFlush() < 0) then
      Sleep(FALLBACK_FRAME_MS);
end;

{ text: a memory DC with the font selected, a DIB to draw on }

type
  PGdiText = ^TGdiText;
  TGdiText = record
    dc: HDC;
    font: HFONT;
    dib: HBITMAP;
    oldFont, oldBmp: HGDIOBJ;
    bits: PByte;             { BGRA, top-down }
    w, h: Integer;
    coverage: PByte;
  end;

function OsTextOpen(heightPx: Integer; bold: Boolean): TOsText;
var
  t: PGdiText;
  weight: Integer;
begin
  Result := nil;
  New(t);
  if t = nil then Exit;
  FillChar(t^, SizeOf(t^), 0);
  t^.dc := CreateCompatibleDC(0);
  if t^.dc = 0 then
  begin
    Dispose(t);
    Exit;
  end;
  weight := FW_NORMAL;
  if bold then weight := FW_BOLD;
  t^.font := CreateFontW(-heightPx, 0, 0, 0, weight, 0, 0, 0,
    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
    ANTIALIASED_QUALITY, FIXED_PITCH or FF_DONTCARE, FONT_NAME);
  if t^.font = 0 then
  begin
    DeleteDC(t^.dc);
    Dispose(t);
    Exit;
  end;
  t^.oldFont := SelectObject(t^.dc, t^.font);
  Result := t;
end;

procedure OsTextClose(var t: TOsText);
var
  c: PGdiText;
begin
  c := PGdiText(t);
  if c = nil then Exit;
  t := nil;
  if c^.oldBmp <> 0 then SelectObject(c^.dc, c^.oldBmp);
  if c^.oldFont <> 0 then SelectObject(c^.dc, c^.oldFont);
  if c^.dib <> 0 then DeleteObject(c^.dib);
  if c^.font <> 0 then DeleteObject(c^.font);
  DeleteDC(c^.dc);
  FreeMem(c^.coverage);
  Dispose(c);
end;

procedure OsTextMetrics(t: TOsText; out ascent, height: Integer);
var
  tm: TEXTMETRICA;
begin
  FillChar(tm{%H-}, SizeOf(tm), 0);
  GetTextMetricsA(PGdiText(t)^.dc, @tm);
  ascent := tm.tmAscent;
  height := tm.tmHeight;
end;

function OsTextWidth(t: TOsText; const s: AnsiString): Integer;
var
  sz: Windows.TSize;
begin
  sz.cx := 0;
  sz.cy := 0;
  GetTextExtentPoint32A(PGdiText(t)^.dc, PAnsiChar(s), Length(s), @sz);
  Result := sz.cx;
end;

function OsTextCanvas(t: TOsText; w, h: Integer): Boolean;
var
  c: PGdiText;
  bi: BITMAPINFO;
  bits: Pointer;
begin
  c := PGdiText(t);
  Result := False;
  if c^.dib <> 0 then Exit;   { one canvas per text }
  FillChar(bi{%H-}, SizeOf(bi), 0);
  bi.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth := w;
  bi.bmiHeader.biHeight := -h;   { top-down }
  bi.bmiHeader.biPlanes := 1;
  bi.bmiHeader.biBitCount := 32;
  bi.bmiHeader.biCompression := BI_RGB;
  bits := nil;
  c^.dib := CreateDIBSection(c^.dc, bi, DIB_RGB_COLORS, bits, 0, 0);
  Result := (c^.dib <> 0) and (bits <> nil);
  if not Result then Exit;
  c^.bits := bits;
  c^.w := w;
  c^.h := h;
  c^.oldBmp := SelectObject(c^.dc, c^.dib);
  SetBkMode(c^.dc, TRANSPARENT);
  SetTextColor(c^.dc, $FFFFFF);
end;

procedure OsTextDraw(t: TOsText; x, y: Integer; const s: AnsiString);
begin
  TextOutA(PGdiText(t)^.dc, x, y, PAnsiChar(s), Length(s));
end;

{ GDI antialiasing is grayscale here: any channel is the coverage }
function OsTextCoverage(t: TOsText): PByte;
var
  c: PGdiText;
  i: Integer;
begin
  c := PGdiText(t);
  Result := nil;
  if c^.bits = nil then Exit;
  GdiFlush;
  if c^.coverage = nil then
    c^.coverage := GetMem(c^.w * c^.h);
  if c^.coverage = nil then Exit;
  for i := 0 to c^.w * c^.h - 1 do
    c^.coverage[i] := c^.bits[i * 4 + 1];
  Result := c^.coverage;
end;
