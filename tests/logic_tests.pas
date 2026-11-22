unit logic_tests;

{ Tests for the core (ring, view, params): no dll, no window }

{$mode objfpc}{$H+}
{$packrecords c}
{$pointermath on}

interface

procedure RunLogicTests;
procedure RunStressTest;

implementation

uses
  SysUtils, clap_api, scope_ring, scope_state, scope_dsp, scope_view;

const
  SRATE = 1000.0;   { ~10 000 frames of history }

var
  Inst: TScopeInstance;
  RefL, RefR: array of Single;
  RefCount: Int64 = 0;
  ColsA, ColsB: TColumns;
  Seed: UInt32 = 12345;

procedure Fail(const msg: string);
begin
  WriteLn('FAIL: ', msg);
  Halt(1);
end;

procedure Check(cond: Boolean; const msg: string);
begin
  if not cond then Fail(msg);
end;

function Rnd: UInt32;
begin
  Seed := Seed * 1664525 + 1013904223;
  Result := Seed shr 8;
end;

{ uniform in [-1, 1) }
function RndSample: Single;
begin
  Result := Integer(Rnd mod 20001 - 10000) / 10000.0;
end;

procedure NewInstance(rate: Double);
begin
  FillChar(Inst, SizeOf(Inst), 0);
  System.InitCriticalSection(Inst.lock);
  ResetParams(@Inst);
  Check(ScopeConfigure(@Inst, rate), 'ScopeConfigure');
  SetLength(RefL, 0);
  SetLength(RefR, 0);
  RefCount := 0;
end;

procedure FreeInstance;
begin
  ScopeReleaseBuffers(@Inst);
  System.DoneCriticalSection(Inst.lock);
end;

type
  TGen = function(a: Int64; right: Boolean): Single;

function GenNoise(a: Int64; right: Boolean): Single;
begin
  Result := RndSample;
end;

function GenSine(a: Int64; right: Boolean): Single;
begin
  Result := Sin(a * 2 * Pi / 37.3);
  if right then Result := -Result;
end;

function GenSilence(a: Int64; right: Boolean): Single;
begin
  Result := 0;
end;

function GenDC(a: Int64; right: Boolean): Single;
begin
  Result := 0.25;
end;

function GenRamp(a: Int64; right: Boolean): Single;
begin
  Result := (a mod 1000) * 0.001;
end;

{ write n frames in odd-sized blocks, mirrored into Ref }
procedure Feed(gen: TGen; n: Int64);
var
  blkL, blkR: array[0..699] of Single;
  k, i: Integer;
begin
  if Length(RefL) < RefCount + n then
  begin
    SetLength(RefL, RefCount + n);
    SetLength(RefR, RefCount + n);
  end;
  while n > 0 do
  begin
    k := Rnd mod 700 + 1;
    if k > n then k := n;
    for i := 0 to k - 1 do
    begin
      blkL[i] := gen(RefCount + i, False);
      blkR[i] := gen(RefCount + i, True);
      RefL[RefCount + i] := blkL[i];
      RefR[RefCount + i] := blkR[i];
    end;
    RingWrite(Inst.ring, @blkL[0], @blkR[0], k);
    Inc(RefCount, k);
    Dec(n, k);
  end;
end;

procedure RefMinMax(a0, a1: Int64; out mm: TMinMax);
var
  a: Int64;
begin
  mm.mnL := RefL[a0]; mm.mxL := mm.mnL;
  mm.mnR := RefR[a0]; mm.mxR := mm.mnR;
  for a := a0 + 1 to a1 - 1 do
  begin
    if RefL[a] < mm.mnL then mm.mnL := RefL[a];
    if RefL[a] > mm.mxL then mm.mxL := RefL[a];
    if RefR[a] < mm.mnR then mm.mnR := RefR[a];
    if RefR[a] > mm.mxR then mm.mxR := RefR[a];
  end;
end;

function SameMM(const a, b: TMinMax): Boolean;
begin
  Result := (a.mnL = b.mnL) and (a.mxL = b.mxL) and
    (a.mnR = b.mnR) and (a.mxR = b.mxR);
end;

function ColMM(const c: TColumns; x: Integer): TMinMax;
begin
  Result.mnL := c.minL[x]; Result.mxL := c.maxL[x];
  Result.mnR := c.minR[x]; Result.mxR := c.maxR[x];
end;

procedure TestPyramid;
var
  i: Integer;
  w, lowest, a0, a1: Int64;
  got, want: TMinMax;
