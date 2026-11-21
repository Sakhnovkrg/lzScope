unit scope_gui_types;

{ State shared by the GUI units }

{$mode objfpc}{$H+}

interface

uses
  Windows, scope_state, scope_view;

const
  ATLAS_FIRST = 32;         { ASCII 32..127 }
  ATLAS_COUNT = 96;
  ATLAS_COLS  = 16;
  ABOUT_LINES = 12;

  { status line items }
  ST_NONE  = -1;
  ST_LEN   = 0;
  ST_RANGE = 1;
  ST_TRIG  = 2;
  ST_COUNT = 3;

type
  TStatusRect = record
    x0, y0, x1, y1: Integer;   { client px }
  end;

  TTextTex = record
    tex: DWORD;              { 0 = none }
    w, h, ascent: Integer;
  end;

  { all UI glyphs in one texture }
  TGlyphAtlas = record
    tex: DWORD;              { 0 = no font }
    cellW, cellH, ascent: Integer;
    texW, texH: Integer;
    adv: array[0..ATLAS_COUNT - 1] of Integer;
  end;

  TVertex = record
    x, y: Single;
    r, g, b, a: Single;
  end;

  { everything a frame depends on }
  TFrameKey = record
    written, validFrom: Int64;
    params: array[0..PARAM_COUNT - 1] of Int64;
    holdOffs: Double;
    w, h, fontH: Integer;
    cursorX, cursorY: Integer;   { -1 = outside }
    about: LongInt;
    statusDrag: LongInt;
  end;

  PScopeGui = ^TScopeGui;
  TScopeGui = record
    inst: PScopeInstance;
    wnd: HWND;
    dc: HDC;
    glrc: HGLRC;
    w, h: Integer;
    stop: LongBool;
    redraw: LongInt;         { atomic; redraw requested }
    thread: TThreadID;
    scale: Single;           { 1.0 = 96 dpi }
    msaa: Boolean;
    fontH: Integer;          { px }
    atlas: TGlyphAtlas;
    holdOffs: Double;        { hold scroll, samples back }
    lastAnchorOffs: Double;  { anchor of the last frame }
    pressed: Boolean;
    moved: Boolean;          { drag, not a click }
    pressX, pressY: Integer;
    dragLastX: Integer;
    statusRects: array[0..ST_COUNT - 1] of TStatusRect;
    statusDrag: LongInt;     { pressed item or ST_NONE }
    statusLastY: Integer;
    aboutOpen: Boolean;
    aboutT0: QWord;
    plasmaProg: DWORD;       { 0 = no GLSL }
    plasmaLocT: LongInt;
    plasmaLocK: LongInt;
    plasmaLocRes: LongInt;
    plasmaLocScene: LongInt;
    sceneTex: DWORD;
    sceneTexW, sceneTexH: Integer;
    aboutTex: array[0..ABOUT_LINES - 1] of TTextTex;
    aboutTexFontH: Integer;
    lastKey: TFrameKey;
    lastDrawTick: QWord;
    cols: TColumns;
    verts: array[0..MAX_COLS * 2 - 1] of TVertex;
  end;

{ host scale, else OS DPI }
function EffectiveScale(inst: PScopeInstance; wnd: HWND): Single;
{ ST_NONE if none }
function StatusItemAt(g: PScopeGui; x, y: Integer): Integer;

implementation

function StatusItemAt(g: PScopeGui; x, y: Integer): Integer;
var
  i: Integer;
begin
  Result := ST_NONE;
  if g^.aboutOpen then Exit;
  for i := 0 to ST_COUNT - 1 do
    if (x >= g^.statusRects[i].x0) and (x < g^.statusRects[i].x1) and
       (y >= g^.statusRects[i].y0) and (y < g^.statusRects[i].y1) then
      Exit(i);
end;

type
  TGetDpiForWindow = function(wnd: HWND): UINT; stdcall;

function QueryDpiScale(wnd: HWND): Single;
var
  getDpi: TGetDpiForWindow;
  dc: HDC;
  dpi: Integer;
begin
  getDpi := TGetDpiForWindow(
    GetProcAddress(GetModuleHandleW('user32.dll'), 'GetDpiForWindow'));
  dpi := 0;
  if (wnd <> 0) and (getDpi <> nil) then
    dpi := Integer(getDpi(wnd));
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

function EffectiveScale(inst: PScopeInstance; wnd: HWND): Single;
begin
  if (inst <> nil) and (inst^.guiScale > 0.01) then
    Result := inst^.guiScale
  else
    Result := QueryDpiScale(wnd);
  if Result < 1.0 then Result := 1.0;
  if Result > 8.0 then Result := 8.0;
end;

end.
