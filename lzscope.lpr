library lzscope;

{ The built DLL is the .clap file, renamed on install }

{$mode objfpc}{$H+}

uses
  clap_api,
  scope_ring,
  scope_state,
  scope_dsp,
  scope_view,
  gl_min,
  scope_shader,
  scope_gui_types,
  scope_gui_text,
  scope_gui_render,
  scope_gui,
  scope_plugin;

exports
  clap_entry name 'clap_entry';

begin
end.
