{ Win32 test host window. Part of testhost_window. }

uses
  Windows;

const
  HOST_CLASS: PWideChar = 'lzScopeTestHostWnd';

var
  HostWnd: HWND = 0;
  EditorWnd: HWND = 0;
  Running: Boolean = False;

function HostWndProc(hw: HWND; msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT; stdcall;
var
  cw, ch: Integer;
begin
  case msg of
    WM_SIZE:
      if OnHostResize <> nil then
      begin
        cw := Integer(lp and $FFFF);
        ch := Integer((lp shr 16) and $FFFF);
        if (cw > 0) and (ch > 0) then
          OnHostResize(cw, ch);
        Exit(0);
      end;
    WM_CLOSE:
      begin
        { the editor goes before its parent }
        if OnHostClose <> nil then
          OnHostClose;
        DestroyWindow(hw);
        Exit(0);
      end;
    WM_DESTROY:
      begin
        Running := False;
        HostWnd := 0;
        PostQuitMessage(0);
        Exit(0);
      end;
  end;
  Result := DefWindowProcW(hw, msg, wp, lp);
end;

function HostWindowOpen(w, h: Integer; const title: AnsiString): Boolean;
var
  wc: WNDCLASSW;
  rc: TRect;
  wtitle: UnicodeString;
begin
  FillChar(wc, SizeOf(wc), 0);
  wc.lpfnWndProc := @HostWndProc;
  wc.hInstance := HInstance;
  wc.hCursor := LoadCursor(0, IDC_ARROW);
  wc.lpszClassName := HOST_CLASS;
  Result := RegisterClassW(wc) <> 0;
  if not Result then Exit;

  rc.Left := 0; rc.Top := 0;
  rc.Right := w; rc.Bottom := h;
  AdjustWindowRect(@rc, WS_OVERLAPPEDWINDOW, False);
  wtitle := UnicodeString(title);
  HostWnd := CreateWindowExW(0, HOST_CLASS, PWideChar(wtitle),
    WS_OVERLAPPEDWINDOW or WS_VISIBLE, 100, 100,
    rc.Right - rc.Left, rc.Bottom - rc.Top, 0, 0, HInstance, nil);
  Result := HostWnd <> 0;
  Running := Result;
end;

procedure HostWindowFree;
begin
  if HostWnd <> 0 then
    DestroyWindow(HostWnd);
  HostWnd := 0;
end;

function HostWindowHandle: Pointer;
begin
  Result := {%H-}Pointer(HostWnd);
end;

procedure HostWindowClientSize(out w, h: Integer);
var
  rc: TRect;
begin
  GetClientRect(HostWnd, @rc);
  w := rc.Right;
  h := rc.Bottom;
end;

procedure HostWindowFocus;
begin
  ShowWindow(GetConsoleWindow, SW_MINIMIZE);
  SetForegroundWindow(HostWnd);
end;

function HostPump: Boolean;
var
  mm: MSG;
begin
  while PeekMessageW(@mm, 0, 0, 0, PM_REMOVE) do
  begin
    if mm.message = WM_QUIT then Running := False;
    TranslateMessage(@mm);
    DispatchMessageW(@mm);
  end;
  Result := Running;
end;

function EditorFind: Boolean;
begin
  EditorWnd := GetWindow(HostWnd, GW_CHILD);
  Result := EditorWnd <> 0;
end;

function MouseLP(x, y: Integer): LPARAM;
begin
  Result := LPARAM(((y and $FFFF) shl 16) or (x and $FFFF));
end;

procedure EditorPress(x, y: Integer; dbl: Boolean);
begin
  if dbl then
    SendMessageW(EditorWnd, WM_LBUTTONDBLCLK, MK_LBUTTON, MouseLP(x, y))
  else
    SendMessageW(EditorWnd, WM_LBUTTONDOWN, MK_LBUTTON, MouseLP(x, y));
end;

procedure EditorMove(x, y: Integer);
begin
  SendMessageW(EditorWnd, WM_MOUSEMOVE, MK_LBUTTON, MouseLP(x, y));
end;

procedure EditorRelease(x, y: Integer);
begin
  SendMessageW(EditorWnd, WM_LBUTTONUP, 0, MouseLP(x, y));
end;

procedure EditorWheel(x, y, notches: Integer; vzoom: Boolean);
var
  pt: TPoint;
  keys: WPARAM;
begin
  { the wheel reports screen coordinates }
  pt.x := x;
  pt.y := y;
  ClientToScreen(EditorWnd, pt);
  keys := 0;
  if vzoom then keys := MK_CONTROL;
  SendMessageW(EditorWnd, WM_MOUSEWHEEL,
    WPARAM(((notches * WHEEL_DELTA) and $FFFF) shl 16) or keys,
    MouseLP(pt.x, pt.y));
end;
