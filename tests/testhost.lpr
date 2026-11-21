program testhost;

{ Minimal CLAP host for lzscope.dll.
  No args: run all tests. -i: interactive demo window. }

{$mode objfpc}{$H+}
{$packrecords c}
{$pointermath on}
{$apptype console}

uses
  SysUtils, Windows, clap_api, scope_state, logic_tests;

const
  NFRAMES = 512;
  SRATE = 48000.0;
  TWO_PI = 2 * Pi;
  HOST_CLASS: PWideChar = 'lzScopeTestHostWnd';

var
  GHost: TClapHost;
  GEvent: TClapEventParamValue;
  GEventCount: UInt32 = 0;
  GInteractive: Boolean = False;
  GRunning: Boolean = True;
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

function HostWndProc(hw: HWND; msg: UINT; wp: WPARAM; lp: LPARAM): LRESULT; stdcall;
var
  cw, ch: Integer;
begin
  case msg of
    WM_SIZE:
      if (GGuiExt <> nil) and (GPlug <> nil) then
      begin
        cw := Integer(lp and $FFFF);
        ch := Integer((lp shr 16) and $FFFF);
        if (cw > 0) and (ch > 0) then
          GGuiExt^.set_size(GPlug, cw, ch);
        Exit(0);
      end;
    WM_CLOSE:
      begin
        { destroy the editor before its parent }
        if GGuiExt <> nil then
        begin
          GGuiExt^.hide(GPlug);
          GGuiExt^.destroy(GPlug);
          GGuiExt := nil;
        end;
        DestroyWindow(hw);
        Exit(0);
      end;
    WM_DESTROY:
      begin
        GRunning := False;
        PostQuitMessage(0);
        Exit(0);
      end;
  end;
  Result := DefWindowProcW(hw, msg, wp, lp);
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
  lib: HMODULE;
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
  dllPath: AnsiString;
  bufL, bufR, outL, outR: array[0..NFRAMES - 1] of Single;
  inPtrs, outPtrs: array[0..1] of PSingle;
  inBuf, outBuf: TClapAudioBuffer;
  inEvents: TClapInputEvents;
  outEvents: TClapOutputEvents;
  proc: TClapProcess;
  i: Integer;
  status: Int32;
  v: Double;
  phase: Double = 0;
  phase2: Double = 0;
  lfoPhase: Double = 0;
  samplesFed: QWord = 0;
  target: QWord;
  rectCl: TRect;
  wc: WNDCLASSW;
  hostWnd, childWnd: HWND;
  clapWin: TClapWindow;
  gw, gh: UInt32;
  m: MSG;
  t0: QWord;
  apiName: PAnsiChar;
  floating: Boolean;
  txt: array[0..63] of AnsiChar;

function ParamNow(id: TClapId): Double;
begin
  Result := 0;
  if not paramsExt^.get_value(plug, id, @Result) then Fail('get_value');
end;

function MouseLP(x, y: Integer): LPARAM;
begin
  Result := LPARAM(((y and $FFFF) shl 16) or (x and $FFFF));
end;

{ press, move by (dx, dy), release }
procedure MouseDrag(x, y, dx, dy: Integer);
var
  k: Integer;
begin
  SendMessageW(childWnd, WM_LBUTTONDOWN, MK_LBUTTON, MouseLP(x, y));
  for k := 1 to 4 do
    SendMessageW(childWnd, WM_MOUSEMOVE, MK_LBUTTON,
      MouseLP(x + dx * k div 4, y + dy * k div 4));
  SendMessageW(childWnd, WM_LBUTTONUP, 0, MouseLP(x + dx, y + dy));
end;