begin
  NewInstance(SRATE);
  Check(Inst.ring.size mod PYR_BLOCK = 0, 'ring size not block aligned');
  Feed(@GenNoise, 25000);
  w := RingWritten(Inst.ring);
  Check(w = RefCount, 'framesWritten');
  lowest := w - Inst.ring.size + RING_CHUNK;
  for i := 1 to 3000 do
  begin
    a0 := lowest + Rnd mod (w - lowest);
    case i mod 3 of
      0: a1 := a0 + 1 + Rnd mod 40;
      1: a1 := a0 + 1 + Rnd mod 300;
    else
      a1 := a0 + 1 + Rnd mod 6000;
    end;
    if a1 > w then a1 := w;
    RingMinMax(Inst.ring, a0, a1, got);
    RefMinMax(a0, a1, want);
    if not SameMM(got, want) then
      Fail(Format('pyramid: min/max of [%d, %d) differs', [a0, a1]));
  end;
  FreeInstance;
  WriteLn('logic: pyramid min/max ok');
end;

function RefCrossing(mode: Integer; oldL, newL: Single): Boolean;
begin
  case mode of
    RETRIG_ASC:  Result := (oldL < 0) and (newL >= 0);
    RETRIG_DESC: Result := (oldL > 0) and (newL <= 0);
  else
    Result := (oldL < 0) <> (newL < 0);
  end;
end;

procedure TestTriggerWith(gen: TGen; const name: string; expectFound: Boolean);
const
  COLS = 100;
var
  mode, vs, searchLimit, x: Integer;
  w, low, a, cross, base: Int64;
  anchor: Double;
  found: Boolean;
  want: TMinMax;
begin
  NewInstance(SRATE);
  SetParam(@Inst, PARAM_VIEW_MS, 200.0);
  Feed(gen, 23457);
  w := RefCount;
  vs := ViewSampleCount(@Inst);
  Check(vs = 200, 'view samples');
  for mode := RETRIG_ANY to RETRIG_DESC do
  begin
    SetParam(@Inst, PARAM_RETRIG, mode);
    BuildColumns(@Inst, 0, COLS, ColsA, anchor);
    Check(ColsA.count = COLS, name + ': no frame');

    searchLimit := vs + Round(SRATE * 0.1);
    low := w - 1 - (searchLimit - 1);
    found := False;
    cross := w - 1;
    a := w - 1;
    while a > low do
    begin
      if RefCrossing(mode, RefL[a - 1], RefL[a]) then
      begin
        found := True;
        cross := a;
        Break;
      end;
      Dec(a);
    end;
    Check(found = expectFound, name + ': reference trigger expectation');

    if found then
    begin
      if anchor <> (w - 1) - cross then
        Fail(Format('%s mode %d: anchor %.0f, expected %d',
          [name, mode, anchor, (w - 1) - cross]));
      base := cross - vs + 1;
      for x := 0 to COLS - 1 do
      begin
        RefMinMax(base + Int64(x) * vs div COLS,
          base + Int64(x + 1) * vs div COLS, want);
        if not SameMM(ColMM(ColsA, x), want) then
          Fail(Format('%s mode %d: column %d differs', [name, mode, x]));
      end;
    end
    else
      Check((anchor >= 0) and (anchor < vs / COLS + 1),
        name + ': anchor without a trigger');
  end;
  FreeInstance;
end;

procedure TestTrigger;
begin
  TestTriggerWith(@GenSine, 'sine', True);
  TestTriggerWith(@GenNoise, 'noise', True);
  TestTriggerWith(@GenSilence, 'silence', False);
  TestTriggerWith(@GenDC, 'dc', False);
  WriteLn('logic: trigger search ok');
end;

{ more audio shifts the picture by whole columns, value for value }
procedure TestGridAndHold;
const
  COLS = 300;
var
  i, x, shift, vs: Integer;
  anchorA, anchorB, anchorH: Double;
  endA, endB: Int64;
  spp: Double;
