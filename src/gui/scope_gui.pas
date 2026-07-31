unit scope_gui;

{ Win32 child window + OpenGL renderer.

  Rendering runs on its own thread, paced by vsync. The Gui* entry
  points are called on the host's main thread (CLAP contract); the GL
  context is only ever current on the render thread. w/h races between
  wndproc and renderer are benign, the viewport fixes itself next frame. }

{$mode objfpc}{$H+}
{$pointermath on}

interface

uses
  Windows, scope_state, scope_view;

function GuiCreate(inst: PScopeInstance): Boolean;
procedure GuiDestroy(inst: PScopeInstance);
function GuiSetParent(inst: PScopeInstance; parentHandle: Pointer): Boolean;
function GuiGetSize(inst: PScopeInstance; outW, outH: PUInt32): Boolean;
function GuiSetSize(inst: PScopeInstance; w, h: UInt32): Boolean;
function GuiShow(inst: PScopeInstance): Boolean;
function GuiHide(inst: PScopeInstance): Boolean;
procedure GuiGlobalCleanup;

implementation

uses
  Math, clap_api, gl_min, scope_shader;

const
  WND_CLASS_NAME: PWideChar = 'lzScopeCLAPWnd';
  GUI_PROP: PWideChar = 'lzScopeGuiPtr';
  LN10_OVER_20 = 0.11512925464970229;
  FALLBACK_FRAME_MS = 12;  { pacing when the driver has no vsync ext }

type
  TTextTex = record
    tex: DWORD;              { 0 = build failed, fall back to bitmap text }
    w, h, ascent: Integer;
  end;

  PScopeGui = ^TScopeGui;
  TScopeGui = record
    inst: PScopeInstance;
    wnd: HWND;
    dc: HDC;
    glrc: HGLRC;
    w, h: Integer;
    stop: LongBool;
    thread: TThreadID;       { thread handle on Windows }
    scale: Single;           { UI scale, 1.0 = 96 dpi }
    msaa: Boolean;
    fontBase: DWORD;         { glyph display lists, 0 = no font }
    fontHandle: HFONT;
    fontH: Integer;
    holdOffs: Double;        { hold scroll, samples back from newest }
    lastAnchorOffs: Double;  { where the last frame was anchored; engaging
                               hold picks this up to freeze the exact view }
    pressed: Boolean;
    moved: Boolean;          { drag passed the click threshold }
    pressX, pressY: Integer;
    dragLastX: Integer;
    aboutOpen: Boolean;
    aboutT0: QWord;
    plasmaProg: DWORD;       { about shader, 0 = no GLSL on this driver }
    plasmaLocT: LongInt;
    plasmaLocK: LongInt;
    plasmaLocRes: LongInt;
    plasmaLocScene: LongInt;
    sceneTex: DWORD;
    sceneTexW, sceneTexH: Integer;
    aboutTex: array[0..9] of TTextTex;  { about text as textures; quads
                               move subpixel, bitmap text snaps to px }
    aboutTexFontH: Integer;  { fontH the textures were built for }
    cols: TColumns;
  end;

var
  ClassRegistered: Boolean = False;

{ UI scale: whatever the host told us via set_scale, else OS DPI }

type
  TGetDpiForWindow = function(wnd: HWND): UINT; stdcall;

var
  GetDpiForWindowProc: TGetDpiForWindow = nil;
  DpiProcLoaded: Boolean = False;

function QueryDpiScale(wnd: HWND): Single;
var
  dc: HDC;
  dpi: Integer;
begin
  if not DpiProcLoaded then
  begin
    GetDpiForWindowProc := TGetDpiForWindow(
      GetProcAddress(GetModuleHandleW('user32.dll'), 'GetDpiForWindow'));
    DpiProcLoaded := True;
  end;
  dpi := 0;
  if (wnd <> 0) and (GetDpiForWindowProc <> nil) then
    dpi := Integer(GetDpiForWindowProc(wnd));
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

procedure SetupPlasma(g: PScopeGui);
begin
  g^.plasmaProg := CompileFragmentProgram(PLASMA_FS);
  if g^.plasmaProg = 0 then Exit;
  g^.plasmaLocT := GetShaderUniform(g^.plasmaProg, 't');
  g^.plasmaLocK := GetShaderUniform(g^.plasmaProg, 'k');
  g^.plasmaLocRes := GetShaderUniform(g^.plasmaProg, 'res');
  g^.plasmaLocScene := GetShaderUniform(g^.plasmaProg, 'scene');
end;

procedure CleanupPlasma(g: PScopeGui);
begin
  DeleteShaderProgram(g^.plasmaProg);
  g^.plasmaProg := 0;
  if g^.sceneTex <> 0 then
    glDeleteTextures(1, @g^.sceneTex);
  g^.sceneTex := 0;
end;

const
  TrigNamesS: array[0..3] of string[10] =
    ('instant', 'any', 'ascending', 'descending');

{ text via wglUseFontBitmaps: system font rasterized into GL lists }

procedure SetupFont(g: PScopeGui; heightPx: Integer);
begin
  g^.fontH := heightPx;
  g^.fontHandle := CreateFontW(-heightPx, 0, 0, 0, FW_NORMAL, 0, 0, 0,
    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
    NONANTIALIASED_QUALITY, FIXED_PITCH or FF_DONTCARE, 'Consolas');
  if g^.fontHandle = 0 then Exit;
  SelectObject(g^.dc, g^.fontHandle);
  { 128 lists so list id = fontBase + ASCII; fontBase-32 could underflow }
  g^.fontBase := glGenLists(128);
  if g^.fontBase = 0 then Exit;
  if not wglUseFontBitmapsW(g^.dc, 32, 96, g^.fontBase + 32) then
  begin
    glDeleteLists(g^.fontBase, 128);
    g^.fontBase := 0;
  end;
