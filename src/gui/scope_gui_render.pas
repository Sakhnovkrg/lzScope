unit scope_gui_render;

{ Render thread: owns the GL context, draws when something changed }

{$mode objfpc}{$H+}
{$pointermath on}

interface

function RenderThreadProc(param: Pointer): PtrInt;

implementation

uses
  SysUtils, Math, gl_min, scope_ring, scope_state, scope_view, scope_shader,
  scope_gui_types, scope_gui_text, scope_gui_os;

const
  LN10_OVER_20 = 0.11512925464970229;
  IDLE_POLL_MS = 8;        { nothing changed }
  HIDDEN_POLL_MS = 30;     { hidden or minimized }
  MAX_IDLE_MS = 500;       { forced redraw interval }

  TrigNamesS: array[0..RETRIG_COUNT - 1] of string[10] =
    ('instant', 'any', 'ascending', 'descending');
  { the longest the status line gets }
  STATUS_WIDEST = 'len 1/2 bar x999.9  range -60.0dB  trig descending  sync (no tempo)  split';
  BtnNames: array[0..BT_COUNT - 1] of string[12] = ('save default', 'help');
  HEADER_RIGHT = '    HOLD  save default  help';

type
  TFrame = record
    w, h: Integer;
    px: Single;            { UI scale }
    { waveform area: right of the dB sidebar, between header and footer }
    x0, pw, pTop, pBot: Integer;
    split: Boolean;
    yMid: Integer;         { split view: where the lanes meet }
    yTop, yBot: Single;    { lane of the channel being drawn }
    yCent, scopeH: Single;
    sc: Single;            { px per unit of amplitude }
    vzoom, viewMs: Double;
    cursorX, cursorY: Integer;
    colW: Single;          { px per waveform column }
    vi: TViewInfo;
  end;

{ formatting }

procedure FormatDb(v: Double; out s: ShortString);
begin
  Str(v: 0: 1, s);
  if v >= 0 then s := '+' + s;
  s := s + 'dB';
end;

{ sidebar label: whole dB, no unit }
procedure FormatDbShort(v: Double; out s: ShortString);
begin
  Str(Round(v), s);
  if Round(v) > 0 then s := '+' + s;
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
  s := EffectiveScale(g^.inst, g);
  g^.scale := s;
  fh := Round(12 * s);
  if fh < 9 then fh := 9;
  if fh <> g^.fontH then
  begin
    BuildAtlas(g, fh);
    { narrowest window that still fits the whole header }
    g^.minW := 0;
    if g^.atlas.tex <> 0 then
      g^.minW := Round(TextWidth(g, STATUS_WIDEST + HEADER_RIGHT) + 16 * s);
  end;
end;

{ draw passes }

{ footer label centered under a line at x; returns its right end }
function DrawFootLabel(g: PScopeGui; const f: TFrame; x: Single;
  const s: ShortString): Single;
var
  tw, tx: Single;
begin
  tw := TextWidth(g, s);
  tx := x - tw * 0.5;
  if tx + tw > f.w - 2 then tx := f.w - 2 - tw;
  if tx < 2 then tx := 2;
  DrawTextGL(g, tx, f.h - 7 * f.px, s);
  Result := tx + tw;
end;

{ sync view: lines on bars, beats and finer; labelled bar.beat.sixteenth
  of the song, as the host counts bars }
procedure DrawBeatGrid(g: PScopeGui; const f: TFrame);
const
  Steps: array[0..8] of Double =
    (1 / 256, 1 / 128, 1 / 64, 1 / 32, 1 / 16, 1 / 8, 1 / 4, 1 / 2, 1);   { beats }
var
  bpb, lenBeats, step, p, beat, first, visBeats, labelEnd, song: Double;
  i, k, bar, x, q: Integer;
  tw: Single;
  s, s2: ShortString;