begin
  NewInstance(SRATE);
  SetParam(@Inst, PARAM_VIEW_MS, 3001.0);
  Feed(@GenNoise, 12000);
  vs := ViewSampleCount(@Inst);
  spp := vs / COLS;
  for i := 1 to 200 do
  begin
    BuildColumns(@Inst, 0, COLS, ColsA, anchorA);
    Check(ColsA.count = COLS, 'grid: no frame A');
    Check((anchorA >= 0) and (anchorA < spp + 1), 'grid: anchor A');
    endA := RefCount - 1 - Round(anchorA);

    { freezing must not move the picture }
    SetParam(@Inst, PARAM_HOLD, 1.0);
    BuildColumns(@Inst, anchorA, COLS, ColsB, anchorH);
    SetParam(@Inst, PARAM_HOLD, 0.0);
    Check(anchorH = anchorA, 'hold: anchor moved on freeze');
    for x := 0 to COLS - 1 do
      if not SameMM(ColMM(ColsA, x), ColMM(ColsB, x)) then
        Fail(Format('hold: column %d changed on freeze', [x]));

    Feed(@GenNoise, Rnd mod 400 + 1);
    BuildColumns(@Inst, 0, COLS, ColsB, anchorB);
    Check(ColsB.count = COLS, 'grid: no frame B');
    endB := RefCount - 1 - Round(anchorB);
    shift := Round((endB - endA) / spp);
    for x := 0 to COLS - 1 - shift do
      if not SameMM(ColMM(ColsB, x), ColMM(ColsA, x + shift)) then
        Fail(Format('grid: column %d changed after shifting by %d', [x, shift]));
  end;

  { scrubbing past the end clamps }
  SetParam(@Inst, PARAM_HOLD, 1.0);
  BuildColumns(@Inst, 1e12, COLS, ColsA, anchorA);
  Check(ColsA.count = COLS, 'hold: no frame at the far end');
  Check(anchorA <= HoldReach(@Inst, vs, COLS) + spp + 1, 'hold: reach exceeded');
  Check(anchorA + vs + RING_CHUNK <= Inst.ring.size, 'hold: view enters the write zone');
  FreeInstance;
  WriteLn('logic: column grid + hold ok');
end;

procedure TestClear;
const
  COLS = 100;
var
  anchor: Double;
  x: Integer;
begin
  NewInstance(SRATE);
  SetParam(@Inst, PARAM_VIEW_MS, 1000.0);
  Feed(@GenDC, 15000);
  ScopeClear(@Inst);
  BuildColumns(@Inst, 0, COLS, ColsA, anchor);
  Check(ColsA.count = COLS, 'clear: no frame');
  for x := 0 to COLS - 1 do
    Check((ColsA.minL[x] = 0) and (ColsA.maxL[x] = 0) and
      (ColsA.minR[x] = 0) and (ColsA.maxR[x] = 0), 'clear: old audio still visible');

  Feed(@GenDC, 105);
  BuildColumns(@Inst, 0, COLS, ColsA, anchor);
  Check((ColsA.minL[0] = 0) and (ColsA.maxL[0] = 0), 'clear: left edge not silent');
  Check((ColsA.minL[COLS - 1] = 0.25) and (ColsA.maxL[COLS - 1] = 0.25),
    'clear: new audio missing');
  for x := 0 to COLS - 1 do
    Check(((ColsA.minL[x] = 0) or (ColsA.minL[x] = 0.25)) and
      ((ColsA.maxL[x] = 0) or (ColsA.maxL[x] = 0.25)) and
      (ColsA.minL[x] <= ColsA.maxL[x]), 'clear: unexpected column value');

  { trigger must not look into the cleared part }
  SetParam(@Inst, PARAM_RETRIG, RETRIG_ANY);
  BuildColumns(@Inst, 0, COLS, ColsA, anchor);
  Check(ColsA.count = COLS, 'clear: no frame with trigger');
  FreeInstance;
  WriteLn('logic: reset ok');
end;

{ fewer samples than pixels: steps }
procedure TestSteps;
const
  COLS = 64;
var
  anchor: Double;
  x: Integer;
  base: Int64;
  want: Single;
begin
  NewInstance(SRATE);
  SetParam(@Inst, PARAM_VIEW_MS, 1.0);
  Feed(@GenRamp, 11500);
  Check(ViewSampleCount(@Inst) = 16, 'steps: view samples');
  BuildColumns(@Inst, 0, COLS, ColsA, anchor);
  Check(ColsA.count = COLS, 'steps: no frame');
  Check(anchor = 0, 'steps: anchor');
  base := RefCount - 16;
  for x := 0 to COLS - 1 do
  begin
    want := RefL[base + x div 4];
    if (ColsA.minL[x] <> want) or (ColsA.maxL[x] <> want) then
      Fail(Format('steps: column %d = %.6f, expected %.6f', [x, ColsA.minL[x], want]));
  end;
  Check(ColsA.minL[COLS - 1] = RefL[RefCount - 1], 'steps: last column is not the newest sample');
  FreeInstance;
  WriteLn('logic: sample steps ok');
end;

var
  EvCount: Integer = 0;
  EvLastId: TClapId = CLAP_INVALID_ID;
  EvLastVal: Double = 0;

function CollectPush(list: PClapOutputEvents; event: PClapEventHeader): Boolean; cdecl;
begin
  Inc(EvCount);
  if event^.event_type = CLAP_EVENT_PARAM_VALUE then
  begin
    EvLastId := PClapEventParamValue(event)^.param_id;
    EvLastVal := PClapEventParamValue(event)^.value;
  end;
  Result := True;
