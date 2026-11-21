unit scope_dsp;

{ Audio side: buffers, param events, process (pass-through + capture) }

{$mode objfpc}{$H+}
{$packrecords c}
{$pointermath on}

interface

uses
  clap_api, scope_ring, scope_state;

{ False = bad sample rate or out of memory }
function ScopeConfigure(inst: PScopeInstance; sampleRate: Double): Boolean;
procedure ScopeReleaseBuffers(inst: PScopeInstance);
procedure ScopeClear(inst: PScopeInstance);
procedure ScopeHandleEvent(inst: PScopeInstance; hdr: PClapEventHeader);
function ScopeProcess(inst: PScopeInstance; p: PClapProcess): Int32;

procedure ReportDirtyParams(inst: PScopeInstance; outEvents: PClapOutputEvents);

implementation

function ScopeConfigure(inst: PScopeInstance; sampleRate: Double): Boolean;
begin
  System.EnterCriticalSection(inst^.lock);
  try
    RingFree(inst^.ring);
    Result := (not IsNaNValue(sampleRate)) and
      (sampleRate >= MIN_SAMPLE_RATE) and (sampleRate <= MAX_SAMPLE_RATE);
    if not Result then Exit;
    inst^.srate := sampleRate;
    Result := RingAlloc(inst^.ring, Round(sampleRate * HIST_SECONDS));
  finally
    System.LeaveCriticalSection(inst^.lock);
  end;
end;

procedure ScopeReleaseBuffers(inst: PScopeInstance);
begin
  System.EnterCriticalSection(inst^.lock);
  try
    RingFree(inst^.ring);
  finally
    System.LeaveCriticalSection(inst^.lock);
  end;
end;

procedure ScopeClear(inst: PScopeInstance);
begin
  RingClear(inst^.ring);
end;

{ starting playback releases hold }
procedure NoteTransport(inst: PScopeInstance; flags: UInt32);
var
  playing: Boolean;
begin
  playing := (flags and CLAP_TRANSPORT_IS_PLAYING) <> 0;
  if playing and (not inst^.wasPlaying) and
     (GetParam(inst, PARAM_HOLD) >= 0.5) then
  begin
    SetParam(inst, PARAM_HOLD, 0.0);
    MarkParamDirty(inst, PARAM_HOLD);
  end;
  inst^.wasPlaying := playing;
end;

procedure ScopeHandleEvent(inst: PScopeInstance; hdr: PClapEventHeader);
var
  pev: PClapEventParamValue;
  idx: Integer;
begin
  if (hdr = nil) or (hdr^.space_id <> CLAP_CORE_EVENT_SPACE_ID) then
    Exit;
  if hdr^.event_type = CLAP_EVENT_TRANSPORT then
    NoteTransport(inst, PClapEventTransport(hdr)^.flags)
  else if hdr^.event_type = CLAP_EVENT_PARAM_VALUE then
  begin
    pev := PClapEventParamValue(hdr);
    idx := ParamIndex(pev^.param_id);
    if idx >= 0 then
      SetParam(inst, idx, ClampParam(idx, pev^.value));
  end;
end;

procedure ReportDirtyParams(inst: PScopeInstance; outEvents: PClapOutputEvents);
var
  mask: LongInt;
  idx: Integer;
  gest: TClapEventParamGesture;
  pev: TClapEventParamValue;
begin
  if (outEvents = nil) or (outEvents^.try_push = nil) then
    Exit;
  mask := TakeDirtyParams(inst);
  if mask = 0 then Exit;

  for idx := 0 to PARAM_COUNT - 1 do
  begin
    if mask and (1 shl idx) = 0 then Continue;

    FillChar(gest, SizeOf(gest), 0);
    gest.header.size := SizeOf(gest);
    gest.header.space_id := CLAP_CORE_EVENT_SPACE_ID;
    gest.header.event_type := CLAP_EVENT_PARAM_GESTURE_BEGIN;
    gest.param_id := ParamDefs[idx].id;
    outEvents^.try_push(outEvents, @gest.header);

    FillChar(pev, SizeOf(pev), 0);
    pev.header.size := SizeOf(pev);
    pev.header.space_id := CLAP_CORE_EVENT_SPACE_ID;
    pev.header.event_type := CLAP_EVENT_PARAM_VALUE;
    pev.param_id := ParamDefs[idx].id;
    pev.note_id := -1;
    pev.port_index := -1;
    pev.channel := -1;
    pev.key := -1;
    pev.value := GetParam(inst, idx);
    outEvents^.try_push(outEvents, @pev.header);

    gest.header.event_type := CLAP_EVENT_PARAM_GESTURE_END;
    outEvents^.try_push(outEvents, @gest.header);
  end;
end;

function ScopeProcess(inst: PScopeInstance; p: PClapProcess): Int32;
var
  i, n, evcount: UInt32;
  nin, nout, ch: UInt32;
  srcL, srcR, dst, src: PSingle;
  inb, outb: PClapAudioBuffer;
begin
  Result := CLAP_PROCESS_CONTINUE;
  n := p^.frames_count;

  { transport first, so a hold set by the host in this block wins }
  if p^.transport <> nil then
    NoteTransport(inst, p^.transport^.flags);

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

  ReportDirtyParams(inst, p^.out_events);

  if (p^.audio_inputs_count = 0) or (n = 0) then
    Exit;
  inb := p^.audio_inputs;
  nin := inb^.channel_count;
  if nin = 0 then Exit;
  if inb^.data32 = nil then
    Exit(CLAP_PROCESS_ERROR);

  { pass-through; mono input feeds every output }
  if p^.audio_outputs_count > 0 then
  begin
    outb := p^.audio_outputs;
    nout := outb^.channel_count;
    if (nout > 0) and (outb^.data32 = nil) then
      Exit(CLAP_PROCESS_ERROR);
    ch := 0;
    while ch < nout do
    begin
      if ch < nin then
        src := inb^.data32[ch]
      else
        src := inb^.data32[nin - 1];
      dst := outb^.data32[ch];
      if dst <> src then
        Move(src^, dst^, n * SizeOf(Single));
      Inc(ch);
    end;
  end;

  { capture unless holding }
  if GetParam(inst, PARAM_HOLD) >= 0.5 then
    Exit;
  srcL := inb^.data32[0];
  if nin > 1 then
    srcR := inb^.data32[1]
  else
    srcR := srcL;
  RingWrite(inst^.ring, srcL, srcR, n);
end;

end.
