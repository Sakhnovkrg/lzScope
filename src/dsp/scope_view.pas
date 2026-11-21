unit scope_view;

{ Turns the ring into per-pixel min/max columns: trigger, hold, anchor. No GL/WinAPI. }

{$mode objfpc}{$H+}
{$pointermath on}

interface

uses
  scope_ring, scope_state;

const
  MAX_COLS = 8192;

type
  TColumns = record
    count: Integer;
    minL, maxL, minR, maxR: array[0..MAX_COLS - 1] of Single;
  end;

{ anchorOffs = samples between the right edge and the newest sample.
  cols.count = 0: nothing to draw. }
procedure BuildColumns(inst: PScopeInstance; holdOffs: Double;
  colCount: Integer; var cols: TColumns; out anchorOffs: Double);

function ViewSampleCount(inst: PScopeInstance): Integer;
{ largest usable hold offset }
function HoldReach(inst: PScopeInstance; viewSamples, colCount: Integer): Int64;

implementation

const
  SNAPSHOT_TRIES = 4;

function FloorDiv(a, b: Int64): Int64; inline;
begin
  Result := a div b;
  if (a < 0) and (Result * b <> a) then Dec(Result);
end;

function ViewSamplesFor(const r: TScopeRing; srate, viewMs: Double): Integer;
begin
  Result := Round(ClampParam(PARAM_VIEW_MS, viewMs) * 0.001 * srate);
  if Result < 16 then Result := 16;
  if Result > Integer(r.size div 2) then Result := Integer(r.size div 2);
end;

