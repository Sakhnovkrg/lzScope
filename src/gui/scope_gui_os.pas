unit scope_gui_os;

{ The platform under the editor: a native view with a GL context, frame
  pacing and a text rasterizer. Everything above it is portable; each
  platform implements this interface in one include file under os/. }

{$mode objfpc}{$H+}
{$pointermath on}
{$IFDEF DARWIN}
  {$modeswitch objectivec1}
{$ENDIF}

interface

uses
  clap_api, scope_gui_types;

const
{$IF DEFINED(WINDOWS)}
  OS_WINDOW_API = CLAP_WINDOW_API_WIN32;
  { CLAP sizes are physical pixels and the host may set the UI scale }
  OS_HOST_SCALE = True;
  OS_VZOOM_KEY  = 'ctrl';
{$ELSEIF DEFINED(DARWIN)}
  OS_WINDOW_API = CLAP_WINDOW_API_COCOA;
  { CLAP sizes are points; the scale is the screen's backing scale }
  OS_HOST_SCALE = False;
  OS_VZOOM_KEY  = 'cmd';
{$ENDIF}

{ view, main thread }

{ hidden and parentless, with a GL context; fills g^.native }
function OsViewCreate(g: PScopeGui): Boolean;
procedure OsViewDestroy(g: PScopeGui);
{ parent: the window handle from clap_window }
function OsViewAttach(g: PScopeGui; parent: Pointer): Boolean;
{ to g^.w x g^.h px }
procedure OsViewResize(g: PScopeGui);
procedure OsViewSetVisible(g: PScopeGui; visible: Boolean);
{ waits for the render thread without blocking what it may wait on }
procedure OsJoinRenderThread(g: PScopeGui);
procedure OsGlobalCleanup;

{ any thread; g may be nil }

{ px per UI unit, the editor's scale when the host sets none }
function OsDisplayScale(g: PScopeGui): Single;
{ px per unit of the sizes and mouse moves the host deals in }
function OsPixelsPerUnit(g: PScopeGui): Single;

{ render thread }

{ makes the context current on the calling thread; False = no context }
function OsRenderBegin(g: PScopeGui): Boolean;
procedure OsRenderEnd(g: PScopeGui);
{ on screen: not hidden, minimized or covered }
function OsViewShowing(g: PScopeGui): Boolean;
{ mouse in px from the top-left; False when outside }
function OsCursorPos(g: PScopeGui; out x, y: Integer): Boolean;
{ brackets a frame's GL calls; OsFrameEnd presents and paces to the display }
function OsFrameBegin(g: PScopeGui): Boolean;
procedure OsFrameEnd(g: PScopeGui);

{ text rasterizer, render thread: white antialiased text, coverage only }

type
  TOsText = Pointer;

{ nil = no font }
function OsTextOpen(heightPx: Integer; bold: Boolean): TOsText;
procedure OsTextClose(var t: TOsText);
procedure OsTextMetrics(t: TOsText; out ascent, height: Integer);
function OsTextWidth(t: TOsText; const s: AnsiString): Integer;
{ a blank w x h canvas to draw on }
function OsTextCanvas(t: TOsText; w, h: Integer): Boolean;
{ (x, y) = top-left of the line }
procedure OsTextDraw(t: TOsText; x, y: Integer; const s: AnsiString);
{ the canvas: 1 byte of coverage per px, rows top-down; nil without one }
function OsTextCoverage(t: TOsText): PByte;

implementation

{$IF DEFINED(WINDOWS)}
  {$I os/scope_os_win32.inc}
{$ELSEIF DEFINED(DARWIN)}
  {$I os/scope_os_cocoa.inc}
{$ELSE}
  {$FATAL no editor for this platform}
{$ENDIF}

end.
