unit scope_gui_render;

{ Render thread: owns the GL context, draws when something changed }

{$mode objfpc}{$H+}
{$pointermath on}

interface

function RenderThreadProc(param: Pointer): PtrInt;

implementation

uses
  Windows, Math, gl_min, scope_ring, scope_state, scope_view, scope_shader,
  scope_gui_types, scope_gui_text;

const
  LN10_OVER_20 = 0.11512925464970229;
  FALLBACK_FRAME_MS = 12;  { no DWM, no vsync }
  IDLE_POLL_MS = 8;        { nothing changed }
  HIDDEN_POLL_MS = 30;     { hidden or minimized }
  MAX_IDLE_MS = 500;       { forced redraw interval }

  TrigNamesS: array[0..3] of string[10] =
    ('instant', 'any', 'ascending', 'descending');

type
  TFrame = record
    w, h: Integer;
    px: Single;            { UI scale }
    yCent, scopeH: Single;
    sc: Single;            { px per unit of amplitude }
    vzoom, viewMs: Double;
    cursorX, cursorY: Integer;
  end;

{ formatting }

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
  if not (v > 1e-6) then   { also NaN }
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

{ GL resources }

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

{ rebuild the font when the DPI changes }
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
    BuildAtlas(g, fh);
end;

{ draw passes }

procedure DrawGrid(g: PScopeGui; const f: TFrame);
var
  iter, gridStep, x: Integer;
  v, t: Double;
  a, ly: Single;
  s: ShortString;
begin
  { center line }
  glColor4f(0.6, 0.6, 0.6, 1.0);
  glBegin(GL_LINES);
  glVertex2f(0, f.yCent); glVertex2f(f.w, f.yCent);
  glEnd;

  { dB grid }
  v := f.vzoom;
  ly := f.scopeH + 20 * f.px;
  for iter := 1 to 64 do
  begin
    a := Exp(v * LN10_OVER_20) * f.sc;
    if a <= 24 * f.px then Break;
    if a < ly then
    begin
      glColor4f(0.6, 0.6, 0.6, 0.25);
      glBegin(GL_LINES);
      glVertex2f(0, f.yCent - a); glVertex2f(f.w, f.yCent - a);
      glVertex2f(0, f.yCent + a); glVertex2f(f.w, f.yCent + a);
      glEnd;
      if iter > 1 then   { outermost line unlabeled }
      begin
        FormatDb(v, s);
        glColor4f(0.75, 0.75, 0.75, 0.55);
        DrawTextGL(g, 8 * f.px, f.yCent - a - 5 * f.px, s);
        DrawTextGL(g, 8 * f.px, f.yCent + a + g^.fontH + 4, s);
      end;
      ly := a - 20 * f.px;
    end;
    v := Floor(v / 3 - 1) * 3;
  end;

  { time grid, from the right edge }
  gridStep := Round(72 * f.px);
  x := f.w - gridStep;
  while x > 24 * f.px do
  begin
    glColor4f(0.6, 0.6, 0.6, 0.18);
    glBegin(GL_LINES);
    glVertex2f(x, 0); glVertex2f(x, f.h);
    glEnd;
    t := f.viewMs * (f.w - x) / f.w;
    glColor4f(0.75, 0.75, 0.75, 0.55);
    FormatTime(t, s);
    DrawTextGL(g, x + 5 * f.px, f.h - 9 * f.px, s);
    if t <= 250 then
    begin
      FormatHz(t, s);
      DrawTextGL(g, x + 5 * f.px, f.h - 9 * f.px - (g^.fontH + 3), s);
    end;
    Dec(x, gridStep);
  end;
end;

procedure DrawChannel(g: PScopeGui; constref mins, maxs: array of Single;
  cols: Integer; const f: TFrame; r, gr, b: Single);
var
  x: Integer;
  yLo, yHi, maxY: Single;
  v: ^TVertex;

  function ToY(s: Single): Single; inline;
  begin
    Result := f.yCent - s * f.sc;
    if not (Result >= -2) then Result := -2;   { also NaN }
    if Result > maxY then Result := maxY;
  end;

