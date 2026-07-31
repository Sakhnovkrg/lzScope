library lzscope;

{ lzScope — CLAP oscilloscope. The built DLL *is* the .clap file,
  just renamed on install (see build.ps1). }

{$mode objfpc}{$H+}

uses
  clap_api,
  scope_state,
  scope_dsp,
  gl_min,
  scope_shader,
  scope_view,
  scope_gui,
  scope_plugin;

exports
  clap_entry name 'clap_entry';

begin
end.
