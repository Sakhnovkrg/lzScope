unit scope_plugin;

{ CLAP glue: entry point, factory, plugin lifecycle, extension vtables. }

{$mode objfpc}{$H+}
{$packrecords c}

interface

uses
  clap_api;

function EntryInit(plugin_path: PAnsiChar): Boolean; cdecl;
procedure EntryDeinit; cdecl;
function EntryGetFactory(factory_id: PAnsiChar): Pointer; cdecl;

{ a C symbol: Darwin can only export variables under their own name }
var
  clap_entry: TClapPluginEntry = (
    clap_version: (major: CLAP_VERSION_MAJOR; minor: CLAP_VERSION_MINOR;
                   revision: CLAP_VERSION_REVISION);
    init: @EntryInit;
    deinit: @EntryDeinit;
    get_factory: @EntryGetFactory
  ); cvar; export;

implementation

uses
  SysUtils, scope_state, scope_dsp, scope_gui, scope_gui_os;

const
  STATE_MAGIC_V0 = $4C5A5030; { 'LZP0': PARAM_COUNT_V0 doubles }
  STATE_MAGIC    = $4C5A5031; { 'LZP1': UInt32 count, then count doubles }
  PARAM_COUNT_V0 = 4;
  STATE_MAX_PARAMS = 1024;

var
  InitCount: LongInt = 0;

{ descriptor }

const
  ScopeFeatures: array[0..3] of PAnsiChar =
    ('audio-effect', 'analyzer', 'stereo', nil);

  ScopeDescriptor: TClapPluginDescriptor = (
    clap_version: (major: CLAP_VERSION_MAJOR; minor: CLAP_VERSION_MINOR;
                   revision: CLAP_VERSION_REVISION);
    id: 'com.dsgdnb.lzscope';
    name: 'lzScope';
    vendor: PLUGIN_AUTHOR;
    url: PLUGIN_URL;
    manual_url: '';
    support_url: '';
    version: PLUGIN_VERSION;
    description: 'Oscilloscope written in Free Pascal (OpenGL GUI)';
    features: @ScopeFeatures[0]
  );

  WINDOW_API_NAME: PAnsiChar = OS_WINDOW_API;

{ audio-ports }

function AudioPortsCount(plugin: PClapPlugin; is_input: Boolean): UInt32; cdecl;
begin
  Result := 1;
end;

function AudioPortsGet(plugin: PClapPlugin; index: UInt32; is_input: Boolean;
  info: PClapAudioPortInfo): Boolean; cdecl;
begin
  Result := False;
  if index <> 0 then Exit;
  FillChar(info^, SizeOf(info^), 0);
  info^.id := 0;
  StrPLCopy(info^.name, 'Main', CLAP_NAME_SIZE - 1);
  info^.flags := CLAP_AUDIO_PORT_IS_MAIN;
  info^.channel_count := 2;
  info^.port_type := CLAP_PORT_STEREO;
  info^.in_place_pair := 0;   { in-place allowed }
  Result := True;
end;

const
  AudioPortsExt: TClapPluginAudioPorts = (
    count: @AudioPortsCount;
    get: @AudioPortsGet
  );

{ params }

function ParamsCount(plugin: PClapPlugin): UInt32; cdecl;
begin
  Result := PARAM_COUNT;
end;

function ParamsGetInfo(plugin: PClapPlugin; param_index: UInt32;
  info: PClapParamInfo): Boolean; cdecl;
begin
  Result := False;
  if param_index >= PARAM_COUNT then Exit;
  FillChar(info^, SizeOf(info^), 0);
  info^.id := ParamDefs[param_index].id;
  info^.flags := ParamDefs[param_index].flags;
  info^.cookie := nil;
  StrPLCopy(info^.name, ParamDefs[param_index].name, CLAP_NAME_SIZE - 1);
  info^.module := '';
  info^.min_value := ParamDefs[param_index].minV;
  info^.max_value := ParamDefs[param_index].maxV;
  info^.default_value := ParamDefs[param_index].defV;
  Result := True;
end;

function ParamsGetValue(plugin: PClapPlugin; param_id: TClapId;
  out_value: PDouble): Boolean; cdecl;
var
  idx: Integer;
begin
  Result := False;
  idx := ParamIndex(param_id);
  if idx < 0 then Exit;
  out_value^ := GetParam(PScopeInstance(plugin^.plugin_data), idx);
  Result := True;
