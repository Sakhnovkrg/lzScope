unit scope_view;

{ Turns the ring buffer into per-pixel min/max columns: retrigger
  search, hold offset, anchor tracking. No GL/WinAPI here on purpose —
  this part ports to other platforms as-is.

  Runs on the render thread, reads the buffer under inst^.lock. }

{$mode objfpc}{$H+}
{$pointermath on}

interface

uses
  scope_state;

const
  MAX_COLS = 8192;

type
  TColumns = record
    count: Integer;
    minL, maxL, minR, maxR: array[0..MAX_COLS - 1] of Single;
  end;

{ anchorOffs = how far (samples) the view's right edge is behind the
  newest sample; engaging hold with it freezes the exact current view }
procedure BuildColumns(inst: PScopeInstance; holdOffs: Double;
  colCount: Integer; var cols: TColumns; out anchorOffs: Double);

implementation

{ trigger source is the left channel only (CH1 style); triggering on
  both channels never stabilizes on uncorrelated material }
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

procedure BuildColumns(inst: PScopeInstance; holdOffs: Double;
  colCount: Integer; var cols: TColumns; out anchorOffs: Double);
var
  hs, idx: UInt32;
  endIdx, origEnd, base: Int64;
  viewSamples, searchLimit, retrig, pos, x, i, i0, i1: Integer;
  viewMs: Double;
  vL, vR, mnL, mxL, mnR, mxR: Single;
  newL, oldL: Single;
begin
  cols.count := 0;
  anchorOffs := 0;
  if colCount > MAX_COLS then colCount := MAX_COLS;
  if colCount < 1 then Exit;

  System.EnterCriticalSection(inst^.lock);
  try
    hs := inst^.histSize;
    if (inst^.bufL = nil) or (hs < 64) then
      Exit;

    viewMs := ClampParam(PARAM_VIEW_MS, inst^.params[PARAM_VIEW_MS]);
    viewSamples := Round(viewMs * 0.001 * inst^.srate);
    if viewSamples < 16 then viewSamples := 16;
    if viewSamples > Integer(hs div 2) then viewSamples := Integer(hs div 2);

    { newest written frame }
    endIdx := Int64(inst^.writePos) + Int64(hs) - 1;
    origEnd := endIdx;

    if inst^.params[PARAM_HOLD] >= 0.5 then
    begin
      { holding: scroll instead of triggering }
      pos := Round(holdOffs);
      if pos < 0 then pos := 0;
      if Int64(pos) > Int64(hs) - viewSamples - 1 then
        pos := Integer(Int64(hs) - viewSamples - 1);
      endIdx := endIdx - pos;
    end
    else
    begin
      { retrigger: end the view at the most recent zero crossing;
        search up to 100 ms past the window so short views of low
        frequencies still lock }
      retrig := Round(inst^.params[PARAM_RETRIG]);
      if (retrig >= RETRIG_ANY) and (retrig <= RETRIG_DESC) then
      begin
        searchLimit := viewSamples + Round(inst^.srate * 0.1);
        if searchLimit > Integer(hs div 2) then
          searchLimit := Integer(hs div 2);
        idx := UInt32(endIdx mod hs);
        newL := inst^.bufL[idx];
        for pos := 1 to searchLimit - 1 do
        begin
          if idx = 0 then idx := hs - 1 else Dec(idx);
          oldL := inst^.bufL[idx];
          if IsCrossing(retrig, oldL, newL) then
          begin
            endIdx := endIdx - pos + 1;
            Break;
          end;
          newL := oldL;
        end;
      end;
    end;

    anchorOffs := origEnd - endIdx;

    base := endIdx - viewSamples + 1;
    while base < 0 do
      base := base + hs;

    for x := 0 to colCount - 1 do
    begin
      i0 := (Int64(x) * viewSamples) div colCount;
      i1 := (Int64(x + 1) * viewSamples) div colCount;
      if i1 <= i0 then i1 := i0 + 1;

      idx := UInt32((base + i0) mod hs);
      mnL := inst^.bufL[idx]; mxL := mnL;
      mnR := inst^.bufR[idx]; mxR := mnR;
      for i := i0 + 1 to i1 - 1 do
      begin
        { incremental wrap, no `mod`: this loop is the hot path }
        Inc(idx);
        if idx >= hs then idx := 0;
        vL := inst^.bufL[idx];
        vR := inst^.bufR[idx];
        if vL < mnL then mnL := vL;
        if vL > mxL then mxL := vL;
        if vR < mnR then mnR := vR;
        if vR > mxR then mxR := vR;
      end;
      cols.minL[x] := mnL; cols.maxL[x] := mxL;
      cols.minR[x] := mnR; cols.maxR[x] := mxR;
    end;
    cols.count := colCount;
  finally
    System.LeaveCriticalSection(inst^.lock);
  end;
end;

end.
