unit scope_gui_text;

{ Text: the platform rasterizes, GL draws textured quads. Render thread only. }

{$mode objfpc}{$H+}
{$pointermath on}

interface

uses
  scope_gui_types;

const
  ABOUT_CREDITS = 5;   { about lines before the shortcuts }

procedure BuildAtlas(g: PScopeGui; heightPx: Integer);
procedure CleanupAtlas(g: PScopeGui);
{ (x, y) = baseline; set the color first }
procedure DrawTextGL(g: PScopeGui; x, y: Single; const s: ShortString);
function TextWidth(g: PScopeGui; const s: ShortString): Single;

function AboutText(idx: Integer): ShortString;
procedure BuildAboutTextures(g: PScopeGui);
procedure CleanupAboutTextures(g: PScopeGui);
function AboutLineW(g: PScopeGui; idx: Integer; const s: ShortString): Single;
{ (x, y) = baseline }
procedure DrawAboutLine(g: PScopeGui; idx: Integer; const s: ShortString;
  x, y: Single);

implementation

uses
  gl_min, scope_state, scope_gui_os;

{ white texture, coverage as alpha; 0 on failure }
function UploadCoverage(t: TOsText; w, h: Integer): DWord;
var
  cov, buf: PByte;
  i: Integer;
begin
  Result := 0;
  cov := OsTextCoverage(t);
  if cov = nil then Exit;
  buf := GetMem(w * h * 4);
  if buf = nil then Exit;
  for i := 0 to w * h - 1 do
  begin
    buf[i * 4 + 0] := 255;
    buf[i * 4 + 1] := 255;
    buf[i * 4 + 2] := 255;
    buf[i * 4 + 3] := cov[i];
  end;
  glGenTextures(1, @Result);
  glBindTexture(GL_TEXTURE_2D, Result);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA,
    GL_UNSIGNED_BYTE, buf);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  FreeMem(buf);
end;

{ glyph atlas }

procedure CleanupAtlas(g: PScopeGui);
begin
  if g^.atlas.tex <> 0 then
    glDeleteTextures(1, @g^.atlas.tex);
  FillChar(g^.atlas, SizeOf(g^.atlas), 0);
end;

procedure BuildAtlas(g: PScopeGui; heightPx: Integer);
var
  t: TOsText;
  ch: AnsiString;
  i, maxAdv, ascent, height: Integer;
begin
  CleanupAtlas(g);
  g^.fontH := heightPx;   { also on failure: no retry every frame }
  t := OsTextOpen(heightPx, False);
  if t = nil then Exit;

  OsTextMetrics(t, ascent, height);
  maxAdv := 1;
  for i := 0 to ATLAS_COUNT - 1 do
  begin
    ch := AnsiChar(ATLAS_FIRST + i);
    g^.atlas.adv[i] := OsTextWidth(t, ch);
    if g^.atlas.adv[i] > maxAdv then maxAdv := g^.atlas.adv[i];
  end;
  { 1 px padding against filter bleed }
  g^.atlas.cellW := maxAdv + 2;
  g^.atlas.cellH := height + 2;
  g^.atlas.ascent := ascent + 1;
  g^.atlas.texW := ATLAS_COLS * g^.atlas.cellW;
  g^.atlas.texH := ((ATLAS_COUNT + ATLAS_COLS - 1) div ATLAS_COLS) * g^.atlas.cellH;

  if OsTextCanvas(t, g^.atlas.texW, g^.atlas.texH) then
  begin
    for i := 0 to ATLAS_COUNT - 1 do
      OsTextDraw(t, (i mod ATLAS_COLS) * g^.atlas.cellW + 1,
        (i div ATLAS_COLS) * g^.atlas.cellH + 1, AnsiChar(ATLAS_FIRST + i));
    g^.atlas.tex := UploadCoverage(t, g^.atlas.texW, g^.atlas.texH);
  end;
  OsTextClose(t);
end;

function TextWidth(g: PScopeGui; const s: ShortString): Single;
var
  i, c, w: Integer;
begin
  w := 0;
  for i := 1 to Length(s) do
  begin
    c := Ord(s[i]) - ATLAS_FIRST;
    if (c < 0) or (c >= ATLAS_COUNT) then c := 0;
    Inc(w, g^.atlas.adv[c]);
  end;
  Result := w;