begin
  maxY := f.h + 2;
  glEnableClientState(GL_VERTEX_ARRAY);
  glVertexPointer(2, GL_FLOAT, SizeOf(TVertex), @g^.verts[0].x);
  glColorPointer(4, GL_FLOAT, SizeOf(TVertex), @g^.verts[0].r);

  { glow }
  v := @g^.verts[0];
  for x := 0 to cols - 1 do
  begin
    v^.x := x + 0.5; v^.y := f.yCent;
    v^.r := r; v^.g := gr; v^.b := b; v^.a := 0.04;
    Inc(v);
    v^.x := x + 0.5; v^.y := ToY(maxs[x]);
    v^.r := r; v^.g := gr; v^.b := b; v^.a := 0.26;
    Inc(v);
  end;
  glEnableClientState(GL_COLOR_ARRAY);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, cols * 2);
  for x := 0 to cols - 1 do
    g^.verts[x * 2 + 1].y := ToY(mins[x]);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, cols * 2);
  glDisableClientState(GL_COLOR_ARRAY);

  { body }
  for x := 0 to cols - 1 do
  begin
    yHi := ToY(maxs[x]);
    yLo := ToY(mins[x]);
    if yLo - yHi < f.px then
    begin
      yHi := (yHi + yLo - f.px) * 0.5;
      yLo := yHi + f.px;
    end;
    g^.verts[x * 2].y := yHi;
    g^.verts[x * 2 + 1].y := yLo;
  end;
  glColor4f(r, gr, b, 0.42);
  glDrawArrays(GL_TRIANGLE_STRIP, 0, cols * 2);

  { outlines }
  for x := 0 to cols - 1 do
  begin
    g^.verts[x * 2].y := ToY(maxs[x]);
    g^.verts[x * 2 + 1].y := ToY(mins[x]);
  end;
  glColor4f(r, gr, b, 0.9);
  glVertexPointer(2, GL_FLOAT, 2 * SizeOf(TVertex), @g^.verts[0].x);
  glDrawArrays(GL_LINE_STRIP, 0, cols);
  glVertexPointer(2, GL_FLOAT, 2 * SizeOf(TVertex), @g^.verts[1].x);
  glDrawArrays(GL_LINE_STRIP, 0, cols);

  glDisableClientState(GL_VERTEX_ARRAY);
end;

procedure DrawStatus(g: PScopeGui; const f: TFrame);
var
  trig, i, hot: Integer;
  x, y, gap, w: Single;
  s: ShortString;
  seg: array[0..ST_COUNT - 1] of ShortString;
  r: TStatusRect;
begin
  trig := Round(ClampParam(PARAM_RETRIG, GetParam(g^.inst, PARAM_RETRIG)));
  FormatTime(f.viewMs, s);
  seg[ST_LEN] := 'len ' + s;
  FormatDb(f.vzoom, s);
  seg[ST_RANGE] := 'range ' + s;
  seg[ST_TRIG] := 'trig ' + TrigNamesS[trig];

  { dragged or hovered item is highlighted }
  hot := g^.statusDrag;
  if (hot = ST_NONE) and (f.cursorX >= 0) then
    hot := StatusItemAt(g, f.cursorX, f.cursorY);

  x := Round(8 * f.px);
  y := 6 * f.px + g^.fontH;
  gap := TextWidth(g, '  ');
  for i := 0 to ST_COUNT - 1 do
  begin
    w := TextWidth(g, seg[i]);
    r.x0 := Round(x - gap * 0.5);
    r.x1 := Round(x + w + gap * 0.5);
    r.y0 := 0;
    r.y1 := Round(y + 6 * f.px);
    g^.statusRects[i] := r;
    if i = hot then
      glColor4f(1.0, 0.85, 0.2, 1.0)
    else
      glColor4f(0.85, 0.85, 0.85, 0.8);
    DrawTextGL(g, x, y, seg[i]);
    x := x + w + gap;
  end;

  if GetParam(g^.inst, PARAM_HOLD) >= 0.5 then
  begin
    glColor4f(1.0, 0.3, 0.3, 0.9);
    { same baseline as "?" }
    DrawTextGL(g, f.w - 68 * f.px, 4 * f.px + (22 * f.px + g^.fontH) * 0.5, 'HOLD');
  end;
end;

{ crosshair with level and L/R peak readout }
procedure DrawCrosshair(g: PScopeGui; const f: TFrame);
var
  col: Integer;
  peakL, peakR: Single;
  havePeaks: Boolean;
  bx, by, bw, bh, rowW, gapW: Single;
  s, s2, s3: ShortString;
