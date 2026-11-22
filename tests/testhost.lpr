program testhost;

{ Minimal CLAP host for the plugin library.
  No args: run all tests. -i: interactive demo window. }

{$mode objfpc}{$H+}
{$packrecords c}
{$pointermath on}
{$IFDEF WINDOWS}
  {$apptype console}
{$ENDIF}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils, dynlibs, clap_api, scope_state, logic_tests, testhost_window;

const
  NFRAMES = 512;
  SRATE = 48000.0;
  TWO_PI = 2 * Pi;

var
  GHost: TClapHost;
  GEvent: TClapEventParamValue;
  GEventCount: UInt32 = 0;
  GInteractive: Boolean = False;
  GRunning: Boolean = True;
  GUseTransport: Boolean = False;   { feed a playing 120 bpm transport }
  GDefaultsPath: AnsiString;        { where the plugin under test keeps its defaults }
  GStartSync: Boolean = False;
  GStartSplit: Boolean = False;
  GScale: Double = 0;
  GFmt: TFormatSettings;
  GGuiExt: PClapPluginGui = nil;   { interactive mode only }
  GPlug: PClapPlugin = nil;

var
  GDirtyCalls: Integer = 0;

procedure HostMarkDirty(host: PClapHost); cdecl;
begin
  Inc(GDirtyCalls);
end;

const
  GHostState: TClapHostState = (mark_dirty: @HostMarkDirty);

function HostGetExtension(host: PClapHost; extension_id: PAnsiChar): Pointer; cdecl;
begin
  Result := nil;
  if StrComp(extension_id, CLAP_EXT_STATE) = 0 then
    Result := @GHostState;
end;

procedure HostNoOp(host: PClapHost); cdecl;
begin
end;

function EvSize(list: PClapInputEvents): UInt32; cdecl;
begin
  Result := GEventCount;
end;

function EvGet(list: PClapInputEvents; index: UInt32): PClapEventHeader; cdecl;
begin
  Result := @GEvent.header;
end;

var
  GOutEvents: Integer = 0;
  GLastOutParamId: TClapId = CLAP_INVALID_ID;
  GLastOutParamVal: Double = 0;

function EvTryPush(list: PClapOutputEvents; event: PClapEventHeader): Boolean; cdecl;
begin
  Inc(GOutEvents);
  if (event <> nil) and (event^.space_id = CLAP_CORE_EVENT_SPACE_ID) and
     (event^.event_type = CLAP_EVENT_PARAM_VALUE) then
  begin
    GLastOutParamId := PClapEventParamValue(event)^.param_id;
    GLastOutParamVal := PClapEventParamValue(event)^.value;
  end;
  Result := True;
end;

