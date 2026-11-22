{ macOS: an NSView whose NSOpenGLContext the render thread drives through
  CGL, CoreText for text. Part of scope_gui_os. }

uses
  MacOSAll, CocoaAll, SysUtils, Math, gl_min, scope_gui_input;

const
  FONT_REGULAR = 'Menlo-Regular';
  FONT_BOLD    = 'Menlo-Bold';
  { trackpad scrolling, points per wheel notch }
  SCROLL_PT_PER_NOTCH = 30.0;
  { a flush this quick did not wait for the display: covered, or no vsync }
  NO_VSYNC_MS = 2;
  FALLBACK_FRAME_MS = 12;

type
  TLzScopeView = objcclass(NSView)
  public
    gui: PScopeGui;
    tracking: NSTrackingArea;

    function isFlipped: ObjCBOOL; override;
    function isOpaque: ObjCBOOL; override;
    function acceptsFirstMouse(event: NSEvent): ObjCBOOL; override;
    procedure drawRect(dirtyRect: NSRect); override;
    procedure setFrameSize(newSize: NSSize); override;
    procedure viewWillMoveToWindow(newWindow: NSWindow); override;
    procedure viewDidMoveToWindow; override;
    procedure viewDidHide; override;
    procedure viewDidUnhide; override;
    procedure viewDidChangeBackingProperties; override;
    procedure updateTrackingAreas; override;

    procedure mouseDown(event: NSEvent); override;
    procedure mouseDragged(event: NSEvent); override;
    procedure mouseUp(event: NSEvent); override;
    procedure rightMouseDown(event: NSEvent); override;
    procedure mouseMoved(event: NSEvent); override;
    procedure mouseExited(event: NSEvent); override;
    procedure cursorUpdate(event: NSEvent); override;
    procedure scrollWheel(event: NSEvent); override;

    procedure windowChanged(note: NSNotification); message 'lzScopeWindowChanged:';
  end;

  PCocoaView = ^TCocoaView;
  TCocoaView = record
    view: TLzScopeView;
    ctx: NSOpenGLContext;
    cgl: CGLContextObj;
    { written on the main thread, read by the render thread }
    showing: LongBool;
    backing: Single;           { px per point }
    mouseX, mouseY: LongInt;   { px, -1 = outside }
  end;

function View(g: PScopeGui): PCocoaView; inline;
begin
  Result := PCocoaView(g^.native);
end;

function MainScreenBacking: Single;
begin
  Result := 1.0;
  if NSScreen.mainScreen <> nil then
    Result := NSScreen.mainScreen.backingScaleFactor;
end;

{ view state, main thread }