end;

procedure TestParams;
var
  nan, inf, ninf, anchor: Double;
  oe: TClapOutputEvents;
begin
  PInt64(@nan)^ := $7FF8000000000000;
  PInt64(@inf)^ := $7FF0000000000000;
  PInt64(@ninf)^ := Int64($FFF0000000000000);
  Check(ClampParam(PARAM_VIEW_MS, nan) = ParamDefs[PARAM_VIEW_MS].defV, 'NaN -> default');
  Check(ClampParam(PARAM_VIEW_MS, inf) = ParamDefs[PARAM_VIEW_MS].maxV, '+Inf -> max');
  Check(ClampParam(PARAM_VZOOM_DB, ninf) = ParamDefs[PARAM_VZOOM_DB].minV, '-Inf -> min');

  NewInstance(SRATE);
  oe.ctx := nil;
  oe.try_push := @CollectPush;
  SetParam(@Inst, PARAM_VIEW_MS, 123.0);
  MarkParamDirty(@Inst, PARAM_VIEW_MS);
  SetParam(@Inst, PARAM_VIEW_MS, 124.0);
  MarkParamDirty(@Inst, PARAM_VIEW_MS);
  SetParam(@Inst, PARAM_RETRIG, 2.0);
  MarkParamDirty(@Inst, PARAM_RETRIG);

  ReportDirtyParams(@Inst, nil);             { nobody to tell: flags stay }
  EvCount := 0;
  ReportDirtyParams(@Inst, @oe);
  Check(EvCount = 6, Format('dirty params: %d events, expected 6', [EvCount]));
  Check((EvLastId = PARAM_RETRIG) and (EvLastVal = 2.0), 'dirty params: last value');
  EvCount := 0;
  ReportDirtyParams(@Inst, @oe);
  Check(EvCount = 0, 'dirty params: reported twice');
  FreeInstance;

  { bad sample rates fail cleanly }
  FillChar(Inst, SizeOf(Inst), 0);
  System.InitCriticalSection(Inst.lock);
  ResetParams(@Inst);
  Check(not ScopeConfigure(@Inst, nan), 'NaN sample rate accepted');
  Check(not ScopeConfigure(@Inst, 0), 'zero sample rate accepted');
  Check(not ScopeConfigure(@Inst, 1e12), 'absurd sample rate accepted');
  BuildColumns(@Inst, 0, 100, ColsA, anchor);
  Check(ColsA.count = 0, 'frame without a buffer');
  FreeInstance;
  WriteLn('logic: params ok');
end;

procedure TestProcessChannels;
var
  inL, outL, outR: array[0..63] of Single;
  inPtrs: array[0..0] of PSingle;
  outPtrs: array[0..1] of PSingle;
  ib, ob: TClapAudioBuffer;
  pr: TClapProcess;
  i: Integer;
begin
  NewInstance(SRATE);
  for i := 0 to 63 do
  begin
    inL[i] := i + 1;
    outL[i] := -1;
    outR[i] := -1;
  end;
  inPtrs[0] := @inL[0];
  outPtrs[0] := @outL[0]; outPtrs[1] := @outR[0];
  FillChar(ib, SizeOf(ib), 0);
  ib.data32 := @inPtrs[0];
  ib.channel_count := 1;
  FillChar(ob, SizeOf(ob), 0);
  ob.data32 := @outPtrs[0];
  ob.channel_count := 2;
  FillChar(pr, SizeOf(pr), 0);
  pr.frames_count := 64;
  pr.audio_inputs := @ib;
  pr.audio_outputs := @ob;
  pr.audio_inputs_count := 1;
  pr.audio_outputs_count := 1;

  Check(ScopeProcess(@Inst, @pr) = CLAP_PROCESS_CONTINUE, 'process mono');
  for i := 0 to 63 do
    Check((outL[i] = inL[i]) and (outR[i] = inL[i]), 'mono in -> stereo out');
  Check(RingWritten(Inst.ring) = 64, 'mono capture');

  ib.channel_count := 0;
  Check(ScopeProcess(@Inst, @pr) = CLAP_PROCESS_CONTINUE, 'process without channels');
  Check(RingWritten(Inst.ring) = 64, 'capture without channels');
  FreeInstance;
  WriteLn('logic: process channel layouts ok');
end;

{ play releases hold }
procedure TestTransportReleasesHold;
var
  tr: TClapEventTransport;
  oe: TClapOutputEvents;
  pr: TClapProcess;

  procedure Block(playing: Boolean);
  begin
    tr.flags := 0;
    if playing then tr.flags := CLAP_TRANSPORT_IS_PLAYING;
    EvCount := 0;
    Check(ScopeProcess(@Inst, @pr) = CLAP_PROCESS_CONTINUE, 'transport: process');
  end;

