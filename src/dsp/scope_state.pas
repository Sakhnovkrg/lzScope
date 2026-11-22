unit scope_state;

{ Shared instance state: params, capture ring, GUI -> host change flags }

{$mode objfpc}{$H+}
{$packrecords c}

interface

uses
  clap_api, scope_ring;

const
  PLUGIN_VERSION = '1.2.0';
  PLUGIN_AUTHOR  = 'DsgDnB';
  PLUGIN_URL     = 'https://github.com/sakhnovkrg';

  PARAM_VIEW_MS  = 0;
  PARAM_VZOOM_DB = 1;
  PARAM_RETRIG   = 2;
  PARAM_HOLD     = 3;
  PARAM_SYNC_LEN = 4;
  PARAM_SYNC     = 5;   { view locked to the host's bars }
  PARAM_SPLIT    = 6;   { left and right in separate lanes }
  PARAM_COUNT    = 7;

  RETRIG_INSTANT = 0;
  RETRIG_ANY     = 1;
  RETRIG_ASC     = 2;
  RETRIG_DESC    = 3;
  RETRIG_COUNT   = 4;

  RetrigNames: array[0..RETRIG_COUNT - 1] of PAnsiChar =
    ('instant', 'any', 'ascending', 'descending');

  { view length in sync mode, in bars }
  SYNC_LEN_COUNT   = 6;
  SYNC_LEN_DEFAULT = 2;
  SyncLenNames: array[0..SYNC_LEN_COUNT - 1] of PAnsiChar =
    ('1/4 bar', '1/2 bar', '1 bar', '2 bars', '4 bars', '8 bars');
  SyncLenBars: array[0..SYNC_LEN_COUNT - 1] of Double =
    (0.25, 0.5, 1.0, 2.0, 4.0, 8.0);

  SYNC_JUMP_BARS = 0.001;   { the song position may be off by this much }

  HIST_SECONDS = 20;   { 8 bars down to 98 bpm, 4 bars down to 49 }

  MIN_SAMPLE_RATE = 1000.0;
  MAX_SAMPLE_RATE = 1536000.0;

  { at 96 dpi }
  DEFAULT_GUI_W = 800;
  DEFAULT_GUI_H = 360;
  MIN_GUI_W = 540;   { until the status line has been measured }
  MIN_GUI_H = 160;
  MIN_GUI_H_SPLIT = 240;
  MAX_GUI_W = 8192;
  MAX_GUI_H = 8192;

type
  TParamDef = record
    id: TClapId;
    name: PAnsiChar;
    minV, maxV, defV: Double;
    flags: UInt32;
  end;

const
  ParamDefs: array[0..PARAM_COUNT - 1] of TParamDef = (
    (id: PARAM_VIEW_MS;  name: 'View Size';
     minV: 1.0;   maxV: 5000.0; defV: 2740.0;
     flags: CLAP_PARAM_IS_AUTOMATABLE),
    (id: PARAM_VZOOM_DB; name: 'V-Zoom';
     minV: -60.0; maxV: 36.0;   defV: 0.0;
     flags: CLAP_PARAM_IS_AUTOMATABLE),
    (id: PARAM_RETRIG;   name: 'Retrigger';
     minV: 0.0;   maxV: RETRIG_COUNT - 1; defV: 0.0;
     flags: CLAP_PARAM_IS_AUTOMATABLE or CLAP_PARAM_IS_STEPPED),
    (id: PARAM_HOLD;     name: 'Hold';
     minV: 0.0;   maxV: 1.0;    defV: 0.0;
     flags: CLAP_PARAM_IS_AUTOMATABLE or CLAP_PARAM_IS_STEPPED),
    (id: PARAM_SYNC_LEN; name: 'Sync Length';
     minV: 0.0;   maxV: SYNC_LEN_COUNT - 1; defV: SYNC_LEN_DEFAULT;
     flags: CLAP_PARAM_IS_AUTOMATABLE or CLAP_PARAM_IS_STEPPED),
    (id: PARAM_SYNC;     name: 'Sync';
     minV: 0.0;   maxV: 1.0;    defV: 0.0;
     flags: CLAP_PARAM_IS_AUTOMATABLE or CLAP_PARAM_IS_STEPPED),
    (id: PARAM_SPLIT;    name: 'Split';
     minV: 0.0;   maxV: 1.0;    defV: 0.0;
     flags: CLAP_PARAM_IS_AUTOMATABLE or CLAP_PARAM_IS_STEPPED)
  );

type
  { host transport at one ring frame, published by the audio thread }
  TSyncInfo = record
    valid: Boolean;      { host gives tempo and position }
    playing: Boolean;
    frame: Int64;        { ring frame the position refers to }
    bars: Double;        { song position at that frame, in bars }
    samplesPerBar: Double;
    beatsPerBar: Double;
    { the last time the position jumped (seek, loop): what was recorded
      before it sits jumpBars away from where the bars now say }
    jumpFrame: Int64;
    jumpBars: Double;
    prevJumpFrame: Int64;   { the jump before that; older frames are unusable }
  end;

  PScopeInstance = ^TScopeInstance;
  TScopeInstance = record
    plug: TClapPlugin;           { must stay first }
    host: PClapHost;
    hostParams: PClapHostParams; { may be nil }
    hostState: PClapHostState;   { may be nil }
    lock: TRTLCriticalSection;   { ring (re)allocation vs readers }

    srate: Double;
    ring: TScopeRing;

    paramBits: array[0..PARAM_COUNT - 1] of Int64;  { atomic }
    dirty: LongInt;              { atomic; bit per param changed by the GUI }
    wasPlaying: Boolean;         { audio thread }
    syncSeq: LongInt;            { atomic; odd while sync is being written }
    sync: TSyncInfo;
    guiScale: Double;
    gui: Pointer;                { PScopeGui, owned by scope_gui }
  end;

function ParamIndex(id: TClapId): Integer;
{ bit test: comparing a NaN can raise }
function IsNaNValue(v: Double): Boolean;
{ NaN becomes the default }
function ClampParam(idx: Integer; v: Double): Double;
procedure ResetParams(inst: PScopeInstance);

{ atomic, any thread }
function GetParam(inst: PScopeInstance; idx: Integer): Double;
procedure SetParam(inst: PScopeInstance; idx: Integer; v: Double);

procedure MarkParamDirty(inst: PScopeInstance; idx: Integer);
function TakeDirtyParams(inst: PScopeInstance): LongInt;
procedure RequestHostFlush(inst: PScopeInstance);
{ main thread only }
procedure MarkHostStateDirty(inst: PScopeInstance);

{ audio thread }
procedure PublishSync(inst: PScopeInstance; const s: TSyncInfo);
{ any thread; False = no consistent copy, treat as not valid }
function ReadSync(inst: PScopeInstance; out s: TSyncInfo): Boolean;

implementation

function ParamIndex(id: TClapId): Integer;
begin
  if id < PARAM_COUNT then
    Result := Integer(id)
  else
    Result := -1;
end;

{ via pointers: absolute overlays misread register values }
function DoubleBits(v: Double): Int64;
begin
  Result := PInt64(@v)^;
end;

function BitsDouble(bits: Int64): Double;
begin
  Result := PDouble(@bits)^;
end;

function IsNaNValue(v: Double): Boolean;
var
  bits: Int64;
begin
  bits := DoubleBits(v);
  Result := ((bits and $7FF0000000000000) = $7FF0000000000000) and
    ((bits and $000FFFFFFFFFFFFF) <> 0);
end;

function ClampParam(idx: Integer; v: Double): Double;
begin
  if IsNaNValue(v) then
    Exit(ParamDefs[idx].defV);
  if v < ParamDefs[idx].minV then v := ParamDefs[idx].minV;
  if v > ParamDefs[idx].maxV then v := ParamDefs[idx].maxV;
  Result := v;
end;

procedure ResetParams(inst: PScopeInstance);
var
  i: Integer;
begin
  for i := 0 to PARAM_COUNT - 1 do
    SetParam(inst, i, ParamDefs[i].defV);
end;

function GetParam(inst: PScopeInstance; idx: Integer): Double;
var
  bits: Int64;
begin
  bits := inst^.paramBits[idx];
  ReadBarrier;
  Result := BitsDouble(bits);
end;

procedure SetParam(inst: PScopeInstance; idx: Integer; v: Double);
begin
  InterlockedExchange64(inst^.paramBits[idx], DoubleBits(v));
end;

procedure MarkParamDirty(inst: PScopeInstance; idx: Integer);
var
  old: LongInt;
begin
  repeat
    old := inst^.dirty;
  until InterlockedCompareExchange(inst^.dirty, old or (1 shl idx), old) = old;
end;

function TakeDirtyParams(inst: PScopeInstance): LongInt;
begin
  Result := InterlockedExchange(inst^.dirty, 0);
end;

procedure RequestHostFlush(inst: PScopeInstance);
begin
  if (inst^.hostParams <> nil) and (inst^.hostParams^.request_flush <> nil) and
     (inst^.host <> nil) then
    inst^.hostParams^.request_flush(inst^.host);
end;

procedure MarkHostStateDirty(inst: PScopeInstance);
begin
  if (inst^.hostState <> nil) and (inst^.hostState^.mark_dirty <> nil) and
     (inst^.host <> nil) then
    inst^.hostState^.mark_dirty(inst^.host);
end;

procedure PublishSync(inst: PScopeInstance; const s: TSyncInfo);
begin
  InterlockedIncrement(inst^.syncSeq);
  inst^.sync := s;
  InterlockedIncrement(inst^.syncSeq);
end;

function ReadSync(inst: PScopeInstance; out s: TSyncInfo): Boolean;
var
  seq, attempt: LongInt;
begin
  for attempt := 1 to 4 do
  begin
    ReadWriteBarrier;
    seq := inst^.syncSeq;
    ReadWriteBarrier;
    s := inst^.sync;
    ReadWriteBarrier;
    if (not Odd(seq)) and (inst^.syncSeq = seq) then
      Exit(True);
  end;
  s.valid := False;
  Result := False;
end;

end.