procedure MouseClick(x, y: Integer);
begin
  SendMessageW(childWnd, WM_LBUTTONDOWN, MK_LBUTTON, MouseLP(x, y));
  SendMessageW(childWnd, WM_LBUTTONUP, 0, MouseLP(x, y));
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
  SendMessageW(childWnd, WM_LBUTTONDBLCLK, MK_LBUTTON, MouseLP(xRange, sy));
  SendMessageW(childWnd, WM_LBUTTONUP, 0, MouseLP(xRange, sy));
  if ParamNow(PARAM_VZOOM_DB) <> 0.0 then Fail('status: double click did not reset range');

  { v-zoom stops at 0 dB }
  SetParamNow(PARAM_VZOOM_DB, -1.28);
  SendMessageW(childWnd, WM_MOUSEWHEEL, WPARAM((-120 and $FFFF) shl 16) or MK_CONTROL, 0);
  if ParamNow(PARAM_VZOOM_DB) <> 0.0 then
    Fail(Format('v-zoom: step over 0 dB gave %.3f, expected 0', [ParamNow(PARAM_VZOOM_DB)]));
  SendMessageW(childWnd, WM_MOUSEWHEEL, WPARAM((-120 and $FFFF) shl 16) or MK_CONTROL, 0);
  if Abs(ParamNow(PARAM_VZOOM_DB) - 3.0) > 1e-9 then Fail('v-zoom: step from 0 dB');
  SendMessageW(childWnd, WM_MOUSEWHEEL, WPARAM(240 shl 16) or MK_CONTROL, 0);
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
  SendMessageW(childWnd, WM_LBUTTONDOWN, MK_LBUTTON, MouseLP(xTrig, sy));
  SendMessageW(childWnd, WM_LBUTTONUP, 0, MouseLP(xTrig, sy + Round(150 * scale)));
  if ParamNow(PARAM_RETRIG) <> 1.0 then Fail('status: release off trig still clicked');
  if ParamNow(PARAM_HOLD) >= 0.5 then Fail('status: release off trig toggled hold');
  SetParamNow(PARAM_RETRIG, 0.0);

  { len: up = longer }
  v0 := ParamNow(PARAM_VIEW_MS);
  MouseDrag(xLen, sy, 0, -50);
  v1 := ParamNow(PARAM_VIEW_MS);
  if Abs(v1 / v0 - Exp(0.5)) > 1e-6 then
    Fail(Format('status: len drag %.3f -> %.3f, expected x%.4f', [v0, v1, Exp(0.5)]));
  SendMessageW(childWnd, WM_LBUTTONDBLCLK, MK_LBUTTON, MouseLP(xLen, sy));
  SendMessageW(childWnd, WM_LBUTTONUP, 0, MouseLP(xLen, sy));
  if ParamNow(PARAM_VIEW_MS) <> 2740.0 then Fail('status: double click did not reset len');

  { a double click elsewhere is two clicks }
  MouseClick(400, Round(200 * scale));
  SendMessageW(childWnd, WM_LBUTTONDBLCLK, MK_LBUTTON, MouseLP(400, Round(200 * scale)));
  SendMessageW(childWnd, WM_LBUTTONUP, 0, MouseLP(400, Round(200 * scale)));
  if ParamNow(PARAM_HOLD) >= 0.5 then Fail('double click should toggle hold twice');

  SetParamNow(PARAM_VIEW_MS, 50.0);
  WriteLn('status line controls: ok');
end;

procedure PumpMessages;
var
  mm: MSG;
begin
  while PeekMessageW(@mm, 0, 0, 0, PM_REMOVE) do
  begin
    if mm.message = WM_QUIT then GRunning := False;
    TranslateMessage(@mm);
    DispatchMessageW(@mm);
  end;
end;

procedure ProcessSineBlock;
var
  k: Integer;
  ampL: Double;