begin
  if f.cursorX < 0 then Exit;

  glColor4f(1.0, 1.0, 1.0, 0.30);
  glBegin(GL_LINES);
  glVertex2f(f.cursorX + 0.5, 0); glVertex2f(f.cursorX + 0.5, f.h);
  glVertex2f(0, f.cursorY + 0.5); glVertex2f(f.w, f.cursorY + 0.5);
  glEnd;

  FormatPeakDb(Abs(f.yCent - f.cursorY) / f.sc, s);
  rowW := TextWidth(g, s);
  gapW := TextWidth(g, '  ');
  havePeaks := g^.cols.count > 0;
  if havePeaks then
  begin
    col := (f.cursorX * g^.cols.count) div f.w;
    if col > g^.cols.count - 1 then col := g^.cols.count - 1;
    peakL := Abs(g^.cols.minL[col]);
    if Abs(g^.cols.maxL[col]) > peakL then peakL := Abs(g^.cols.maxL[col]);
    peakR := Abs(g^.cols.minR[col]);
    if Abs(g^.cols.maxR[col]) > peakR then peakR := Abs(g^.cols.maxR[col]);
    FormatPeakDb(peakL, s2);
    s2 := 'L ' + s2;
    FormatPeakDb(peakR, s3);
    s3 := 'R ' + s3;
    if TextWidth(g, s2) + gapW + TextWidth(g, s3) > rowW then
      rowW := TextWidth(g, s2) + gapW + TextWidth(g, s3);
  end;

  bw := rowW + 10 * f.px;
  bh := g^.fontH + 9 * f.px;
  if havePeaks then bh := bh + g^.fontH + 3 * f.px;
  bx := f.cursorX + 16 * f.px;
  if bx + bw > f.w - 2 then bx := f.cursorX - 16 * f.px - bw;
  if bx < 2 then bx := 2;
  by := f.cursorY - 12 * f.px - bh;
  if by < 2 then by := f.cursorY + 20 * f.px;

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
  DrawTextGL(g, bx + 5 * f.px, by + 4 * f.px + g^.fontH, s);
  if havePeaks then
  begin
    glColor4f(0.5, 1.0, 0.5, 0.95);
    DrawTextGL(g, bx + 5 * f.px, by + bh - 5 * f.px, s2);
    glColor4f(1.0, 0.5, 1.0, 0.95);
    DrawTextGL(g, bx + 5 * f.px + TextWidth(g, s2) + gapW, by + bh - 5 * f.px, s3);
  end;
end;

procedure DrawAboutButton(g: PScopeGui; const f: TFrame);
begin
  glColor4f(0.6, 0.6, 0.7, 0.5);
  glBegin(GL_LINE_STRIP);
  glVertex2f(f.w - 26 * f.px, 4 * f.px); glVertex2f(f.w - 4 * f.px, 4 * f.px);
  glVertex2f(f.w - 4 * f.px, 26 * f.px); glVertex2f(f.w - 26 * f.px, 26 * f.px);
  glVertex2f(f.w - 26 * f.px, 4 * f.px);
  glEnd;
  glColor4f(0.8, 0.8, 0.9, 0.8);
  DrawTextGL(g, f.w - 18 * f.px, 4 * f.px + (22 * f.px + g^.fontH) * 0.5, '?');
end;

procedure DrawAbout(g: PScopeGui; const f: TFrame);
const
  Shortcuts: array[5..ABOUT_LINES - 1] of string[40] = (
    'wheel ............. time zoom',
    'ctrl+wheel ........... v-zoom',
    'click .................. hold',
    'drag while hold ....... scrub',
    'right-click .... trigger mode',
    'drag len/range ....... adjust',
    'double-click .......... reset');
var
  aboutT: Double;
  ty, easeK: Single;
  s: ShortString;
  i: Integer;