end;

procedure CleanupFont(g: PScopeGui);
begin
  if g^.fontBase <> 0 then glDeleteLists(g^.fontBase, 128);
  g^.fontBase := 0;
  if g^.fontHandle <> 0 then DeleteObject(g^.fontHandle);
  g^.fontHandle := 0;
end;

{ (x, y) = baseline; set the color before calling, glRasterPos latches it }
procedure DrawTextGL(g: PScopeGui; x, y: Single; const s: ShortString);
begin
  if (g^.fontBase = 0) or (Length(s) = 0) then Exit;
  glRasterPos2f(x, y);
  glListBase(g^.fontBase);
  glCallLists(Length(s), GL_UNSIGNED_BYTE, @s[1]);
end;

{ GDI-render one line of text into a white alpha texture }
procedure BuildTextTexture(g: PScopeGui; const s: AnsiString; bold: Boolean;
  var t: TTextTex);
var
  memDC: HDC;
  font: HFONT;
  oldFont, oldBmp: HGDIOBJ;
  dib: HBITMAP;
  bi: BITMAPINFO;
  bits: Pointer;
  sz: Windows.TSize;
  tm: TEXTMETRICA;
  tw, th, i, weight: Integer;
  buf: PByte;
begin
  t.tex := 0;
  memDC := CreateCompatibleDC(0);
  if memDC = 0 then Exit;
  weight := FW_NORMAL;
  if bold then weight := FW_BOLD;
  font := CreateFontW(-g^.fontH, 0, 0, 0, weight, 0, 0, 0,
    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
    ANTIALIASED_QUALITY, FIXED_PITCH or FF_DONTCARE, 'Consolas');
  if font = 0 then
  begin
    DeleteDC(memDC);
    Exit;
  end;
  oldFont := SelectObject(memDC, font);
  GetTextExtentPoint32A(memDC, PAnsiChar(s), Length(s), @sz);
  GetTextMetricsA(memDC, @tm);
  tw := sz.cx + 2;
  th := sz.cy + 2;

  FillChar(bi{%H-}, SizeOf(bi), 0);
  bi.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth := tw;
  bi.bmiHeader.biHeight := -th;   { top-down }
  bi.bmiHeader.biPlanes := 1;
  bi.bmiHeader.biBitCount := 32;
  bi.bmiHeader.biCompression := BI_RGB;
  bits := nil;
  dib := CreateDIBSection(memDC, bi, DIB_RGB_COLORS, bits, 0, 0);
  if (dib = 0) or (bits = nil) then
  begin
    SelectObject(memDC, oldFont);
    DeleteObject(font);
    DeleteDC(memDC);
    Exit;
  end;
  oldBmp := SelectObject(memDC, dib);
  SetBkMode(memDC, TRANSPARENT);
  SetTextColor(memDC, $FFFFFF);
  TextOutA(memDC, 1, 1, PAnsiChar(s), Length(s));
  GdiFlush;

  { white texture, GDI grayscale coverage as alpha }
  GetMem(buf, tw * th * 4);
  for i := 0 to tw * th - 1 do
  begin
    buf[i * 4 + 0] := 255;
    buf[i * 4 + 1] := 255;
    buf[i * 4 + 2] := 255;
    buf[i * 4 + 3] := PByte(bits)[i * 4 + 1];
  end;
  glGenTextures(1, @t.tex);
  glBindTexture(GL_TEXTURE_2D, t.tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, tw, th, 0, GL_RGBA,
    GL_UNSIGNED_BYTE, buf);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  FreeMem(buf);

  t.w := tw;
  t.h := th;
  t.ascent := tm.tmAscent + 1;   { +1 = padding row in the bitmap }

  SelectObject(memDC, oldBmp);
  SelectObject(memDC, oldFont);
  DeleteObject(dib);
  DeleteObject(font);
  DeleteDC(memDC);
end;

procedure CleanupAboutTextures(g: PScopeGui);
var
  i: Integer;
begin
  for i := 0 to High(g^.aboutTex) do
  begin
    if g^.aboutTex[i].tex <> 0 then
      glDeleteTextures(1, @g^.aboutTex[i].tex);
    g^.aboutTex[i].tex := 0;
  end;
  g^.aboutTexFontH := 0;
end;

procedure BuildAboutTextures(g: PScopeGui);
begin
  if g^.aboutTexFontH = g^.fontH then Exit;
  CleanupAboutTextures(g);
  BuildTextTexture(g, 'lzScope v' + PLUGIN_VERSION, True, g^.aboutTex[0]);
  BuildTextTexture(g, 'created by ' + PLUGIN_AUTHOR, False, g^.aboutTex[1]);
  BuildTextTexture(g, PLUGIN_URL, False, g^.aboutTex[2]);
  BuildTextTexture(g, 'built with Free Pascal & Lazarus', False, g^.aboutTex[3]);
  BuildTextTexture(g, 'inspired by the Cockos JSFX Oscilloscope Meter',
    False, g^.aboutTex[4]);
  BuildTextTexture(g, 'wheel ............. time zoom', False, g^.aboutTex[5]);
  BuildTextTexture(g, 'ctrl+wheel ........... v-zoom', False, g^.aboutTex[6]);
  BuildTextTexture(g, 'click .................. hold', False, g^.aboutTex[7]);
  BuildTextTexture(g, 'drag while hold ....... scrub', False, g^.aboutTex[8]);
  BuildTextTexture(g, 'right-click .... trigger mode', False, g^.aboutTex[9]);
  g^.aboutTexFontH := g^.fontH;