{ the context follows the view's drawable: attach, detach, resize }
procedure SyncDrawable(v: PCocoaView);
begin
  CGLLockContext(v^.cgl);
  if v^.view.window = nil then
    v^.ctx.clearDrawable
  else
  begin
    if v^.ctx.view <> NSView(v^.view) then
      v^.ctx.setView(v^.view);
    v^.ctx.update;
  end;
  CGLUnlockContext(v^.cgl);
end;

procedure UpdateShowing(v: PCocoaView);
var
  w: NSWindow;
begin
  w := v^.view.window;
  v^.showing := (w <> nil) and not v^.view.isHiddenOrHasHiddenAncestor and
    ((w.occlusionState and NSWindowOcclusionStateVisible) <> 0);
end;

{ the drawable in px from the frame in points }
procedure UpdateGeometry(g: PScopeGui);
var
  v: PCocoaView;
  sz: NSSize;
begin
  v := View(g);
  if v^.view.window <> nil then
    v^.backing := v^.view.window.backingScaleFactor;
  sz := v^.view.frame.size;
  g^.w := Round(sz.width * v^.backing);
  g^.h := Round(sz.height * v^.backing);
  SyncDrawable(v);
  InterlockedExchange(g^.redraw, 1);
end;

procedure EventPos(v: TLzScopeView; event: NSEvent; out x, y: Integer);
var
  p: NSPoint;
  backing: Single;
begin
  p := v.convertPoint_fromView(event.locationInWindow, nil);
  backing := View(v.gui)^.backing;
  x := Round(p.x * backing);
  y := Round(p.y * backing);
end;

procedure TrackMouse(v: TLzScopeView; x, y: Integer);
begin
  View(v.gui)^.mouseX := x;
  View(v.gui)^.mouseY := y;
end;

procedure SetCursorAt(v: TLzScopeView; x, y: Integer);
begin
  case InputCursor(v.gui, x, y) of
    ecResizeV: NSCursor.resizeUpDownCursor.set_;
    ecHand: NSCursor.pointingHandCursor.set_;
  else
    NSCursor.arrowCursor.set_;
  end;
end;

{ TLzScopeView }

function TLzScopeView.isFlipped: ObjCBOOL;
begin
  Result := True;   { y down, like the rest of the editor }
end;

function TLzScopeView.isOpaque: ObjCBOOL;
begin
  Result := True;
end;

{ the first click on an inactive host window still counts }
function TLzScopeView.acceptsFirstMouse(event: NSEvent): ObjCBOOL;
begin
  Result := True;
end;

procedure TLzScopeView.drawRect(dirtyRect: NSRect);
begin
  if gui <> nil then
    InterlockedExchange(gui^.redraw, 1);
end;

procedure TLzScopeView.setFrameSize(newSize: NSSize);
begin
  inherited setFrameSize(newSize);
  if gui <> nil then
    UpdateGeometry(gui);
end;

procedure TLzScopeView.viewWillMoveToWindow(newWindow: NSWindow);
var
  nc: NSNotificationCenter;
begin
  inherited viewWillMoveToWindow(newWindow);
  nc := NSNotificationCenter.defaultCenter;
  if window <> nil then
    nc.removeObserver_name_object(self, NSWindowDidChangeOcclusionStateNotification, window);
  if newWindow <> nil then
    nc.addObserver_selector_name_object(self, objcselector('lzScopeWindowChanged:'),
      NSWindowDidChangeOcclusionStateNotification, newWindow);
end;

procedure TLzScopeView.viewDidMoveToWindow;
begin
  inherited viewDidMoveToWindow;
  if gui = nil then Exit;
  UpdateGeometry(gui);
  UpdateShowing(View(gui));
end;

procedure TLzScopeView.viewDidHide;
begin
  inherited viewDidHide;
  if gui <> nil then UpdateShowing(View(gui));
end;

procedure TLzScopeView.viewDidUnhide;
begin
  inherited viewDidUnhide;
  if gui <> nil then UpdateShowing(View(gui));
end;

procedure TLzScopeView.viewDidChangeBackingProperties;
begin
  inherited viewDidChangeBackingProperties;
  if gui <> nil then UpdateGeometry(gui);
end;

procedure TLzScopeView.windowChanged(note: NSNotification);
begin
  if gui <> nil then UpdateShowing(View(gui));
end;

procedure TLzScopeView.updateTrackingAreas;
begin
  if tracking <> nil then
  begin
    removeTrackingArea(tracking);
    tracking.release;
  end;
  tracking := NSTrackingArea.alloc.initWithRect_options_owner_userInfo(bounds,
    NSTrackingMouseMoved or NSTrackingMouseEnteredAndExited or
    NSTrackingCursorUpdate or NSTrackingActiveAlways or NSTrackingInVisibleRect,
    self, nil);
  addTrackingArea(tracking);
  inherited updateTrackingAreas;
end;

procedure TLzScopeView.mouseDown(event: NSEvent);
var
  x, y: Integer;
begin
  if gui = nil then Exit;
  { control-click is the Mac's right click }
  if (event.modifierFlags and NSControlKeyMask) <> 0 then
  begin
    InputSecondaryPress(gui);
    Exit;
  end;
  EventPos(self, event, x, y);
  { every second click of a run, as Windows reports them }
  InputPress(gui, x, y, not Odd(event.clickCount));
end;

procedure TLzScopeView.mouseDragged(event: NSEvent);
var
  x, y: Integer;
begin
  if gui = nil then Exit;
  EventPos(self, event, x, y);
  TrackMouse(self, x, y);
  if InputActive(gui) then
    InputMove(gui, x, y);
end;

procedure TLzScopeView.mouseUp(event: NSEvent);
var
  x, y: Integer;
begin
  if (gui = nil) or not InputActive(gui) then Exit;
  EventPos(self, event, x, y);
  InputRelease(gui, x, y);
end;

procedure TLzScopeView.rightMouseDown(event: NSEvent);
begin
  if gui <> nil then
    InputSecondaryPress(gui);
end;

procedure TLzScopeView.mouseMoved(event: NSEvent);
var
  x, y: Integer;
begin
  if gui = nil then Exit;
  EventPos(self, event, x, y);
  TrackMouse(self, x, y);
  SetCursorAt(self, x, y);
end;

procedure TLzScopeView.mouseExited(event: NSEvent);
begin
  if gui = nil then Exit;
  TrackMouse(self, -1, -1);
  NSCursor.arrowCursor.set_;
end;

procedure TLzScopeView.cursorUpdate(event: NSEvent);
var
  x, y: Integer;
begin
  if gui = nil then Exit;
  EventPos(self, event, x, y);
  SetCursorAt(self, x, y);
end;

procedure TLzScopeView.scrollWheel(event: NSEvent);
var
  x, y: Integer;
  notches: Double;
begin
  if gui = nil then Exit;
  if event.hasPreciseScrollingDeltas then
    notches := event.scrollingDeltaY / SCROLL_PT_PER_NOTCH
  else
    notches := event.deltaY;
  { the way the wheel or fingers moved, whatever "natural scrolling" says }
  if event.isDirectionInvertedFromDevice then
    notches := -notches;
  if notches = 0 then Exit;
  EventPos(self, event, x, y);
  InputWheel(gui, x, y, notches,
    (event.modifierFlags and (NSCommandKeyMask or NSControlKeyMask)) <> 0);
end;

{ view }

function CreateContext(msaa: Boolean): NSOpenGLContext;
const
  ATTR_BASE: array[0..8] of NSOpenGLPixelFormatAttribute = (
    NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersionLegacy,
    NSOpenGLPFADoubleBuffer, NSOpenGLPFAAccelerated,
    NSOpenGLPFAColorSize, 24, NSOpenGLPFAAlphaSize, 8, 0);
  ATTR_MSAA: array[0..13] of NSOpenGLPixelFormatAttribute = (
    NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersionLegacy,
    NSOpenGLPFADoubleBuffer, NSOpenGLPFAAccelerated,
    NSOpenGLPFAColorSize, 24, NSOpenGLPFAAlphaSize, 8,
    NSOpenGLPFAMultisample, NSOpenGLPFASampleBuffers, 1,
    NSOpenGLPFASamples, 4, 0);
var
  pf: NSOpenGLPixelFormat;
begin
  if msaa then
    pf := NSOpenGLPixelFormat.alloc.initWithAttributes(@ATTR_MSAA[0])
  else
    pf := NSOpenGLPixelFormat.alloc.initWithAttributes(@ATTR_BASE[0]);
  Result := nil;
  if pf = nil then Exit;
  Result := NSOpenGLContext.alloc.initWithFormat_shareContext(pf, nil);
  pf.release;
end;

function OsViewCreate(g: PScopeGui): Boolean;
var
  v: PCocoaView;
  swapInterval: GLint;
begin
  Result := False;
  New(v);
  if v = nil then Exit;
  FillChar(v^, SizeOf(v^), 0);
  v^.mouseX := -1;
  v^.mouseY := -1;
  v^.backing := MainScreenBacking;

  g^.msaa := True;
  v^.ctx := CreateContext(True);
  if v^.ctx = nil then
  begin
    g^.msaa := False;
    v^.ctx := CreateContext(False);
  end;
  if v^.ctx = nil then
  begin
    Dispose(v);
    Exit;
  end;
  v^.cgl := CGLContextObj(v^.ctx.CGLContextObj);
  swapInterval := 1;   { flush waits for the display }
  v^.ctx.setValues_forParameter(@swapInterval, NSOpenGLCPSwapInterval);

  v^.view := TLzScopeView.alloc.initWithFrame(
    NSMakeRect(0, 0, g^.w / v^.backing, g^.h / v^.backing));
  v^.view.setWantsBestResolutionOpenGLSurface(True);
  { hidden until the host shows it }
  v^.view.setHidden(True);
  g^.native := v;
  v^.view.gui := g;
  Result := True;
end;

procedure OsViewDestroy(g: PScopeGui);
var
  v: PCocoaView;
begin
  v := View(g);
  if v = nil then Exit;
  v^.view.gui := nil;
  NSNotificationCenter.defaultCenter.removeObserver(v^.view);
  v^.view.removeFromSuperview;
  if v^.view.tracking <> nil then
    v^.view.tracking.release;
  CGLLockContext(v^.cgl);
  v^.ctx.clearDrawable;
  CGLUnlockContext(v^.cgl);
  v^.view.release;
  v^.ctx.release;
  g^.native := nil;
  Dispose(v);
end;

function OsViewAttach(g: PScopeGui; parent: Pointer): Boolean;
var
  v: PCocoaView;
begin
  v := View(g);
  v^.view.setFrameOrigin(NSMakePoint(0, 0));
  NSView(parent).addSubview(v^.view);
  Result := True;
end;

procedure OsViewResize(g: PScopeGui);
var
  v: PCocoaView;
begin
  v := View(g);
  v^.view.setFrameSize(NSMakeSize(g^.w / v^.backing, g^.h / v^.backing));
end;

procedure OsViewSetVisible(g: PScopeGui; visible: Boolean);
begin
  View(g)^.view.setHidden(not visible);
  UpdateShowing(View(g));
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
begin
  if (g <> nil) and (g^.native <> nil) then
    Result := View(g)^.backing
  else
    Result := MainScreenBacking;
end;

{ CLAP sizes are points: px per unit is the backing scale }
function OsPixelsPerUnit(g: PScopeGui): Single;
begin
  Result := OsDisplayScale(g);
end;

{ render thread: CGL only, no Objective-C }

function OsRenderBegin(g: PScopeGui): Boolean;
begin
  Result := CGLSetCurrentContext(View(g)^.cgl) = kCGLNoError;
end;

procedure OsRenderEnd(g: PScopeGui);
begin
  CGLSetCurrentContext(nil);
end;

function OsViewShowing(g: PScopeGui): Boolean;
begin
  Result := View(g)^.showing;
end;

function OsCursorPos(g: PScopeGui; out x, y: Integer): Boolean;
begin
  x := View(g)^.mouseX;
  y := View(g)^.mouseY;
  Result := x >= 0;
end;

{ the main thread changes the drawable under the same lock }
function OsFrameBegin(g: PScopeGui): Boolean;
begin
  Result := CGLLockContext(View(g)^.cgl) = kCGLNoError;
end;

procedure OsFrameEnd(g: PScopeGui);
var
  t0: QWord;
begin
  t0 := GetTickCount64;
  CGLFlushDrawable(View(g)^.cgl);
  CGLUnlockContext(View(g)^.cgl);
  if GetTickCount64 - t0 < NO_VSYNC_MS then
    Sleep(FALLBACK_FRAME_MS);
end;

{ text: CoreText glyphs on an 8-bit gray bitmap }

type
  PCtText = ^TCtText;
  TCtText = record
    font: CTFontRef;
    ascent: Integer;
    canvas: CGContextRef;
    pixels: PByte;
    w, h: Integer;
  end;

function OsTextOpen(heightPx: Integer; bold: Boolean): TOsText;
var
  t: PCtText;
  name: CFStringRef;
begin
  Result := nil;
  if bold then
    name := CFStringCreateWithCString(nil, FONT_BOLD, kCFStringEncodingASCII)
  else
    name := CFStringCreateWithCString(nil, FONT_REGULAR, kCFStringEncodingASCII);
  if name = nil then Exit;
  New(t);
  FillChar(t^, SizeOf(t^), 0);
  t^.font := CTFontCreateWithName(name, heightPx, nil);
  CFRelease(name);
  if t^.font = nil then
  begin
    Dispose(t);
    Exit;
  end;
  t^.ascent := Ceil(CTFontGetAscent(t^.font));
  Result := t;
end;

procedure OsTextClose(var t: TOsText);
var
  c: PCtText;
begin
  c := PCtText(t);
  if c = nil then Exit;
  t := nil;
  if c^.canvas <> nil then CGContextRelease(c^.canvas);
  FreeMem(c^.pixels);
  CFRelease(c^.font);
  Dispose(c);
end;

procedure OsTextMetrics(t: TOsText; out ascent, height: Integer);
begin
  ascent := PCtText(t)^.ascent;
  height := ascent + Ceil(CTFontGetDescent(PCtText(t)^.font));
end;

{ glyphs and their advances; n = Length(s) }
function ShapeText(t: PCtText; const s: AnsiString; glyphs: CGGlyphPtr;
  advances: CGSizePtr): Double;
var
  chars: array of UniChar;
  i: Integer;
begin
  SetLength(chars, Length(s));
  for i := 1 to Length(s) do
    chars[i - 1] := Ord(s[i]);
  CTFontGetGlyphsForCharacters(t^.font, @chars[0], glyphs, Length(s));
  Result := CTFontGetAdvancesForGlyphs(t^.font, kCTFontOrientationHorizontal,
    glyphs, advances, Length(s));
end;

function OsTextWidth(t: TOsText; const s: AnsiString): Integer;
var
  glyphs: array of CGGlyph;
  advances: array of CGSize;
begin
  Result := 0;
  if s = '' then Exit;
  SetLength(glyphs, Length(s));
  SetLength(advances, Length(s));
  Result := Round(ShapeText(PCtText(t), s, @glyphs[0], @advances[0]));
end;

function OsTextCanvas(t: TOsText; w, h: Integer): Boolean;
var
  c: PCtText;
  gray: CGColorSpaceRef;
begin
  c := PCtText(t);
  Result := False;
  if c^.canvas <> nil then Exit;   { one canvas per text }
  c^.pixels := GetMem(w * h);
  if c^.pixels = nil then Exit;
  FillChar(c^.pixels^, w * h, 0);
  gray := CGColorSpaceCreateDeviceGray;
  c^.canvas := CGBitmapContextCreate(c^.pixels, w, h, 8, w, gray, kCGImageAlphaNone);
  CGColorSpaceRelease(gray);
  if c^.canvas = nil then Exit;
  c^.w := w;
  c^.h := h;
  { plain grayscale coverage on whole pixels, like the GDI path }
  CGContextSetGrayFillColor(c^.canvas, 1.0, 1.0);
  CGContextSetShouldAntialias(c^.canvas, Ord(True));
  CGContextSetAllowsFontSmoothing(c^.canvas, Ord(False));
  CGContextSetShouldSubpixelPositionFonts(c^.canvas, Ord(False));
  Result := True;
end;

procedure OsTextDraw(t: TOsText; x, y: Integer; const s: AnsiString);
var
  c: PCtText;
  glyphs: array of CGGlyph;
  advances: array of CGSize;
  positions: array of CGPoint;
  i: Integer;
  pen: Double;
begin
  c := PCtText(t);
  if (c^.canvas = nil) or (s = '') then Exit;
  SetLength(glyphs, Length(s));
  SetLength(advances, Length(s));
  SetLength(positions, Length(s));
  ShapeText(c, s, @glyphs[0], @advances[0]);
  { Quartz has y up from the bottom of the canvas }
  pen := x;
  for i := 0 to Length(s) - 1 do
  begin
    positions[i].x := pen;
    positions[i].y := c^.h - (y + c^.ascent);
    pen := pen + advances[i].width;
  end;
  CTFontDrawGlyphs(c^.font, @glyphs[0], @positions[0], Length(s), c^.canvas);
end;

{ the bitmap's first row is the top one }
function OsTextCoverage(t: TOsText): PByte;
begin
  if PCtText(t)^.canvas = nil then
    Exit(nil);
  Result := PCtText(t)^.pixels;
end;