begin
  aboutT := (GetTickCount64 - g^.aboutT0) * 0.001;

  { warp the scene through the shader; plain dim without GLSL }
  if g^.plasmaProg <> 0 then
  begin
    easeK := aboutT / 0.35;
    if easeK > 1.0 then easeK := 1.0;

    if g^.sceneTex = 0 then
      glGenTextures(1, @g^.sceneTex);
    glBindTexture(GL_TEXTURE_2D, g^.sceneTex);
    if (g^.sceneTexW <> f.w) or (g^.sceneTexH <> f.h) then
    begin
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, f.w, f.h, 0, GL_RGB,
        GL_UNSIGNED_BYTE, nil);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      g^.sceneTexW := f.w;
      g^.sceneTexH := f.h;
    end;
    glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, f.w, f.h);

    glDisable(GL_BLEND);
    UseShaderProgram(g^.plasmaProg);
    SetUniform1f(g^.plasmaLocT, aboutT);
    SetUniform1f(g^.plasmaLocK, easeK);
    SetUniform2f(g^.plasmaLocRes, f.w, f.h);
    SetUniform1i(g^.plasmaLocScene, 0);
    glBegin(GL_QUADS);
    glVertex2f(0, 0); glVertex2f(f.w, 0);
    glVertex2f(f.w, f.h); glVertex2f(0, f.h);
    glEnd;
    UseShaderProgram(0);
    glEnable(GL_BLEND);
  end
  else
  begin
    glColor4f(0.0, 0.0, 0.02, 0.62);
    glBegin(GL_QUADS);
    glVertex2f(0, 0); glVertex2f(f.w, 0);
    glVertex2f(f.w, f.h); glVertex2f(0, f.h);
    glEnd;
  end;

  BuildAboutTextures(g);

  s := 'lzScope v' + PLUGIN_VERSION;
  ty := f.h * 0.5 - 3.0 * g^.fontH + Sin(aboutT * 2.0) * 3 * f.px;
  glColor4f(1.0, 1.0, 1.0, 0.95);
  DrawAboutLine(g, 0, s, (f.w - AboutLineW(g, 0, s)) * 0.5, ty);

  s := 'created by ' + PLUGIN_AUTHOR;
  ty := ty + 2.0 * g^.fontH;
  glColor4f(0.8, 0.8, 0.8, 0.9);
  DrawAboutLine(g, 1, s, (f.w - AboutLineW(g, 1, s)) * 0.5, ty);

  s := PLUGIN_URL;
  ty := ty + 2.0 * g^.fontH;
  glColor4f(0.5, 1.0, 0.5, 0.9);
  DrawAboutLine(g, 2, s, (f.w - AboutLineW(g, 2, s)) * 0.5, ty);

  s := 'built with Free Pascal & Lazarus';
  ty := ty + 2.0 * g^.fontH;
  glColor4f(0.8, 0.8, 0.8, 0.9);
  DrawAboutLine(g, 3, s, (f.w - AboutLineW(g, 3, s)) * 0.5, ty);

  s := 'inspired by the Cockos JSFX Oscilloscope Meter';
  ty := ty + 1.6 * g^.fontH;
  glColor4f(0.62, 0.62, 0.68, 0.85);
  DrawAboutLine(g, 4, s, (f.w - AboutLineW(g, 4, s)) * 0.5, ty);

  { shortcuts, top-right }
  glColor4f(0.62, 0.62, 0.68, 0.85);
  ty := 20 * f.px + g^.fontH;
  for i := Low(Shortcuts) to High(Shortcuts) do
  begin
    s := Shortcuts[i];
    DrawAboutLine(g, i, s, f.w - AboutLineW(g, i, s) - 16 * f.px, ty);
    ty := ty + 1.6 * g^.fontH;
  end;
end;

procedure RenderFrame(g: PScopeGui; const key: TFrameKey);
var
  f: TFrame;
  anchor: Double;
begin
  f.w := key.w;
  f.h := key.h;
  if (f.w < 8) or (f.h < 8) then Exit;
  f.px := g^.scale;
  if f.px < 1.0 then f.px := 1.0;
  f.cursorX := key.cursorX;
  f.cursorY := key.cursorY;

  BuildColumns(g^.inst, key.holdOffs, f.w, g^.cols, anchor);
  g^.lastAnchorOffs := anchor;

  glViewport(0, 0, f.w, f.h);
  glClearColor(0.02, 0.02, 0.045, 1.0);
  glClear(GL_COLOR_BUFFER_BIT);

  glMatrixMode(GL_PROJECTION);
  glLoadIdentity;
  glOrtho(0, f.w, f.h, 0, -1, 1);   { pixel coords, y down }
  glMatrixMode(GL_MODELVIEW);
  glLoadIdentity;

  glEnable(GL_BLEND);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  glLineWidth(f.px);

  f.yCent := f.h * 0.5;
  f.scopeH := f.h * 0.5 - 4 * f.px;
  if f.scopeH < 10 then f.scopeH := 10;
  f.vzoom := ClampParam(PARAM_VZOOM_DB, GetParam(g^.inst, PARAM_VZOOM_DB));
  f.viewMs := ClampParam(PARAM_VIEW_MS, GetParam(g^.inst, PARAM_VIEW_MS));
  f.sc := Exp(-f.vzoom * LN10_OVER_20) * f.scopeH;

  DrawGrid(g, f);
  if g^.cols.count > 0 then
  begin
    DrawChannel(g, g^.cols.minL, g^.cols.maxL, g^.cols.count, f,
      0.5, 1.0, 0.5);               { left:  green }
    DrawChannel(g, g^.cols.minR, g^.cols.maxR, g^.cols.count, f,
      1.0, 0.5, 1.0);               { right: magenta }
  end;
  DrawStatus(g, f);

  if key.about = 0 then
  begin
    DrawCrosshair(g, f);
    DrawAboutButton(g, f);
  end
  else
    DrawAbout(g, f);

  SwapBuffers(g^.dc);
