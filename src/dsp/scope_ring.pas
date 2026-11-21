unit scope_ring;

{ Capture ring: one writer (audio thread), lock-free readers.
  Readers check RingSpanValid after reading and retry. }

{$mode objfpc}{$H+}
{$pointermath on}

{$ifndef CPU64}
  {$fatal lzScope relies on atomic 64-bit loads and stores}
{$endif}

interface

const
  { max frames the writer holds unpublished }
  RING_CHUNK = 256;
  { frames per min/max block }
  PYR_BLOCK = 64;

type
  TMinMax = record
    mnL, mxL, mnR, mxR: Single;
  end;
  PMinMax = ^TMinMax;

  PScopeRing = ^TScopeRing;
  TScopeRing = record
    bufL, bufR: PSingle;
    pyr: PMinMax;           { min/max per block }
    size: UInt32;           { frames, 0 = none }
    framesWritten: Int64;   { atomic }
    validFrom: Int64;       { atomic; older frames are silence }
    pyrDone: Int64;         { writer only }
  end;

{ False = out of memory }
function RingAlloc(var r: TScopeRing; frames: UInt32): Boolean;
procedure RingFree(var r: TScopeRing);

procedure RingWrite(var r: TScopeRing; srcL, srcR: PSingle; n: UInt32);
procedure RingClear(var r: TScopeRing);

function RingWritten(const r: TScopeRing): Int64;
function RingValidFrom(const r: TScopeRing): Int64;
{ True if frames [oldest, w1) were not overwritten while reading }
function RingSpanValid(const r: TScopeRing; w1, w2, oldest: Int64): Boolean;
{ min/max over frames [a0, a1) }
procedure RingMinMax(const r: TScopeRing; a0, a1: Int64; out mm: TMinMax);

implementation

function RingAlloc(var r: TScopeRing; frames: UInt32): Boolean;
begin
  RingFree(r);
  frames := ((frames + PYR_BLOCK - 1) div PYR_BLOCK) * PYR_BLOCK;
  Result := False;
  if frames = 0 then Exit;
  r.bufL := GetMem(PtrUInt(frames) * SizeOf(Single));
  r.bufR := GetMem(PtrUInt(frames) * SizeOf(Single));
  r.pyr := GetMem(PtrUInt(frames div PYR_BLOCK) * SizeOf(TMinMax));
  if (r.bufL = nil) or (r.bufR = nil) or (r.pyr = nil) then
  begin
    RingFree(r);
    Exit;
  end;
  r.size := frames;
  Result := True;
end;

procedure RingFree(var r: TScopeRing);
begin
  r.size := 0;
  if r.bufL <> nil then FreeMem(r.bufL);
  if r.bufR <> nil then FreeMem(r.bufR);
  if r.pyr <> nil then FreeMem(r.pyr);
  r.bufL := nil;
  r.bufR := nil;
  r.pyr := nil;
  r.pyrDone := 0;
  InterlockedExchange64(r.validFrom, 0);
  InterlockedExchange64(r.framesWritten, 0);
end;

procedure SummarizeBlock(var r: TScopeRing; blk: Int64);
var
  i: Integer;
  pL, pR: PSingle;
  mm: TMinMax;
  v: Single;
begin
  pL := r.bufL + (blk * PYR_BLOCK) mod r.size;
  pR := r.bufR + (blk * PYR_BLOCK) mod r.size;
  mm.mnL := pL[0]; mm.mxL := mm.mnL;
  mm.mnR := pR[0]; mm.mxR := mm.mnR;
  for i := 1 to PYR_BLOCK - 1 do
  begin
    v := pL[i];
    if v < mm.mnL then mm.mnL := v;
    if v > mm.mxL then mm.mxL := v;
    v := pR[i];
    if v < mm.mnR then mm.mnR := v;
    if v > mm.mxR then mm.mxR := v;
  end;
  r.pyr[blk mod (r.size div PYR_BLOCK)] := mm;
end;