begin
  bpb := f.vi.beatsPerBar;
  lenBeats := f.vi.lenBars * bpb;
  if (bpb <= 0) or (lenBeats <= 0) or (f.vi.zoomSpan <= 0) then Exit;
  first := f.vi.zoomStart * lenBeats;     { left edge, beats from the cycle start }
  song := f.vi.cycleBar * bpb;            { the cycle start, beats into the song }
  visBeats := f.vi.zoomSpan * lenBeats;

  { the finest step that keeps the lines apart }
  step := 0;
  for i := 0 to High(Steps) + 3 do
  begin
    if i <= High(Steps) then
      p := Steps[i]
    else
      p := bpb * (1 shl (i - High(Steps) - 1));   { 1, 2, 4 bars }
    if f.pw * p / visBeats >= 56 * f.px then
    begin
      step := p;
      Break;
    end;
  end;
  if step = 0 then Exit;

  labelEnd := 0;
  { from the left edge when it is on a step: the cycle start is bar 1 }
  k := Ceil(first / step - 1e-9);
  while k * step < first + visBeats - 1e-9 do
  begin
    p := k * step;
    x := f.x0 + Round(f.pw * (p - first) / visBeats);
    { the label from where the line is in the song }
    bar := Floor((song + p) / bpb + 1e-9);
    beat := song + p - bar * bpb;
    if beat < 0 then beat := 0;
    { whole sixteenths get a label, anything finer only a faint line }
    q := Round(beat * 4);
    if Abs(beat * 4 - q) > 1e-6 then q := -1;
    if q = 0 then
      glColor4f(0.6, 0.6, 0.6, 0.42)   { bar }
    else if (q > 0) and (q mod 4 = 0) then
      glColor4f(0.6, 0.6, 0.6, 0.28)   { beat }
    else if q > 0 then
      glColor4f(0.6, 0.6, 0.6, 0.16)
    else
      glColor4f(0.6, 0.6, 0.6, 0.08);
    glBegin(GL_LINES);
    glVertex2f(x, f.pTop); glVertex2f(x, f.pBot);
    glEnd;

    Str(bar + 1, s);
    if q > 0 then
    begin
      Str(q div 4 + 1, s2);
      s := s + '.' + s2;
    end;
    if (q > 0) and (q mod 4 <> 0) then
    begin
      Str(q mod 4 + 1, s2);
      s := s + '.' + s2;
    end;
    { skip a label that would run into the previous one }
    tw := TextWidth(g, s);
    if (q >= 0) and (x - tw * 0.5 >= labelEnd) then
    begin
      glColor4f(0.75, 0.75, 0.75, 0.55);
      labelEnd := DrawFootLabel(g, f, x, s) + 8 * f.px;
    end;
    Inc(k);
  end;
end;

{ lane of channel idx: the whole waveform area, or its half in split view }
procedure SetLane(var f: TFrame; idx: Integer);
begin
  f.yTop := f.pTop;
  f.yBot := f.pBot;
  if f.split and (idx = 0) then f.yBot := f.yMid;
  if f.split and (idx = 1) then f.yTop := f.yMid;
  f.yCent := (f.yTop + f.yBot) * 0.5;
  { room for the outer labels of both lanes where they meet }
  f.scopeH := (f.yBot - f.yTop) * 0.5 - (4 + 4 * Ord(f.split)) * f.px;
  if f.scopeH < 10 then f.scopeH := 10;
  f.sc := Exp(-f.vzoom * LN10_OVER_20) * f.scopeH;
end;

{ sidebar label for a line at y }
procedure DrawLevelLabel(g: PScopeGui; const f: TFrame; y: Single;
  const s: ShortString);
begin
  DrawTextGL(g, f.x0 - 6 * f.px - TextWidth(g, s), y + g^.fontH * 0.35, s);
end;

