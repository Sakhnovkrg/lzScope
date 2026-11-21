unit scope_gui_text;

{ Text: GDI rasterizes, GL draws textured quads. Render thread only. }

{$mode objfpc}{$H+}
{$pointermath on}

interface

uses
  scope_gui_types;

procedure BuildAtlas(g: PScopeGui; heightPx: Integer);
procedure CleanupAtlas(g: PScopeGui);
{ (x, y) = baseline; set the color first }
procedure DrawTextGL(g: PScopeGui; x, y: Single; const s: ShortString);
function TextWidth(g: PScopeGui; const s: ShortString): Single;

procedure BuildAboutTextures(g: PScopeGui);
procedure CleanupAboutTextures(g: PScopeGui);
function AboutLineW(g: PScopeGui; idx: Integer; const s: ShortString): Single;
{ (x, y) = baseline }
procedure DrawAboutLine(g: PScopeGui; idx: Integer; const s: ShortString;
  x, y: Single);

implementation

uses
  Windows, gl_min, scope_state;

const
  FONT_NAME: PWideChar = 'Consolas';

type
  { memory DC + DIB with a font selected }
  TGdiCanvas = record
    dc: HDC;
    font: HFONT;
    dib: HBITMAP;
    oldFont, oldBmp: HGDIOBJ;
    bits: PByte;
    w, h: Integer;
  end;

function OpenFontDC(var c: TGdiCanvas; heightPx: Integer; bold: Boolean): Boolean;
var
  weight: Integer;
begin
  FillChar(c, SizeOf(c), 0);
  Result := False;
  c.dc := CreateCompatibleDC(0);
  if c.dc = 0 then Exit;
  weight := FW_NORMAL;
  if bold then weight := FW_BOLD;
  c.font := CreateFontW(-heightPx, 0, 0, 0, weight, 0, 0, 0,
    DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
    ANTIALIASED_QUALITY, FIXED_PITCH or FF_DONTCARE, FONT_NAME);
  if c.font = 0 then
  begin
    DeleteDC(c.dc);
    c.dc := 0;
    Exit;
  end;
  c.oldFont := SelectObject(c.dc, c.font);
  Result := True;
end;

function AttachBitmap(var c: TGdiCanvas; w, h: Integer): Boolean;
var
  bi: BITMAPINFO;
  bits: Pointer;
begin
  FillChar(bi{%H-}, SizeOf(bi), 0);
  bi.bmiHeader.biSize := SizeOf(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth := w;
  bi.bmiHeader.biHeight := -h;   { top-down }
  bi.bmiHeader.biPlanes := 1;
  bi.bmiHeader.biBitCount := 32;
  bi.bmiHeader.biCompression := BI_RGB;
  bits := nil;
  c.dib := CreateDIBSection(c.dc, bi, DIB_RGB_COLORS, bits, 0, 0);
  Result := (c.dib <> 0) and (bits <> nil);
  if not Result then Exit;
  c.bits := bits;
  c.w := w;
  c.h := h;
  c.oldBmp := SelectObject(c.dc, c.dib);
  SetBkMode(c.dc, TRANSPARENT);
  SetTextColor(c.dc, $FFFFFF);
end;

procedure CloseCanvas(var c: TGdiCanvas);
begin
  if c.dc = 0 then Exit;
  if c.oldBmp <> 0 then SelectObject(c.dc, c.oldBmp);
  if c.oldFont <> 0 then SelectObject(c.dc, c.oldFont);
  if c.dib <> 0 then DeleteObject(c.dib);
  if c.font <> 0 then DeleteObject(c.font);
  DeleteDC(c.dc);
  c.dc := 0;
end;

{ white texture, coverage as alpha; 0 on failure }
function UploadCanvas(var c: TGdiCanvas): DWORD;
var
  buf: PByte;
  i: Integer;
begin
  Result := 0;
  GdiFlush;
  buf := GetMem(c.w * c.h * 4);
  if buf = nil then Exit;
  for i := 0 to c.w * c.h - 1 do
  begin
    buf[i * 4 + 0] := 255;
    buf[i * 4 + 1] := 255;
    buf[i * 4 + 2] := 255;
    buf[i * 4 + 3] := c.bits[i * 4 + 1];
  end;
  glGenTextures(1, @Result);
  glBindTexture(GL_TEXTURE_2D, Result);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, c.w, c.h, 0, GL_RGBA,
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
  c: TGdiCanvas;
  tm: TEXTMETRICA;
  sz: Windows.TSize;
  ch: AnsiChar;
  i, maxAdv: Integer;
begin
  CleanupAtlas(g);
  g^.fontH := heightPx;   { also on failure: no retry every frame }
  if not OpenFontDC(c, heightPx, False) then Exit;

  GetTextMetricsA(c.dc, @tm);
  maxAdv := 1;
  for i := 0 to ATLAS_COUNT - 1 do
  begin
    ch := AnsiChar(ATLAS_FIRST + i);
    sz.cx := 0;
    GetTextExtentPoint32A(c.dc, @ch, 1, @sz);
    g^.atlas.adv[i] := sz.cx;
    if sz.cx > maxAdv then maxAdv := sz.cx;
  end;
  { 1 px padding against filter bleed }
  g^.atlas.cellW := maxAdv + 2;
  g^.atlas.cellH := tm.tmHeight + 2;
  g^.atlas.ascent := tm.tmAscent + 1;
  g^.atlas.texW := ATLAS_COLS * g^.atlas.cellW;
  g^.atlas.texH := ((ATLAS_COUNT + ATLAS_COLS - 1) div ATLAS_COLS) * g^.atlas.cellH;

  if AttachBitmap(c, g^.atlas.texW, g^.atlas.texH) then
  begin
    for i := 0 to ATLAS_COUNT - 1 do
    begin
      ch := AnsiChar(ATLAS_FIRST + i);
      TextOutA(c.dc, (i mod ATLAS_COLS) * g^.atlas.cellW + 1,
        (i div ATLAS_COLS) * g^.atlas.cellH + 1, @ch, 1);
    end;
    g^.atlas.tex := UploadCanvas(c);
  end;
  CloseCanvas(c);
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

procedure BuildTextTexture(g: PScopeGui; const s: AnsiString; bold: Boolean;
  var t: TTextTex);
var
  c: TGdiCanvas;
  sz: Windows.TSize;
  tm: TEXTMETRICA;
begin
  t.tex := 0;
  if not OpenFontDC(c, g^.fontH, bold) then Exit;
  sz.cx := 0;
  sz.cy := 0;
  GetTextExtentPoint32A(c.dc, PAnsiChar(s), Length(s), @sz);
  GetTextMetricsA(c.dc, @tm);
  if AttachBitmap(c, sz.cx + 2, sz.cy + 2) then
  begin
    TextOutA(c.dc, 1, 1, PAnsiChar(s), Length(s));
    t.tex := UploadCanvas(c);
    t.w := c.w;
    t.h := c.h;
    t.ascent := tm.tmAscent + 1;   { +1 = padding row }
  end;
  CloseCanvas(c);
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
  BuildTextTexture(g, 'drag len/range ....... adjust', False, g^.aboutTex[10]);
  BuildTextTexture(g, 'double-click .......... reset', False, g^.aboutTex[11]);
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