function ReachFor(const r: TScopeRing; viewSamples, colCount: Integer): Int64;
begin
  if colCount < 1 then colCount := 1;
  { stay out of the writer's chunk, plus one column of slack }
  Result := Int64(r.size) - viewSamples - 1 - RING_CHUNK -
    (viewSamples div colCount + 1);
  if Result < 0 then Result := 0;
end;

function ViewSampleCount(inst: PScopeInstance): Integer;
begin
  if inst^.ring.size = 0 then Exit(0);
  Result := ViewSamplesFor(inst^.ring, inst^.srate,
    GetParam(inst, PARAM_VIEW_MS));
end;

function HoldReach(inst: PScopeInstance; viewSamples, colCount: Integer): Int64;
begin
  if inst^.ring.size = 0 then Exit(0);
  Result := ReachFor(inst^.ring, viewSamples, colCount);
end;

{ trigger on the left channel only }
function IsCrossing(mode: Integer; oldL, newL: Single): Boolean; inline;
begin
  case mode of
    RETRIG_ASC:
      Result := (oldL < 0) and (newL >= 0);
    RETRIG_DESC:
      Result := (oldL > 0) and (newL <= 0);
  else { RETRIG_ANY }
    Result := (oldL < 0) <> (newL < 0);
  end;
end;

{ -1 / 0 / +1 }
function SignClass(v: Single): Integer; inline;
begin
  if v < 0 then Result := -1
  else if v > 0 then Result := 1
  else Result := 0;
end;

{ most recent crossing walking back from start to low; one-sided blocks are skipped }
function FindCrossing(const r: TScopeRing; mode: Integer; start, low: Int64;
  out crossAt: Int64): Boolean;
var
  a: Int64;
  newL, oldL: Single;
  p: PMinMax;
  cls: Integer;
begin
  Result := False;
  crossAt := start;
  if start < low then Exit;
  a := start;
  newL := r.bufL[a mod r.size];
  while a > low do
  begin
    if (a mod PYR_BLOCK = 0) and (a - PYR_BLOCK >= low) then
    begin
      p := @r.pyr[(a div PYR_BLOCK - 1) mod (r.size div PYR_BLOCK)];
      cls := SignClass(newL);
      if ((cls < 0) and (p^.mxL < 0)) or ((cls > 0) and (p^.mnL > 0)) or
         ((cls = 0) and (p^.mnL = 0) and (p^.mxL = 0)) then
      begin
        Dec(a, PYR_BLOCK);
        newL := r.bufL[a mod r.size];
        Continue;
      end;
    end;
    oldL := r.bufL[(a - 1) mod r.size];
    if IsCrossing(mode, oldL, newL) then
    begin
      crossAt := a;
      Exit(True);
    end;
    newL := oldL;
    Dec(a);
  end;
end;

{ one pass; returns the oldest frame read }
function ScanColumns(inst: PScopeInstance; const r: TScopeRing;
  written, validFrom: Int64; holdOffs: Double; colCount: Integer;
  var cols: TColumns; out anchorOffs: Double): Int64;
var
  endAbs, base, reach, low, crossAt, kBase, c0, c1, lo: Int64;
  viewSamples, searchLimit, retrig, x: Integer;
  pos: Int64;
  useGrid: Boolean;
  mm: TMinMax;
begin
  Result := written;

  viewSamples := ViewSamplesFor(r, inst^.srate, GetParam(inst, PARAM_VIEW_MS));
  reach := ReachFor(r, viewSamples, colCount);
  endAbs := written - 1;
  useGrid := viewSamples > colCount;

  if GetParam(inst, PARAM_HOLD) >= 0.5 then
  begin
    { holding: scroll }
    pos := Round(holdOffs);
    if pos < 0 then pos := 0;
    if pos > reach then pos := reach;
    endAbs := endAbs - pos;
  end
  else
  begin
    { end the view at the most recent crossing }
    retrig := Round(GetParam(inst, PARAM_RETRIG));
    if (retrig >= RETRIG_ANY) and (retrig <= RETRIG_DESC) then
    begin
      searchLimit := viewSamples + Round(inst^.srate * 0.1);
      if searchLimit > Integer(r.size div 2) then
        searchLimit := Integer(r.size div 2);
      if Int64(searchLimit) > reach then
        searchLimit := Integer(reach);
      low := endAbs - (searchLimit - 1);
      if low < validFrom then low := validFrom;
      if low <= endAbs then
      begin
        Result := low;
        if FindCrossing(r, retrig, endAbs, low, crossAt) then
        begin
          endAbs := crossAt;
          useGrid := False;
        end;
      end;
    end;
  end;

  kBase := 0;
  if useGrid then
  begin
    { snap columns to a fixed sample grid so min/max does not shimmer }
    kBase := FloorDiv((endAbs + 2) * colCount - 1, viewSamples);
    endAbs := FloorDiv(kBase * viewSamples, colCount) - 1;
    kBase := kBase - colCount;
  end;
  base := endAbs - viewSamples + 1;
  anchorOffs := (written - 1) - endAbs;

  lo := base;
  if lo < validFrom then lo := validFrom;
  if lo < Result then Result := lo;

  for x := 0 to colCount - 1 do
  begin
    if useGrid then
    begin
      c0 := FloorDiv((kBase + x) * viewSamples, colCount);
      c1 := FloorDiv((kBase + x + 1) * viewSamples, colCount);
    end
    else
    begin
      c0 := base + (Int64(x) * viewSamples) div colCount;
      c1 := base + (Int64(x + 1) * viewSamples) div colCount;
    end;
    { fewer samples than pixels: steps }
    if c1 <= c0 then c1 := c0 + 1;

    lo := c0;
    if lo < validFrom then lo := validFrom;
    if lo >= c1 then
    begin
      cols.minL[x] := 0; cols.maxL[x] := 0;
      cols.minR[x] := 0; cols.maxR[x] := 0;
      Continue;
    end;
    RingMinMax(r, lo, c1, mm);
    if c0 < validFrom then
    begin
      { partly cleared column: include silence }
      if mm.mnL > 0 then mm.mnL := 0;
      if mm.mxL < 0 then mm.mxL := 0;
      if mm.mnR > 0 then mm.mnR := 0;
      if mm.mxR < 0 then mm.mxR := 0;
    end;
    cols.minL[x] := mm.mnL; cols.maxL[x] := mm.mxL;
    cols.minR[x] := mm.mnR; cols.maxR[x] := mm.mxR;
  end;
end;

procedure BuildColumns(inst: PScopeInstance; holdOffs: Double;
  colCount: Integer; var cols: TColumns; out anchorOffs: Double);
var
  w1, w2, validFrom, oldest: Int64;
  attempt: Integer;
begin
  cols.count := 0;
  anchorOffs := 0;
  if colCount > MAX_COLS then colCount := MAX_COLS;
  if colCount < 2 then Exit;

  System.EnterCriticalSection(inst^.lock);
  try
    if inst^.ring.size < 4 * RING_CHUNK then
      Exit;

    for attempt := 1 to SNAPSHOT_TRIES do
    begin
      validFrom := RingValidFrom(inst^.ring);
      w1 := RingWritten(inst^.ring);
      oldest := ScanColumns(inst, inst^.ring, w1, validFrom, holdOffs,
        colCount, cols, anchorOffs);
      w2 := RingWritten(inst^.ring);
      if RingSpanValid(inst^.ring, w1, w2, oldest) then
      begin
        cols.count := colCount;
        Exit;
      end;
    end;
    anchorOffs := 0;
  finally
    System.LeaveCriticalSection(inst^.lock);
  end;
end;

end.
