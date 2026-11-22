{ X11 test host window. Part of testhost_window.

  Input goes to the editor's window with XSendEvent, the way the server
  delivers it; the editor reads it when the host calls its on_fd. }

uses
  x, xlib, xutil;

const
  { synthetic event times: presses this far apart are no double click }
  CLICK_GAP_MS = 1000;
  DOUBLE_GAP_MS = 50;
  EVENT_WAIT_MS = 200;

var
  Dpy: PDisplay = nil;
  HostWin: TWindow = 0;
  EditorWin: TWindow = 0;
  WmDelete: TAtom = 0;
  Running: Boolean = False;
  EventTime: TTime = 1;
  ButtonState: LongWord = 0;

function HostWindowOpen(w, h: Integer; const title: AnsiString): Boolean;
var
  ev: TXEvent;
begin
  Result := False;
  Dpy := XOpenDisplay(nil);
  if Dpy = nil then Exit;
  HostWin := XCreateSimpleWindow(Dpy, XDefaultRootWindow(Dpy), 100, 100, w, h, 0,
    XBlackPixel(Dpy, XDefaultScreen(Dpy)), XBlackPixel(Dpy, XDefaultScreen(Dpy)));
  if HostWin = 0 then Exit;
  XStoreName(Dpy, HostWin, PChar(title));
  WmDelete := XInternAtom(Dpy, 'WM_DELETE_WINDOW', False);
  XSetWMProtocols(Dpy, HostWin, @WmDelete, 1);
  XSelectInput(Dpy, HostWin, StructureNotifyMask);
  XMapWindow(Dpy, HostWin);
  { viewable before the editor goes in: it only renders when it is }
  repeat
    XNextEvent(Dpy, @ev);
  until ev._type = MapNotify;
  Running := True;
  Result := True;
end;

procedure HostWindowFree;
begin
  if Dpy = nil then Exit;
  if HostWin <> 0 then
    XDestroyWindow(Dpy, HostWin);
  HostWin := 0;
  XCloseDisplay(Dpy);
  Dpy := nil;
end;

function HostWindowHandle: Pointer;
begin
  Result := Pointer(PtrUInt(HostWin));
end;

procedure HostWindowClientSize(out w, h: Integer);
var
  attr: TXWindowAttributes;
begin
  FillChar(attr{%H-}, SizeOf(attr), 0);
  XGetWindowAttributes(Dpy, HostWin, @attr);
  w := attr.width;
  h := attr.height;
end;

function setenv(name, value: PAnsiChar; overwrite: LongInt): LongInt; cdecl; external 'c';

procedure HostSetEnv(const name, value: AnsiString);
begin
  setenv(PAnsiChar(name), PAnsiChar(value), 1);
end;

procedure HostWindowFocus;
begin
  XRaiseWindow(Dpy, HostWin);
  XFlush(Dpy);
end;

function HostPump: Boolean;
var
  ev: TXEvent;
begin
  while Running and (XPending(Dpy) > 0) do
  begin
    XNextEvent(Dpy, @ev);
    case ev._type of
      ConfigureNotify:
        if (ev.xconfigure.window = HostWin) and (OnHostResize <> nil) and
           (ev.xconfigure.width > 0) and (ev.xconfigure.height > 0) then
          OnHostResize(ev.xconfigure.width, ev.xconfigure.height);
      ClientMessage:
        if TAtom(ev.xclient.data.l[0]) = WmDelete then
        begin
          { the editor goes before its parent }
          if OnHostClose <> nil then
            OnHostClose;
          XDestroyWindow(Dpy, HostWin);
          HostWin := 0;
          Running := False;
        end;
    end;
  end;
  if OnHostEvents <> nil then
    OnHostEvents(0);
  Result := Running;
end;

function EditorFind: Boolean;
var
  root, parent: TWindow;
  children: PWindow;
  n: LongWord;
