unit scope_dsp;

{ Audio side: buffer management, param events, process (pass-through
  + capture into the ring buffer). }

{$mode objfpc}{$H+}
{$packrecords c}
{$pointermath on}

interface

uses
  clap_api, scope_state;

procedure ScopeConfigure(inst: PScopeInstance; sampleRate: Double);
procedure ScopeReleaseBuffers(inst: PScopeInstance);
procedure ScopeClear(inst: PScopeInstance);
procedure ScopeHandleEvent(inst: PScopeInstance; hdr: PClapEventHeader);
function ScopeProcess(inst: PScopeInstance; p: PClapProcess): Int32;

{ apply queued GUI changes and report them to the host as
  gesture_begin / param_value / gesture_end }
procedure DrainParamQueue(inst: PScopeInstance; outEvents: PClapOutputEvents);

implementation

procedure ScopeConfigure(inst: PScopeInstance; sampleRate: Double);
var
  size: UInt32;
begin
  System.EnterCriticalSection(inst^.lock);
  try
    if inst^.bufL <> nil then FreeMem(inst^.bufL);
    if inst^.bufR <> nil then FreeMem(inst^.bufR);
    inst^.srate := sampleRate;
    size := Round(sampleRate * HIST_SECONDS);
    inst^.histSize := size;
    GetMem(inst^.bufL, size * SizeOf(Single));
    GetMem(inst^.bufR, size * SizeOf(Single));
    FillChar(inst^.bufL^, size * SizeOf(Single), 0);
    FillChar(inst^.bufR^, size * SizeOf(Single), 0);
    inst^.writePos := 0;
  finally
    System.LeaveCriticalSection(inst^.lock);
  end;
end;

procedure ScopeReleaseBuffers(inst: PScopeInstance);
begin
  System.EnterCriticalSection(inst^.lock);
  try
    if inst^.bufL <> nil then FreeMem(inst^.bufL);
    if inst^.bufR <> nil then FreeMem(inst^.bufR);
    inst^.bufL := nil;
    inst^.bufR := nil;
    inst^.histSize := 0;
    inst^.writePos := 0;
  finally
    System.LeaveCriticalSection(inst^.lock);
  end;
end;

procedure ScopeClear(inst: PScopeInstance);
begin
  { safe on the audio thread: pointers are stable while active }
  if inst^.bufL <> nil then
    FillChar(inst^.bufL^, inst^.histSize * SizeOf(Single), 0);
  if inst^.bufR <> nil then
    FillChar(inst^.bufR^, inst^.histSize * SizeOf(Single), 0);
end;

procedure ScopeHandleEvent(inst: PScopeInstance; hdr: PClapEventHeader);
var
  pev: PClapEventParamValue;
  idx: Integer;
begin
  if (hdr = nil) or (hdr^.space_id <> CLAP_CORE_EVENT_SPACE_ID) then
    Exit;
  if hdr^.event_type = CLAP_EVENT_PARAM_VALUE then
  begin
    pev := PClapEventParamValue(hdr);
    idx := ParamIndex(pev^.param_id);
    if idx >= 0 then
      inst^.params[idx] := ClampParam(idx, pev^.value);
  end;
end;

procedure DrainParamQueue(inst: PScopeInstance; outEvents: PClapOutputEvents);
var
  chg: TParamChange;
  idx: Integer;
  gest: TClapEventParamGesture;
  pev: TClapEventParamValue;
begin
  while PopParamChange(inst, chg) do
  begin
    idx := ParamIndex(chg.id);
    if idx < 0 then Continue;
    inst^.params[idx] := ClampParam(idx, chg.value);
    if (outEvents = nil) or (outEvents^.try_push = nil) then Continue;

    FillChar(gest, SizeOf(gest), 0);
    gest.header.size := SizeOf(gest);
    gest.header.space_id := CLAP_CORE_EVENT_SPACE_ID;
    gest.header.event_type := CLAP_EVENT_PARAM_GESTURE_BEGIN;
    gest.param_id := chg.id;
    outEvents^.try_push(outEvents, @gest.header);

    FillChar(pev, SizeOf(pev), 0);
    pev.header.size := SizeOf(pev);
    pev.header.space_id := CLAP_CORE_EVENT_SPACE_ID;
    pev.header.event_type := CLAP_EVENT_PARAM_VALUE;
    pev.param_id := chg.id;
    pev.note_id := -1;
    pev.port_index := -1;
    pev.channel := -1;
    pev.key := -1;
    pev.value := inst^.params[idx];
    outEvents^.try_push(outEvents, @pev.header);

    gest.header.event_type := CLAP_EVENT_PARAM_GESTURE_END;
    outEvents^.try_push(outEvents, @gest.header);
  end;
end;

function ScopeProcess(inst: PScopeInstance; p: PClapProcess): Int32;
var
  i, n, evcount: UInt32;
  nch, ch: UInt32;
  wp, hs: UInt32;
  srcL, srcR, dst, src: PSingle;
  inb, outb: PClapAudioBuffer;
begin
  Result := CLAP_PROCESS_CONTINUE;
  n := p^.frames_count;

  { scope params don't need sample accuracy, apply everything up front }
  if p^.in_events <> nil then
  begin
    evcount := p^.in_events^.size(p^.in_events);
    i := 0;
    while i < evcount do
    begin
      ScopeHandleEvent(inst, p^.in_events^.get(p^.in_events, i));
      Inc(i);
    end;
  end;

  DrainParamQueue(inst, p^.out_events);

  if (p^.audio_inputs_count = 0) or (p^.audio_outputs_count = 0) or (n = 0) then
    Exit;

  inb := p^.audio_inputs;
  outb := p^.audio_outputs;
  if (inb^.data32 = nil) or (outb^.data32 = nil) then
    Exit(CLAP_PROCESS_ERROR);

  { pass-through, audio is untouched }
  nch := inb^.channel_count;
  if outb^.channel_count < nch then
    nch := outb^.channel_count;
  for ch := 0 to nch - 1 do
  begin
    src := inb^.data32[ch];
    dst := outb^.data32[ch];
    if dst <> src then
      Move(src^, dst^, n * SizeOf(Single));
  end;

  { capture unless holding }
  hs := inst^.histSize;
  if (hs = 0) or (inst^.params[PARAM_HOLD] >= 0.5) then
    Exit;

  srcL := inb^.data32[0];
  if inb^.channel_count > 1 then
    srcR := inb^.data32[1]
  else
    srcR := srcL;

  wp := inst^.writePos;
  for i := 0 to n - 1 do
  begin
    inst^.bufL[wp] := srcL[i];
    inst^.bufR[wp] := srcR[i];
    Inc(wp);
    if wp >= hs then wp := 0;
  end;
  inst^.writePos := wp;
end;

end.
