unit scope_gui_types;

{ State shared by the GUI units }

{$mode objfpc}{$H+}

interface

uses
  scope_state, scope_view;

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
  ST_SYNC  = 3;
  ST_SPLIT = 4;
  ST_COUNT = 5;

type
  TStatusRect = record
    x0, y0, x1, y1: Integer;   { client px }
  end;

  TTextTex = record
    tex: DWord;              { 0 = none }
    w, h, ascent: Integer;
  end;

  { all UI glyphs in one texture }
  TGlyphAtlas = record
    tex: DWord;              { 0 = no font }
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
    syncSeq: LongInt;
    zoomStart, zoomSpan: Double;
  end;

  PScopeGui = ^TScopeGui;
  TScopeGui = record
    inst: PScopeInstance;
    native: Pointer;         { the platform's view and GL context, see scope_gui_os }
    w, h: Integer;           { drawable px }
    sized: Boolean;          { the host has set a size }
    minW: Integer;           { px the status line needs, 0 = not measured }
    stop: LongBool;
    redraw: LongInt;         { atomic; redraw requested }
    thread: TThreadID;
    scale: Single;           { px per UI unit: 96-dpi pixel, or macOS point }
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
    statusAccum: Double;     { host units dragged towards the next sync length }
    zoomStart, zoomSpan: Double;   { part of a synced cycle on screen; span 0 = all }
    view: TViewState;        { render thread }
    viewInfo: TViewInfo;     { last frame, read by the input handlers }
    aboutOpen: Boolean;
    aboutT0: QWord;
    plasmaProg: DWord;       { 0 = no GLSL }
    plasmaLocT: LongInt;
    plasmaLocK: LongInt;
    plasmaLocRes: LongInt;
    plasmaLocScene: LongInt;
    sceneTex: DWord;
    sceneTexW, sceneTexH: Integer;
    aboutTex: array[0..ABOUT_LINES - 1] of TTextTex;
    aboutTexFontH: Integer;
    lastKey: TFrameKey;
    lastDrawTick: QWord;
    cols: TColumns;
    verts: array[0..MAX_COLS * 2 - 1] of TVertex;
  end;

{ host scale, else the display's; g may be nil }
function EffectiveScale(inst: PScopeInstance; g: PScopeGui): Single;
{ ST_NONE if none }
function StatusItemAt(g: PScopeGui; x, y: Integer): Integer;

implementation

uses
  scope_gui_os;

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

function EffectiveScale(inst: PScopeInstance; g: PScopeGui): Single;
begin
  if (inst <> nil) and (inst^.guiScale > 0.01) then
    Result := inst^.guiScale
  else
    Result := OsDisplayScale(g);
  if Result < 1.0 then Result := 1.0;
  if Result > 8.0 then Result := 8.0;
end;

end.
