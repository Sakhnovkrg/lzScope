library lzscope;

{ The built library is the .clap: renamed on Windows, the binary inside
  the .clap bundle on macOS }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,   { first: the render thread and critical sections need it }
  {$ENDIF}
  clap_api,
  scope_ring,
  scope_state,
  scope_dsp,
  scope_view,
  gl_min,
  scope_shader,
  scope_gui_types,
  scope_gui_text,
  scope_gui_os,
  scope_gui_input,
  scope_gui_render,
  scope_gui,
  scope_plugin;

exports
  clap_entry;   { cvar: the C name on every platform }

begin
end.