end;

procedure DrawTextGL(g: PScopeGui; x, y: Single; const s: ShortString);
var
  i, c: Integer;
  px, py, u0, v0, du, dv: Single;
begin
  if (g^.atlas.tex = 0) or (Length(s) = 0) then Exit;
  { whole pixels keep the glyphs sharp }
  px := Round(x);
  py := Round(y) - g^.atlas.ascent;
  du := g^.atlas.cellW / g^.atlas.texW;
  dv := g^.atlas.cellH / g^.atlas.texH;
  glEnable(GL_TEXTURE_2D);
  glBindTexture(GL_TEXTURE_2D, g^.atlas.tex);
  glBegin(GL_QUADS);
  for i := 1 to Length(s) do
  begin
    c := Ord(s[i]) - ATLAS_FIRST;
    if (c < 0) or (c >= ATLAS_COUNT) then c := 0;
    if c <> 0 then   { space }
    begin
      u0 := (c mod ATLAS_COLS) * du;
      v0 := (c div ATLAS_COLS) * dv;
      glTexCoord2f(u0, v0);           glVertex2f(px, py);
      glTexCoord2f(u0 + du, v0);      glVertex2f(px + g^.atlas.cellW, py);
      glTexCoord2f(u0 + du, v0 + dv); glVertex2f(px + g^.atlas.cellW, py + g^.atlas.cellH);
      glTexCoord2f(u0, v0 + dv);      glVertex2f(px, py + g^.atlas.cellH);
    end;
    px := px + g^.atlas.adv[c];
  end;
  glEnd;
  glDisable(GL_TEXTURE_2D);
end;

{ about overlay lines }

{ "keys ...... action", lined up on the right }
function ShortcutLine(const keys, action: ShortString): ShortString;
const
  WIDTH = 29;
begin
  Result := keys + ' ';
  while Length(Result) < WIDTH - Length(action) - 1 do
    Result := Result + '.';
  Result := Result + ' ' + action;
end;

function AboutText(idx: Integer): ShortString;
begin
  case idx of
    0: Result := 'lzScope v' + PLUGIN_VERSION;
    1: Result := 'created by ' + PLUGIN_AUTHOR;
    2: Result := PLUGIN_URL;
    3: Result := 'built with Free Pascal & Lazarus';
    4: Result := 'inspired by the Cockos JSFX Oscilloscope Meter';
    5: Result := ShortcutLine('wheel', 'time zoom');
    6: Result := ShortcutLine(OS_VZOOM_KEY + '+wheel', 'v-zoom');
    7: Result := ShortcutLine('click', 'hold');
    8: Result := ShortcutLine('drag while hold', 'scrub');
    9: Result := ShortcutLine('right-click', 'trigger mode');
    10: Result := ShortcutLine('drag len/range', 'adjust');
    11: Result := ShortcutLine('double-click', 'reset');
  else
    Result := '';
  end;
end;

procedure BuildTextTexture(g: PScopeGui; const s: AnsiString; bold: Boolean;
  var tt: TTextTex);
var
  t: TOsText;
  ascent, height, w: Integer;
begin
  tt.tex := 0;
  t := OsTextOpen(g^.fontH, bold);
  if t = nil then Exit;
  OsTextMetrics(t, ascent, height);
  w := OsTextWidth(t, s);
  if OsTextCanvas(t, w + 2, height + 2) then
  begin
    OsTextDraw(t, 1, 1, s);
    tt.tex := UploadCoverage(t, w + 2, height + 2);
    tt.w := w + 2;
    tt.h := height + 2;
    tt.ascent := ascent + 1;   { +1 = padding row }
  end;
  OsTextClose(t);
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
var
  i: Integer;
begin
  if g^.aboutTexFontH = g^.fontH then Exit;
  CleanupAboutTextures(g);
  for i := 0 to ABOUT_LINES - 1 do
    BuildTextTexture(g, AboutText(i), i = 0, g^.aboutTex[i]);
  g^.aboutTexFontH := g^.fontH;
end;

function AboutLineW(g: PScopeGui; idx: Integer; const s: ShortString): Single;
begin
  if g^.aboutTex[idx].tex <> 0 then
    Result := g^.aboutTex[idx].w
  else
    Result := TextWidth(g, s);
end;

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

end.
