unit clap_api;

{ CLAP API translation (clap-1.2.x), only what this plugin needs }

{$mode objfpc}{$H+}
{$packrecords c}

interface

const
  CLAP_VERSION_MAJOR    = 1;
  CLAP_VERSION_MINOR    = 2;
  CLAP_VERSION_REVISION = 2;

  CLAP_NAME_SIZE = 256;
  CLAP_PATH_SIZE = 1024;

  CLAP_PLUGIN_FACTORY_ID = 'clap.plugin-factory';

  CLAP_EXT_AUDIO_PORTS = 'clap.audio-ports';
  CLAP_EXT_PARAMS      = 'clap.params';
  CLAP_EXT_STATE       = 'clap.state';
  CLAP_EXT_GUI         = 'clap.gui';

  CLAP_WINDOW_API_WIN32 = 'win32';
  CLAP_WINDOW_API_COCOA = 'cocoa';
  CLAP_WINDOW_API_X11   = 'x11';

  CLAP_PORT_MONO   = 'mono';
  CLAP_PORT_STEREO = 'stereo';

  CLAP_INVALID_ID = High(UInt32);

  { events }
  CLAP_CORE_EVENT_SPACE_ID = 0;

  CLAP_EVENT_NOTE_ON             = 0;
  CLAP_EVENT_NOTE_OFF            = 1;
  CLAP_EVENT_NOTE_CHOKE          = 2;
  CLAP_EVENT_NOTE_END            = 3;
  CLAP_EVENT_NOTE_EXPRESSION     = 4;
  CLAP_EVENT_PARAM_VALUE         = 5;
  CLAP_EVENT_PARAM_MOD           = 6;
  CLAP_EVENT_PARAM_GESTURE_BEGIN = 7;
  CLAP_EVENT_PARAM_GESTURE_END   = 8;
  CLAP_EVENT_TRANSPORT           = 9;

  CLAP_TRANSPORT_HAS_TEMPO          = 1 shl 0;
  CLAP_TRANSPORT_HAS_BEATS_TIMELINE = 1 shl 1;
  CLAP_TRANSPORT_HAS_TIME_SIGNATURE = 1 shl 3;
  CLAP_TRANSPORT_IS_PLAYING         = 1 shl 4;

  CLAP_BEATTIME_FACTOR = Int64(1) shl 31;
  CLAP_EVENT_MIDI                = 10;
  CLAP_EVENT_MIDI_SYSEX          = 11;
  CLAP_EVENT_MIDI2               = 12;

  { process status }
  CLAP_PROCESS_ERROR                 = 0;
  CLAP_PROCESS_CONTINUE              = 1;
  CLAP_PROCESS_CONTINUE_IF_NOT_QUIET = 2;
  CLAP_PROCESS_TAIL                  = 3;
  CLAP_PROCESS_SLEEP                 = 4;

  { audio port flags }
  CLAP_AUDIO_PORT_IS_MAIN         = 1 shl 0;
  CLAP_AUDIO_PORT_SUPPORTS_64BITS = 1 shl 1;

  { param info flags }
  CLAP_PARAM_IS_STEPPED     = 1 shl 0;
  CLAP_PARAM_IS_PERIODIC    = 1 shl 1;
  CLAP_PARAM_IS_HIDDEN      = 1 shl 2;
  CLAP_PARAM_IS_READONLY    = 1 shl 3;
  CLAP_PARAM_IS_BYPASS      = 1 shl 4;
  CLAP_PARAM_IS_AUTOMATABLE = 1 shl 5;

