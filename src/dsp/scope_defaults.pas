unit scope_defaults;

{ The user's default settings: what a new instance starts with.
  Main thread only. }

{$mode objfpc}{$H+}

interface

uses
  scope_state;

{ '' if there is nowhere to keep it; $LZSCOPE_DEFAULTS overrides the place }
function DefaultsPath: UnicodeString;
function SaveDefaults(inst: PScopeInstance): Boolean;
{ leaves the params alone if there is no usable file }
function LoadDefaults(inst: PScopeInstance): Boolean;

{ what a double click resets a param to: the saved value, else the factory one }
function UserDefault(idx: Integer): Double;

function SaveDefaultsTo(inst: PScopeInstance; const path: UnicodeString): Boolean;
function UserDefaultFrom(const path: UnicodeString; idx: Integer): Double;
function LoadDefaultsFrom(inst: PScopeInstance; const path: UnicodeString): Boolean;

implementation

uses
  SysUtils;

const
  DEFAULTS_MAGIC = $4C5A4431;   { 'LZD1': count, then that many doubles }
  MAX_PARAMS = 64;

type
  TDefaultsFile = packed record
    magic, count: UInt32;
    vals: array[0..MAX_PARAMS - 1] of Double;
  end;

{$IFDEF UNIX}
function getenv(name: PAnsiChar): PAnsiChar; cdecl; external 'c';
{$ENDIF}

function EnvVar(const name: AnsiString): UnicodeString;
begin
{$IFDEF WINDOWS}
  Result := SysUtils.GetEnvironmentVariable(UnicodeString(name));
{$ELSE}
  Result := UTF8Decode(AnsiString(getenv(PAnsiChar(name))));
{$ENDIF}
end;

function DefaultsPath: UnicodeString;
begin
  Result := EnvVar('LZSCOPE_DEFAULTS');
  if Result <> '' then Exit;
{$IFDEF WINDOWS}
  Result := EnvVar('APPDATA');
  if Result <> '' then
    Result := Result + '\' + PLUGIN_AUTHOR + '\lzScope\defaults.bin';
{$ELSE}
  Result := EnvVar('HOME');
  if Result <> '' then
    Result := Result + '/Library/Application Support/' + PLUGIN_AUTHOR +
      '/lzScope/defaults.bin';
{$ENDIF}
end;

function SaveDefaultsTo(inst: PScopeInstance; const path: UnicodeString): Boolean;
var
  f: TDefaultsFile;
  h: THandle;
  i, size: Integer;
begin
  Result := False;
  if path = '' then Exit;
  f.magic := DEFAULTS_MAGIC;
  f.count := PARAM_COUNT;
  for i := 0 to PARAM_COUNT - 1 do
    f.vals[i] := GetParam(inst, i);
  f.vals[PARAM_HOLD] := 0;   { a new instance never starts frozen }
  size := 8 + PARAM_COUNT * SizeOf(Double);

  ForceDirectories(ExtractFileDir(path));
  h := FileCreate(path);
  if h = THandle(-1) then Exit;
  Result := FileWrite(h, f, size) = size;
  FileClose(h);
end;

{ False = no usable file }
function ReadFile(const path: UnicodeString; out f: TDefaultsFile): Boolean;
var
  h: THandle;
  got: Integer;
begin
  Result := False;
  if (path = '') or not FileExists(path) then Exit;
  h := FileOpen(path, fmOpenRead or fmShareDenyNone);
  if h = THandle(-1) then Exit;
  got := FileRead(h, f, SizeOf(f));
  FileClose(h);
  Result := (got >= 8) and (f.magic = DEFAULTS_MAGIC) and
    (f.count <= MAX_PARAMS) and
    (got >= 8 + Integer(f.count) * SizeOf(Double));
end;

function LoadDefaultsFrom(inst: PScopeInstance; const path: UnicodeString): Boolean;
var
  f: TDefaultsFile;
  i: Integer;
begin
  Result := ReadFile(path, f);
  if not Result then Exit;
  { params the file does not have keep their values }
  for i := 0 to PARAM_COUNT - 1 do
    if i < Integer(f.count) then
      SetParam(inst, i, ClampParam(i, f.vals[i]));
  SetParam(inst, PARAM_HOLD, 0);
end;

function UserDefaultFrom(const path: UnicodeString; idx: Integer): Double;
var
  f: TDefaultsFile;
begin
  Result := ParamDefs[idx].defV;
  if ReadFile(path, f) and (idx < Integer(f.count)) then
    Result := ClampParam(idx, f.vals[idx]);
end;

function UserDefault(idx: Integer): Double;
begin
  Result := UserDefaultFrom(DefaultsPath, idx);
end;

function SaveDefaults(inst: PScopeInstance): Boolean;
begin
  Result := SaveDefaultsTo(inst, DefaultsPath);
end;

function LoadDefaults(inst: PScopeInstance): Boolean;
begin
  Result := LoadDefaultsFrom(inst, DefaultsPath);
end;

end.