{ the host window's events }

procedure HostResized(w, h: Integer);
begin
  if (GGuiExt <> nil) and (GPlug <> nil) then
    GGuiExt^.set_size(GPlug, w, h);
end;

procedure HostClosed;
begin
  if GGuiExt <> nil then
  begin
    GGuiExt^.hide(GPlug);
    GGuiExt^.destroy(GPlug);
    GGuiExt := nil;
  end;
end;

procedure Fail(const msg: string);
begin
  WriteLn('FAIL: ', msg);
  Halt(1);
end;

procedure SendParam(id: TClapId; value: Double);
begin
  FillChar(GEvent, SizeOf(GEvent), 0);
  GEvent.header.size := SizeOf(GEvent);
  GEvent.header.space_id := CLAP_CORE_EVENT_SPACE_ID;
  GEvent.header.event_type := CLAP_EVENT_PARAM_VALUE;
  GEvent.param_id := id;
  GEvent.note_id := -1;
  GEvent.port_index := -1;
  GEvent.channel := -1;
  GEvent.key := -1;
  GEvent.value := value;
  GEventCount := 1;
end;

{ state streams, a few bytes per call }

var
  GStream: array[0..255] of Byte;
  GStreamLen: Integer = 0;
  GStreamPos: Integer = 0;
  GStreamChunk: Integer = 3;

function StreamWrite(stream: PClapOStream; buffer: Pointer; size: UInt64): Int64; cdecl;
begin
  Result := GStreamChunk;
  if UInt64(Result) > size then Result := size;
  if GStreamLen + Result > SizeOf(GStream) then Exit(-1);
  Move(buffer^, GStream[GStreamLen], Result);
  Inc(GStreamLen, Result);
end;

function StreamRead(stream: PClapIStream; buffer: Pointer; size: UInt64): Int64; cdecl;
begin
  Result := GStreamChunk;
  if UInt64(Result) > size then Result := size;
  if Result > GStreamLen - GStreamPos then Result := GStreamLen - GStreamPos;
  Move(GStream[GStreamPos], buffer^, Result);
  Inc(GStreamPos, Result);
end;

var
  lib: TLibHandle;
  entry: PClapPluginEntry;
  factory: PClapPluginFactory;
  desc: PClapPluginDescriptor;
  plug: PClapPlugin;
  paramsExt: PClapPluginParams;
  stateExt: PClapPluginState;
  ostream: TClapOStream;
  istream: TClapIStream;
  oldState: array[0..4] of Double;
  nanBits: Int64;
  guiExt: PClapPluginGui;
  libPath: AnsiString;
  bufL, bufR, outL, outR: array[0..NFRAMES - 1] of Single;
  inPtrs, outPtrs: array[0..1] of PSingle;
  inBuf, outBuf: TClapAudioBuffer;
  inEvents: TClapInputEvents;
  outEvents: TClapOutputEvents;
  proc: TClapProcess;
  i: Integer;
  status: Int32;
  v, v2: Double;
  phase: Double = 0;
  phase2: Double = 0;
  lfoPhase: Double = 0;
  samplesFed: QWord = 0;
  target: QWord;
  clapWin: TClapWindow;
  gw, gh: UInt32;
  cw, ch: Integer;
  t0: QWord;
  apiName: PAnsiChar;
  floating: Boolean;
  txt: array[0..63] of AnsiChar;

function ParamNow(id: TClapId): Double;
begin
  Result := 0;
  if not paramsExt^.get_value(plug, id, @Result) then Fail('get_value');
end;

{ press, move by (dx, dy), release }
procedure MouseDrag(x, y, dx, dy: Integer);
var
  k: Integer;
begin
  EditorPress(x, y);
  for k := 1 to 4 do
    EditorMove(x + dx * k div 4, y + dy * k div 4);
  EditorRelease(x + dx, y + dy);
end;

procedure MouseClick(x, y: Integer);
begin
  EditorPress(x, y);
  EditorRelease(x, y);
end;

{ the second click of a double click }
procedure MouseDoubleClick(x, y: Integer);
begin
  EditorPress(x, y, True);
  EditorRelease(x, y);
end;

procedure ProcessSineBlock; forward;
procedure SetParamNow(id: TClapId; value: Double); forward;

{ items are found by probing: their position depends on the font }
procedure TestStatusControls(scale: Double);
var
  sy, x, xLen, xRange, xTrig: Integer;
  v0, z0, v1: Double;
begin
  sy := Round(12 * scale);
  SetParamNow(PARAM_VIEW_MS, 50.0);
  SetParamNow(PARAM_VZOOM_DB, 0.0);
  SetParamNow(PARAM_RETRIG, 0.0);
  Sleep(100);

  xLen := -1; xRange := -1;
  x := 4;
  while (x < Round(500 * scale)) and ((xLen < 0) or (xRange < 0)) do
  begin
    { sideways too: a miss must be a drag, not a click }
    MouseDrag(x, sy, 10, -20);
    if (xLen < 0) and (ParamNow(PARAM_VIEW_MS) > 50.0 + 1e-6) then xLen := x;
    if (xRange < 0) and (ParamNow(PARAM_VZOOM_DB) > 1e-6) then xRange := x;
    SetParamNow(PARAM_VIEW_MS, 50.0);
    SetParamNow(PARAM_VZOOM_DB, 0.0);
    Inc(x, 6);
  end;
  if xLen < 0 then Fail('status: len does not respond to dragging');
  if xRange < 0 then Fail('status: range does not respond to dragging');
  if xRange <= xLen then Fail('status: range is not to the right of len');
  Inc(xLen, Round(12 * scale));
  Inc(xRange, Round(12 * scale));

  { range: 0.25 dB per pixel }
  GOutEvents := 0;
  GDirtyCalls := 0;
  MouseDrag(xRange, sy, 0, 8);
  ProcessSineBlock;
  z0 := ParamNow(PARAM_VZOOM_DB);
  if Abs(z0 + 2.0) > 1e-9 then Fail(Format('status: range drag gave %.3f dB, expected -2', [z0]));
  if (GOutEvents < 3) or (GLastOutParamId <> PARAM_VZOOM_DB) or
     (Abs(GLastOutParamVal - z0) > 1e-9) then
    Fail('status: range drag not reported to the host');
  if GDirtyCalls = 0 then Fail('status: host state not marked dirty');
  MouseDoubleClick(xRange, sy);
  if ParamNow(PARAM_VZOOM_DB) <> 0.0 then Fail('status: double click did not reset range');

  { v-zoom stops at 0 dB }
  SetParamNow(PARAM_VZOOM_DB, -1.28);
  EditorWheel(0, 0, -1, True);
  if ParamNow(PARAM_VZOOM_DB) <> 0.0 then
    Fail(Format('v-zoom: step over 0 dB gave %.3f, expected 0', [ParamNow(PARAM_VZOOM_DB)]));
  EditorWheel(0, 0, -1, True);
  if Abs(ParamNow(PARAM_VZOOM_DB) - 3.0) > 1e-9 then Fail('v-zoom: step from 0 dB');
  EditorWheel(0, 0, 2, True);
  if ParamNow(PARAM_VZOOM_DB) <> 0.0 then Fail('v-zoom: step back over 0 dB should stop there');

  { trig: first spot right of range that reacts to a click }
  xTrig := -1;
  x := xRange;
  while (x < Round(600 * scale)) and (xTrig < 0) do
  begin
    MouseClick(x, sy);
    if ParamNow(PARAM_RETRIG) <> 0.0 then xTrig := x;
    Inc(x, 6);
  end;
  if xTrig < 0 then Fail('status: trig does not respond to clicks');
  if ParamNow(PARAM_RETRIG) <> 1.0 then Fail('status: trig click should step to "any"');
  if ParamNow(PARAM_HOLD) >= 0.5 then Fail('status: probing toggled hold');
  { released off trig: not a click }
  EditorPress(xTrig, sy);
  EditorRelease(xTrig, sy + Round(150 * scale));
  if ParamNow(PARAM_RETRIG) <> 1.0 then Fail('status: release off trig still clicked');
  if ParamNow(PARAM_HOLD) >= 0.5 then Fail('status: release off trig toggled hold');

  { sync: the item right of trig toggles on a click }
  x := xTrig;
  while (x < Round(700 * scale)) and (ParamNow(PARAM_SYNC) = 0.0) do
  begin
    MouseClick(x, sy);
    Inc(x, 6);
  end;
  if ParamNow(PARAM_SYNC) <> 1.0 then Fail('status: sync does not respond to clicks');
  MouseClick(x - 6, sy);
  if ParamNow(PARAM_SYNC) <> 0.0 then Fail('status: second click should turn sync off');
  if ParamNow(PARAM_HOLD) >= 0.5 then Fail('status: clicking sync toggled hold');
  { split: the item right of sync }
  while (x < Round(780 * scale)) and (ParamNow(PARAM_SPLIT) = 0.0) do
  begin
    MouseClick(x, sy);
    Inc(x, 6);
  end;
  if ParamNow(PARAM_SPLIT) <> 1.0 then Fail('status: split does not respond to clicks');
  if ParamNow(PARAM_HOLD) >= 0.5 then Fail('status: clicking split toggled hold');
  SetParamNow(PARAM_SYNC, 0.0);
  SetParamNow(PARAM_SPLIT, 0.0);
  SetParamNow(PARAM_RETRIG, 0.0);

  { len: up = longer }
  v0 := ParamNow(PARAM_VIEW_MS);
  MouseDrag(xLen, sy, 0, -50);
  v1 := ParamNow(PARAM_VIEW_MS);
  if Abs(v1 / v0 - Exp(0.5)) > 1e-6 then
    Fail(Format('status: len drag %.3f -> %.3f, expected x%.4f', [v0, v1, Exp(0.5)]));
  MouseDoubleClick(xLen, sy);
  if ParamNow(PARAM_VIEW_MS) <> 2740.0 then Fail('status: double click did not reset len');

  { a double click elsewhere is two clicks }
  MouseClick(400, Round(200 * scale));
  MouseDoubleClick(400, Round(200 * scale));
  if ParamNow(PARAM_HOLD) >= 0.5 then Fail('double click should toggle hold twice');

  { sync: with a host transport, len picks the number of bars instead }
  GUseTransport := True;
  SetParamNow(PARAM_SYNC, 1.0);
  for x := 1 to 20 do
  begin
    ProcessSineBlock;
    Sleep(10);
  end;
  v0 := ParamNow(PARAM_VIEW_MS);
  if ParamNow(PARAM_SYNC_LEN) <> SYNC_LEN_DEFAULT then Fail('sync: default length');
  MouseDrag(xLen, sy, 0, -40);   { two steps of 18 px }
  if ParamNow(PARAM_SYNC_LEN) <> SYNC_LEN_DEFAULT + 2 then
    Fail(Format('sync: len drag gave index %.0f', [ParamNow(PARAM_SYNC_LEN)]));
  MouseDoubleClick(xLen, sy);
  if ParamNow(PARAM_SYNC_LEN) <> SYNC_LEN_DEFAULT then Fail('sync: double click did not reset the length');
  { the wheel zooms inside the cycle and never changes its length }
  EditorWheel(0, 0, 1);
  for x := 1 to 4 do
    EditorWheel(0, 0, -1);
  if ParamNow(PARAM_SYNC_LEN) <> SYNC_LEN_DEFAULT then Fail('sync: the wheel changed the length');

  if ParamNow(PARAM_VIEW_MS) <> v0 then Fail('sync: view size changed while synced');
  if not paramsExt^.value_to_text(plug, PARAM_SYNC_LEN, 4.0, @txt[0], SizeOf(txt)) or
     (StrComp(PAnsiChar(@txt[0]), '4 bars') <> 0) then
    Fail('sync: length text');
  { no transport: len still sets the length in bars }
  GUseTransport := False;
  for x := 1 to 10 do
  begin
    ProcessSineBlock;
    Sleep(10);
  end;
  MouseDrag(xLen, sy, 0, -20);
  if ParamNow(PARAM_SYNC_LEN) <> SYNC_LEN_DEFAULT + 1 then
    Fail('sync: len should set bars without a host tempo too');
  if ParamNow(PARAM_VIEW_MS) <> v0 then Fail('sync: view size changed without a host tempo');
  MouseDoubleClick(xLen, sy);
  SetParamNow(PARAM_SYNC, 0.0);
  for x := 1 to 10 do
  begin
    ProcessSineBlock;
    Sleep(10);
  end;

  SetParamNow(PARAM_VIEW_MS, 50.0);
  WriteLn('status line controls: ok');
end;

var
  GTransport: TClapEventTransport;
  GSongFrames: Int64 = 0;

{ 120 bpm, 4/4, playing }
procedure UpdateTransport;
var
  beats: Double;
begin
  FillChar(GTransport, SizeOf(GTransport), 0);
  beats := GSongFrames / (SRATE * 60.0 / 120.0);
  GTransport.flags := CLAP_TRANSPORT_HAS_TEMPO or CLAP_TRANSPORT_HAS_BEATS_TIMELINE or
    CLAP_TRANSPORT_HAS_TIME_SIGNATURE or CLAP_TRANSPORT_IS_PLAYING;
  GTransport.song_pos_beats := Round(beats * CLAP_BEATTIME_FACTOR);
  GTransport.bar_number := Trunc(beats / 4);
  GTransport.bar_start := Round(GTransport.bar_number * 4.0 * CLAP_BEATTIME_FACTOR);
  GTransport.tempo := 120.0;
  GTransport.tsig_num := 4;
  GTransport.tsig_denom := 4;
  Inc(GSongFrames, NFRAMES);
end;

procedure ProcessSineBlock;
var
  k: Integer;
  ampL: Double;
begin
  proc.transport := nil;
  if GUseTransport then
  begin
    UpdateTransport;
    proc.transport := @GTransport;
  end;
  { 220 Hz + slow AM on the left, 330 Hz with vibrato on the right }
  for k := 0 to NFRAMES - 1 do
  begin
    ampL := 0.55 + 0.45 * Sin(lfoPhase);
    bufL[k] := Single(0.7 * ampL * Sin(phase));
    bufR[k] := Single(0.4 * Sin(phase2));
    phase := phase + TWO_PI * 220.0 / SRATE;
    phase2 := phase2 + TWO_PI * (330.0 + 20.0 * Sin(lfoPhase * 3.0)) / SRATE;
    lfoPhase := lfoPhase + TWO_PI * 0.35 / SRATE;
    if phase > TWO_PI then phase := phase - TWO_PI;
    if phase2 > TWO_PI then phase2 := phase2 - TWO_PI;
    if lfoPhase > TWO_PI then lfoPhase := lfoPhase - TWO_PI;
  end;
  status := plug^.process(plug, @proc);
  if status = CLAP_PROCESS_ERROR then Fail('process returned ERROR');
  GEventCount := 0;
end;

{ set a param the way a host does }
procedure SetParamNow(id: TClapId; value: Double);
begin
  SendParam(id, value);
  ProcessSineBlock;
end;

begin
  GInteractive := (ParamCount > 0) and
    ((ParamStr(1) = '-i') or (ParamStr(1) = '--interactive'));
  { -i extras: --sync / --split start in that mode, -s N sets the UI scale }
  GFmt := DefaultFormatSettings;
  GFmt.DecimalSeparator := '.';
  for i := 2 to ParamCount do
  begin
    if ParamStr(i) = '--sync' then GStartSync := True;
    if ParamStr(i) = '--split' then GStartSplit := True;
    if (ParamStr(i) = '-s') and (i < ParamCount) then
      GScale := StrToFloatDef(ParamStr(i + 1), 0, GFmt);
  end;

  if not GInteractive then
  begin
    RunLogicTests;
    RunStressTest;
  end;

  { the library sits next to the exe or one directory up }
  libPath := ExtractFilePath(ParamStr(0)) + PLUGIN_LIB;
  if not FileExists(libPath) then
    libPath := ExtractFilePath(ParamStr(0)) + '..' + PathDelim + PLUGIN_LIB;
  if not FileExists(libPath) then Fail(PLUGIN_LIB + ' not found near ' + ParamStr(0));

  { the user's own defaults stay out of the tests }
  GDefaultsPath := GetTempDir + 'lzscope-test-defaults.bin';
  DeleteFile(GDefaultsPath);
  HostSetEnv('LZSCOPE_DEFAULTS', GDefaultsPath);

  lib := LoadLibrary(libPath);
  if lib = NilHandle then Fail('LoadLibrary: ' + libPath);

  entry := PClapPluginEntry(GetProcedureAddress(lib, 'clap_entry'));
  if entry = nil then Fail('clap_entry symbol not found');
  if entry^.clap_version.major < 1 then Fail('bad clap version');
  if not entry^.init(PAnsiChar(libPath)) then Fail('entry.init');

  factory := PClapPluginFactory(entry^.get_factory(CLAP_PLUGIN_FACTORY_ID));
  if factory = nil then Fail('get_factory');
  desc := factory^.get_plugin_descriptor(factory, 0);
  if desc = nil then Fail('descriptor');
  WriteLn('plugin: ', desc^.id, ' / ', desc^.name, ' v', desc^.version);
  if StrComp(desc^.id, 'com.dsgdnb.lzscope') <> 0 then Fail('unexpected plugin id');

  FillChar(GHost, SizeOf(GHost), 0);
  GHost.clap_version.major := 1;
  GHost.clap_version.minor := 2;
  GHost.name := 'testhost';
  GHost.vendor := 'DsgDnB';
  GHost.url := '';
  GHost.version := '1.0';
  GHost.get_extension := @HostGetExtension;
  GHost.request_restart := @HostNoOp;
  GHost.request_process := @HostNoOp;
  GHost.request_callback := @HostNoOp;

  plug := factory^.create_plugin(factory, @GHost, desc^.id);
  if plug = nil then Fail('create_plugin');
  if not plug^.init(plug) then Fail('plugin.init');
  if not plug^.activate(plug, SRATE, 1, NFRAMES) then Fail('activate');
  if not plug^.start_processing(plug) then Fail('start_processing');

  inPtrs[0] := @bufL[0]; inPtrs[1] := @bufR[0];
  outPtrs[0] := @outL[0]; outPtrs[1] := @outR[0];
  FillChar(inBuf, SizeOf(inBuf), 0);
  inBuf.data32 := @inPtrs[0];
  inBuf.channel_count := 2;
  FillChar(outBuf, SizeOf(outBuf), 0);
  outBuf.data32 := @outPtrs[0];
  outBuf.channel_count := 2;
  inEvents.ctx := nil;
  inEvents.size := @EvSize;
  inEvents.get := @EvGet;
  outEvents.ctx := nil;
  outEvents.try_push := @EvTryPush;
  FillChar(proc, SizeOf(proc), 0);
  proc.frames_count := NFRAMES;
  proc.audio_inputs := @inBuf;
  proc.audio_outputs := @outBuf;
  proc.audio_inputs_count := 1;
  proc.audio_outputs_count := 1;
  proc.in_events := @inEvents;
  proc.out_events := @outEvents;

  { pass-through }
  ProcessSineBlock;
  for i := 0 to NFRAMES - 1 do
    if (outL[i] <> bufL[i]) or (outR[i] <> bufR[i]) then
      Fail('pass-through mismatch at sample ' + IntToStr(i));
  WriteLn('pass-through: ok');

  { param event -> get_value }
  paramsExt := PClapPluginParams(plug^.get_extension(plug, CLAP_EXT_PARAMS));
  if paramsExt = nil then Fail('params extension missing');
  if paramsExt^.count(plug) <> PARAM_COUNT then Fail('params count');
  SendParam(PARAM_VIEW_MS, 50.0);
  ProcessSineBlock;
  if not paramsExt^.get_value(plug, PARAM_VIEW_MS, @v) then Fail('get_value');
  if Abs(v - 50.0) > 1e-9 then Fail(Format('view size = %.3f, expected 50', [v]));
  if not paramsExt^.value_to_text(plug, PARAM_RETRIG, 2.0, @txt[0], SizeOf(txt)) then
    Fail('value_to_text');
  if StrComp(PAnsiChar(@txt[0]), 'ascending') <> 0 then
    Fail('retrig text: ' + AnsiString(PAnsiChar(@txt[0])));
  if not paramsExt^.text_to_value(plug, PARAM_VIEW_MS, '1.5 s', @v) then
    Fail('text_to_value');
  if Abs(v - 1500.0) > 1e-6 then Fail(Format('text_to_value 1.5s = %.3f', [v]));
  WriteLn('params: ok');

  { state, 3 bytes per call }
  stateExt := PClapPluginState(plug^.get_extension(plug, CLAP_EXT_STATE));
  if stateExt = nil then Fail('state extension missing');
  ostream.ctx := nil;
  ostream.write := @StreamWrite;
  istream.ctx := nil;
  istream.read := @StreamRead;
  SendParam(PARAM_VZOOM_DB, -12.0);
  ProcessSineBlock;
  GStreamLen := 0;
  if not stateExt^.save(plug, @ostream) then Fail('state.save');
  SendParam(PARAM_VIEW_MS, 777.0);
  ProcessSineBlock;
  SendParam(PARAM_VZOOM_DB, 6.0);
  ProcessSineBlock;
  GStreamPos := 0;
  if not stateExt^.load(plug, @istream) then Fail('state.load');
  paramsExt^.get_value(plug, PARAM_VIEW_MS, @v);
  if Abs(v - 50.0) > 1e-9 then Fail(Format('state: view size %.3f, expected 50', [v]));
  paramsExt^.get_value(plug, PARAM_VZOOM_DB, @v);
  if Abs(v + 12.0) > 1e-9 then Fail(Format('state: v-zoom %.3f, expected -12', [v]));

  { truncated: must fail and change nothing }
  SendParam(PARAM_VIEW_MS, 321.0);
  ProcessSineBlock;
  Dec(GStreamLen, 5);
  GStreamPos := 0;
  if stateExt^.load(plug, @istream) then Fail('truncated state accepted');
  paramsExt^.get_value(plug, PARAM_VIEW_MS, @v);
  if Abs(v - 321.0) > 1e-9 then Fail('truncated state changed a param');

  { 1.0.0 layout; NaN falls back to the default }
  PUInt32(@GStream[0])^ := $4C5A5030;
  oldState[0] := 250.0;
  oldState[1] := 3.0;
  nanBits := $7FF8000000000000;
  Move(nanBits, oldState[2], 8);
  oldState[3] := 0.0;
  Move(oldState[0], GStream[4], 32);
  GStreamLen := 36;
  GStreamPos := 0;
  if not stateExt^.load(plug, @istream) then Fail('old state rejected');
  paramsExt^.get_value(plug, PARAM_VIEW_MS, @v);
  if Abs(v - 250.0) > 1e-9 then Fail('old state: view size');
  paramsExt^.get_value(plug, PARAM_RETRIG, @v);
  if v <> 0.0 then Fail('NaN in state did not fall back to the default');
  SendParam(PARAM_VIEW_MS, 50.0);
  ProcessSineBlock;
  SendParam(PARAM_VZOOM_DB, 0.0);
  ProcessSineBlock;
  WriteLn('state: ok');

  { GUI smoke test }
  guiExt := PClapPluginGui(plug^.get_extension(plug, CLAP_EXT_GUI));
  if guiExt = nil then Fail('gui extension missing');
  if not guiExt^.is_api_supported(plug, HOST_WINDOW_API, False) then
    Fail(HOST_WINDOW_API + ' embedded api not supported');
  if not guiExt^.get_preferred_api(plug, @apiName, @floating) then
    Fail('get_preferred_api');
  WriteLn('preferred api: ', apiName, ' floating=', floating);

  if not guiExt^.create(plug, HOST_WINDOW_API, False) then Fail('gui.create');
  { the order hosts use: create, set_scale, get_size }
  if GScale > 0 then guiExt^.set_scale(plug, GScale);
  if not guiExt^.get_size(plug, @gw, @gh) then Fail('gui.get_size');
  WriteLn(Format('gui size: %dx%d', [gw, gh]));

  OnHostResize := @HostResized;
  OnHostClose := @HostClosed;
  if not HostWindowOpen(gw, gh, 'lzScope testhost') then Fail('host window');
  clapWin.api := HOST_WINDOW_API;
  clapWin.handle := HostWindowHandle;
  if not guiExt^.set_parent(plug, @clapWin) then Fail('gui.set_parent');
  if not guiExt^.show(plug) then Fail('gui.show');

  if GInteractive then
  begin
    WriteLn('interactive mode: close the window to exit');
    GUseTransport := True;
    if GStartSplit then
    begin
      SendParam(PARAM_SPLIT, 1.0);
      ProcessSineBlock;
    end;
    if GStartSync then
    begin
      SendParam(PARAM_SYNC, 1.0);
      ProcessSineBlock;
    end;
    GPlug := plug;
    GGuiExt := guiExt;

    HostWindowClientSize(cw, ch);
    guiExt^.set_size(plug, cw, ch);
    HostWindowFocus;

    { feed audio in real time }
    t0 := GetTickCount64;
    samplesFed := 0;
    while GRunning do
    begin
      GRunning := HostPump;
      target := QWord(GetTickCount64 - t0) * 48;
      while samplesFed < target do
      begin
        ProcessSineBlock;
        Inc(samplesFed, NFRAMES);
      end;
      Sleep(5);
    end;
    WriteLn('window closed');
  end
  else
  begin
    { wheel -> gesture + value events }
    if not EditorFind then Fail('plugin child window not found');
    GOutEvents := 0;
    EditorWheel(0, 0, 1);
    ProcessSineBlock;
    if GOutEvents < 3 then
      Fail(Format('expected >=3 out events (gesture+value), got %d', [GOutEvents]));
    if GLastOutParamId <> PARAM_VIEW_MS then Fail('wrong out param id');
    if GLastOutParamVal >= 50.0 then
      Fail(Format('wheel up should zoom in below 50 ms, got %.3f', [GLastOutParamVal]));
    if not paramsExt^.get_value(plug, PARAM_VIEW_MS, @v) then Fail('get_value 2');
    if Abs(v - GLastOutParamVal) > 1e-9 then Fail('param/event value mismatch');
    WriteLn(Format('gui->host params: ok (view size now %.2f ms)', [v]));

    { about: open, then a click closes it without toggling hold }
    MouseClick(785, 15);
    t0 := GetTickCount64;
    while GetTickCount64 - t0 < 300 do
    begin
      HostPump;
      ProcessSineBlock;
      Sleep(10);
    end;
    MouseClick(400, 200);
    if not paramsExt^.get_value(plug, PARAM_HOLD, @v) then Fail('get hold');
    if v >= 0.5 then Fail('click on about overlay must close it, not toggle hold');
    MouseClick(400, 200);
    if not paramsExt^.get_value(plug, PARAM_HOLD, @v) then Fail('get hold 2');
    if v < 0.5 then Fail('plain click should toggle hold on');
    MouseClick(400, 200);
    WriteLn('about overlay + click routing: ok');

    { save default: writes the file, does not toggle hold }
    MouseClick(710, 15);
    if not FileExists(GDefaultsPath) then Fail('save default: no file written');
    { a double click on len now resets to the saved value }
    if not paramsExt^.get_value(plug, PARAM_VIEW_MS, @v) then Fail('get view size');
    EditorWheel(0, 0, 3);
    MouseDoubleClick(40, 15);
    if not paramsExt^.get_value(plug, PARAM_VIEW_MS, @v2) then Fail('get view size 2');
    if Abs(v2 - v) > 1e-9 then
      Fail(Format('double click should reset len to the saved %.3f, got %.3f', [v, v2]));
    DeleteFile(GDefaultsPath);
    if not paramsExt^.get_value(plug, PARAM_HOLD, @v) then Fail('get hold 3');
    if v >= 0.5 then Fail('save default toggled hold');
    WriteLn('save default: ok');

    { let the render thread run }
    t0 := GetTickCount64;
    while GetTickCount64 - t0 < 1500 do
    begin
      HostPump;
      ProcessSineBlock;
      Sleep(10);
    end;

    TestStatusControls(gw / 800.0);

    if not guiExt^.set_size(plug, 500, 300) then Fail('gui.set_size');
    t0 := GetTickCount64;
    while GetTickCount64 - t0 < 300 do
    begin
      HostPump;
      ProcessSineBlock;
      Sleep(10);
    end;
    WriteLn('gui: ok (render thread ran ~1.8 s)');

    guiExt^.hide(plug);
    guiExt^.destroy(plug);
  end;
  HostWindowFree;

  plug^.stop_processing(plug);
  plug^.deactivate(plug);
  plug^.destroy(plug);
  entry^.deinit();
  UnloadLibrary(lib);
  WriteLn('ALL TESTS PASSED');
end.
