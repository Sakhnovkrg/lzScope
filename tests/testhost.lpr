program testhost;

{ Minimal CLAP host for lzscope.dll.

  No args: smoke test — entry/factory, pass-through, params, GUI for
  ~1.8 s, exit code 0/1.
  -i: interactive demo host — window stays open, live test tone,
  resizable. This is what F9 in the IDE launches. }

{$mode objfpc}{$H+}
{$packrecords c}
{$pointermath on}
{$apptype console}

uses
  SysUtils, Windows, clap_api, scope_state;

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
  GGuiExt: PClapPluginGui = nil;   { set in interactive mode only }
  GPlug: PClapPlugin = nil;

function HostGetExtension(host: PClapHost; extension_id: PAnsiChar): Pointer; cdecl;
begin
  Result := nil;
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
        { tear the plugin editor down before its parent goes away }
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

var
  lib: HMODULE;
  entry: PClapPluginEntry;
  factory: PClapPluginFactory;
  desc: PClapPluginDescriptor;
  plug: PClapPlugin;
  paramsExt: PClapPluginParams;
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

begin
  GInteractive := (ParamCount > 0) and
    ((ParamStr(1) = '-i') or (ParamStr(1) = '--interactive'));

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

  { pass-through check }
  ProcessSineBlock;
  for i := 0 to NFRAMES - 1 do
    if (outL[i] <> bufL[i]) or (outR[i] <> bufR[i]) then
      Fail('pass-through mismatch at sample ' + IntToStr(i));
  WriteLn('pass-through: ok');

  { param event -> get_value round trip }
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

  { host window sized so its client area matches the editor }
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

    { fit the editor to the window and get the console out of the way }
    GetClientRect(hostWnd, @rectCl);
    guiExt^.set_size(plug, rectCl.Right, rectCl.Bottom);
    ShowWindow(GetConsoleWindow, SW_MINIMIZE);
    SetForegroundWindow(hostWnd);

    { pump messages, feeding audio paced to wall-clock real time }
    t0 := GetTickCount64;
    samplesFed := 0;
    while GRunning do
    begin
      PumpMessages;
      target := QWord(GetTickCount64 - t0) * 48;   { 48 samples per ms }
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
    { wheel message to the plugin window should come back to us as
      gesture+value out events }
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

    { about overlay: open via the "?" button, render a bit, then make
      sure a click closes it without toggling hold }
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

    { smoke test: pump + feed audio ~1.5 s so the render thread runs }
    t0 := GetTickCount64;
    while GetTickCount64 - t0 < 1500 do
    begin
      PumpMessages;
      ProcessSineBlock;
      Sleep(10);
    end;

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
