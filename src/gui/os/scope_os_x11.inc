{ Linux: an X11 child window with a GLX context, cairo for text. Part of
  scope_gui_os.

  Two Xlib connections per editor, so neither needs XInitThreads (the host
  may not have called it, and it is too late to call from a plugin):
  - main: the window, its events and cursor; main thread only. Its fd is
    watched by the host (posix-fd-support) and a host timer catches events
    Xlib has already read into its queue.
  - render: the GLX context and swaps; render thread only, once running.
  A window id is valid on any connection to the same server. }

uses
  SysUtils, Math, dynlibs, x, xlib, xutil, gl_min, scope_gui_input;

const
  { a frame takes at least this long: vsync where the swap does not wait }
  MIN_FRAME_MS = 15;
  { how often the render thread asks the server whether the window is viewable }
  SHOWING_POLL_MS = 200;
  DOUBLE_CLICK_MS = 400;
  DOUBLE_CLICK_PX = 4;

  { X cursor font }
  XC_HAND2 = 60;
  XC_SB_V_DOUBLE_ARROW = 116;

  { GLX 1.3 }
  GLX_DOUBLEBUFFER   = 5;
  GLX_RED_SIZE       = 8;
  GLX_GREEN_SIZE     = 9;
  GLX_BLUE_SIZE      = 10;
  GLX_ALPHA_SIZE     = 11;
  GLX_X_VISUAL_TYPE  = $22;
  GLX_TRUE_COLOR     = $8002;
  GLX_DRAWABLE_TYPE  = $8010;
  GLX_RENDER_TYPE    = $8011;
  GLX_X_RENDERABLE   = $8012;
  GLX_RGBA_TYPE      = $8014;
  GLX_WINDOW_BIT     = 1;
  GLX_RGBA_BIT       = 1;
  GLX_SAMPLE_BUFFERS = 100000;
  GLX_SAMPLES        = 100001;

type
  TGLXFBConfig = Pointer;
  PGLXFBConfig = ^TGLXFBConfig;
  TGLXContext = Pointer;

  TGlXSwapIntervalEXT = procedure(dpy: PDisplay; drawable: TWindow;
    interval: LongInt); cdecl;
  TGlXSwapIntervalMESA = function(interval: LongWord): LongInt; cdecl;

function glXChooseFBConfig(dpy: PDisplay; screen: LongInt; attribs: PLongInt;
  nelements: PLongInt): PGLXFBConfig; cdecl; external GL_LIB;
function glXGetVisualFromFBConfig(dpy: PDisplay;
  config: TGLXFBConfig): PXVisualInfo; cdecl; external GL_LIB;
function glXCreateNewContext(dpy: PDisplay; config: TGLXFBConfig;
  renderType: LongInt; share: TGLXContext;
  direct: TBool): TGLXContext; cdecl; external GL_LIB;
procedure glXDestroyContext(dpy: PDisplay; ctx: TGLXContext); cdecl; external GL_LIB;
function glXMakeCurrent(dpy: PDisplay; drawable: TWindow;
  ctx: TGLXContext): TBool; cdecl; external GL_LIB;
procedure glXSwapBuffers(dpy: PDisplay; drawable: TWindow); cdecl; external GL_LIB;

type
  PX11View = ^TX11View;
  TX11View = record
    dpy: PDisplay;           { main thread }
    rdpy: PDisplay;          { render thread }
    win: TWindow;
    cmap: TColormap;
    ctx: TGLXContext;
    gone: Boolean;           { destroyed with its parent }
    scale: Single;
    cursorHand, cursorResize: TCursor;
    cursorShown: TEditorCursor;
    lastPressTime: TTime;
    lastPressX, lastPressY: Integer;
    lastWasDouble: Boolean;
    { written on the main thread, read by the render thread }
    mouseX, mouseY: LongInt; { px, -1 = outside }
    { render thread }
    showing: Boolean;
    showingTick: QWord;
    frameTick: QWord;
    glW, glH: Integer;       { the size the context was last bound at }
  end;