begin
  NewInstance(SRATE);
  FillChar(tr, SizeOf(tr), 0);
  oe.ctx := nil;
  oe.try_push := @CollectPush;
  FillChar(pr, SizeOf(pr), 0);
  pr.transport := @tr;
  pr.out_events := @oe;

  Block(False);
  SetParam(@Inst, PARAM_HOLD, 1.0);
  Block(False);
  Check(GetParam(@Inst, PARAM_HOLD) = 1.0, 'transport: hold lost while stopped');

  Block(True);
  Check(GetParam(@Inst, PARAM_HOLD) = 0.0, 'transport: play did not release hold');
  Check((EvCount = 3) and (EvLastId = PARAM_HOLD) and (EvLastVal = 0.0),
    'transport: host not told about the released hold');

  SetParam(@Inst, PARAM_HOLD, 1.0);   { engaged while playing: stays }
  Block(True);
  Check(GetParam(@Inst, PARAM_HOLD) = 1.0, 'transport: hold lost while playing');
  Check(EvCount = 0, 'transport: unexpected events');

  Block(False);
  Check(GetParam(@Inst, PARAM_HOLD) = 1.0, 'transport: stop released hold');
  Block(True);
  Check(GetParam(@Inst, PARAM_HOLD) = 0.0, 'transport: second play did not release hold');

  { no transport info: nothing happens }
  pr.transport := nil;
  SetParam(@Inst, PARAM_HOLD, 1.0);
  EvCount := 0;
  ScopeProcess(@Inst, @pr);
  Check(GetParam(@Inst, PARAM_HOLD) = 1.0, 'transport: hold lost without transport');
  FreeInstance;
  WriteLn('logic: play releases hold ok');
end;

{ ------------------------------------------------------------------ }

{ Sync view. The signal is the phase within the cycle (0..1), so column
  x must show x / COLS wherever the playhead is. }

var
  SyncTempo: Double = 133.0;
  SyncBeatsPerBar: Double = 4.0;
  SyncLenBarsT: Double = 1.0;
  SyncFrame: Int64 = 0;      { song position of the next frame fed }

function SyncBarsAt(frame: Int64): Double;
begin
  Result := frame / (SRATE * 60.0 / SyncTempo) / SyncBeatsPerBar;
end;

{ n frames through ScopeProcess in odd blocks, with a host transport }
procedure FeedSync(n: Int64; playing, withTransport: Boolean);
var
  blk: array[0..699] of Single;
  ptrs: array[0..1] of PSingle;
  ab: TClapAudioBuffer;
  tr: TClapEventTransport;
  pr: TClapProcess;
  k, i: Integer;
  ph, beats, barIdx: Double;
begin
  ptrs[0] := @blk[0]; ptrs[1] := @blk[0];
  FillChar(ab, SizeOf(ab), 0);
  ab.data32 := @ptrs[0];
  ab.channel_count := 2;
  FillChar(pr, SizeOf(pr), 0);
  pr.audio_inputs := @ab;
  pr.audio_outputs := @ab;
  pr.audio_inputs_count := 1;
  pr.audio_outputs_count := 1;
  if withTransport then pr.transport := @tr;
  while n > 0 do
  begin
    k := Rnd mod 700 + 1;
    if k > n then k := n;
    for i := 0 to k - 1 do
    begin
      ph := SyncBarsAt(SyncFrame + i) / SyncLenBarsT;
      blk[i] := ph - Trunc(ph);
    end;
    FillChar(tr, SizeOf(tr), 0);
    tr.flags := CLAP_TRANSPORT_HAS_TEMPO or CLAP_TRANSPORT_HAS_BEATS_TIMELINE or
      CLAP_TRANSPORT_HAS_TIME_SIGNATURE;
    if playing then tr.flags := tr.flags or CLAP_TRANSPORT_IS_PLAYING;
    beats := SyncBarsAt(SyncFrame) * SyncBeatsPerBar;
    barIdx := Trunc(beats / SyncBeatsPerBar);
    tr.song_pos_beats := Round(beats * CLAP_BEATTIME_FACTOR);
    tr.bar_start := Round(barIdx * SyncBeatsPerBar * CLAP_BEATTIME_FACTOR);
    tr.bar_number := Round(barIdx);
    tr.tempo := SyncTempo;
    tr.tsig_num := Round(SyncBeatsPerBar);
    tr.tsig_denom := 4;
    pr.frames_count := k;
    Check(ScopeProcess(@Inst, @pr) = CLAP_PROCESS_CONTINUE, 'sync: process');
    if playing then Inc(SyncFrame, k);
    Dec(n, k);
  end;