end;

{ width of an about line in px; fallback estimate when the texture failed }
function AboutLineW(g: PScopeGui; idx: Integer; const s: ShortString): Single;
begin
  if g^.aboutTex[idx].tex <> 0 then
    Result := g^.aboutTex[idx].w
  else
    Result := Length(s) * (g^.fontH * 7.0 / 12.0);
end;

{ (x, y) = baseline, like DrawTextGL; color/alpha modulate the texture }
procedure DrawAboutLine(g: PScopeGui; idx: Integer; const s: ShortString;
  x, y: Single);
var
  t: ^TTextTex;
begin
  t := @g^.aboutTex[idx];
  if t^.tex = 0 then
  begin
    DrawTextGL(g, x, y, s);
    Exit;
  end;
  y := y - t^.ascent;
  glEnable(GL_TEXTURE_2D);
  glBindTexture(GL_TEXTURE_2D, t^.tex);
  glBegin(GL_QUADS);
  glTexCoord2f(0, 0); glVertex2f(x, y);
  glTexCoord2f(1, 0); glVertex2f(x + t^.w, y);
  glTexCoord2f(1, 1); glVertex2f(x + t^.w, y + t^.h);
  glTexCoord2f(0, 1); glVertex2f(x, y + t^.h);
  glEnd;
  glDisable(GL_TEXTURE_2D);
end;

{ rebuild the font if the DPI changed (window moved to another monitor) }
procedure UpdateScaleAndFont(g: PScopeGui);
var
  s: Single;
  fh: Integer;
begin
  s := EffectiveScale(g^.inst, g^.wnd);
  g^.scale := s;
  fh := Round(12 * s);
  if fh < 9 then fh := 9;
  if fh <> g^.fontH then
  begin
    CleanupFont(g);
    SetupFont(g, fh);
  end;
end;

procedure FormatDb(v: Double; out s: ShortString);
begin
  Str(v: 0: 1, s);
  if v >= 0 then s := '+' + s;
  s := s + 'dB';
end;

procedure FormatTime(ms: Double; out s: ShortString);
begin
  if ms >= 1000 then
  begin
    Str((ms / 1000): 0: 2, s);
    s := s + 's';
  end
  else
  begin
    Str(ms: 0: 1, s);
    s := s + 'ms';
  end;
end;

procedure FormatPeakDb(v: Single; out s: ShortString);
var
  db: Double;
begin
  if v <= 1e-6 then
  begin
    s := '-inf';
    Exit;
  end;
  db := 20.0 * Log10(v);
  Str(db: 0: 1, s);
  if db >= 0 then s := '+' + s;
  s := s + 'dB';
end;

procedure FormatHz(ms: Double; out s: ShortString);
var
  f: Double;
begin
  s := '';
  if ms <= 0 then Exit;
  f := 1000.0 / ms;
  if f >= 1000 then
  begin
    Str((f / 1000): 0: 1, s);
    s := s + 'kHz';
  end
  else
  begin
    Str(f: 0: 0, s);
    s := s + 'Hz';
  end;
end;

{ ------------------------------------------------------------------ }
{ rendering                                                           }
{ ------------------------------------------------------------------ }

procedure DrawChannel(constref mins, maxs: array of Single;
  cols: Integer; yCent, sc, maxY, px: Single; r, gr, b: Single);
var
  x: Integer;
  yLo, yHi: Single;

  function ToY(v: Single): Single; inline;
  begin
    Result := yCent - v * sc;
    if Result < -2 then Result := -2;
    if Result > maxY then Result := maxY;
  end;

begin
  { soft gradient glow from the center line out to each envelope }
  glBegin(GL_TRIANGLE_STRIP);
  for x := 0 to cols - 1 do
  begin
    glColor4f(r, gr, b, 0.04); glVertex2f(x + 0.5, yCent);
    glColor4f(r, gr, b, 0.26); glVertex2f(x + 0.5, ToY(maxs[x]));
  end;
  glEnd;
  glBegin(GL_TRIANGLE_STRIP);
  for x := 0 to cols - 1 do
  begin
    glColor4f(r, gr, b, 0.04); glVertex2f(x + 0.5, yCent);
    glColor4f(r, gr, b, 0.26); glVertex2f(x + 0.5, ToY(mins[x]));
  end;
  glEnd;

  { body: band between the min and max envelopes }
  glColor4f(r, gr, b, 0.42);
  glBegin(GL_TRIANGLE_STRIP);
  for x := 0 to cols - 1 do
  begin
    yHi := ToY(maxs[x]);
    yLo := ToY(mins[x]);
    if yLo - yHi < px then
    begin
      yHi := (yHi + yLo - px) * 0.5;
      yLo := yHi + px;
    end;
    glVertex2f(x + 0.5, yHi);
    glVertex2f(x + 0.5, yLo);
  end;
  glEnd;

  { envelope outlines }
  glColor4f(r, gr, b, 0.9);
  glBegin(GL_LINE_STRIP);
  for x := 0 to cols - 1 do
    glVertex2f(x + 0.5, ToY(maxs[x]));
  glEnd;
  glBegin(GL_LINE_STRIP);
  for x := 0 to cols - 1 do
    glVertex2f(x + 0.5, ToY(mins[x]));
  glEnd;
end;