type
  TClapId = UInt32;

  PPSingle = ^PSingle;
  PPDouble = ^PDouble;

  TClapVersion = record
    major, minor, revision: UInt32;
  end;

  PClapHost = ^TClapHost;
  TClapHost = record
    clap_version: TClapVersion;
    host_data: Pointer;
    name, vendor, url, version: PAnsiChar;
    get_extension: function(host: PClapHost; extension_id: PAnsiChar): Pointer; cdecl;
    request_restart: procedure(host: PClapHost); cdecl;
    request_process: procedure(host: PClapHost); cdecl;
    request_callback: procedure(host: PClapHost); cdecl;
  end;

  PClapEventHeader = ^TClapEventHeader;
  TClapEventHeader = record
    size: UInt32;
    time: UInt32;
    space_id: UInt16;
    event_type: UInt16;   { 'type' in the C headers }
    flags: UInt32;
  end;

  PClapEventParamValue = ^TClapEventParamValue;
  TClapEventParamValue = record
    header: TClapEventHeader;
    param_id: TClapId;
    cookie: Pointer;
    note_id: Int32;
    port_index: Int16;
    channel: Int16;
    key: Int16;
    value: Double;
  end;

  PClapEventParamGesture = ^TClapEventParamGesture;
  TClapEventParamGesture = record
    header: TClapEventHeader;
    param_id: TClapId;
  end;

  PClapEventTransport = ^TClapEventTransport;
  TClapEventTransport = record
    header: TClapEventHeader;
    flags: UInt32;
    song_pos_beats: Int64;     { fixed point, see CLAP_BEATTIME_FACTOR }
    song_pos_seconds: Int64;
    tempo: Double;             { bpm }
    tempo_inc: Double;
    loop_start_beats: Int64;
    loop_end_beats: Int64;
    loop_start_seconds: Int64;
    loop_end_seconds: Int64;
    bar_start: Int64;          { start of the current bar, beats }
    bar_number: Int32;
    tsig_num: UInt16;
    tsig_denom: UInt16;
  end;

  PClapInputEvents = ^TClapInputEvents;
  TClapInputEvents = record
    ctx: Pointer;
    size: function(list: PClapInputEvents): UInt32; cdecl;
    get: function(list: PClapInputEvents; index: UInt32): PClapEventHeader; cdecl;
  end;

  PClapOutputEvents = ^TClapOutputEvents;
  TClapOutputEvents = record
    ctx: Pointer;
    try_push: function(list: PClapOutputEvents; event: PClapEventHeader): Boolean; cdecl;
  end;

  PClapAudioBuffer = ^TClapAudioBuffer;
  TClapAudioBuffer = record
    data32: PPSingle;
    data64: PPDouble;
    channel_count: UInt32;
    latency: UInt32;
    constant_mask: UInt64;
  end;

  PClapProcess = ^TClapProcess;
  TClapProcess = record
    steady_time: Int64;
    frames_count: UInt32;
    transport: PClapEventTransport;   { may be nil }
    audio_inputs: PClapAudioBuffer;
    audio_outputs: PClapAudioBuffer;
    audio_inputs_count: UInt32;
    audio_outputs_count: UInt32;
    in_events: PClapInputEvents;
    out_events: PClapOutputEvents;
  end;

  PClapPluginDescriptor = ^TClapPluginDescriptor;
  TClapPluginDescriptor = record
    clap_version: TClapVersion;
    id, name, vendor, url, manual_url, support_url, version, description: PAnsiChar;
    features: PPAnsiChar;   { null-terminated array of C strings }
  end;

  PClapPlugin = ^TClapPlugin;
  TClapPlugin = record
    desc: PClapPluginDescriptor;
    plugin_data: Pointer;
    init: function(plugin: PClapPlugin): Boolean; cdecl;
    destroy: procedure(plugin: PClapPlugin); cdecl;
    activate: function(plugin: PClapPlugin; sample_rate: Double;
                       min_frames, max_frames: UInt32): Boolean; cdecl;
    deactivate: procedure(plugin: PClapPlugin); cdecl;
    start_processing: function(plugin: PClapPlugin): Boolean; cdecl;
    stop_processing: procedure(plugin: PClapPlugin); cdecl;
    reset: procedure(plugin: PClapPlugin); cdecl;
    process: function(plugin: PClapPlugin; p: PClapProcess): Int32; cdecl;
    get_extension: function(plugin: PClapPlugin; id: PAnsiChar): Pointer; cdecl;
    on_main_thread: procedure(plugin: PClapPlugin); cdecl;
  end;

  PClapPluginFactory = ^TClapPluginFactory;
  TClapPluginFactory = record
    get_plugin_count: function(factory: PClapPluginFactory): UInt32; cdecl;
    get_plugin_descriptor: function(factory: PClapPluginFactory;
                                    index: UInt32): PClapPluginDescriptor; cdecl;
    create_plugin: function(factory: PClapPluginFactory; host: PClapHost;
                            plugin_id: PAnsiChar): PClapPlugin; cdecl;
  end;

  PClapPluginEntry = ^TClapPluginEntry;
  TClapPluginEntry = record
    clap_version: TClapVersion;
    init: function(plugin_path: PAnsiChar): Boolean; cdecl;
    deinit: procedure; cdecl;
    get_factory: function(factory_id: PAnsiChar): Pointer; cdecl;
  end;

  { audio-ports }

  PClapAudioPortInfo = ^TClapAudioPortInfo;
  TClapAudioPortInfo = record
    id: TClapId;
    name: array[0..CLAP_NAME_SIZE - 1] of AnsiChar;
    flags: UInt32;
    channel_count: UInt32;
    port_type: PAnsiChar;
    in_place_pair: TClapId;
  end;

  PClapPluginAudioPorts = ^TClapPluginAudioPorts;
  TClapPluginAudioPorts = record
    count: function(plugin: PClapPlugin; is_input: Boolean): UInt32; cdecl;
    get: function(plugin: PClapPlugin; index: UInt32; is_input: Boolean;
                  info: PClapAudioPortInfo): Boolean; cdecl;
  end;

  { params }

  PClapParamInfo = ^TClapParamInfo;
  TClapParamInfo = record
    id: TClapId;
    flags: UInt32;
    cookie: Pointer;
    name: array[0..CLAP_NAME_SIZE - 1] of AnsiChar;
    module: array[0..CLAP_PATH_SIZE - 1] of AnsiChar;
    min_value, max_value, default_value: Double;
  end;

  PClapPluginParams = ^TClapPluginParams;
  TClapPluginParams = record
    count: function(plugin: PClapPlugin): UInt32; cdecl;
    get_info: function(plugin: PClapPlugin; param_index: UInt32;
                       info: PClapParamInfo): Boolean; cdecl;
    get_value: function(plugin: PClapPlugin; param_id: TClapId;
                        out_value: PDouble): Boolean; cdecl;
    value_to_text: function(plugin: PClapPlugin; param_id: TClapId; value: Double;
                            out_buffer: PAnsiChar; out_buffer_capacity: UInt32): Boolean; cdecl;
    text_to_value: function(plugin: PClapPlugin; param_id: TClapId;
                            text: PAnsiChar; out_value: PDouble): Boolean; cdecl;
    flush: procedure(plugin: PClapPlugin; input: PClapInputEvents;
                     output: PClapOutputEvents); cdecl;
  end;

  { host side of params }
  PClapHostParams = ^TClapHostParams;
  TClapHostParams = record
    rescan: procedure(host: PClapHost; flags: UInt32); cdecl;
    clear: procedure(host: PClapHost; param_id: TClapId; flags: UInt32); cdecl;
    request_flush: procedure(host: PClapHost); cdecl;
  end;

  PClapHostState = ^TClapHostState;
  TClapHostState = record
    mark_dirty: procedure(host: PClapHost); cdecl;
  end;

  { state }

  PClapIStream = ^TClapIStream;
  TClapIStream = record
    ctx: Pointer;
    read: function(stream: PClapIStream; buffer: Pointer; size: UInt64): Int64; cdecl;
  end;

  PClapOStream = ^TClapOStream;
  TClapOStream = record
    ctx: Pointer;
    write: function(stream: PClapOStream; buffer: Pointer; size: UInt64): Int64; cdecl;
  end;

  PClapPluginState = ^TClapPluginState;
  TClapPluginState = record
    save: function(plugin: PClapPlugin; stream: PClapOStream): Boolean; cdecl;
    load: function(plugin: PClapPlugin; stream: PClapIStream): Boolean; cdecl;
  end;

  { gui }

  PClapWindow = ^TClapWindow;
  TClapWindow = record
    api: PAnsiChar;
    handle: Pointer;   { C union, pointer-sized }
  end;

  PClapGuiResizeHints = ^TClapGuiResizeHints;
  TClapGuiResizeHints = record
    can_resize_horizontally: Boolean;
    can_resize_vertically: Boolean;
    preserve_aspect_ratio: Boolean;
    aspect_ratio_width: UInt32;
    aspect_ratio_height: UInt32;
  end;

  PClapPluginGui = ^TClapPluginGui;
  TClapPluginGui = record
    is_api_supported: function(plugin: PClapPlugin; api: PAnsiChar;
                               is_floating: Boolean): Boolean; cdecl;
    get_preferred_api: function(plugin: PClapPlugin; api: PPAnsiChar;
                                is_floating: PBoolean): Boolean; cdecl;
    create: function(plugin: PClapPlugin; api: PAnsiChar;
                     is_floating: Boolean): Boolean; cdecl;
    destroy: procedure(plugin: PClapPlugin); cdecl;
    set_scale: function(plugin: PClapPlugin; scale: Double): Boolean; cdecl;
    get_size: function(plugin: PClapPlugin; width, height: PUInt32): Boolean; cdecl;
    can_resize: function(plugin: PClapPlugin): Boolean; cdecl;
    get_resize_hints: function(plugin: PClapPlugin;
                               hints: PClapGuiResizeHints): Boolean; cdecl;
    adjust_size: function(plugin: PClapPlugin; width, height: PUInt32): Boolean; cdecl;
    set_size: function(plugin: PClapPlugin; width, height: UInt32): Boolean; cdecl;
    set_parent: function(plugin: PClapPlugin; window: PClapWindow): Boolean; cdecl;
    set_transient: function(plugin: PClapPlugin; window: PClapWindow): Boolean; cdecl;
    suggest_title: procedure(plugin: PClapPlugin; title: PAnsiChar); cdecl;
    show: function(plugin: PClapPlugin): Boolean; cdecl;
    hide: function(plugin: PClapPlugin): Boolean; cdecl;
  end;

  PClapHostGui = ^TClapHostGui;
  TClapHostGui = record
    resize_hints_changed: procedure(host: PClapHost); cdecl;
    request_resize: function(host: PClapHost; width, height: UInt32): Boolean; cdecl;
    request_show: function(host: PClapHost): Boolean; cdecl;
    request_hide: function(host: PClapHost): Boolean; cdecl;
    closed: procedure(host: PClapHost; was_destroyed: Boolean); cdecl;
  end;

implementation

end.