end;

procedure CopyToBuffer(const s: ShortString; out_buffer: PAnsiChar;
  capacity: UInt32);
var
  n: UInt32;
begin
  n := Length(s);
  if n > capacity - 1 then n := capacity - 1;
  if n > 0 then
    Move(s[1], out_buffer^, n);
  out_buffer[n] := #0;
end;

function ParamsValueToText(plugin: PClapPlugin; param_id: TClapId;
  value: Double; out_buffer: PAnsiChar; out_buffer_capacity: UInt32): Boolean; cdecl;
var
  s: ShortString;
  iv: Integer;
begin
  Result := False;
  if out_buffer_capacity = 0 then Exit;
  case param_id of
    PARAM_VIEW_MS:
      if value >= 1000 then
      begin
        Str((value / 1000): 0: 2, s);
        s := s + ' s';
      end
      else
      begin
        Str(value: 0: 1, s);
        s := s + ' ms';
      end;
    PARAM_VZOOM_DB:
      begin
        Str(value: 0: 1, s);
        if value >= 0 then s := '+' + s;
        s := s + ' dB';
      end;
    PARAM_RETRIG:
      begin
        iv := Round(value);
        if iv < 0 then iv := 0;
        if iv > RETRIG_COUNT - 1 then iv := RETRIG_COUNT - 1;
        s := ShortString(RetrigNames[iv]);
      end;
    PARAM_SYNC_LEN:
      begin
        iv := Round(value);
        if iv < 0 then iv := 0;
        if iv > SYNC_LEN_COUNT - 1 then iv := SYNC_LEN_COUNT - 1;
        s := ShortString(SyncLenNames[iv]);
      end;
    PARAM_HOLD, PARAM_SYNC, PARAM_SPLIT:
      if value >= 0.5 then s := 'on' else s := 'off';
  else
    Exit;
  end;
  CopyToBuffer(s, out_buffer, out_buffer_capacity);
  Result := True;
end;

function ParamsTextToValue(plugin: PClapPlugin; param_id: TClapId;
  text: PAnsiChar; out_value: PDouble): Boolean; cdecl;
var
  s, raw: AnsiString;
  i, code, idx: Integer;
  v: Double;
begin
  Result := False;
  idx := ParamIndex(param_id);
  if (idx < 0) or (text = nil) then Exit;
  s := LowerCase(Trim(AnsiString(text)));

  if param_id = PARAM_RETRIG then
    for i := 0 to RETRIG_COUNT - 1 do
      if s = LowerCase(AnsiString(RetrigNames[i])) then
      begin
        out_value^ := i;
        Exit(True);
      end;
  if param_id = PARAM_SYNC_LEN then
    for i := 0 to SYNC_LEN_COUNT - 1 do
      if s = LowerCase(AnsiString(SyncLenNames[i])) then
      begin
        out_value^ := i;
        Exit(True);
      end;
  if (param_id = PARAM_HOLD) or (param_id = PARAM_SYNC) or
     (param_id = PARAM_SPLIT) then
  begin
    if (s = 'on') or (s = 'yes') or (s = 'true') then
    begin
      out_value^ := 1;
      Exit(True);
    end;
    if (s = 'off') or (s = 'no') or (s = 'false') then
    begin
      out_value^ := 0;
      Exit(True);
    end;
  end;

  for i := 1 to Length(s) do
    if s[i] = ',' then s[i] := '.';
  raw := s;
  { strip a trailing unit: "100 ms", "1.5s", "-6 dB" }
  while (Length(s) > 0) and not (s[Length(s)] in ['0'..'9', '.', '-']) do
    SetLength(s, Length(s) - 1);
  Val(s, v, code);
  if code <> 0 then Exit;
  { trailing "s" (but not "ms") means seconds }
  if (param_id = PARAM_VIEW_MS) and (Length(raw) > 0) and
     (raw[Length(raw)] = 's') and
     ((Length(raw) < 2) or (raw[Length(raw) - 1] <> 'm')) then
    v := v * 1000;
  out_value^ := ClampParam(idx, v);
  Result := True;
end;

{ never runs alongside process() }
procedure ParamsFlush(plugin: PClapPlugin; input: PClapInputEvents;
  output: PClapOutputEvents); cdecl;
var
  inst: PScopeInstance;
  i, n: UInt32;