{ one frame; GL context must be current }
procedure RenderFrame(g: PScopeGui);
var
  inst: PScopeInstance;
  w, h, iter, trig, gridStep, col, rowLen: Integer;
  yCent, scopeH, sc, a, ly, px: Single;
  vzoom, v, viewMs, t, anchor: Double;
  x: Integer;
  s, s2, s3: ShortString;
  cp: TPoint;
  peakL, peakR: Single;
  havePeaks: Boolean;
  bx, by, bw, bh, cw: Single;
  aboutT: Double;
  ty, easeK: Single;
begin
  inst := g^.inst;
  w := g^.w; h := g^.h;
  if (w < 8) or (h < 8) then Exit;
  px := g^.scale;
  if px < 1.0 then px := 1.0;

  BuildColumns(inst, g^.holdOffs, w, g^.cols, anchor);
  g^.lastAnchorOffs := anchor;

  aboutT := 0;
  if g^.aboutOpen then
    aboutT := (GetTickCount64 - g^.aboutT0) * 0.001;

  glViewport(0, 0, w, h);
  glClearColor(0.02, 0.02, 0.045, 1.0);
  glClear(GL_COLOR_BUFFER_BIT);

  glMatrixMode(GL_PROJECTION);
  glLoadIdentity;
  glOrtho(0, w, h, 0, -1, 1);   { pixel coords, y down }
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity;

  glEnable(GL_BLEND);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  glLineWidth(px);

  yCent := h * 0.5;
  scopeH := h * 0.5 - 4 * px;
  if scopeH < 10 then scopeH := 10;
  vzoom := ClampParam(PARAM_VZOOM_DB, inst^.params[PARAM_VZOOM_DB]);
  viewMs := ClampParam(PARAM_VIEW_MS, inst^.params[PARAM_VIEW_MS]);
  sc := Exp(-vzoom * LN10_OVER_20) * scopeH;

  { center line }
  glColor4f(0.6, 0.6, 0.6, 1.0);
  glBegin(GL_LINES);
  glVertex2f(0, yCent); glVertex2f(w, yCent);
  glEnd;

  { dB grid: exponential spacing, denser lines skipped }
  v := vzoom;
  ly := scopeH + 20 * px;
  for iter := 1 to 64 do
  begin
    a := Exp(v * LN10_OVER_20) * sc;
    if a <= 24 * px then Break;
    if a < ly then
    begin
      glColor4f(0.6, 0.6, 0.6, 0.25);
      glBegin(GL_LINES);
      glVertex2f(0, yCent - a); glVertex2f(w, yCent - a);
      glVertex2f(0, yCent + a); glVertex2f(w, yCent + a);
      glEnd;
      if iter > 1 then   { outermost line stays unlabeled }
      begin
        FormatDb(v, s);
        glColor4f(0.75, 0.75, 0.75, 0.55);
        DrawTextGL(g, 8 * px, yCent - a - 5 * px, s);
        DrawTextGL(g, 8 * px, yCent + a + g^.fontH + 4, s);
      end;
      ly := a - 20 * px;
    end;
    v := Floor(v / 3 - 1) * 3;
  end;

  { time grid, laid out from the right edge }
  gridStep := Round(72 * px);
  x := w - gridStep;
  while x > 24 * px do
  begin
    glColor4f(0.6, 0.6, 0.6, 0.18);
    glBegin(GL_LINES);
    glVertex2f(x, 0); glVertex2f(x, h);
    glEnd;
    t := viewMs * (w - x) / w;
    glColor4f(0.75, 0.75, 0.75, 0.55);
    FormatTime(t, s);
    DrawTextGL(g, x + 5 * px, h - 9 * px, s);
    if t <= 250 then
    begin
      FormatHz(t, s2);
      DrawTextGL(g, x + 5 * px, h - 9 * px - (g^.fontH + 3), s2);
    end;
    Dec(x, gridStep);
  end;

  if g^.cols.count > 0 then
  begin
    DrawChannel(g^.cols.minL, g^.cols.maxL, g^.cols.count,
      yCent, sc, h + 2, px, 0.5, 1.0, 0.5);               { left:  green }
    DrawChannel(g^.cols.minR, g^.cols.maxR, g^.cols.count,
      yCent, sc, h + 2, px, 1.0, 0.5, 1.0);               { right: magenta }
  end;

  { status line }
  trig := Round(ClampParam(PARAM_RETRIG, inst^.params[PARAM_RETRIG]));
  FormatTime(viewMs, s);
  s := 'len ' + s + '  range ';
  FormatDb(vzoom, s2);
  s := s + s2 + '  trig ' + TrigNamesS[trig];
  glColor4f(0.85, 0.85, 0.85, 0.8);
  DrawTextGL(g, 8 * px, 6 * px + g^.fontH, s);

  { hold indicator }
  if inst^.params[PARAM_HOLD] >= 0.5 then
  begin
    glColor4f(1.0, 0.3, 0.3, 0.9);
    { same baseline as the "?" glyph so the corner pair lines up }
    DrawTextGL(g, w - 68 * px, 4 * px + (22 * px + g^.fontH) * 0.5, 'HOLD');
  end;

  { crosshair }
  if not g^.aboutOpen then
  begin
    if GetCursorPos(cp{%H-}) then
    begin
      ScreenToClient(g^.wnd, cp);
      if (cp.x >= 0) and (cp.x < w) and (cp.y >= 0) and (cp.y < h) then
      begin
        glColor4f(1.0, 1.0, 1.0, 0.30);
        glBegin(GL_LINES);
        glVertex2f(cp.x + 0.5, 0); glVertex2f(cp.x + 0.5, h);
        glVertex2f(0, cp.y + 0.5); glVertex2f(w, cp.y + 0.5);
        glEnd;

        { row 1: level at the horizontal line, row 2: L/R peaks under it }
        FormatPeakDb(Abs(yCent - cp.y) / sc, s);
        havePeaks := g^.cols.count > 0;
        if havePeaks then
        begin
          col := (cp.x * g^.cols.count) div w;
          if col > g^.cols.count - 1 then col := g^.cols.count - 1;
          peakL := Abs(g^.cols.minL[col]);
          if Abs(g^.cols.maxL[col]) > peakL then peakL := Abs(g^.cols.maxL[col]);
          peakR := Abs(g^.cols.minR[col]);
          if Abs(g^.cols.maxR[col]) > peakR then peakR := Abs(g^.cols.maxR[col]);
          FormatPeakDb(peakL, s2);
          s2 := 'L ' + s2;
          FormatPeakDb(peakR, s3);
          s3 := 'R ' + s3;
        end;

        cw := g^.fontH * 7.0 / 12.0;   { approx Consolas advance }
        rowLen := Length(s);
        if havePeaks and (Length(s2) + 2 + Length(s3) > rowLen) then
          rowLen := Length(s2) + 2 + Length(s3);
        bw := rowLen * cw + 10 * px;
        bh := g^.fontH + 9 * px;
        if havePeaks then bh := bh + g^.fontH + 3 * px;
        bx := cp.x + 16 * px;
        if bx + bw > w - 2 then bx := cp.x - 16 * px - bw;
        if bx < 2 then bx := 2;
        by := cp.y - 12 * px - bh;
        if by < 2 then by := cp.y + 20 * px;

        glColor4f(0.05, 0.05, 0.09, 0.85);
        glBegin(GL_QUADS);
        glVertex2f(bx, by); glVertex2f(bx + bw, by);
        glVertex2f(bx + bw, by + bh); glVertex2f(bx, by + bh);
        glEnd;
        glColor4f(0.5, 0.5, 0.6, 0.5);
        glBegin(GL_LINE_STRIP);
        glVertex2f(bx, by); glVertex2f(bx + bw, by);
        glVertex2f(bx + bw, by + bh); glVertex2f(bx, by + bh);
        glVertex2f(bx, by);
        glEnd;

        glColor4f(0.95, 0.95, 0.95, 0.95);
        DrawTextGL(g, bx + 5 * px, by + 4 * px + g^.fontH, s);
        if havePeaks then
        begin
          glColor4f(0.5, 1.0, 0.5, 0.95);
          DrawTextGL(g, bx + 5 * px, by + bh - 5 * px, s2);
          glColor4f(1.0, 0.5, 1.0, 0.95);
          DrawTextGL(g, bx + 5 * px + (Length(s2) + 2) * cw,
            by + bh - 5 * px, s3);
        end;
      end;
    end;
  end;

  { "?" button, or the about overlay when it is open }
  if not g^.aboutOpen then
  begin
    glColor4f(0.6, 0.6, 0.7, 0.5);
    glBegin(GL_LINE_STRIP);
    glVertex2f(w - 26 * px, 4 * px); glVertex2f(w - 4 * px, 4 * px);
    glVertex2f(w - 4 * px, 26 * px); glVertex2f(w - 26 * px, 26 * px);
    glVertex2f(w - 26 * px, 4 * px);
    glEnd;
    glColor4f(0.8, 0.8, 0.9, 0.8);
    DrawTextGL(g, w - 18 * px, 4 * px + (22 * px + g^.fontH) * 0.5, '?');
  end
  else
  begin
    { grab the scene into a texture and redraw it through the warp
      shader; plain dim when there is no GLSL }
    if g^.plasmaProg <> 0 then
    begin
      easeK := aboutT / 0.35;
      if easeK > 1.0 then easeK := 1.0;

      if g^.sceneTex = 0 then
        glGenTextures(1, @g^.sceneTex);
      glBindTexture(GL_TEXTURE_2D, g^.sceneTex);
      if (g^.sceneTexW <> w) or (g^.sceneTexH <> h) then
      begin
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, w, h, 0, GL_RGB,
          GL_UNSIGNED_BYTE, nil);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        g^.sceneTexW := w;
        g^.sceneTexH := h;
      end;
      glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, w, h);

      glDisable(GL_BLEND);
      UseShaderProgram(g^.plasmaProg);
      SetUniform1f(g^.plasmaLocT, aboutT);
      SetUniform1f(g^.plasmaLocK, easeK);
      SetUniform2f(g^.plasmaLocRes, w, h);
      SetUniform1i(g^.plasmaLocScene, 0);
      glBegin(GL_QUADS);
      glVertex2f(0, 0); glVertex2f(w, 0);
      glVertex2f(w, h); glVertex2f(0, h);
      glEnd;
      UseShaderProgram(0);
      glEnable(GL_BLEND);
    end
    else
    begin
      glColor4f(0.0, 0.0, 0.02, 0.62);
      glBegin(GL_QUADS);
      glVertex2f(0, 0); glVertex2f(w, 0);
      glVertex2f(w, h); glVertex2f(0, h);
      glEnd;
    end;

    BuildAboutTextures(g);

    s := 'lzScope v' + PLUGIN_VERSION;
    ty := h * 0.5 - 3.0 * g^.fontH + Sin(aboutT * 2.0) * 3 * px;
    glColor4f(1.0, 1.0, 1.0, 0.95);
    DrawAboutLine(g, 0, s, (w - AboutLineW(g, 0, s)) * 0.5, ty);

    s := 'created by ' + PLUGIN_AUTHOR;
    ty := ty + 2.0 * g^.fontH;
    glColor4f(0.8, 0.8, 0.8, 0.9);
    DrawAboutLine(g, 1, s, (w - AboutLineW(g, 1, s)) * 0.5, ty);

    s := PLUGIN_URL;
    ty := ty + 2.0 * g^.fontH;
    glColor4f(0.5, 1.0, 0.5, 0.9);
    DrawAboutLine(g, 2, s, (w - AboutLineW(g, 2, s)) * 0.5, ty);

    s := 'built with Free Pascal & Lazarus';
    ty := ty + 2.0 * g^.fontH;
    glColor4f(0.8, 0.8, 0.8, 0.9);
    DrawAboutLine(g, 3, s, (w - AboutLineW(g, 3, s)) * 0.5, ty);

    s := 'inspired by the Cockos JSFX Oscilloscope Meter';
    ty := ty + 1.6 * g^.fontH;
    glColor4f(0.62, 0.62, 0.68, 0.85);
    DrawAboutLine(g, 4, s, (w - AboutLineW(g, 4, s)) * 0.5, ty);

    { shortcuts, top-right }
    glColor4f(0.62, 0.62, 0.68, 0.85);
    ty := 20 * px + g^.fontH;
    s := 'wheel ............. time zoom';
    DrawAboutLine(g, 5, s, w - AboutLineW(g, 5, s) - 16 * px, ty);
    ty := ty + 1.6 * g^.fontH;
    s := 'ctrl+wheel ........... v-zoom';
    DrawAboutLine(g, 6, s, w - AboutLineW(g, 6, s) - 16 * px, ty);
    ty := ty + 1.6 * g^.fontH;
    s := 'click .................. hold';
    DrawAboutLine(g, 7, s, w - AboutLineW(g, 7, s) - 16 * px, ty);
    ty := ty + 1.6 * g^.fontH;
    s := 'drag while hold ....... scrub';
    DrawAboutLine(g, 8, s, w - AboutLineW(g, 8, s) - 16 * px, ty);
    ty := ty + 1.6 * g^.fontH;
    s := 'right-click .... trigger mode';
    DrawAboutLine(g, 9, s, w - AboutLineW(g, 9, s) - 16 * px, ty);
  end;

  SwapBuffers(g^.dc);   { blocks until vblank when vsync is on }