procedure RingWrite(var r: TScopeRing; srcL, srcR: PSingle; n: UInt32);
var
  total: Int64;
  wp, done, chunkEnd, i: UInt32;
begin
  if (r.size = 0) or (n = 0) then Exit;
  total := r.framesWritten;
  wp := UInt32(total mod r.size);
  done := 0;
  while done < n do
  begin
    chunkEnd := done + RING_CHUNK;
    if chunkEnd > n then chunkEnd := n;
    for i := done to chunkEnd - 1 do
    begin
      r.bufL[wp] := srcL[i];
      r.bufR[wp] := srcR[i];
      Inc(wp);
      if wp >= r.size then wp := 0;
    end;
    Inc(total, chunkEnd - done);
    done := chunkEnd;
    while (r.pyrDone + 1) * PYR_BLOCK <= total do
    begin
      SummarizeBlock(r, r.pyrDone);
      Inc(r.pyrDone);
    end;
    { publish after the data is stored }
    InterlockedExchange64(r.framesWritten, total);
  end;
end;

procedure RingClear(var r: TScopeRing);
begin
  InterlockedExchange64(r.validFrom, r.framesWritten);
end;

function RingWritten(const r: TScopeRing): Int64;
begin
  ReadWriteBarrier;
  Result := r.framesWritten;
  ReadWriteBarrier;
end;

function RingValidFrom(const r: TScopeRing): Int64;
begin
  ReadWriteBarrier;
  Result := r.validFrom;
  ReadWriteBarrier;
end;

function RingSpanValid(const r: TScopeRing; w1, w2, oldest: Int64): Boolean;
begin
  { the writer may be up to RING_CHUNK frames ahead of w2 }
  Result := (w2 >= w1) and (oldest >= w2 + RING_CHUNK - Int64(r.size));
end;

procedure ScanRange(const r: TScopeRing; a0, a1: Int64; var mm: TMinMax); inline;
var
  idx: UInt32;
  a: Int64;
  v: Single;
begin
  if a0 >= a1 then Exit;
  idx := UInt32(a0 mod r.size);
  for a := a0 to a1 - 1 do
  begin
    v := r.bufL[idx];
    if v < mm.mnL then mm.mnL := v;
    if v > mm.mxL then mm.mxL := v;
    v := r.bufR[idx];
    if v < mm.mnR then mm.mnR := v;
    if v > mm.mxR then mm.mxR := v;
    Inc(idx);
    if idx >= r.size then idx := 0;
  end;
end;

procedure RingMinMax(const r: TScopeRing; a0, a1: Int64; out mm: TMinMax);
var
  idx, slots: UInt32;
  b, b0, b1: Int64;
  p: PMinMax;
begin
  idx := UInt32(a0 mod r.size);
  mm.mnL := r.bufL[idx]; mm.mxL := mm.mnL;
  mm.mnR := r.bufR[idx]; mm.mxR := mm.mnR;
  Inc(a0);

  b0 := (a0 + PYR_BLOCK - 1) div PYR_BLOCK;   { first whole block }
  b1 := a1 div PYR_BLOCK;                     { one past the last }
  if b1 <= b0 then
  begin
    ScanRange(r, a0, a1, mm);
    Exit;
  end;

  ScanRange(r, a0, b0 * PYR_BLOCK, mm);
  slots := r.size div PYR_BLOCK;
  idx := UInt32(b0 mod slots);
  for b := b0 to b1 - 1 do
  begin
    p := @r.pyr[idx];
    if p^.mnL < mm.mnL then mm.mnL := p^.mnL;
    if p^.mxL > mm.mxL then mm.mxL := p^.mxL;
    if p^.mnR < mm.mnR then mm.mnR := p^.mnR;
    if p^.mxR > mm.mxR then mm.mxR := p^.mxR;
    Inc(idx);
    if idx >= slots then idx := 0;
  end;
  ScanRange(r, b1 * PYR_BLOCK, a1, mm);
end;

end.