end;

procedure TestSyncCase(lenIdx: Integer; tempo, beatsPerBar: Double);
const
  COLS = 200;
var
  st: TViewState;
  vi: TViewInfo;
  i, x: Integer;
  lenSamples, eps, d, ph: Double;
begin
  NewInstance(SRATE);
  SyncTempo := tempo;
  SyncBeatsPerBar := beatsPerBar;
  SyncLenBarsT := SyncLenBars[lenIdx];
  SyncFrame := 0;
  SetParam(@Inst, PARAM_SYNC, 1.0);
  SetParam(@Inst, PARAM_SYNC_LEN, lenIdx);
  lenSamples := SyncLenBarsT * beatsPerBar * SRATE * 60.0 / tempo;
  eps := 2.5 / lenSamples + 1e-4;
  InitViewState(st);

  FeedSync(Round(2.5 * lenSamples) + 300, True, True);
  for i := 1 to 250 do
  begin
    BuildColumns(@Inst, 0, COLS, ColsA, st, vi);
    Check(ColsA.count = COLS, 'sync: no frame');
    Check(vi.sync and vi.sweep and (vi.syncLen = lenIdx), 'sync: not sweeping');
    Check(vi.viewSamples = Round(lenSamples), 'sync: view length');
    ph := SyncBarsAt(SyncFrame) / SyncLenBarsT;
    d := vi.playhead - (ph - Trunc(ph));
    d := d - Round(d);
    Check(Abs(d) <= eps, Format('sync: playhead off by %.5f', [d]));
    for x := 0 to COLS - 1 do
    begin
      d := ColsA.minL[x] - (x + 0.5) / COLS;
      d := d - Round(d);
      if Abs(d) > 0.5 / COLS + eps then
        Fail(Format('sync len %d: column %d min shows phase %.4f', [lenIdx, x, ColsA.minL[x]]));
      d := ColsA.maxL[x] - (x + 0.5) / COLS;
      d := d - Round(d);
      if Abs(d) > 0.5 / COLS + eps then
        Fail(Format('sync len %d: column %d max shows phase %.4f', [lenIdx, x, ColsA.maxL[x]]));
    end;
    FeedSync(Rnd mod 500 + 1, True, True);
  end;

  { zoomed into the middle half of the cycle }
  st.zoomStart := 0.25;
  st.zoomSpan := 0.5;
  for i := 1 to 40 do
  begin
    BuildColumns(@Inst, 0, COLS, ColsA, st, vi);
    Check((ColsA.count = COLS) and vi.sweep, 'sync zoom: no frame');
    Check((Abs(vi.zoomStart - 0.25) < 1e-9) and (Abs(vi.zoomSpan - 0.5) < 1e-9), 'sync zoom: window');
    ph := SyncBarsAt(SyncFrame) / SyncLenBarsT;
    ph := ph - Trunc(ph);
    if (ph > 0.25 + eps) and (ph < 0.75 - eps) then
      Check(Abs(vi.playhead - (ph - 0.25) / 0.5) <= 2 * eps, 'sync zoom: playhead')
    else if (ph < 0.25 - eps) or (ph > 0.75 + eps) then
      Check((vi.playhead < 0) or (vi.playhead > 1) or (ph < 0.25), 'sync zoom: playhead outside');
    for x := 0 to COLS - 1 do
    begin
      d := ColsA.minL[x] - (0.25 + (x + 0.5) / COLS * 0.5);
      d := d - Round(d);
      if Abs(d) > 0.25 / COLS + eps then
        Fail(Format('sync zoom len %d: column %d shows phase %.4f', [lenIdx, x, ColsA.minL[x]]));
    end;
    FeedSync(Rnd mod 500 + 1, True, True);
  end;
  st.zoomStart := 0;
  st.zoomSpan := 1;

  { hold: capture stops, the picture stays as it is }
  BuildColumns(@Inst, 0, COLS, ColsA, st, vi);
  SetParam(@Inst, PARAM_HOLD, 1.0);
  FeedSync(777, True, True);
  BuildColumns(@Inst, 0, COLS, ColsB, st, vi);
  Check(vi.sweep, 'sync: hold left the sweep');
  for x := 0 to COLS - 1 do
    Check(SameMM(ColMM(ColsA, x), ColMM(ColsB, x)), 'sync: picture moved while holding');
  SetParam(@Inst, PARAM_HOLD, 0.0);
  FreeInstance;
end;

procedure TestSync;
var
  st: TViewState;
  vi: TViewInfo;
  x: Integer;