begin
  inst := PScopeInstance(plugin^.plugin_data);
  if input <> nil then
  begin
    n := input^.size(input);
    i := 0;
    while i < n do
    begin
      ScopeHandleEvent(inst, input^.get(input, i));
      Inc(i);
    end;
  end;
  ReportDirtyParams(inst, output);
end;

const
  ParamsExt: TClapPluginParams = (
    count: @ParamsCount;
    get_info: @ParamsGetInfo;
    get_value: @ParamsGetValue;
    value_to_text: @ParamsValueToText;
    text_to_value: @ParamsTextToValue;
    flush: @ParamsFlush
  );

{ state }

{ streams may move fewer bytes than asked }
function WriteAll(stream: PClapOStream; buf: PByte; size: UInt64): Boolean;
var
  n: Int64;
begin
  while size > 0 do
  begin
    n := stream^.write(stream, buf, size);
    if n <= 0 then Exit(False);
    Inc(buf, n);
    Dec(size, n);
  end;
  Result := True;
end;

function ReadAll(stream: PClapIStream; buf: PByte; size: UInt64): Boolean;
var
  n: Int64;
begin
  while size > 0 do
  begin
    n := stream^.read(stream, buf, size);
    if n <= 0 then Exit(False);
    Inc(buf, n);
    Dec(size, n);
  end;
  Result := True;
end;

function StateSave(plugin: PClapPlugin; stream: PClapOStream): Boolean; cdecl;
var
  inst: PScopeInstance;
  hdr: array[0..1] of UInt32;
  vals: array[0..PARAM_COUNT - 1] of Double;
  i: Integer;
begin
  inst := PScopeInstance(plugin^.plugin_data);
  hdr[0] := STATE_MAGIC;
  hdr[1] := PARAM_COUNT;
  for i := 0 to PARAM_COUNT - 1 do
    vals[i] := GetParam(inst, i);
  Result := WriteAll(stream, @hdr[0], SizeOf(hdr)) and
    WriteAll(stream, @vals[0], SizeOf(vals));
end;

function StateLoad(plugin: PClapPlugin; stream: PClapIStream): Boolean; cdecl;
var
  inst: PScopeInstance;
  magic, count, i: UInt32;
  vals: array[0..PARAM_COUNT - 1] of Double;
  v: Double;
begin
  Result := False;
  inst := PScopeInstance(plugin^.plugin_data);
  if not ReadAll(stream, @magic, SizeOf(magic)) then Exit;
  if magic = STATE_MAGIC_V0 then
    count := PARAM_COUNT_V0
  else if magic = STATE_MAGIC then
  begin
    if not ReadAll(stream, @count, SizeOf(count)) then Exit;
    if count > STATE_MAX_PARAMS then Exit;
  end
  else
    Exit;

  { missing params keep defaults, extra ones are ignored }
  for i := 0 to PARAM_COUNT - 1 do
    vals[i] := ParamDefs[i].defV;
  i := 0;
  while i < count do
  begin
    if not ReadAll(stream, @v, SizeOf(v)) then Exit;
    if i < PARAM_COUNT then vals[i] := v;
    Inc(i);
  end;
  { apply only if everything was read }
  for i := 0 to PARAM_COUNT - 1 do
    SetParam(inst, i, ClampParam(i, vals[i]));
  Result := True;
end;

const
  StateExt: TClapPluginState = (
    save: @StateSave;
    load: @StateLoad
  );

{ gui }

function GuiExtIsApiSupported(plugin: PClapPlugin; api: PAnsiChar;
  is_floating: Boolean): Boolean; cdecl;
begin
  Result := (api <> nil) and (StrComp(api, OS_WINDOW_API) = 0) and
    not is_floating;
end;

function GuiExtGetPreferredApi(plugin: PClapPlugin; api: PPAnsiChar;
  is_floating: PBoolean): Boolean; cdecl;
begin
  api^ := WINDOW_API_NAME;
  is_floating^ := False;
  Result := True;
end;

function GuiExtCreate(plugin: PClapPlugin; api: PAnsiChar;
  is_floating: Boolean): Boolean; cdecl;
begin
  Result := False;
  if not GuiExtIsApiSupported(plugin, api, is_floating) then Exit;
  Result := GuiCreate(PScopeInstance(plugin^.plugin_data));
end;