begin
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

  if not GInteractive then
  begin
    RunLogicTests;
    RunStressTest;
  end;

  { the dll sits next to the exe or one directory up }
  dllPath := ExtractFilePath(ParamStr(0)) + 'lzscope.dll';
  if not FileExists(dllPath) then
    dllPath := ExtractFilePath(ParamStr(0)) + '..\lzscope.dll';
  if not FileExists(dllPath) then Fail('lzscope.dll not found near ' + ParamStr(0));

  lib := LoadLibraryA(PAnsiChar(dllPath));
  if lib = 0 then Fail('LoadLibrary: ' + dllPath);

  entry := PClapPluginEntry(GetProcAddress(lib, 'clap_entry'));
  if entry = nil then Fail('clap_entry symbol not found');
  if entry^.clap_version.major < 1 then Fail('bad clap version');
  if not entry^.init(PAnsiChar(dllPath)) then Fail('entry.init');

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
  if not guiExt^.is_api_supported(plug, CLAP_WINDOW_API_WIN32, False) then
    Fail('win32 embedded api not supported');
  if not guiExt^.get_preferred_api(plug, @apiName, @floating) then
    Fail('get_preferred_api');
  WriteLn('preferred api: ', apiName, ' floating=', floating);

  FillChar(wc, SizeOf(wc), 0);
  wc.lpfnWndProc := @HostWndProc;
  wc.hInstance := HInstance;
  wc.hCursor := LoadCursor(0, IDC_ARROW);
  wc.lpszClassName := HOST_CLASS;
  if RegisterClassW(wc) = 0 then Fail('RegisterClassW');

  if not guiExt^.create(plug, CLAP_WINDOW_API_WIN32, False) then Fail('gui.create');
  if not guiExt^.get_size(plug, @gw, @gh) then Fail('gui.get_size');
  WriteLn(Format('gui size: %dx%d', [gw, gh]));

  rectCl.Left := 0; rectCl.Top := 0;
  rectCl.Right := gw; rectCl.Bottom := gh;
  AdjustWindowRect(@rectCl, WS_OVERLAPPEDWINDOW, False);
  hostWnd := CreateWindowExW(0, HOST_CLASS, 'lzScope testhost',
    WS_OVERLAPPEDWINDOW or WS_VISIBLE, 100, 100,
    rectCl.Right - rectCl.Left, rectCl.Bottom - rectCl.Top,
    0, 0, HInstance, nil);
  if hostWnd = 0 then Fail('host window');
  clapWin.api := CLAP_WINDOW_API_WIN32;
  clapWin.handle := {%H-}Pointer(hostWnd);
  if not guiExt^.set_parent(plug, @clapWin) then Fail('gui.set_parent');
  if not guiExt^.show(plug) then Fail('gui.show');

  if GInteractive then
  begin
    WriteLn('interactive mode: close the window to exit');
    GPlug := plug;
    GGuiExt := guiExt;

    GetClientRect(hostWnd, @rectCl);
    guiExt^.set_size(plug, rectCl.Right, rectCl.Bottom);
    ShowWindow(GetConsoleWindow, SW_MINIMIZE);
    SetForegroundWindow(hostWnd);

    { feed audio in real time }
    t0 := GetTickCount64;
    samplesFed := 0;
    while GRunning do
    begin
      PumpMessages;
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
    childWnd := GetWindow(hostWnd, GW_CHILD);
    if childWnd = 0 then Fail('plugin child window not found');
    GOutEvents := 0;
    SendMessageW(childWnd, WM_MOUSEWHEEL, WPARAM(120) shl 16, 0);
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
    SendMessageW(childWnd, WM_LBUTTONDOWN, MK_LBUTTON, LPARAM(15 shl 16) or 785);
    SendMessageW(childWnd, WM_LBUTTONUP, 0, LPARAM(15 shl 16) or 785);
    t0 := GetTickCount64;
    while GetTickCount64 - t0 < 300 do
    begin
      PumpMessages;
      ProcessSineBlock;
      Sleep(10);
    end;
    SendMessageW(childWnd, WM_LBUTTONDOWN, MK_LBUTTON, LPARAM(200 shl 16) or 400);
    SendMessageW(childWnd, WM_LBUTTONUP, 0, LPARAM(200 shl 16) or 400);
    if not paramsExt^.get_value(plug, PARAM_HOLD, @v) then Fail('get hold');
    if v >= 0.5 then Fail('click on about overlay must close it, not toggle hold');
    SendMessageW(childWnd, WM_LBUTTONDOWN, MK_LBUTTON, LPARAM(200 shl 16) or 400);
    SendMessageW(childWnd, WM_LBUTTONUP, 0, LPARAM(200 shl 16) or 400);
    if not paramsExt^.get_value(plug, PARAM_HOLD, @v) then Fail('get hold 2');
    if v < 0.5 then Fail('plain click should toggle hold on');
    SendMessageW(childWnd, WM_LBUTTONDOWN, MK_LBUTTON, LPARAM(200 shl 16) or 400);
    SendMessageW(childWnd, WM_LBUTTONUP, 0, LPARAM(200 shl 16) or 400);
    WriteLn('about overlay + click routing: ok');

    { let the render thread run }
    t0 := GetTickCount64;
    while GetTickCount64 - t0 < 1500 do
    begin
      PumpMessages;
      ProcessSineBlock;
      Sleep(10);
    end;

    TestStatusControls(gw / 800.0);

    if not guiExt^.set_size(plug, 500, 300) then Fail('gui.set_size');
    t0 := GetTickCount64;
    while GetTickCount64 - t0 < 300 do
    begin
      PumpMessages;
      ProcessSineBlock;
      Sleep(10);
    end;
    WriteLn('gui: ok (render thread ran ~1.8 s)');

    guiExt^.hide(plug);
    guiExt^.destroy(plug);
    DestroyWindow(hostWnd);
  end;

  plug^.stop_processing(plug);
  plug^.deactivate(plug);
  plug^.destroy(plug);
  entry^.deinit();
  FreeLibrary(lib);
  WriteLn('ALL TESTS PASSED');
end.