begin
  TestSyncCase(2, 133.0, 4.0);   { 1 bar }
  TestSyncCase(0, 133.0, 4.0);   { 1/4 bar }
  TestSyncCase(1, 97.3, 4.0);    { 1/2 bar }
  TestSyncCase(5, 171.0, 4.0);   { 8 bars }
  TestSyncCase(4, 120.0, 3.0);   { 4 bars of 3/4 }

  InitViewState(st);
  NewInstance(SRATE);
  SyncTempo := 120.0;
  SyncBeatsPerBar := 4.0;
  SyncLenBarsT := 1.0;
  SyncFrame := 0;
  SetParam(@Inst, PARAM_SYNC_LEN, 2);
  FeedSync(9000, True, True);

  { sync off: the transport is ignored }
  BuildColumns(@Inst, 0, 200, ColsA, st, vi);
  Check((ColsA.count = 200) and (not vi.sync), 'sync: active without being selected');

  SetParam(@Inst, PARAM_SYNC, 1.0);
  BuildColumns(@Inst, 0, 200, ColsA, st, vi);
  Check(vi.sync and vi.sweep, 'sync: not active when selected');
  Check((vi.lenBars = 1.0) and (vi.beatsPerBar = 4.0), 'sync: bar info');

  { stop: hold engages and the last cycle stays; play releases it }
  BuildColumns(@Inst, 0, 200, ColsA, st, vi);
  FeedSync(500, False, True);
  Check(GetParam(@Inst, PARAM_HOLD) = 1.0, 'sync: stop did not engage hold');
  BuildColumns(@Inst, 0, 200, ColsB, st, vi);
  Check(vi.sync and vi.sweep, 'sync: stop left the cycle view');
  for x := 0 to 199 do
    Check(SameMM(ColMM(ColsA, x), ColMM(ColsB, x)), 'sync: picture changed on stop');
  FeedSync(500, True, True);
  Check(GetParam(@Inst, PARAM_HOLD) = 0.0, 'sync: play did not release hold');
  BuildColumns(@Inst, 0, 200, ColsB, st, vi);
  Check(vi.sweep, 'sync: no cycle view after play');

  { stopped with hold released by hand: free-running view of the same length }
  FeedSync(500, False, True);
  SetParam(@Inst, PARAM_HOLD, 0.0);
  FeedSync(500, False, True);
  BuildColumns(@Inst, 0, 200, ColsA, st, vi);
  Check(vi.sync and (not vi.sweep) and (vi.viewSamples = 2000), 'sync: stopped view');

  { host without transport: back to the normal view }
  FeedSync(500, False, False);
  BuildColumns(@Inst, 0, 200, ColsA, st, vi);
  Check((ColsA.count = 200) and (not vi.sync), 'sync: active without a transport');
  Check(vi.viewSamples = ViewSampleCount(@Inst), 'sync: fallback view length');
  FreeInstance;

  { 8 bars at 30 bpm do not fit the ring: the longest that fits is used }
  NewInstance(SRATE);
  SyncTempo := 30.0;
  SyncFrame := 0;
  SetParam(@Inst, PARAM_SYNC, 1.0);
  SetParam(@Inst, PARAM_SYNC_LEN, 5);
  FeedSync(3000, True, True);
  BuildColumns(@Inst, 0, 200, ColsA, st, vi);
  Check(vi.sync and (vi.syncLen = 3) and (ColsA.count = 200), 'sync: long cycle not shortened');
  FreeInstance;
  WriteLn('logic: bar sync ok');
end;

procedure RunLogicTests;
begin
  ReturnNilIfGrowHeapFails := True;
  TestPyramid;
  TestTrigger;
  TestGridAndHold;
  TestClear;
  TestSteps;
  TestParams;
  TestProcessChannels;
  TestTransportReleasesHold;
  TestSync;
end;

{ threading stress test }

{ Audio, render and main threads on one instance. The signal is a
  counter: every frame must be an unbroken run. }

const
  STRESS_MS = 1500;
  STRESS_MAXBLOCK = 700;     { > RING_CHUNK }
  VZOOM_STEPS = 97;

var
  SStop: LongBool = False;
  SErr: LongInt = 0;         { 1 L/R, 2 gap, 3 bad param value }
  SCols: Integer = 0;
  SFramesOk: Int64 = 0;
  SFramesDropped: Int64 = 0;
  SReports: Int64 = 0;
  SLastReported: Double = 0;

function StressTryPush(list: PClapOutputEvents; event: PClapEventHeader): Boolean; cdecl;
var
  v: Double;
begin
  Result := True;
  if event^.event_type <> CLAP_EVENT_PARAM_VALUE then Exit;
  v := PClapEventParamValue(event)^.value;
  if (v < -60) or (v > 36) or (v <> Round(v)) then
    InterlockedCompareExchange(SErr, 3, 0);
  SLastReported := v;
  Inc(SReports);
