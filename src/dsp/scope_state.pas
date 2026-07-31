unit scope_state;

{ Shared instance state: parameter table and the capture ring buffer.

  Audio thread writes bufL/bufR + writePos lock-free; the GUI reads them
  under `lock`, which only guards reallocation in activate(). The audio
  thread never takes the lock — the host guarantees activate() and
  process() don't overlap. }

{$mode objfpc}{$H+}
{$packrecords c}

interface

uses
  clap_api;

const
  PLUGIN_VERSION = '1.0.0';
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

  { logical 96-dpi pixels, scaled by the UI scale at runtime }
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

const
  PQ_SIZE = 64;   { must be a power of two }

type
  TParamChange = record
    id: TClapId;
    value: Double;
  end;

  PScopeInstance = ^TScopeInstance;
  TScopeInstance = record
    plug: TClapPlugin;           { must stay first }
    host: PClapHost;
    hostParams: PClapHostParams; { may be nil }
    lock: TRTLCriticalSection;

    srate: Double;
    bufL, bufR: PSingle;
    histSize: UInt32;            { frames per channel, 0 = unallocated }
    writePos: UInt32;

    params: array[0..PARAM_COUNT - 1] of Double;
    guiScale: Double;
    gui: Pointer;                { PScopeGui, owned by scope_gui }

    { GUI -> host param changes, SPSC ring: wndproc pushes, process or
      flush drains into out_events }
    pq: array[0..PQ_SIZE - 1] of TParamChange;
    pqWrite, pqRead: UInt32;
  end;

function ParamIndex(id: TClapId): Integer;
function ClampParam(idx: Integer; v: Double): Double;
procedure ResetParams(inst: PScopeInstance);

procedure PushParamChange(inst: PScopeInstance; id: TClapId; value: Double);
function PopParamChange(inst: PScopeInstance; out chg: TParamChange): Boolean;
procedure RequestHostFlush(inst: PScopeInstance);

implementation

function ParamIndex(id: TClapId): Integer;
begin
  if id < PARAM_COUNT then
    Result := Integer(id)
  else
    Result := -1;
end;

function ClampParam(idx: Integer; v: Double): Double;
begin
  if v < ParamDefs[idx].minV then v := ParamDefs[idx].minV;
  if v > ParamDefs[idx].maxV then v := ParamDefs[idx].maxV;
  Result := v;
end;

procedure ResetParams(inst: PScopeInstance);
var
  i: Integer;
begin
  for i := 0 to PARAM_COUNT - 1 do
    inst^.params[i] := ParamDefs[i].defV;
end;

procedure PushParamChange(inst: PScopeInstance; id: TClapId; value: Double);
var
  next: UInt32;
begin
  next := (inst^.pqWrite + 1) and (PQ_SIZE - 1);
  if next = inst^.pqRead then
    Exit;   { full — drop, host re-syncs via get_value }
  inst^.pq[inst^.pqWrite].id := id;
  inst^.pq[inst^.pqWrite].value := value;
  inst^.pqWrite := next;
end;

function PopParamChange(inst: PScopeInstance; out chg: TParamChange): Boolean;
begin
  Result := inst^.pqRead <> inst^.pqWrite;
  if not Result then Exit;
  chg := inst^.pq[inst^.pqRead];
  inst^.pqRead := (inst^.pqRead + 1) and (PQ_SIZE - 1);
end;

procedure RequestHostFlush(inst: PScopeInstance);
begin
  if (inst^.hostParams <> nil) and (inst^.hostParams^.request_flush <> nil) and
     (inst^.host <> nil) then
    inst^.hostParams^.request_flush(inst^.host);
end;

end.