end;

function RenderThreadProc(param: Pointer): PtrInt;
var
  g: PScopeGui;
  swapInterval: TWglSwapIntervalEXT;
  hasVsync: Boolean;
begin
  Result := 0;
  g := PScopeGui(param);
  if not wglMakeCurrent(g^.dc, g^.glrc) then Exit;

  if g^.msaa then
    glEnable(GL_MULTISAMPLE)
  else
  begin
    { no MSAA on this driver, smooth at least the lines }
    glEnable(GL_LINE_SMOOTH);
    glHint(GL_LINE_SMOOTH_HINT, GL_NICEST);
  end;
  SetupPlasma(g);

  swapInterval := TWglSwapIntervalEXT(wglGetProcAddress('wglSwapIntervalEXT'));
  hasVsync := swapInterval <> nil;
  if hasVsync then
    swapInterval(1);

  while not g^.stop do
  begin
    if IsWindowVisible(g^.wnd) then
    begin
      UpdateScaleAndFont(g);
      RenderFrame(g);
      if not hasVsync then
        Sleep(FALLBACK_FRAME_MS);
    end
    else
      Sleep(30);   { editor hidden, don't burn GPU }
  end;

  CleanupPlasma(g);
  CleanupAboutTextures(g);
  CleanupFont(g);
  wglMakeCurrent(0, 0);
end;

{ apply locally + queue for the host (turned into gesture/value events) }
procedure ApplyGuiParam(inst: PScopeInstance; id: TClapId; v: Double);
begin
  v := ClampParam(ParamIndex(id), v);
  inst^.params[id] := v;
  PushParamChange(inst, id, v);
  RequestHostFlush(inst);
end;

function InAboutButton(g: PScopeGui; x, y: Integer): Boolean;
var
  px: Single;
begin
  px := g^.scale;
  if px < 1 then px := 1;
  Result := (x >= g^.w - Round(26 * px)) and (x <= g^.w - Round(4 * px)) and
    (y >= Round(4 * px)) and (y <= Round(26 * px));
end;

{ drag while holding scrubs the history; drag right = older }
procedure HandleDrag(g: PScopeGui; x: Integer);
var
  inst: PScopeInstance;
  dx: Integer;
  perPixel, maxOffs: Double;
begin
  inst := g^.inst;
  if Abs(x - g^.pressX) > 2 then
    g^.moved := True;
  dx := x - g^.dragLastX;
  g^.dragLastX := x;
  if (dx = 0) or (inst^.params[PARAM_HOLD] < 0.5) or (g^.w < 1) then
    Exit;
  perPixel := ClampParam(PARAM_VIEW_MS, inst^.params[PARAM_VIEW_MS]) *
    0.001 * inst^.srate / g^.w;
  maxOffs := Double(inst^.histSize) - perPixel * g^.w - 1;
  if maxOffs < 0 then maxOffs := 0;
  g^.holdOffs := g^.holdOffs + dx * perPixel;
  if g^.holdOffs < 0 then g^.holdOffs := 0;
  if g^.holdOffs > maxOffs then g^.holdOffs := maxOffs;
end;

procedure HandleWheel(g: PScopeGui; wp: WPARAM; lp: LPARAM);
var
  inst: PScopeInstance;
  delta: Integer;
  pt: TPoint;
  frac, oldVs, newVs, cursorOffs, maxOffs, newMs: Double;
begin
  inst := g^.inst;
  delta := SmallInt((wp shr 16) and $FFFF);
  if (wp and MK_CONTROL) <> 0 then
    ApplyGuiParam(inst, PARAM_VZOOM_DB,
      inst^.params[PARAM_VZOOM_DB] - delta * (3.0 / 120.0))
  else
  begin
    newMs := ClampParam(PARAM_VIEW_MS,
      inst^.params[PARAM_VIEW_MS] * Exp(-delta * 0.001));

    { while holding, zoom around the cursor: keep the sample under it put }
    if (inst^.params[PARAM_HOLD] >= 0.5) and (g^.w > 0) then
    begin
      pt.x := SmallInt(lp and $FFFF);
      pt.y := SmallInt((lp shr 16) and $FFFF);
      ScreenToClient(g^.wnd, pt);
      frac := (g^.w - pt.x) / g^.w;   { 0 = right edge }
      if frac < 0 then frac := 0;
      if frac > 1 then frac := 1;
      oldVs := ClampParam(PARAM_VIEW_MS, inst^.params[PARAM_VIEW_MS]) *
        0.001 * inst^.srate;
      newVs := newMs * 0.001 * inst^.srate;
      cursorOffs := g^.holdOffs + frac * oldVs;
      g^.holdOffs := cursorOffs - frac * newVs;
      maxOffs := Double(inst^.histSize) - newVs - 1;
      if maxOffs < 0 then maxOffs := 0;
      if g^.holdOffs < 0 then g^.holdOffs := 0;
      if g^.holdOffs > maxOffs then g^.holdOffs := maxOffs;
    end;

    ApplyGuiParam(inst, PARAM_VIEW_MS, newMs);
  end;
end;

function ScopeWndProc(hw: HWND; msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT; stdcall;
var
  g: PScopeGui;
  ps: PAINTSTRUCT;
begin
  g := PScopeGui(GetPropW(hw, GUI_PROP));
  case msg of
    WM_PAINT:
      begin
        { render thread repaints anyway, just validate }
        BeginPaint(hw, @ps);
        EndPaint(hw, @ps);
        Exit(0);
      end;
    WM_SIZE:
      if g <> nil then
      begin
        g^.w := Integer(lp and $FFFF);
        g^.h := Integer((lp shr 16) and $FFFF);
        Exit(0);
      end;
    WM_ERASEBKGND:
      Exit(1);
    WM_MOUSEWHEEL:
      if g <> nil then
      begin
        HandleWheel(g, wp, lp);
        Exit(0);
      end;
    WM_LBUTTONDOWN:
      if g <> nil then
      begin
        g^.pressed := True;
        g^.moved := False;
        g^.pressX := SmallInt(lp and $FFFF);
        g^.pressY := SmallInt((lp shr 16) and $FFFF);
        g^.dragLastX := g^.pressX;
        SetCapture(hw);
        Exit(0);
      end;
    WM_MOUSEMOVE:
      if (g <> nil) and g^.pressed then
      begin
        HandleDrag(g, SmallInt(lp and $FFFF));
        Exit(0);
      end;
    WM_LBUTTONUP:
      if (g <> nil) and g^.pressed then
      begin
        g^.pressed := False;
        ReleaseCapture;
        if not g^.moved then
        begin
          { plain click: close about / open about / toggle hold }
          if g^.aboutOpen then
            g^.aboutOpen := False
          else if InAboutButton(g, g^.pressX, g^.pressY) then
          begin
            g^.aboutOpen := True;
            g^.aboutT0 := GetTickCount64;
          end
          else if g^.inst^.params[PARAM_HOLD] >= 0.5 then
          begin
            g^.holdOffs := 0;
            ApplyGuiParam(g^.inst, PARAM_HOLD, 0.0);
          end
          else
          begin
            { freeze exactly what is on screen; with retrigger after a
              transport stop the anchor can sit way behind the head }
            g^.holdOffs := g^.lastAnchorOffs;
            ApplyGuiParam(g^.inst, PARAM_HOLD, 1.0);
          end;
        end;
        Exit(0);
      end;
    WM_RBUTTONDOWN:
      if g <> nil then
      begin
        ApplyGuiParam(g^.inst, PARAM_RETRIG,
          (Round(g^.inst^.params[PARAM_RETRIG]) + 1) mod 4);
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
  wc.style := CS_HREDRAW or CS_VREDRAW or CS_OWNDC;
  wc.lpfnWndProc := @ScopeWndProc;
  wc.hInstance := HInstance;
  wc.hCursor := LoadCursor(0, IDC_ARROW);
  wc.hbrBackground := 0;
  wc.lpszClassName := WND_CLASS_NAME;
  Result := RegisterClassW(wc) <> 0;
  if (not Result) and (GetLastError = ERROR_CLASS_ALREADY_EXISTS) then
  begin
    { stale registration from a previous load of this DLL: window classes
      are not unregistered on unload, so drop it and register again }
    UnregisterClassW(WND_CLASS_NAME, HInstance);
    Result := RegisterClassW(wc) <> 0;
  end;
  ClassRegistered := Result;
end;

procedure GuiGlobalCleanup;
begin
  if ClassRegistered then
  begin
    UnregisterClassW(WND_CLASS_NAME, HInstance);
    ClassRegistered := False;
  end;
end;

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

{ classic WGL bootstrap: wglChoosePixelFormatARB needs a current context
  and SetPixelFormat works once per window, so probe on a throwaway one }
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
        choose := TWglChoosePixelFormatARB(
          wglGetProcAddress('wglChoosePixelFormatARB'));
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

function SetupGl(g: PScopeGui): Boolean;
var
  pfd: PIXELFORMATDESCRIPTOR;
  pf: Integer;
begin
  Result := False;
  g^.dc := GetDC(g^.wnd);
  if g^.dc = 0 then Exit;

  pf := ChooseMsaaFormat(4);
  g^.msaa := pf <> 0;
  FillBasicPfd(pfd);
  if g^.msaa then
    DescribePixelFormat(g^.dc, pf, SizeOf(pfd), @pfd)
  else
    pf := ChoosePixelFormat(g^.dc, @pfd);
  if pf = 0 then Exit;

  if not SetPixelFormat(g^.dc, pf, @pfd) then
  begin
    g^.msaa := False;
    FillBasicPfd(pfd);
    pf := ChoosePixelFormat(g^.dc, @pfd);
    if (pf = 0) or not SetPixelFormat(g^.dc, pf, @pfd) then Exit;
  end;
  g^.glrc := wglCreateContext(g^.dc);
  Result := g^.glrc <> 0;
end;

function GuiCreate(inst: PScopeInstance): Boolean;
var
  g: PScopeGui;
begin
  Result := False;
  if inst^.gui <> nil then
    Exit(True);
  if not EnsureClass then
    Exit;

  New(g);
  FillChar(g^, SizeOf(g^), 0);
  g^.inst := inst;
  g^.scale := EffectiveScale(inst, 0);
  g^.w := Round(DEFAULT_GUI_W * g^.scale);
  g^.h := Round(DEFAULT_GUI_H * g^.scale);

  { created hidden and parentless, the host reparents it later }
  g^.wnd := CreateWindowExW(0, WND_CLASS_NAME, 'lzScope', WS_POPUP,
    0, 0, g^.w, g^.h, 0, 0, HInstance, nil);
  if g^.wnd = 0 then
  begin
    Dispose(g);
    Exit;
  end;
  SetPropW(g^.wnd, GUI_PROP, HANDLE(g));

  if not SetupGl(g) then
  begin
    if g^.dc <> 0 then ReleaseDC(g^.wnd, g^.dc);
    DestroyWindow(g^.wnd);
    Dispose(g);
    Exit;
  end;

  g^.stop := False;
  g^.thread := BeginThread(@RenderThreadProc, g);
  if g^.thread = TThreadID(0) then
  begin
    wglDeleteContext(g^.glrc);
    ReleaseDC(g^.wnd, g^.dc);
    DestroyWindow(g^.wnd);
    Dispose(g);
    Exit;
  end;

  inst^.gui := g;
  Result := True;
end;

procedure GuiDestroy(inst: PScopeInstance);
var
  g: PScopeGui;
begin
  g := PScopeGui(inst^.gui);
  if g = nil then Exit;
  inst^.gui := nil;

  { join the render thread first }
  g^.stop := True;
  WaitForSingleObject({%H-}HANDLE(g^.thread), 5000);
  CloseHandle({%H-}HANDLE(g^.thread));

  if g^.glrc <> 0 then wglDeleteContext(g^.glrc);
  if g^.dc <> 0 then ReleaseDC(g^.wnd, g^.dc);
  RemovePropW(g^.wnd, GUI_PROP);
  DestroyWindow(g^.wnd);
  Dispose(g);
end;

function GuiSetParent(inst: PScopeInstance; parentHandle: Pointer): Boolean;
var
  g: PScopeGui;
  parent: HWND;
begin
  Result := False;
  g := PScopeGui(inst^.gui);
  parent := {%H-}HWND(parentHandle);
  if (g = nil) or (parent = 0) then Exit;
  SetWindowLongPtrW(g^.wnd, GWL_STYLE, WS_CHILD);
  Windows.SetParent(g^.wnd, parent);
  SetWindowPos(g^.wnd, 0, 0, 0, g^.w, g^.h,
    SWP_NOZORDER or SWP_NOACTIVATE or SWP_FRAMECHANGED);
  Result := True;
end;

function GuiGetSize(inst: PScopeInstance; outW, outH: PUInt32): Boolean;
var
  g: PScopeGui;
  sc: Single;
begin
  g := PScopeGui(inst^.gui);
  if g <> nil then
  begin
    outW^ := g^.w;
    outH^ := g^.h;
  end
  else
  begin
    sc := EffectiveScale(inst, 0);
    outW^ := Round(DEFAULT_GUI_W * sc);
    outH^ := Round(DEFAULT_GUI_H * sc);
  end;
  Result := True;
end;

function GuiSetSize(inst: PScopeInstance; w, h: UInt32): Boolean;
var
  g: PScopeGui;
begin
  Result := False;
  g := PScopeGui(inst^.gui);
  if g = nil then Exit;
  g^.w := Integer(w);
  g^.h := Integer(h);
  SetWindowPos(g^.wnd, 0, 0, 0, g^.w, g^.h,
    SWP_NOZORDER or SWP_NOACTIVATE or SWP_NOMOVE);
  Result := True;
end;

function GuiShow(inst: PScopeInstance): Boolean;
var
  g: PScopeGui;
begin
  Result := False;
  g := PScopeGui(inst^.gui);
  if g = nil then Exit;
  ShowWindow(g^.wnd, SW_SHOWNA);
  Result := True;
end;

function GuiHide(inst: PScopeInstance): Boolean;
var
  g: PScopeGui;
begin
  Result := False;
  g := PScopeGui(inst^.gui);
  if g = nil then Exit;
  ShowWindow(g^.wnd, SW_HIDE);
  Result := True;
end;

end.