end;

function StressAudioThread(p: Pointer): PtrInt;
var
  blk: array[0..STRESS_MAXBLOCK - 1] of Single;
  ptrs: array[0..1] of PSingle;
  ab: TClapAudioBuffer;
  oe: TClapOutputEvents;
  pr: TClapProcess;
  k: Int64;
  n, i, blocks: Integer;
begin
  Result := 0;
  ptrs[0] := @blk[0]; ptrs[1] := @blk[0];
  FillChar(ab, SizeOf(ab), 0);
  ab.data32 := @ptrs[0];
  ab.channel_count := 2;
  oe.ctx := nil;
  oe.try_push := @StressTryPush;
  FillChar(pr, SizeOf(pr), 0);
  pr.audio_inputs := @ab;
  pr.audio_outputs := @ab;   { in place }
  pr.audio_inputs_count := 1;
  pr.audio_outputs_count := 1;
  pr.out_events := @oe;

  k := 0; n := 1; blocks := 0;
  while not SStop do
  begin
    for i := 0 to n - 1 do
      blk[i] := (k + i) and $FFFF;
    pr.frames_count := n;
    ScopeProcess(@Inst, @pr);
    Inc(k, n);
    n := (n * 7 + 13) mod STRESS_MAXBLOCK + 1;
    Inc(blocks);
    if blocks and 4095 = 0 then Sleep(1);   { let the reader win sometimes }
  end;
end;

function StressRenderThread(p: Pointer): PtrInt;
var
  anchor: Double;
  x: Integer;
begin
  Result := 0;
  while not SStop do
  begin
    BuildColumns(@Inst, 0, SCols, ColsA, anchor);
    if ColsA.count = 0 then
    begin
      Inc(SFramesDropped);
      Continue;
    end;
    Inc(SFramesOk);
    for x := 0 to ColsA.count - 1 do
    begin
      if (ColsA.minL[x] <> ColsA.maxL[x]) or (ColsA.minL[x] <> ColsA.minR[x]) then
        InterlockedCompareExchange(SErr, 1, 0);
      if (x > 0) and
         ((Round(ColsA.minL[x]) - Round(ColsA.minL[x - 1])) and $FFFF <> 1) then
        InterlockedCompareExchange(SErr, 2, 0);
    end;
  end;
end;

procedure RunStressTest;
var
  ta, tr: TThreadID;
  t0: QWord;
  changes: Int64;
  oe: TClapOutputEvents;
begin
  NewInstance(SRATE);
  SetParam(@Inst, PARAM_VIEW_MS, 5000.0);
  SCols := ViewSampleCount(@Inst);   { one sample per column }
  Check((SCols > 4000) and (SCols <= MAX_COLS), 'stress: column count');

  ta := BeginThread(@StressAudioThread, nil);
  { fill the ring first }
  while RingWritten(Inst.ring) < 2 * Int64(Inst.ring.size) do
    Sleep(1);
  tr := BeginThread(@StressRenderThread, nil);

  changes := 0;
  t0 := GetTickCount64;
  while GetTickCount64 - t0 < STRESS_MS do
  begin
    SetParam(@Inst, PARAM_VZOOM_DB, -60 + (changes mod VZOOM_STEPS));
    MarkParamDirty(@Inst, PARAM_VZOOM_DB);
    Inc(changes);
    { second half: trigger on }
    if GetTickCount64 - t0 > STRESS_MS div 2 then
      SetParam(@Inst, PARAM_RETRIG, RETRIG_ANY);
  end;

  SStop := True;
  WaitForThreadTerminate(ta, 0);
  WaitForThreadTerminate(tr, 0);
  CloseThread(ta);
  CloseThread(tr);

  oe.ctx := nil;
  oe.try_push := @StressTryPush;
  ReportDirtyParams(@Inst, @oe);

  case SErr of
    1: Fail('stress: L/R columns differ, torn frame');
    2: Fail('stress: gap in a snapshot, overwritten samples got through');
    3: Fail('stress: host was told a value the GUI never set');
  end;
  if SReports = 0 then
    Fail('stress: no param change reached the host');
  if SLastReported <> GetParam(@Inst, PARAM_VZOOM_DB) then
    Fail('stress: host ended up with a stale param value');
  if SFramesOk = 0 then
    Fail('stress: reader never got a consistent frame');
  WriteLn(Format('stress: ok (%d frames checked, %d rejected as inconsistent, ' +
    '%d param changes, host in sync)', [SFramesOk, SFramesDropped, changes]));
  FreeInstance;
end;

end.