var
  ScreenScale: Single = 0;   { 0 = not read yet }

function View(g: PScopeGui): PX11View; inline;
begin
  Result := PX11View(g^.native);
end;

{ errors on our own requests, e.g. a window the host destroyed first, must
  not reach the host's handler: it may abort }
function IgnoreXError(dpy: PDisplay; ev: PXErrorEvent): LongInt; cdecl;
begin
  Result := 0;
end;

{ Xft.dpi from the resource database, the desktop's UI scale }
function ReadScale(dpy: PDisplay): Single;
var
  res, p: PAnsiChar;
  s: AnsiString;
  i: Integer;
  dpi: Double;
begin
  Result := 1.0;
  if dpy = nil then Exit;
  res := XResourceManagerString(dpy);
  if res = nil then Exit;
  p := StrPos(res, 'Xft.dpi:');
  if p = nil then Exit;
  Inc(p, 8);
  while p^ in [' ', #9] do Inc(p);
  s := '';
  while p^ in ['0'..'9', '.'] do
  begin
    s := s + p^;
    Inc(p);
  end;
  Val(s, dpi, i);
  if (i = 0) and (dpi >= 48) then
    Result := dpi / 96.0;
end;

{ input, main thread }

procedure UpdateCursor(g: PScopeGui; x, y: Integer);
var
  v: PX11View;
  c: TEditorCursor;
begin
  v := View(g);
  c := InputCursor(g, x, y);
  if c = v^.cursorShown then Exit;
  v^.cursorShown := c;
  case c of
    ecResizeV: XDefineCursor(v^.dpy, v^.win, v^.cursorResize);
    ecHand: XDefineCursor(v^.dpy, v^.win, v^.cursorHand);
  else
    XUndefineCursor(v^.dpy, v^.win);
  end;
end;

procedure HandleButtonPress(g: PScopeGui; const e: TXButtonEvent);
var
  v: PX11View;
  dbl: Boolean;
begin
  v := View(g);
  case e.button of
    Button1:
      begin
        { the second press of a double click; a third starts over }
        dbl := (not v^.lastWasDouble) and
          (e.time - v^.lastPressTime <= DOUBLE_CLICK_MS) and
          (Abs(e.x - v^.lastPressX) <= DOUBLE_CLICK_PX) and
          (Abs(e.y - v^.lastPressY) <= DOUBLE_CLICK_PX);
        v^.lastWasDouble := dbl;
        v^.lastPressTime := e.time;
        v^.lastPressX := e.x;
        v^.lastPressY := e.y;
        { the server grabs the pointer for us until the release }
        InputPress(g, e.x, e.y, dbl);
      end;
    Button3:
      InputSecondaryPress(g);
  end;
end;

procedure HandleEvent(g: PScopeGui; var ev: TXEvent);
var
  v: PX11View;
begin
  v := View(g);
  case ev._type of
    Expose:
      InterlockedExchange(g^.redraw, 1);
    ConfigureNotify:
      if ev.xconfigure.window = v^.win then
      begin
        if (ev.xconfigure.width > 0) and (ev.xconfigure.height > 0) then
        begin
          g^.w := ev.xconfigure.width;
          g^.h := ev.xconfigure.height;
        end;
        InterlockedExchange(g^.redraw, 1);
      end;
    DestroyNotify:
      if ev.xdestroywindow.window = v^.win then
        v^.gone := True;
    ButtonPress:
      HandleButtonPress(g, ev.xbutton);
    ButtonRelease:
      if (ev.xbutton.button = Button1) and InputActive(g) then
        InputRelease(g, ev.xbutton.x, ev.xbutton.y);
    MotionNotify:
      begin
        v^.mouseX := ev.xmotion.x;
        v^.mouseY := ev.xmotion.y;
        if InputActive(g) then
          InputMove(g, ev.xmotion.x, ev.xmotion.y)
        else
          UpdateCursor(g, ev.xmotion.x, ev.xmotion.y);
      end;
    EnterNotify:
      begin
        v^.mouseX := ev.xcrossing.x;
        v^.mouseY := ev.xcrossing.y;
      end;
    LeaveNotify:
      begin
        { another client took the pointer: the press is lost }
        if (ev.xcrossing.mode = NotifyGrab) and InputActive(g) then
          InputCancel(g);
        if not InputActive(g) then
        begin
          v^.mouseX := -1;
          v^.mouseY := -1;
        end;
      end;
  end;
end;

function OsEventFd(g: PScopeGui): Integer;
begin
  Result := -1;
  if (g <> nil) and (View(g) <> nil) then
    Result := XConnectionNumber(View(g)^.dpy);
end;

{ Wheel notches come one event each (buttons 4 and 5, with a release
  each): what is queued at once is one turn, like Windows' wheel deltas }
procedure OsPumpEvents(g: PScopeGui);
var
  v: PX11View;
  ev: TXEvent;
  notches: Double;
  wheelX, wheelY: Integer;
  wheelVz, vz: Boolean;

  procedure FlushWheel;
  begin
    if notches <> 0 then
      InputWheel(g, wheelX, wheelY, notches, wheelVz);
    notches := 0;
  end;

begin
  v := View(g);
  if v = nil then Exit;
  notches := 0;
  wheelX := 0;
  wheelY := 0;
  wheelVz := False;
  while XPending(v^.dpy) > 0 do
  begin
    XNextEvent(v^.dpy, @ev);
    if (ev._type = ButtonPress) or (ev._type = ButtonRelease) then
      if (ev.xbutton.button = Button4) or (ev.xbutton.button = Button5) then
      begin
        if ev._type = ButtonPress then
        begin
          vz := (ev.xbutton.state and ControlMask) <> 0;
          if (notches <> 0) and ((vz <> wheelVz) or (ev.xbutton.x <> wheelX) or
             (ev.xbutton.y <> wheelY)) then
            FlushWheel;
          wheelX := ev.xbutton.x;
          wheelY := ev.xbutton.y;
          wheelVz := vz;
          if ev.xbutton.button = Button4 then
            notches := notches + 1
          else
            notches := notches - 1;
        end;
        Continue;
      end;
    FlushWheel;
    HandleEvent(g, ev);
  end;
  FlushWheel;
end;

{ GLX }

{ an FBConfig on the render connection, MSAA when samples > 0 }
function ChooseConfig(dpy: PDisplay; samples: LongInt): TGLXFBConfig;
var
  attribs: array[0..24] of LongInt;
  n: Integer;
  list: PGLXFBConfig;
  count: LongInt;
begin
  Result := nil;
  n := 0;
  attribs[n] := GLX_X_RENDERABLE;  attribs[n + 1] := 1; Inc(n, 2);
  attribs[n] := GLX_DRAWABLE_TYPE; attribs[n + 1] := GLX_WINDOW_BIT; Inc(n, 2);
  attribs[n] := GLX_RENDER_TYPE;   attribs[n + 1] := GLX_RGBA_BIT; Inc(n, 2);
  attribs[n] := GLX_X_VISUAL_TYPE; attribs[n + 1] := GLX_TRUE_COLOR; Inc(n, 2);
  attribs[n] := GLX_RED_SIZE;      attribs[n + 1] := 8; Inc(n, 2);
  attribs[n] := GLX_GREEN_SIZE;    attribs[n + 1] := 8; Inc(n, 2);
  attribs[n] := GLX_BLUE_SIZE;     attribs[n + 1] := 8; Inc(n, 2);
  attribs[n] := GLX_DOUBLEBUFFER;  attribs[n + 1] := 1; Inc(n, 2);
  if samples > 0 then
  begin
    attribs[n] := GLX_SAMPLE_BUFFERS; attribs[n + 1] := 1; Inc(n, 2);
    attribs[n] := GLX_SAMPLES;        attribs[n + 1] := samples; Inc(n, 2);
  end;
  attribs[n] := 0;
  count := 0;
  list := glXChooseFBConfig(dpy, XDefaultScreen(dpy), @attribs[0], @count);
  if list = nil then Exit;
  if count > 0 then
    Result := list[0];
  XFree(list);
end;

{ the visual of config, as the main connection knows it }
function MainVisual(v: PX11View; config: TGLXFBConfig;
  out vis: PVisual; out depth: LongInt): Boolean;
var
  rvi, mvi: PXVisualInfo;
  tmpl: TXVisualInfo;
  n: LongInt;
begin
  Result := False;
  rvi := glXGetVisualFromFBConfig(v^.rdpy, config);
  if rvi = nil then Exit;
  FillChar(tmpl{%H-}, SizeOf(tmpl), 0);
  tmpl.visualid := rvi^.visualid;
  tmpl.screen := XDefaultScreen(v^.dpy);
  XFree(rvi);
  n := 0;
  mvi := XGetVisualInfo(v^.dpy, VisualIDMask or VisualScreenMask, @tmpl, @n);
  if mvi = nil then Exit;
  Result := n > 0;
  if Result then
  begin
    vis := mvi^.visual;
    depth := mvi^.depth;
  end;
  XFree(mvi);
end;

function CreateWindowAndContext(g: PScopeGui; v: PX11View): Boolean;
var
  config: TGLXFBConfig;
  vis: PVisual;
  depth: LongInt;
  root: TWindow;
  attr: TXSetWindowAttributes;
begin
  Result := False;
  config := ChooseConfig(v^.rdpy, 4);
  g^.msaa := config <> nil;
  if config = nil then
    config := ChooseConfig(v^.rdpy, 0);
  if config = nil then Exit;
  if not MainVisual(v, config, vis, depth) then Exit;

  root := XDefaultRootWindow(v^.dpy);
  v^.cmap := XCreateColormap(v^.dpy, root, vis, AllocNone);
  FillChar(attr{%H-}, SizeOf(attr), 0);
  attr.colormap := v^.cmap;
  attr.background_pixel := 0;
  attr.border_pixel := 0;
  attr.event_mask := ExposureMask or StructureNotifyMask or ButtonPressMask or
    ButtonReleaseMask or PointerMotionMask or EnterWindowMask or LeaveWindowMask;
  { hidden and parentless; the host reparents it }
  v^.win := XCreateWindow(v^.dpy, root, 0, 0, g^.w, g^.h, 0, depth,
    InputOutput, vis, CWColormap or CWBackPixel or CWBorderPixel or CWEventMask,
    @attr);
  if v^.win = 0 then Exit;
  { the render connection must see the window }
  XSync(v^.dpy, False);

  v^.ctx := glXCreateNewContext(v^.rdpy, config, GLX_RGBA_TYPE, nil, 1);
  Result := v^.ctx <> nil;
end;

{ view }

function OsViewCreate(g: PScopeGui): Boolean;
var
  v: PX11View;
begin
  Result := False;
  New(v);
  if v = nil then Exit;
  FillChar(v^, SizeOf(v^), 0);
  v^.mouseX := -1;
  v^.mouseY := -1;
  v^.cursorShown := ecArrow;
  v^.dpy := XOpenDisplay(nil);
  v^.rdpy := XOpenDisplay(nil);
  if (v^.dpy = nil) or (v^.rdpy = nil) or not CreateWindowAndContext(g, v) then
  begin
    if v^.win <> 0 then XDestroyWindow(v^.dpy, v^.win);
    if v^.cmap <> 0 then XFreeColormap(v^.dpy, v^.cmap);
    if v^.rdpy <> nil then XCloseDisplay(v^.rdpy);
    if v^.dpy <> nil then XCloseDisplay(v^.dpy);
    Dispose(v);
    Exit;
  end;
  v^.scale := ReadScale(v^.dpy);
  v^.cursorHand := XCreateFontCursor(v^.dpy, XC_HAND2);
  v^.cursorResize := XCreateFontCursor(v^.dpy, XC_SB_V_DOUBLE_ARROW);
  XFlush(v^.dpy);
  g^.native := v;
  Result := True;
end;

procedure OsViewDestroy(g: PScopeGui);
var
  v: PX11View;
  old: TXErrorHandler;
begin
  v := View(g);
  if v = nil then Exit;
  g^.native := nil;
  old := XSetErrorHandler(@IgnoreXError);
  glXDestroyContext(v^.rdpy, v^.ctx);
  XSync(v^.rdpy, False);
  OsPumpEvents(g);
  if not v^.gone then
    XDestroyWindow(v^.dpy, v^.win);
  XFreeColormap(v^.dpy, v^.cmap);
  if v^.cursorHand <> 0 then XFreeCursor(v^.dpy, v^.cursorHand);
  if v^.cursorResize <> 0 then XFreeCursor(v^.dpy, v^.cursorResize);
  XSync(v^.dpy, False);
  XSetErrorHandler(old);
  XCloseDisplay(v^.rdpy);
  XCloseDisplay(v^.dpy);
  Dispose(v);
end;

function OsViewAttach(g: PScopeGui; parent: Pointer): Boolean;
var
  v: PX11View;
begin
  v := View(g);
  XReparentWindow(v^.dpy, v^.win, TWindow(PtrUInt(parent)), 0, 0);
  XResizeWindow(v^.dpy, v^.win, g^.w, g^.h);
  XMapWindow(v^.dpy, v^.win);
  XFlush(v^.dpy);
  Result := True;
end;

procedure OsViewResize(g: PScopeGui);
var
  v: PX11View;
begin
  v := View(g);
  if (g^.w < 1) or (g^.h < 1) then Exit;
  XResizeWindow(v^.dpy, v^.win, g^.w, g^.h);
  XFlush(v^.dpy);
end;

procedure OsViewSetVisible(g: PScopeGui; visible: Boolean);
var
  v: PX11View;
begin
  v := View(g);
  if visible then
    XMapWindow(v^.dpy, v^.win)
  else
    XUnmapWindow(v^.dpy, v^.win);
  XFlush(v^.dpy);
end;

{ the render thread never waits on the main thread }
procedure OsJoinRenderThread(g: PScopeGui);
begin
  WaitForThreadTerminate(g^.thread, 0);
  CloseThread(g^.thread);
end;

procedure OsGlobalCleanup;
begin
end;

function OsDisplayScale(g: PScopeGui): Single;
var
  dpy: PDisplay;
begin
  if (g <> nil) and (g^.native <> nil) then
    Exit(View(g)^.scale);
  if ScreenScale = 0 then
  begin
    dpy := XOpenDisplay(nil);
    ScreenScale := ReadScale(dpy);
    if dpy <> nil then XCloseDisplay(dpy);
  end;
  Result := ScreenScale;
end;

function OsPixelsPerUnit(g: PScopeGui): Single;
begin
  Result := 1.0;
end;

{ render thread: the render connection only }

function OsRenderBegin(g: PScopeGui): Boolean;
var
  v: PX11View;
  swapExt: TGlXSwapIntervalEXT;
  swapMesa: TGlXSwapIntervalMESA;
begin
  v := View(g);
  Result := glXMakeCurrent(v^.rdpy, v^.win, v^.ctx) <> 0;
  if not Result then Exit;
  swapExt := TGlXSwapIntervalEXT(GetGLProc('glXSwapIntervalEXT'));
  swapMesa := TGlXSwapIntervalMESA(GetGLProc('glXSwapIntervalMESA'));
  if swapExt <> nil then
    swapExt(v^.rdpy, v^.win, 1)
  else if swapMesa <> nil then
    swapMesa(1);
  v^.showingTick := 0;
end;

procedure OsRenderEnd(g: PScopeGui);
var
  v: PX11View;
begin
  v := View(g);
  glXMakeCurrent(v^.rdpy, 0, nil);
  XSync(v^.rdpy, False);
end;

{ viewable: mapped, and so are all its ancestors (not minimized) }
function OsViewShowing(g: PScopeGui): Boolean;
var
  v: PX11View;
  attr: TXWindowAttributes;
  now: QWord;
begin
  v := View(g);
  now := GetTickCount64;
  if (v^.showingTick = 0) or (now - v^.showingTick >= SHOWING_POLL_MS) then
  begin
    v^.showingTick := now;
    FillChar(attr{%H-}, SizeOf(attr), 0);
    v^.showing := (XGetWindowAttributes(v^.rdpy, v^.win, @attr) <> 0) and
      (attr.map_state = IsViewable);
  end;
  Result := v^.showing;
end;

function OsCursorPos(g: PScopeGui; out x, y: Integer): Boolean;
begin
  x := View(g)^.mouseX;
  y := View(g)^.mouseY;
  Result := x >= 0;
end;

{ Rebinds the context when the size changes: NVIDIA under XWayland was
  seen keeping the back buffer at the old size, the frame cropped }
function OsFrameBegin(g: PScopeGui): Boolean;
var
  v: PX11View;
  w, h: Integer;
begin
  Result := True;
  v := View(g);
  w := g^.w;
  h := g^.h;
  if (w = v^.glW) and (h = v^.glH) then Exit;
  XSync(v^.rdpy, False);
  glXMakeCurrent(v^.rdpy, 0, nil);
  Result := glXMakeCurrent(v^.rdpy, v^.win, v^.ctx) <> 0;
  v^.glW := w;
  v^.glH := h;
end;

{ some drivers queue swaps without waiting: pace to about 60 Hz then }
procedure OsFrameEnd(g: PScopeGui);
var
  v: PX11View;
  now: QWord;
begin
  v := View(g);
  glXSwapBuffers(v^.rdpy, v^.win);
  now := GetTickCount64;
  if (v^.frameTick <> 0) and (now - v^.frameTick < MIN_FRAME_MS) then
  begin
    Sleep(MIN_FRAME_MS - (now - v^.frameTick));
    now := GetTickCount64;
  end;
  v^.frameTick := now;
end;

{ text: cairo on an 8-bit alpha surface, loaded at run time }

const
  CAIRO_LIB = 'libcairo.so.2';
  CAIRO_FORMAT_A8 = 2;
  CAIRO_FONT_SLANT_NORMAL = 0;
  CAIRO_FONT_WEIGHT_NORMAL = 0;
  CAIRO_FONT_WEIGHT_BOLD = 1;
  CAIRO_ANTIALIAS_GRAY = 2;
  CAIRO_HINT_STYLE_SLIGHT = 2;
  CAIRO_HINT_METRICS_ON = 2;
  FONT_FAMILY = 'monospace';

type
  TCairoFontExtents = record
    ascent, descent, height, max_x_advance, max_y_advance: Double;
  end;
  TCairoTextExtents = record
    x_bearing, y_bearing, width, height, x_advance, y_advance: Double;
  end;

  TCairoApi = record
    image_surface_create: function(format, w, h: LongInt): Pointer; cdecl;
    image_surface_get_data: function(s: Pointer): PByte; cdecl;
    image_surface_get_stride: function(s: Pointer): LongInt; cdecl;
    surface_flush: procedure(s: Pointer); cdecl;
    surface_destroy: procedure(s: Pointer); cdecl;
    create: function(s: Pointer): Pointer; cdecl;
    destroy: procedure(cr: Pointer); cdecl;
    select_font_face: procedure(cr: Pointer; family: PAnsiChar;
      slant, weight: LongInt); cdecl;
    set_font_size: procedure(cr: Pointer; size: Double); cdecl;
    set_font_options: procedure(cr: Pointer; o: Pointer); cdecl;
    font_options_create: function: Pointer; cdecl;
    font_options_destroy: procedure(o: Pointer); cdecl;
    font_options_set_antialias: procedure(o: Pointer; a: LongInt); cdecl;
    font_options_set_hint_style: procedure(o: Pointer; h: LongInt); cdecl;
    font_options_set_hint_metrics: procedure(o: Pointer; h: LongInt); cdecl;
    font_extents: procedure(cr: Pointer; out e: TCairoFontExtents); cdecl;
    text_extents: procedure(cr: Pointer; s: PAnsiChar;
      out e: TCairoTextExtents); cdecl;
    set_source_rgba: procedure(cr: Pointer; r, g, b, a: Double); cdecl;
    move_to: procedure(cr: Pointer; x, y: Double); cdecl;
    show_text: procedure(cr: Pointer; s: PAnsiChar); cdecl;
  end;

  PCairoText = ^TCairoText;
  TCairoText = record
    sizePx: Double;
    bold: Boolean;
    ascent, height: Integer;
    surf, cr: Pointer;       { 1x1 for measuring, then the canvas }
    canvas: Boolean;
    w, h: Integer;
    coverage: PByte;
  end;

var
  Cairo: TCairoApi;
  { 0 = not tried, 1 = loaded, -1 = missing. Two render threads may both
    load: they store the same pointers, and the state only after them }
  CairoState: LongInt = 0;

function LoadCairo: Boolean;
var
  lib: TLibHandle;

  function Sym(const name: AnsiString; out p): Boolean;
  begin
    Pointer(p) := GetProcedureAddress(lib, 'cairo_' + name);
    Result := Pointer(p) <> nil;
  end;

begin
  if CairoState = 0 then
  begin
      lib := LoadLibrary(CAIRO_LIB);
      if (lib <> NilHandle) and
         Sym('image_surface_create', Cairo.image_surface_create) and
         Sym('image_surface_get_data', Cairo.image_surface_get_data) and
         Sym('image_surface_get_stride', Cairo.image_surface_get_stride) and
         Sym('surface_flush', Cairo.surface_flush) and
         Sym('surface_destroy', Cairo.surface_destroy) and
         Sym('create', Cairo.create) and
         Sym('destroy', Cairo.destroy) and
         Sym('select_font_face', Cairo.select_font_face) and
         Sym('set_font_size', Cairo.set_font_size) and
         Sym('set_font_options', Cairo.set_font_options) and
         Sym('font_options_create', Cairo.font_options_create) and
         Sym('font_options_destroy', Cairo.font_options_destroy) and
         Sym('font_options_set_antialias', Cairo.font_options_set_antialias) and
         Sym('font_options_set_hint_style', Cairo.font_options_set_hint_style) and
         Sym('font_options_set_hint_metrics', Cairo.font_options_set_hint_metrics) and
         Sym('font_extents', Cairo.font_extents) and
         Sym('text_extents', Cairo.text_extents) and
         Sym('set_source_rgba', Cairo.set_source_rgba) and
         Sym('move_to', Cairo.move_to) and
         Sym('show_text', Cairo.show_text) then
        InterlockedExchange(CairoState, 1)
      else
        InterlockedExchange(CairoState, -1);
      { the library stays loaded: the host keeps it anyway }
  end;
  Result := CairoState = 1;
end;

{ a context on surf with the text's font }
function NewContext(t: PCairoText; surf: Pointer): Pointer;
var
  opts: Pointer;
  weight: LongInt;
begin
  Result := Cairo.create(surf);
  if Result = nil then Exit;
  weight := CAIRO_FONT_WEIGHT_NORMAL;
  if t^.bold then weight := CAIRO_FONT_WEIGHT_BOLD;
  Cairo.select_font_face(Result, FONT_FAMILY, CAIRO_FONT_SLANT_NORMAL, weight);
  Cairo.set_font_size(Result, t^.sizePx);
  opts := Cairo.font_options_create();
  if opts <> nil then
  begin
    Cairo.font_options_set_antialias(opts, CAIRO_ANTIALIAS_GRAY);
    Cairo.font_options_set_hint_style(opts, CAIRO_HINT_STYLE_SLIGHT);
    { whole-pixel advances, like GDI }
    Cairo.font_options_set_hint_metrics(opts, CAIRO_HINT_METRICS_ON);
    Cairo.set_font_options(Result, opts);
    Cairo.font_options_destroy(opts);
  end;
  Cairo.set_source_rgba(Result, 1, 1, 1, 1);
end;

{ heightPx is the em height, as with GDI's negative height }
function OsTextOpen(heightPx: Integer; bold: Boolean): TOsText;
var
  t: PCairoText;
  fe: TCairoFontExtents;
begin
  Result := nil;
  if (heightPx < 1) or not LoadCairo then Exit;
  New(t);
  if t = nil then Exit;
  FillChar(t^, SizeOf(t^), 0);
  t^.sizePx := heightPx;
  t^.bold := bold;
  t^.surf := Cairo.image_surface_create(CAIRO_FORMAT_A8, 1, 1);
  if t^.surf <> nil then
    t^.cr := NewContext(t, t^.surf);
  if t^.cr = nil then
  begin
    if t^.surf <> nil then Cairo.surface_destroy(t^.surf);
    Dispose(t);
    Exit;
  end;
  Cairo.font_extents(t^.cr, fe);
  t^.ascent := Ceil(fe.ascent);
  t^.height := t^.ascent + Ceil(fe.descent);
  Result := t;
end;

procedure OsTextClose(var t: TOsText);
var
  c: PCairoText;
begin
  c := PCairoText(t);
  if c = nil then Exit;
  t := nil;
  Cairo.destroy(c^.cr);
  Cairo.surface_destroy(c^.surf);
  FreeMem(c^.coverage);
  Dispose(c);
end;

procedure OsTextMetrics(t: TOsText; out ascent, height: Integer);
begin
  ascent := PCairoText(t)^.ascent;
  height := PCairoText(t)^.height;
end;

function OsTextWidth(t: TOsText; const s: AnsiString): Integer;
var
  te: TCairoTextExtents;
begin
  if s = '' then Exit(0);
  Cairo.text_extents(PCairoText(t)^.cr, PAnsiChar(s), te);
  Result := Round(te.x_advance);
end;

function OsTextCanvas(t: TOsText; w, h: Integer): Boolean;
var
  c: PCairoText;
  surf, cr: Pointer;
begin
  c := PCairoText(t);
  Result := False;
  if c^.canvas or (w < 1) or (h < 1) then Exit;   { one canvas per text }
  { starts out cleared }
  surf := Cairo.image_surface_create(CAIRO_FORMAT_A8, w, h);
  if surf = nil then Exit;
  cr := NewContext(c, surf);
  if cr = nil then
  begin
    Cairo.surface_destroy(surf);
    Exit;
  end;
  Cairo.destroy(c^.cr);
  Cairo.surface_destroy(c^.surf);
  c^.surf := surf;
  c^.cr := cr;
  c^.canvas := True;
  c^.w := w;
  c^.h := h;
  Result := True;
end;

procedure OsTextDraw(t: TOsText; x, y: Integer; const s: AnsiString);
var
  c: PCairoText;
begin
  c := PCairoText(t);
  if (not c^.canvas) or (s = '') then Exit;
  Cairo.move_to(c^.cr, x, y + c^.ascent);
  Cairo.show_text(c^.cr, PAnsiChar(s));
end;

function OsTextCoverage(t: TOsText): PByte;
var
  c: PCairoText;
  data: PByte;
  stride, row: Integer;
begin
  c := PCairoText(t);
  Result := nil;
  if not c^.canvas then Exit;
  Cairo.surface_flush(c^.surf);
  data := Cairo.image_surface_get_data(c^.surf);
  stride := Cairo.image_surface_get_stride(c^.surf);
  if data = nil then Exit;
  if c^.coverage = nil then
    c^.coverage := GetMem(c^.w * c^.h);
  if c^.coverage = nil then Exit;
  for row := 0 to c^.h - 1 do
    Move(data[row * stride], c^.coverage[row * c^.w], c^.w);
  Result := c^.coverage;
end;