procedure GuiExtDestroy(plugin: PClapPlugin); cdecl;
begin
  GuiDestroy(PScopeInstance(plugin^.plugin_data));
end;

function GuiExtSetScale(plugin: PClapPlugin; scale: Double): Boolean; cdecl;
begin
  Result := GuiSetScale(PScopeInstance(plugin^.plugin_data), scale);
end;

function GuiExtGetSize(plugin: PClapPlugin; width, height: PUInt32): Boolean; cdecl;
begin
  Result := GuiGetSize(PScopeInstance(plugin^.plugin_data), width, height);
end;

function GuiExtCanResize(plugin: PClapPlugin): Boolean; cdecl;
begin
  Result := True;
end;

function GuiExtGetResizeHints(plugin: PClapPlugin;
  hints: PClapGuiResizeHints): Boolean; cdecl;
begin
  hints^.can_resize_horizontally := True;
  hints^.can_resize_vertically := True;
  hints^.preserve_aspect_ratio := False;
  hints^.aspect_ratio_width := 0;
  hints^.aspect_ratio_height := 0;
  Result := True;
end;

function GuiExtAdjustSize(plugin: PClapPlugin; width, height: PUInt32): Boolean; cdecl;
begin
  GuiAdjustSize(PScopeInstance(plugin^.plugin_data), width^, height^);
  Result := True;
end;

function GuiExtSetSize(plugin: PClapPlugin; width, height: UInt32): Boolean; cdecl;
begin
  GuiExtAdjustSize(plugin, @width, @height);
  Result := GuiSetSize(PScopeInstance(plugin^.plugin_data), width, height);
end;

function GuiExtSetParent(plugin: PClapPlugin; window: PClapWindow): Boolean; cdecl;
begin
  Result := False;
  if (window = nil) or (window^.handle = nil) then Exit;
  Result := GuiSetParent(PScopeInstance(plugin^.plugin_data), window^.handle);
end;

function GuiExtSetTransient(plugin: PClapPlugin; window: PClapWindow): Boolean; cdecl;
begin
  Result := False;   { no floating windows }
end;

procedure GuiExtSuggestTitle(plugin: PClapPlugin; title: PAnsiChar); cdecl;
begin
end;

function GuiExtShow(plugin: PClapPlugin): Boolean; cdecl;
begin
  Result := GuiShow(PScopeInstance(plugin^.plugin_data));
end;

function GuiExtHide(plugin: PClapPlugin): Boolean; cdecl;
begin
  Result := GuiHide(PScopeInstance(plugin^.plugin_data));
end;

const
  GuiExt: TClapPluginGui = (
    is_api_supported: @GuiExtIsApiSupported;
    get_preferred_api: @GuiExtGetPreferredApi;
    create: @GuiExtCreate;
    destroy: @GuiExtDestroy;
    set_scale: @GuiExtSetScale;
    get_size: @GuiExtGetSize;
    can_resize: @GuiExtCanResize;
    get_resize_hints: @GuiExtGetResizeHints;
    adjust_size: @GuiExtAdjustSize;
    set_size: @GuiExtSetSize;
    set_parent: @GuiExtSetParent;
    set_transient: @GuiExtSetTransient;
    suggest_title: @GuiExtSuggestTitle;
    show: @GuiExtShow;
    hide: @GuiExtHide
  );

{ plugin core }

function PlugInit(plugin: PClapPlugin): Boolean; cdecl;
var
  inst: PScopeInstance;
begin
  inst := PScopeInstance(plugin^.plugin_data);
  if (inst^.host <> nil) and (inst^.host^.get_extension <> nil) then
  begin
    inst^.hostParams := PClapHostParams(
      inst^.host^.get_extension(inst^.host, CLAP_EXT_PARAMS));
    inst^.hostState := PClapHostState(
      inst^.host^.get_extension(inst^.host, CLAP_EXT_STATE));
  end;
  Result := True;
end;

procedure PlugDestroy(plugin: PClapPlugin); cdecl;
var
  inst: PScopeInstance;
begin
  inst := PScopeInstance(plugin^.plugin_data);
  if inst^.gui <> nil then
    GuiDestroy(inst);
  ScopeReleaseBuffers(inst);
  System.DoneCriticalSection(inst^.lock);
  Dispose(inst);
end;

function PlugActivate(plugin: PClapPlugin; sample_rate: Double;
  min_frames, max_frames: UInt32): Boolean; cdecl;
