unit scope_shader;

{ GLSL support: loads the GL 2.0 entry points at runtime and wraps
  compile/use/uniforms. On drivers without shaders everything no-ops
  and CompileFragmentProgram returns 0. Shader sources live here too. }

{$mode objfpc}{$H+}

interface

uses
  Windows, gl_min;

const
  { about overlay: re-sample the grabbed scene with distorted UVs (the
    scope bends and flows) + rainbow plasma glow. `k` eases in. }
  PLASMA_FS: PAnsiChar =
    'uniform float t;'#10 +
    'uniform float k;'#10 +
    'uniform vec2 res;'#10 +
    'uniform sampler2D scene;'#10 +
    'void main(){'#10 +
    '  vec2 uv=gl_FragCoord.xy/res;'#10 +
    '  vec2 p=uv*2.0-1.0;'#10 +
    '  p.x*=res.x/res.y;'#10 +
    '  float r=length(p);'#10 +
    '  vec2 warp=uv+k*0.018*vec2(sin(p.y*6.0+t*1.5),cos(p.x*5.0-t));'#10 +
    '  warp+=k*0.012*vec2(sin(r*9.0-t*2.0),cos(r*7.0-t*1.3));'#10 +
    '  vec3 scn=texture2D(scene,warp).rgb;'#10 +
    '  float v=sin(p.x*4.0+t)+sin(p.y*4.6+t*1.3);'#10 +
    '  v+=sin((p.x+p.y)*3.0+t*0.7)+sin(r*9.0-t*2.0);'#10 +
    '  v*=0.25;'#10 +
    '  vec3 pl=vec3(0.5+0.5*sin(6.2832*v),'#10 +
    '              0.5+0.5*sin(6.2832*v+2.094),'#10 +
    '              0.5+0.5*sin(6.2832*v+4.189));'#10 +
    '  pl=pl*pl;'#10 +
    '  vec3 col=scn*(0.42+0.38*pl)+pl*0.08;'#10 +
    '  gl_FragColor=vec4(mix(scn,col,k),1.0);'#10 +
    '}';

{ fragment-only program, fixed-function vertex path; 0 on failure }
function CompileFragmentProgram(src: PAnsiChar): DWORD;
procedure DeleteShaderProgram(prog: DWORD);
procedure UseShaderProgram(prog: DWORD);
function GetShaderUniform(prog: DWORD; name: PAnsiChar): LongInt;
procedure SetUniform1f(loc: LongInt; v: Single);
procedure SetUniform2f(loc: LongInt; x, y: Single);
procedure SetUniform1i(loc: LongInt; v: LongInt);

implementation

var
  Loaded: Boolean = False;
  OK: Boolean = False;
  pglCreateShader: TglCreateShader;
  pglShaderSource: TglShaderSource;
  pglCompileShader: TglCompileShader;
  pglGetShaderiv: TglGetShaderiv;
  pglCreateProgram: TglCreateProgram;
  pglAttachShader: TglAttachShader;
  pglLinkProgram: TglLinkProgram;
  pglGetProgramiv: TglGetProgramiv;
  pglUseProgram: TglUseProgram;
  pglGetUniformLocation: TglGetUniformLocation;
  pglUniform1f: TglUniform1f;
  pglUniform2f: TglUniform2f;
  pglUniform1i: TglUniform1i;
  pglDeleteShader: TglDeleteShader;
  pglDeleteProgram: TglDeleteProgram;

procedure LoadFuncs;
begin
  if Loaded then Exit;
  Loaded := True;
  pglCreateShader := TglCreateShader(wglGetProcAddress('glCreateShader'));
  pglShaderSource := TglShaderSource(wglGetProcAddress('glShaderSource'));
  pglCompileShader := TglCompileShader(wglGetProcAddress('glCompileShader'));
  pglGetShaderiv := TglGetShaderiv(wglGetProcAddress('glGetShaderiv'));
  pglCreateProgram := TglCreateProgram(wglGetProcAddress('glCreateProgram'));
  pglAttachShader := TglAttachShader(wglGetProcAddress('glAttachShader'));
  pglLinkProgram := TglLinkProgram(wglGetProcAddress('glLinkProgram'));
  pglGetProgramiv := TglGetProgramiv(wglGetProcAddress('glGetProgramiv'));
  pglUseProgram := TglUseProgram(wglGetProcAddress('glUseProgram'));
  pglGetUniformLocation :=
    TglGetUniformLocation(wglGetProcAddress('glGetUniformLocation'));
  pglUniform1f := TglUniform1f(wglGetProcAddress('glUniform1f'));
  pglUniform2f := TglUniform2f(wglGetProcAddress('glUniform2f'));
  pglUniform1i := TglUniform1i(wglGetProcAddress('glUniform1i'));
  pglDeleteShader := TglDeleteShader(wglGetProcAddress('glDeleteShader'));
  pglDeleteProgram := TglDeleteProgram(wglGetProcAddress('glDeleteProgram'));
  OK := (pglCreateShader <> nil) and (pglShaderSource <> nil) and
    (pglCompileShader <> nil) and (pglGetShaderiv <> nil) and
    (pglCreateProgram <> nil) and (pglAttachShader <> nil) and
    (pglLinkProgram <> nil) and (pglGetProgramiv <> nil) and
    (pglUseProgram <> nil) and (pglGetUniformLocation <> nil) and
    (pglUniform1f <> nil) and (pglUniform2f <> nil) and
    (pglUniform1i <> nil) and
    (pglDeleteShader <> nil) and (pglDeleteProgram <> nil);
end;

function CompileFragmentProgram(src: PAnsiChar): DWORD;
var
  sh, prog: DWORD;
  ok1: LongInt;
begin
  Result := 0;
  LoadFuncs;
  if not OK then Exit;

  sh := pglCreateShader(GL_FRAGMENT_SHADER);
  if sh = 0 then Exit;
  pglShaderSource(sh, 1, @src, nil);
  pglCompileShader(sh);
  ok1 := 0;
  pglGetShaderiv(sh, GL_COMPILE_STATUS, @ok1);
  if ok1 = 0 then
  begin
    pglDeleteShader(sh);
    Exit;
  end;

  prog := pglCreateProgram();
  pglAttachShader(prog, sh);
  pglLinkProgram(prog);
  pglDeleteShader(sh);
  ok1 := 0;
  pglGetProgramiv(prog, GL_LINK_STATUS, @ok1);
  if ok1 = 0 then
  begin
    pglDeleteProgram(prog);
    Exit;
  end;
  Result := prog;
end;

procedure DeleteShaderProgram(prog: DWORD);
begin
  if (prog <> 0) and OK then
    pglDeleteProgram(prog);
end;

procedure UseShaderProgram(prog: DWORD);
begin
  if OK then
    pglUseProgram(prog);
end;

function GetShaderUniform(prog: DWORD; name: PAnsiChar): LongInt;
begin
  if OK then
    Result := pglGetUniformLocation(prog, name)
  else
    Result := -1;
end;

procedure SetUniform1f(loc: LongInt; v: Single);
begin
  if OK then
    pglUniform1f(loc, v);
end;

procedure SetUniform2f(loc: LongInt; x, y: Single);
begin
  if OK then
    pglUniform2f(loc, x, y);
end;

procedure SetUniform1i(loc: LongInt; v: LongInt);
begin
  if OK then
    pglUniform1i(loc, v);
end;

end.