begin
  EditorWin := 0;
  children := nil;
  n := 0;
  if XQueryTree(Dpy, HostWin, @root, @parent, @children, @n) <> 0 then
  begin
    if n > 0 then
      EditorWin := children[0];
    if children <> nil then
      XFree(children);
  end;
  Result := EditorWin <> 0;
end;

var
  { Deliver queues, and the batch reaches the editor at once }
  Batching: Boolean = False;

procedure DeliverQueued;
begin
  { the server has it all once XSync returns; the editor reads it in on_fd }
  XSync(Dpy, False);
  if OnHostEvents <> nil then
    OnHostEvents(EVENT_WAIT_MS);
end;

procedure Deliver(var ev: TXEvent; mask: LongInt);
begin
  ev.xany.display := Dpy;
  ev.xany.window := EditorWin;
  ev.xany.send_event := 1;
  XSendEvent(Dpy, EditorWin, False, mask, @ev);
  if not Batching then
    DeliverQueued;
end;

procedure SendButton(kind, button: LongInt; x, y: Integer; gap: TTime;
  state: LongWord);
var
  ev: TXEvent;
  mask: LongInt;
begin
  FillChar(ev{%H-}, SizeOf(ev), 0);
  Inc(EventTime, gap);
  ev.xbutton._type := kind;
  ev.xbutton.root := XDefaultRootWindow(Dpy);
  ev.xbutton.time := EventTime;
  ev.xbutton.x := x;
  ev.xbutton.y := y;
  ev.xbutton.state := state or ButtonState;
  ev.xbutton.button := button;
  ev.xbutton.same_screen := 1;
  if kind = ButtonPress then
    mask := ButtonPressMask
  else
    mask := ButtonReleaseMask;
  Deliver(ev, mask);
end;

var
  LastPressX: Integer = -1000;
  LastPressY: Integer = -1000;

{ X has no double-click event: the editor times two presses at one spot.
  dbl is the second press, as with Windows' WM_LBUTTONDBLCLK; when the
  last press was elsewhere, the first click goes here, as the hand would }
procedure EditorPress(x, y: Integer; dbl: Boolean);
begin
  if dbl then
  begin
    if (x <> LastPressX) or (y <> LastPressY) then
    begin
      SendButton(ButtonPress, Button1, x, y, CLICK_GAP_MS, 0);
      SendButton(ButtonRelease, Button1, x, y, 1, Button1Mask);
    end;
    SendButton(ButtonPress, Button1, x, y, DOUBLE_GAP_MS, 0);
  end
  else
    SendButton(ButtonPress, Button1, x, y, CLICK_GAP_MS, 0);
  LastPressX := x;
  LastPressY := y;
  ButtonState := Button1Mask;
end;

procedure EditorMove(x, y: Integer);
var
  ev: TXEvent;
begin
  FillChar(ev{%H-}, SizeOf(ev), 0);
  Inc(EventTime);
  ev.xmotion._type := MotionNotify;
  ev.xmotion.root := XDefaultRootWindow(Dpy);
  ev.xmotion.time := EventTime;
  ev.xmotion.x := x;
  ev.xmotion.y := y;
  ev.xmotion.state := ButtonState;
  ev.xmotion.same_screen := 1;
  Deliver(ev, PointerMotionMask);
end;

procedure EditorRelease(x, y: Integer);
begin
  SendButton(ButtonRelease, Button1, x, y, 1, 0);
  ButtonState := 0;
end;

{ one press and release of button 4 (up) or 5 (down) per notch }
procedure EditorWheel(x, y, notches: Integer; vzoom: Boolean);
var
  i: Integer;
  button: LongInt;
  state: LongWord;
begin
  button := Button4;
  if notches < 0 then button := Button5;
  state := 0;
  if vzoom then state := ControlMask;
  { one turn of the wheel: it all arrives together }
  Batching := True;
  for i := 1 to Abs(notches) do
  begin
    SendButton(ButtonPress, button, x, y, 1, state);
    SendButton(ButtonRelease, button, x, y, 1, state);
  end;
  Batching := False;
  DeliverQueued;
end;
