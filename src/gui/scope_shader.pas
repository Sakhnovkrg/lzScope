unit scope_shader;

{ GLSL helpers; everything no-ops on drivers without shaders }

{$mode objfpc}{$H+}

interface

uses
  gl_min;

const
  { about overlay: warped scene + plasma glow }
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

{ 0 on failure }
function CompileFragmentProgram(src: PAnsiChar): DWord;
procedure DeleteShaderProgram(prog: DWord);
procedure UseShaderProgram(prog: DWord);
function GetShaderUniform(prog: DWord; name: PAnsiChar): LongInt;
procedure SetUniform1f(loc: LongInt; v: Single);
procedure SetUniform2f(loc: LongInt; x, y: Single);
procedure SetUniform1i(loc: LongInt; v: LongInt);

implementation

var
  { 0 = not loaded, 1 = loading, 2 = done }
  LoadState: LongInt = 0;
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
  if LoadState = 2 then Exit;
  if InterlockedCompareExchange(LoadState, 1, 0) <> 0 then
  begin
    while LoadState <> 2 do
      ThreadSwitch;
    Exit;
  end;
  pglCreateShader := TglCreateShader(GetGLProc('glCreateShader'));
  pglShaderSource := TglShaderSource(GetGLProc('glShaderSource'));
  pglCompileShader := TglCompileShader(GetGLProc('glCompileShader'));
  pglGetShaderiv := TglGetShaderiv(GetGLProc('glGetShaderiv'));
  pglCreateProgram := TglCreateProgram(GetGLProc('glCreateProgram'));
  pglAttachShader := TglAttachShader(GetGLProc('glAttachShader'));
  pglLinkProgram := TglLinkProgram(GetGLProc('glLinkProgram'));
  pglGetProgramiv := TglGetProgramiv(GetGLProc('glGetProgramiv'));
  pglUseProgram := TglUseProgram(GetGLProc('glUseProgram'));
  pglGetUniformLocation :=
    TglGetUniformLocation(GetGLProc('glGetUniformLocation'));
  pglUniform1f := TglUniform1f(GetGLProc('glUniform1f'));
  pglUniform2f := TglUniform2f(GetGLProc('glUniform2f'));
  pglUniform1i := TglUniform1i(GetGLProc('glUniform1i'));
  pglDeleteShader := TglDeleteShader(GetGLProc('glDeleteShader'));
  pglDeleteProgram := TglDeleteProgram(GetGLProc('glDeleteProgram'));
  OK := (pglCreateShader <> nil) and (pglShaderSource <> nil) and
    (pglCompileShader <> nil) and (pglGetShaderiv <> nil) and
    (pglCreateProgram <> nil) and (pglAttachShader <> nil) and
    (pglLinkProgram <> nil) and (pglGetProgramiv <> nil) and
    (pglUseProgram <> nil) and (pglGetUniformLocation <> nil) and
    (pglUniform1f <> nil) and (pglUniform2f <> nil) and
    (pglUniform1i <> nil) and
    (pglDeleteShader <> nil) and (pglDeleteProgram <> nil);
  InterlockedExchange(LoadState, 2);
end;

function CompileFragmentProgram(src: PAnsiChar): DWord;
var
  sh, prog: DWord;
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

procedure DeleteShaderProgram(prog: DWord);
begin
  if (prog <> 0) and OK then
    pglDeleteProgram(prog);
end;

procedure UseShaderProgram(prog: DWord);
begin
  if OK then
    pglUseProgram(prog);
end;

function GetShaderUniform(prog: DWord; name: PAnsiChar): LongInt;
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