{ split view: the lane's side towards the other lane, +1 = down, -1 = up }
function InnerSide(const f: TFrame): Integer;
begin
  Result := 0;
  if not f.split then Exit;
  if f.yBot <= f.yMid then
    Result := 1
  else
    Result := -1;
end;

{ a line a px from the center on side dir would crowd the lane border:
  both lanes have one there, so the border stands for them }
function AtBorder(const f: TFrame; dir: Integer; a: Single): Boolean;
var
  inner: Integer;
begin
  inner := InnerSide(f);
  Result := (inner <> 0) and (dir = inner) and
    (inner * (f.yCent + inner * a - f.yMid) > -12 * f.px);
end;

{ the labels of a level pair; the one on the lane border goes to edge }
procedure DrawLevelLabels(g: PScopeGui; const f: TFrame; a: Single;
  const s: ShortString; var edge: ShortString);
var
  dir: Integer;
begin
  for dir := -1 to 1 do
  begin
    if dir = 0 then Continue;
    if AtBorder(f, dir, a) then
      edge := s
    else
      DrawLevelLabel(g, f, f.yCent + dir * a, s);
  end;
end;

{ a level line on both sides of the center, but not on the lane border }
procedure DrawLevelPair(const f: TFrame; a: Single);
var
  dir: Integer;
begin
  glBegin(GL_LINES);
  for dir := -1 to 1 do
    if (dir <> 0) and not AtBorder(f, dir, a) then
    begin
      glVertex2f(f.x0, f.yCent + dir * a); glVertex2f(f.w, f.yCent + dir * a);
    end;
  glEnd;
end;

{ center line and dB scale of the current lane. Split view: the lines at
  the lane border are left out, their label goes to edge (edgeRed: the
  0 dBFS one), drawn once on the border by the caller }
procedure DrawLevelGrid(g: PScopeGui; const f: TFrame; var edge: ShortString;
  var edgeRed: Boolean);
var
  iter: Integer;
  v: Double;
  a, ly: Single;
  s: ShortString;
begin
  { center line }
  glColor4f(0.6, 0.6, 0.6, 1.0);
  glBegin(GL_LINES);
  glVertex2f(f.x0, f.yCent); glVertex2f(f.w, f.yCent);
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
      s := '';
      { whole dB only; the red 0 dB label wins over a close one }
      if (Abs(v - Round(v)) < 1e-6) and
         ((f.vzoom <= 0) or (Abs(a - f.sc) > g^.fontH + 2 * f.px)) then
        FormatDbShort(v, s);
      glColor4f(0.6, 0.6, 0.6, 0.25);
      DrawLevelPair(f, a);
      if s <> '' then
      begin
        glColor4f(0.75, 0.75, 0.75, 0.55);
        DrawLevelLabels(g, f, a, s, edge);
      end;
      ly := a - 20 * f.px;
    end;
    v := Floor(v / 3 - 1) * 3;
  end;

  { 0 dBFS threshold, when the range reaches above it }
  if f.vzoom > 0 then
  begin
    a := f.sc;
    glColor4f(0.85, 0.35, 0.35, 0.5);
    DrawLevelPair(f, a);
    s := '';
    DrawLevelLabels(g, f, a, '0', s);
    { on the border it wins over a grey label }
    if s <> '' then
    begin
      edge := s;
      edgeRed := True;
    end;
  end;
end;

{ grid label: round values without the trailing zeros }
procedure FormatGridTime(ms: Double; out s: ShortString);
var
  u: string[2];
begin
  u := 'ms';
  if ms >= 1000 then
  begin
    ms := ms / 1000;
    u := 's';
  end;
  if Abs(ms - Round(ms)) < 1e-6 then
    Str(Round(ms), s)
  else
    Str(ms: 0: 1, s);
  s := s + u;
end;

procedure DrawTimeGrid(g: PScopeGui; const f: TFrame);
const
  Mult: array[0..2] of Double = (1, 2, 5);
var
  i, k, x: Integer;
  step, t: Double;
  s: ShortString;
begin
  if f.vi.sweep then
  begin
    DrawBeatGrid(g, f);
    Exit;
  end;

  { time back from the right edge, in the smallest 1-2-5 step that fits }
  step := 0;
  for i := 0 to 17 do
  begin
    t := Mult[i mod 3] * 0.1 * IntPower(10, i div 3);   { 0.1 ms .. 50 s }
    if f.pw * t / f.viewMs >= 72 * f.px then
    begin
      step := t;
      Break;
    end;
  end;
  if step = 0 then Exit;

  k := 1;
  while k * step < f.viewMs do
  begin
    t := k * step;
    x := f.x0 + Round(f.pw - f.pw * t / f.viewMs);
    if x <= f.x0 + 2 then Break;
    glColor4f(0.6, 0.6, 0.6, 0.18);
    glBegin(GL_LINES);
    glVertex2f(x, f.pTop); glVertex2f(x, f.pBot);
    glEnd;
    glColor4f(0.75, 0.75, 0.75, 0.55);
    FormatGridTime(t, s);
    DrawFootLabel(g, f, x, s);
    Inc(k);
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
    v^.x := f.x0 + (x + 0.5) * f.colW; v^.y := f.yCent;
    v^.r := r; v^.g := gr; v^.b := b; v^.a := 0.04;
    Inc(v);
    v^.x := f.x0 + (x + 0.5) * f.colW; v^.y := ToY(maxs[x]);
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
  syncOn: Boolean;
begin
  trig := Round(ClampParam(PARAM_RETRIG, GetParam(g^.inst, PARAM_RETRIG)));
  syncOn := GetParam(g^.inst, PARAM_SYNC) >= 0.5;
  if syncOn then
  begin
    { in bars whenever sync is on, even before the host's tempo is known }
    i := Round(ClampParam(PARAM_SYNC_LEN, GetParam(g^.inst, PARAM_SYNC_LEN)));
    if f.vi.sync then i := f.vi.syncLen;
    s := SyncLenNames[i];
    if f.vi.sweep and (f.vi.zoomSpan < 0.999) then
    begin
      Str((1 / f.vi.zoomSpan): 0: 1, seg[ST_LEN]);
      s := s + ' x' + seg[ST_LEN];
    end;
  end
  else
    FormatTime(f.viewMs, s);
  seg[ST_LEN] := 'len ' + s;
  FormatDb(f.vzoom, s);
  seg[ST_RANGE] := 'range ' + s;
  seg[ST_TRIG] := 'trig ' + TrigNamesS[trig];
  seg[ST_SYNC] := 'sync';
  seg[ST_SPLIT] := 'split';
  { only once the host has processed a block: before that the tempo is
    simply not known yet }
  if syncOn and (not f.vi.sync) and (g^.inst^.syncSeq <> 0) then
    seg[ST_SYNC] := 'sync (no tempo)';

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
    else if ((i = ST_SYNC) and syncOn) or ((i = ST_SPLIT) and f.split) then
      glColor4f(1.0, 1.0, 1.0, 1.0)
    else if (i = ST_SYNC) or (i = ST_SPLIT) or ((i = ST_TRIG) and syncOn) then
      glColor4f(0.6, 0.6, 0.6, 0.7)   { off, or not in effect }
    else
      glColor4f(0.85, 0.85, 0.85, 0.8);
    DrawTextGL(g, x, y, seg[i]);
    x := x + w + gap;
  end;
end;

{ crosshair with level and peak readout; only: 0 = L, 1 = R, -1 = both }
procedure DrawCrosshair(g: PScopeGui; const f: TFrame; only: Integer);
var
  col: Integer;
  peakL, peakR: Single;
  havePeaks: Boolean;
  t: Double;
  bx, by, bw, bh, rowW, gapW: Single;
  s, s2, s3: ShortString;
begin
  { only over the waveform }
  if (f.cursorX < f.x0) or (f.cursorY < f.pTop) or (f.cursorY >= f.pBot) then
    Exit;

  glColor4f(1.0, 1.0, 1.0, 0.30);
  glBegin(GL_LINES);
  glVertex2f(f.cursorX + 0.5, f.pTop); glVertex2f(f.cursorX + 0.5, f.pBot);
  glVertex2f(f.x0, f.cursorY + 0.5); glVertex2f(f.w, f.cursorY + 0.5);
  glEnd;

  FormatPeakDb(Abs(f.yCent - f.cursorY) / f.sc, s);
  if not f.vi.sweep then
  begin
    { time back from the right edge, and the frequency with that period }
    t := f.viewMs * (f.w - f.cursorX) / f.pw;
    FormatTime(t, s2);
    s := s + '  ' + s2;
    if t <= 250 then
    begin
      FormatHz(t, s2);
      s := s + '  ' + s2;
    end;
  end;
  rowW := TextWidth(g, s);
  gapW := TextWidth(g, '  ');
  havePeaks := g^.cols.count > 0;
  if havePeaks then
  begin
    col := ((f.cursorX - f.x0) * g^.cols.count) div f.pw;
    if col > g^.cols.count - 1 then col := g^.cols.count - 1;
    peakL := Abs(g^.cols.minL[col]);
    if Abs(g^.cols.maxL[col]) > peakL then peakL := Abs(g^.cols.maxL[col]);
    peakR := Abs(g^.cols.minR[col]);
    if Abs(g^.cols.maxR[col]) > peakR then peakR := Abs(g^.cols.maxR[col]);
    FormatPeakDb(peakL, s2);
    s2 := 'L ' + s2;
    FormatPeakDb(peakR, s3);
    s3 := 'R ' + s3;
    if only = 0 then s3 := '';
    if only = 1 then s2 := '';
    bw := TextWidth(g, s2) + TextWidth(g, s3);
    if only < 0 then bw := bw + gapW;
    if bw > rowW then rowW := bw;
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
    if only < 0 then bx := bx + TextWidth(g, s2) + gapW;
    glColor4f(1.0, 0.5, 1.0, 0.95);
    DrawTextGL(g, bx + 5 * f.px, by + bh - 5 * f.px, s3);
  end;
end;

{ right side of the header: HOLD, then the buttons }
procedure DrawHeaderButtons(g: PScopeGui; const f: TFrame);
var
  i, hot: Integer;
  x, y, gap, w: Single;
  s: ShortString;
  r: TStatusRect;
  flash: Boolean;
begin
  hot := BT_NONE;
  if f.cursorX >= 0 then
    hot := HeaderButtonAt(g, f.cursorX, f.cursorY);
  flash := (g^.saveT0 <> 0) and (GetTickCount64 - g^.saveT0 < SAVE_FLASH_MS);

  x := f.w - Round(8 * f.px);
  y := 6 * f.px + g^.fontH;
  gap := TextWidth(g, '  ');
  for i := BT_COUNT - 1 downto 0 do
  begin
    w := TextWidth(g, BtnNames[i]);
    x := x - w;
    r.x0 := Round(x - gap * 0.5);
    r.x1 := Round(x + w + gap * 0.5);
    r.y0 := 0;
    r.y1 := Round(y + 6 * f.px);
    g^.btnRects[i] := r;
    s := BtnNames[i];
    if i = hot then
      glColor4f(1.0, 0.85, 0.2, 1.0)
    else
      glColor4f(0.85, 0.85, 0.85, 0.8);
    if (i = BT_SAVE) and flash then
    begin
      { the result takes the button's place for a moment }
      if g^.saveOk then
      begin
        s := 'saved';
        glColor4f(0.5, 1.0, 0.5, 1.0);
      end
      else
      begin
        s := 'failed';
        glColor4f(1.0, 0.3, 0.3, 1.0);
      end;
    end;
    DrawTextGL(g, x + w - TextWidth(g, s), y, s);
    x := x - gap;
  end;

  if GetParam(g^.inst, PARAM_HOLD) >= 0.5 then
  begin
    glColor4f(1.0, 0.3, 0.3, 0.9);
    DrawTextGL(g, x - TextWidth(g, 'HOLD'), y, 'HOLD');
  end;
end;

procedure DrawAbout(g: PScopeGui; const f: TFrame);
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

  { credits, centered }
  ty := f.h * 0.5 - 3.0 * g^.fontH + Sin(aboutT * 2.0) * 3 * f.px;
  for i := 0 to ABOUT_CREDITS - 1 do
  begin
    case i of
      0: glColor4f(1.0, 1.0, 1.0, 0.95);
      2: glColor4f(0.5, 1.0, 0.5, 0.9);
      4: glColor4f(0.62, 0.62, 0.68, 0.85);
    else
      glColor4f(0.8, 0.8, 0.8, 0.9);
    end;
    s := AboutText(i);
    DrawAboutLine(g, i, s, (f.w - AboutLineW(g, i, s)) * 0.5, ty);
    if i < 3 then
      ty := ty + 2.0 * g^.fontH
    else
      ty := ty + 1.6 * g^.fontH;
  end;

  { shortcuts, top-right }
  glColor4f(0.62, 0.62, 0.68, 0.85);
  ty := 20 * f.px + g^.fontH;
  for i := ABOUT_CREDITS to ABOUT_LINES - 1 do
  begin
    s := AboutText(i);
    DrawAboutLine(g, i, s, f.w - AboutLineW(g, i, s) - 16 * f.px, ty);
    ty := ty + 1.6 * g^.fontH;
  end;
end;

procedure RenderFrame(g: PScopeGui; const key: TFrameKey);
var
  f: TFrame;
  edge: ShortString;
  edgeRed: Boolean;
  x: Single;
  nCols: Integer;
begin
  f.w := key.w;
  f.h := key.h;
  if (f.w < 8) or (f.h < 8) then Exit;
  f.px := g^.scale;
  if f.px < 1.0 then f.px := 1.0;
  f.cursorX := key.cursorX;
  f.cursorY := key.cursorY;

  g^.view.zoomStart := key.zoomStart;
  g^.view.zoomSpan := key.zoomSpan;
  if key.zoomSpan <= 0 then
  begin
    g^.view.zoomStart := 0;
    g^.view.zoomSpan := 1;
  end;
  { header, sidebar and footer keep the text off the waveform }
  f.x0 := Round(TextWidth(g, '-60') + 12 * f.px);
  f.pw := f.w - f.x0;
  if f.pw < 2 then f.pw := 2;
  f.pTop := Round(30 * f.px);
  f.pBot := f.h - Round(g^.fontH + 10 * f.px);
  if f.pBot < f.pTop + 20 then f.pBot := f.pTop + 20;
  g^.plot.x0 := f.x0;
  g^.plot.x1 := f.x0 + f.pw;
  g^.plot.y0 := f.pTop;
  g^.plot.y1 := f.pBot;

  { one column per 96-dpi pixel: the trace looks the same at any UI scale }
  nCols := Round(f.pw / f.px);
  if nCols < 2 then nCols := 2;
  f.colW := f.pw / nCols;
  BuildColumns(g^.inst, key.holdOffs, nCols, g^.cols, g^.view, f.vi);
  g^.lastAnchorOffs := f.vi.anchorOffs;
  g^.viewInfo := f.vi;

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

  f.vzoom := ClampParam(PARAM_VZOOM_DB, GetParam(g^.inst, PARAM_VZOOM_DB));
  f.viewMs := ClampParam(PARAM_VIEW_MS, GetParam(g^.inst, PARAM_VIEW_MS));
  if f.vi.sync and (g^.inst^.srate > 0) then
    f.viewMs := f.vi.viewSamples * 1000.0 / g^.inst^.srate;
  f.split := GetParam(g^.inst, PARAM_SPLIT) >= 0.5;
  f.yMid := (f.pTop + f.pBot) div 2;

  edge := '';
  edgeRed := False;
  SetLane(f, 0);
  DrawLevelGrid(g, f, edge, edgeRed);
  if f.split then
  begin
    SetLane(f, 1);
    DrawLevelGrid(g, f, edge, edgeRed);
    { lane border, labelled with the level both lanes have there }
    glColor4f(0.6, 0.6, 0.6, 0.5);
    glBegin(GL_LINES);
    glVertex2f(f.x0, f.yTop + 0.5); glVertex2f(f.w, f.yTop + 0.5);
    glEnd;
    if edge <> '' then
    begin
      if edgeRed then
        glColor4f(0.85, 0.35, 0.35, 0.8)
      else
        glColor4f(0.75, 0.75, 0.75, 0.55);
      DrawLevelLabel(g, f, f.yTop + 0.5, edge);
    end;
  end;
  DrawTimeGrid(g, f);
  if g^.cols.count > 0 then
  begin
    { each channel stays inside its lane }
    glEnable(GL_SCISSOR_TEST);
    SetLane(f, 0);
    glScissor(f.x0, f.h - Round(f.yBot), f.pw, Round(f.yBot - f.yTop));
    DrawChannel(g, g^.cols.minL, g^.cols.maxL, g^.cols.count, f,
      0.5, 1.0, 0.5);               { left:  green }
    SetLane(f, 1);
    glScissor(f.x0, f.h - Round(f.yBot), f.pw, Round(f.yBot - f.yTop));
    DrawChannel(g, g^.cols.minR, g^.cols.maxR, g^.cols.count, f,
      1.0, 0.5, 1.0);               { right: magenta }
    glDisable(GL_SCISSOR_TEST);
  end;
  if f.split then
  begin
    { lane names, top right of each lane }
    glColor4f(1.0, 1.0, 1.0, 0.75);
    DrawTextGL(g, f.w - 16 * f.px, f.pTop + 8 * f.px + g^.fontH, 'L');
    DrawTextGL(g, f.w - 16 * f.px, f.yMid + 8 * f.px + g^.fontH, 'R');
  end;
  if f.vi.sweep and (f.vi.playhead >= 0) then
  begin
    { playhead }
    x := f.x0 + Round(f.vi.playhead * f.pw) + 0.5;
    glColor4f(1.0, 1.0, 1.0, 0.45);
    glBegin(GL_LINES);
    glVertex2f(x, f.pTop); glVertex2f(x, f.pBot);
    glEnd;
  end;
  DrawStatus(g, f);
  DrawHeaderButtons(g, f);

  if key.about = 0 then
  begin
    if not f.split then
      DrawCrosshair(g, f, -1)
    else
    begin
      { level against the lane under the cursor }
      SetLane(f, Ord(f.cursorY >= f.yMid));
      DrawCrosshair(g, f, Ord(f.cursorY >= f.yMid));
    end;
  end
  else
    DrawAbout(g, f);
end;

{ thread }

procedure MakeFrameKey(g: PScopeGui; out key: TFrameKey);
var
  cx, cy, i: Integer;
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
  key.saveFlash := Ord((g^.saveT0 <> 0) and
    (GetTickCount64 - g^.saveT0 < SAVE_FLASH_MS));
  key.statusDrag := g^.statusDrag;
  key.syncSeq := g^.inst^.syncSeq;
  key.zoomStart := g^.zoomStart;
  key.zoomSpan := g^.zoomSpan;
  key.cursorX := -1;
  key.cursorY := -1;
  if (key.about = 0) and OsCursorPos(g, cx, cy) then
    if (cx >= 0) and (cx < key.w) and (cy >= 0) and (cy < key.h) then
    begin
      key.cursorX := cx;
      key.cursorY := cy;
    end;
end;

function RenderThreadProc(param: Pointer): PtrInt;
var
  g: PScopeGui;
  wasShowing, due: Boolean;
  key: TFrameKey;
  now: QWord;
begin
  Result := 0;
  g := PScopeGui(param);
  { FPC unmasks FPU exceptions per thread; GL drivers can't take that }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow,
    exUnderflow, exPrecision]);
  if not OsRenderBegin(g) then Exit;

  if g^.msaa then
    glEnable(GL_MULTISAMPLE)
  else
  begin
    { no MSAA: smooth the lines }
    glEnable(GL_LINE_SMOOTH);
    glHint(GL_LINE_SMOOTH_HINT, GL_NICEST);
  end;
  SetupPlasma(g);

  wasShowing := False;
  while not g^.stop do
  begin
    if not OsViewShowing(g) then
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
    if due and OsFrameBegin(g) then
    begin
      RenderFrame(g, key);
      OsFrameEnd(g);
      g^.lastKey := key;
      g^.lastDrawTick := now;
      wasShowing := True;
    end
    else
      Sleep(IDLE_POLL_MS);
  end;

  CleanupPlasma(g);
  CleanupAboutTextures(g);
  CleanupAtlas(g);
  OsRenderEnd(g);
end;

end.