begin
  Result := ScopeConfigure(PScopeInstance(plugin^.plugin_data), sample_rate);
end;

procedure PlugDeactivate(plugin: PClapPlugin); cdecl;
begin
  { keep the buffers: an open GUI still shows the last capture }
end;

function PlugStartProcessing(plugin: PClapPlugin): Boolean; cdecl;
begin
  Result := True;
end;

procedure PlugStopProcessing(plugin: PClapPlugin); cdecl;
begin
end;

procedure PlugReset(plugin: PClapPlugin); cdecl;
begin
  ScopeClear(PScopeInstance(plugin^.plugin_data));
end;

function PlugProcess(plugin: PClapPlugin; p: PClapProcess): Int32; cdecl;
begin
  Result := ScopeProcess(PScopeInstance(plugin^.plugin_data), p);
end;

function PlugGetExtension(plugin: PClapPlugin; id: PAnsiChar): Pointer; cdecl;
begin
  Result := nil;
  if id = nil then Exit;
  if StrComp(id, CLAP_EXT_AUDIO_PORTS) = 0 then
    Result := @AudioPortsExt
  else if StrComp(id, CLAP_EXT_PARAMS) = 0 then
    Result := @ParamsExt
  else if StrComp(id, CLAP_EXT_STATE) = 0 then
    Result := @StateExt
  else if StrComp(id, CLAP_EXT_GUI) = 0 then
    Result := @GuiExt;
end;

procedure PlugOnMainThread(plugin: PClapPlugin); cdecl;
begin
end;

{ factory }

function FactoryGetPluginCount(factory: PClapPluginFactory): UInt32; cdecl;
begin
  Result := 1;
end;

function FactoryGetPluginDescriptor(factory: PClapPluginFactory;
  index: UInt32): PClapPluginDescriptor; cdecl;
begin
  if index = 0 then
    Result := @ScopeDescriptor
  else
    Result := nil;
end;

function FactoryCreatePlugin(factory: PClapPluginFactory; host: PClapHost;
  plugin_id: PAnsiChar): PClapPlugin; cdecl;
var
  inst: PScopeInstance;
begin
  Result := nil;
  if (plugin_id = nil) or (StrComp(plugin_id, ScopeDescriptor.id) <> 0) then
    Exit;
  New(inst);
  if inst = nil then Exit;
  FillChar(inst^, SizeOf(inst^), 0);
  System.InitCriticalSection(inst^.lock);
  inst^.host := host;
  inst^.srate := 48000.0;
  inst^.guiScale := 0.0;   { 0 = use OS DPI }
  ResetParams(inst);

  inst^.plug.desc := @ScopeDescriptor;
  inst^.plug.plugin_data := inst;
  inst^.plug.init := @PlugInit;
  inst^.plug.destroy := @PlugDestroy;
  inst^.plug.activate := @PlugActivate;
  inst^.plug.deactivate := @PlugDeactivate;
  inst^.plug.start_processing := @PlugStartProcessing;
  inst^.plug.stop_processing := @PlugStopProcessing;
  inst^.plug.reset := @PlugReset;
  inst^.plug.process := @PlugProcess;
  inst^.plug.get_extension := @PlugGetExtension;
  inst^.plug.on_main_thread := @PlugOnMainThread;
  Result := @inst^.plug;
end;

const
  ScopeFactory: TClapPluginFactory = (
    get_plugin_count: @FactoryGetPluginCount;
    get_plugin_descriptor: @FactoryGetPluginDescriptor;
    create_plugin: @FactoryCreatePlugin
  );

{ entry }

{ init/deinit may be called more than once }
function EntryInit(plugin_path: PAnsiChar): Boolean; cdecl;
begin
  { out of memory returns nil instead of raising into the host }
  ReturnNilIfGrowHeapFails := True;
  InterlockedIncrement(InitCount);
  Result := True;
end;

procedure EntryDeinit; cdecl;
begin
  if InterlockedDecrement(InitCount) = 0 then
    GuiGlobalCleanup;
end;

function EntryGetFactory(factory_id: PAnsiChar): Pointer; cdecl;
begin
  if (factory_id <> nil) and (StrComp(factory_id, CLAP_PLUGIN_FACTORY_ID) = 0) then
    Result := @ScopeFactory
  else
    Result := nil;
end;

end.
