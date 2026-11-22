unit testhost_window;

{ The test host's window, and mouse input delivered straight to the editor
  inside it, the way the OS would. Coordinates are host units from the
  editor's top-left: px on Windows, points on macOS. }

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
  {$modeswitch objectivec1}
{$ENDIF}

interface

uses
  clap_api;

const
{$IF DEFINED(WINDOWS)}
  PLUGIN_LIB = 'lzscope.dll';
  HOST_WINDOW_API = CLAP_WINDOW_API_WIN32;
{$ELSEIF DEFINED(DARWIN)}
  PLUGIN_LIB = 'liblzscope.dylib';
  HOST_WINDOW_API = CLAP_WINDOW_API_COCOA;
{$ENDIF}

type
  THostResize = procedure(w, h: Integer);
  THostClose = procedure;

var
  { the client area changed size }
  OnHostResize: THostResize = nil;
  { the user closed the window; it is gone after this returns }
  OnHostClose: THostClose = nil;

{ for libraries loaded after this }
procedure HostSetEnv(const name, value: AnsiString);
function HostWindowOpen(w, h: Integer; const title: AnsiString): Boolean;
procedure HostWindowFree;
{ for clap_window.handle }
function HostWindowHandle: Pointer;
procedure HostWindowClientSize(out w, h: Integer);
{ interactive: bring the window to the front }
procedure HostWindowFocus;
{ handles pending events; False once the window is closed }
function HostPump: Boolean;

{ the editor: the window's only child; False if there is none }
function EditorFind: Boolean;
{ dbl: the second press of a double click }
procedure EditorPress(x, y: Integer; dbl: Boolean = False);
{ with the button down }
procedure EditorMove(x, y: Integer);
procedure EditorRelease(x, y: Integer);
{ notches: +1 = one step away from the user }
procedure EditorWheel(x, y, notches: Integer; vzoom: Boolean = False);

implementation

{$IF DEFINED(WINDOWS)}
  {$I os/testhost_win32.inc}
{$ELSEIF DEFINED(DARWIN)}
  {$I os/testhost_cocoa.inc}
{$ENDIF}

end.