end;

{ thread }

procedure MakeFrameKey(g: PScopeGui; out key: TFrameKey);
var
  cp: TPoint;
  i: Integer;
begin
  FillChar(key, SizeOf(key), 0);   { keys are compared bytewise }
  key.written := RingWritten(g^.inst^.ring);
  key.validFrom := RingValidFrom(g^.inst^.ring);
  for i := 0 to PARAM_COUNT - 1 do
    key.params[i] := g^.inst^.paramBits[i];
  key.holdOffs := g^.holdOffs;
  key.w := g^.w;
  key.h := g^.h;
  key.fontH := g^.fontH;
  key.about := Ord(g^.aboutOpen);
  key.statusDrag := g^.statusDrag;
  key.cursorX := -1;
  key.cursorY := -1;
  if (key.about = 0) and GetCursorPos(cp{%H-}) then
  begin
    ScreenToClient(g^.wnd, cp);
    if (cp.x >= 0) and (cp.x < key.w) and (cp.y >= 0) and (cp.y < key.h) then
    begin
      key.cursorX := cp.x;
      key.cursorY := cp.y;
    end;
  end;
end;

function EditorShowing(g: PScopeGui): Boolean;
var
  root: HWND;
begin
  Result := IsWindowVisible(g^.wnd);
  if not Result then Exit;
  root := GetAncestor(g^.wnd, GA_ROOT);
  if (root <> 0) and IsIconic(root) then
    Result := False;
end;

type
  TDwmFlush = function: HRESULT; stdcall;

function RenderThreadProc(param: Pointer): PtrInt;
var
  g: PScopeGui;
  swapInterval: TWglSwapIntervalEXT;
  dwmLib: HMODULE;
  dwmFlush: TDwmFlush;
  swapWaits, wasShowing, due: Boolean;
  key: TFrameKey;
  now: QWord;
begin
  Result := 0;
  g := PScopeGui(param);
  { FPC unmasks FPU exceptions per thread; GL drivers can't take that }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow,
    exUnderflow, exPrecision]);
  if not wglMakeCurrent(g^.dc, g^.glrc) then Exit;

  if g^.msaa then
    glEnable(GL_MULTISAMPLE)
  else
  begin
    { no MSAA: smooth the lines }
    glEnable(GL_LINE_SMOOTH);
    glHint(GL_LINE_SMOOTH_HINT, GL_NICEST);
  end;
  SetupPlasma(g);

  { pace with DwmFlush: some drivers spin a core waiting for vsync in SwapBuffers }
  dwmFlush := nil;
  dwmLib := LoadLibraryW('dwmapi.dll');
  if dwmLib <> 0 then
    dwmFlush := TDwmFlush(GetProcAddress(dwmLib, 'DwmFlush'));
  swapInterval := TWglSwapIntervalEXT(wglGetProcAddress('wglSwapIntervalEXT'));
  swapWaits := (swapInterval <> nil) and (dwmFlush = nil);
  if swapInterval <> nil then
    swapInterval(Ord(swapWaits));

  wasShowing := False;
  while not g^.stop do
  begin
    if not EditorShowing(g) then
    begin
      wasShowing := False;
      Sleep(HIDDEN_POLL_MS);
      Continue;
    end;

    UpdateScaleAndFont(g);
    MakeFrameKey(g, key);
    now := GetTickCount64;
    { redraw only when something changed (about animates) }
    due := (InterlockedExchange(g^.redraw, 0) <> 0) or (key.about <> 0) or
      (not wasShowing) or (now - g^.lastDrawTick >= MAX_IDLE_MS) or
      (CompareByte(key, g^.lastKey, SizeOf(key)) <> 0);
    if due then
    begin
      RenderFrame(g, key);
      g^.lastKey := key;
      g^.lastDrawTick := now;
      wasShowing := True;
      if not swapWaits then
        if (dwmFlush = nil) or (dwmFlush() < 0) then
          Sleep(FALLBACK_FRAME_MS);
    end
    else
      Sleep(IDLE_POLL_MS);
  end;

  CleanupPlasma(g);
  CleanupAboutTextures(g);
  CleanupAtlas(g);
  wglMakeCurrent(0, 0);
  if dwmLib <> 0 then
    FreeLibrary(dwmLib);
end;

end.
