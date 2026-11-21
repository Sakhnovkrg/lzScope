unit scope_state;

{ Shared instance state: params, capture ring, GUI -> host change flags }

{$mode objfpc}{$H+}
{$packrecords c}

interface

uses
  clap_api, scope_ring;

const
  PLUGIN_VERSION = '1.0.1';
  PLUGIN_AUTHOR  = 'DsgDnB';
  PLUGIN_URL     = 'https://github.com/sakhnovkrg';

  PARAM_VIEW_MS  = 0;
  PARAM_VZOOM_DB = 1;
  PARAM_RETRIG   = 2;
  PARAM_HOLD     = 3;
  PARAM_COUNT    = 4;

  RETRIG_INSTANT = 0;
  RETRIG_ANY     = 1;
  RETRIG_ASC     = 2;
  RETRIG_DESC    = 3;

  RetrigNames: array[0..3] of PAnsiChar =
    ('instant', 'any', 'ascending', 'descending');

  HIST_SECONDS = 10;   { max view (5 s) + trigger/scrub lookback }

  MIN_SAMPLE_RATE = 1000.0;
  MAX_SAMPLE_RATE = 1536000.0;

  { at 96 dpi }
  DEFAULT_GUI_W = 800;
  DEFAULT_GUI_H = 360;
  MIN_GUI_W = 200;
  MIN_GUI_H = 120;
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
     minV: 0.0;   maxV: 3.0;    defV: 0.0;
     flags: CLAP_PARAM_IS_AUTOMATABLE or CLAP_PARAM_IS_STEPPED),
    (id: PARAM_HOLD;     name: 'Hold';
     minV: 0.0;   maxV: 1.0;    defV: 0.0;
     flags: CLAP_PARAM_IS_AUTOMATABLE or CLAP_PARAM_IS_STEPPED)
  );

type
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

end.
