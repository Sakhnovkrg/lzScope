{ Cocoa test host window. Part of testhost_window. }

uses
  MacOSAll, CocoaAll;

type
  { informal delegate: FPC 3.2's protocol method lists trip Apple's new linker }
  THostDelegate = objcclass(NSObject)
  public
    procedure windowDidResize(notification: NSNotification); message 'windowDidResize:';
    procedure windowWillClose(notification: NSNotification); message 'windowWillClose:';
  end;

{ the non-variadic variant (10.13): FPC can't call C varargs on arm64 }
function CGEventCreateScrollWheelEvent2(source: CGEventSourceRef;
  units: CGScrollEventUnit; wheelCount: UInt32; wheel1, wheel2, wheel3: Int32): CGEventRef;
  cdecl; external name 'CGEventCreateScrollWheelEvent2';

var
  Window: NSWindow = nil;
  Delegate: THostDelegate = nil;
  Editor: NSView = nil;
  Running: Boolean = False;

procedure THostDelegate.windowDidResize(notification: NSNotification);
var
  w, h: Integer;
begin
  HostWindowClientSize(w, h);
  if (OnHostResize <> nil) and (w > 0) and (h > 0) then
    OnHostResize(w, h);
end;

procedure THostDelegate.windowWillClose(notification: NSNotification);
begin
  { the editor goes before its parent }
  if OnHostClose <> nil then
    OnHostClose;
  Running := False;
end;

function HostWindowOpen(w, h: Integer; const title: AnsiString): Boolean;
begin
  NSApplication.sharedApplication;
  NSApp.setActivationPolicy(NSApplicationActivationPolicyRegular);
  NSApp.finishLaunching;

  Window := NSWindow.alloc.initWithContentRect_styleMask_backing_defer(
    NSMakeRect(100, 100, w, h),
    NSTitledWindowMask or NSClosableWindowMask or NSMiniaturizableWindowMask or
    NSResizableWindowMask, NSBackingStoreBuffered, False);
  Result := Window <> nil;
  if not Result then Exit;
  Window.setReleasedWhenClosed(False);
  Window.setTitle(NSString.stringWithUTF8String(PAnsiChar(title)));
  Delegate := THostDelegate.alloc.init;
  Window.setDelegate(id(Delegate));
  Window.makeKeyAndOrderFront(nil);
  NSApp.activateIgnoringOtherApps(True);
  Running := True;
end;

procedure HostWindowFree;
begin
  if Window = nil then Exit;
  Window.setDelegate(nil);
  Window.orderOut(nil);
  Window.release;
  Window := nil;
  Delegate.release;
  Delegate := nil;
end;

function HostWindowHandle: Pointer;
begin
  Result := Window.contentView;
end;

procedure HostWindowClientSize(out w, h: Integer);
var
  sz: NSSize;
begin
  sz := Window.contentView.frame.size;
  w := Round(sz.width);
  h := Round(sz.height);
end;

function setenv(name, value: PAnsiChar; overwrite: LongInt): LongInt; cdecl; external 'c';

procedure HostSetEnv(const name, value: AnsiString);
begin
  setenv(PAnsiChar(name), PAnsiChar(value), 1);
end;

procedure HostWindowFocus;
begin
  Window.makeKeyAndOrderFront(nil);
  NSApp.activateIgnoringOtherApps(True);
end;

function HostPump: Boolean;
var
  pool: NSAutoreleasePool;
  ev: NSEvent;
begin
  pool := NSAutoreleasePool.alloc.init;
  repeat
    ev := NSApp.nextEventMatchingMask_untilDate_inMode_dequeue(NSAnyEventMask,
      nil, NSDefaultRunLoopMode, True);
    if ev <> nil then
      NSApp.sendEvent(ev);
  until ev = nil;
  NSApp.updateWindows;
  pool.release;
  Result := Running;
end;

function EditorFind: Boolean;
begin
  Editor := nil;
  if Window.contentView.subviews.count > 0 then
    Editor := NSView(Window.contentView.subviews.objectAtIndex(0));
  Result := Editor <> nil;
end;

{ editor point -> window coordinates, where events carry their location }
function WindowPoint(x, y: Integer): NSPoint;
begin
  Result := Editor.convertPoint_toView(NSMakePoint(x, y), nil);
end;

function MouseEvent(kind: NSEventType; x, y, clicks: Integer): NSEvent;
begin
  Result := NSEvent.mouseEventWithType_location_modifierFlags_timestamp_windowNumber_context_eventNumber_clickCount_pressure(
    kind, WindowPoint(x, y), 0, 0, Window.windowNumber, nil, 0, clicks, 1.0);
end;

procedure EditorPress(x, y: Integer; dbl: Boolean);
begin
  if dbl then
    Editor.mouseDown(MouseEvent(NSLeftMouseDown, x, y, 2))
  else
    Editor.mouseDown(MouseEvent(NSLeftMouseDown, x, y, 1));
end;

procedure EditorMove(x, y: Integer);
begin
  Editor.mouseDragged(MouseEvent(NSLeftMouseDragged, x, y, 1));
end;

procedure EditorRelease(x, y: Integer);
begin
  Editor.mouseUp(MouseEvent(NSLeftMouseUp, x, y, 1));
end;

procedure EditorWheel(x, y, notches: Integer; vzoom: Boolean);
var
  cg: CGEventRef;
  p: NSPoint;
  screen: NSRect;
  loc: CGPoint;
begin
  cg := CGEventCreateScrollWheelEvent2(nil, kCGScrollEventUnitLine, 1, notches, 0, 0);
  if cg = nil then Exit;
  { CG locations are global, y down from the top of the main screen }
  p := WindowPoint(x, y);
  screen := Window.convertRectToScreen(NSMakeRect(p.x, p.y, 0, 0));
  loc.x := screen.origin.x;
  loc.y := NSScreen.mainScreen.frame.size.height - screen.origin.y;
  CGEventSetLocation(cg, loc);
  if vzoom then
    CGEventSetFlags(cg, NSCommandKeyMask);   { = kCGEventFlagMaskCommand }
  Editor.scrollWheel(NSEvent.eventWithCGEvent(cg));
  CFRelease(cg);
end;
