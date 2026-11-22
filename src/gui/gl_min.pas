unit gl_min;

{ Minimal OpenGL 1.1 bindings, plus the GL 2.0 shader entry points }

{$mode objfpc}{$H+}
{$macro on}

{ glcall: the calling convention; glimport: also where the 1.1 entry points live }
{$IF DEFINED(WINDOWS)}
  {$DEFINE glcall := stdcall}
  {$DEFINE glimport := stdcall; external 'opengl32.dll'}
{$ELSEIF DEFINED(DARWIN)}
  {$DEFINE glcall := cdecl}
  {$DEFINE glimport := cdecl; external}
  {$linkframework OpenGL}
{$ELSE}
  {$DEFINE glcall := cdecl}
  {$DEFINE glimport := cdecl; external 'GL'}
{$ENDIF}

interface

const
{$IF DEFINED(WINDOWS)}
  GL_LIB = 'opengl32.dll';
{$ELSEIF DEFINED(DARWIN)}
  GL_LIB = '/System/Library/Frameworks/OpenGL.framework/OpenGL';
{$ELSE}
  GL_LIB = 'GL';   { libGL.so.1: GLX and GL 1.x }
{$ENDIF}

  GL_COLOR_BUFFER_BIT = $00004000;
  GL_PROJECTION       = $1701;
  GL_MODELVIEW        = $1700;
  GL_LINES            = $0001;
  GL_LINE_STRIP       = $0003;
  GL_TRIANGLES        = $0004;
  GL_TRIANGLE_STRIP   = $0005;
  GL_QUADS            = $0007;
  GL_BLEND            = $0BE2;
  GL_SCISSOR_TEST     = $0C11;
  GL_LINE_SMOOTH      = $0B20;
  GL_LINE_SMOOTH_HINT = $0C52;
  GL_NICEST           = $1102;
  GL_MULTISAMPLE      = $809D;
  GL_SRC_ALPHA        = $0302;
  GL_ONE_MINUS_SRC_ALPHA = $0303;
  GL_UNSIGNED_BYTE    = $1401;
  GL_FLOAT            = $1406;
  GL_VERTEX_ARRAY     = $8074;
  GL_COLOR_ARRAY      = $8076;

  { shaders (GL 2.0) }
  GL_FRAGMENT_SHADER = $8B30;
  GL_VERTEX_SHADER   = $8B31;
  GL_COMPILE_STATUS  = $8B81;
  GL_LINK_STATUS     = $8B82;

  { textures }
  GL_TEXTURE_2D         = $0DE1;
  GL_TEXTURE_MAG_FILTER = $2800;
  GL_TEXTURE_MIN_FILTER = $2801;
  GL_TEXTURE_WRAP_S     = $2802;
  GL_TEXTURE_WRAP_T     = $2803;
  GL_LINEAR             = $2601;
  GL_CLAMP_TO_EDGE      = $812F;
  GL_RGB                = $1907;
  GL_RGBA               = $1908;

procedure glViewport(x, y, width, height: LongInt); glimport;
procedure glClearColor(r, g, b, a: Single); glimport;
procedure glClear(mask: DWord); glimport;
procedure glMatrixMode(mode: DWord); glimport;
procedure glLoadIdentity; glimport;
procedure glOrtho(left, right, bottom, top, zNear, zFar: Double); glimport;
procedure glBegin(mode: DWord); glimport;
procedure glEnd; glimport;
procedure glVertex2f(x, y: Single); glimport;
procedure glTexCoord2f(s, t: Single); glimport;
procedure glColor4f(r, g, b, a: Single); glimport;
procedure glLineWidth(width: Single); glimport;
procedure glEnable(cap: DWord); glimport;
procedure glDisable(cap: DWord); glimport;
procedure glScissor(x, y, width, height: LongInt); glimport;
procedure glBlendFunc(sfactor, dfactor: DWord); glimport;
procedure glHint(target, mode: DWord); glimport;

{ textures }
procedure glGenTextures(n: LongInt; textures: PDWord); glimport;
procedure glDeleteTextures(n: LongInt; textures: PDWord); glimport;
procedure glBindTexture(target, texture: DWord); glimport;
procedure glTexImage2D(target: DWord; level, internalformat, width, height,
  border: LongInt; format, atype: DWord; pixels: Pointer); glimport;
procedure glTexParameteri(target, pname: DWord; param: LongInt); glimport;
procedure glCopyTexSubImage2D(target: DWord; level, xoffset, yoffset,
  x, y, width, height: LongInt); glimport;

{ vertex arrays }
procedure glEnableClientState(cap: DWord); glimport;
procedure glDisableClientState(cap: DWord); glimport;
procedure glVertexPointer(size: LongInt; atype: DWord; stride: LongInt;
  data: Pointer); glimport;
procedure glColorPointer(size: LongInt; atype: DWord; stride: LongInt;
  data: Pointer); glimport;
procedure glDrawArrays(mode: DWord; first, count: LongInt); glimport;

type
  { GL 2.0 shaders, loaded at run time }
  TglCreateShader = function(shaderType: DWord): DWord; glcall;
  TglShaderSource = procedure(shader: DWord; count: LongInt;
    src: PPAnsiChar; lengths: PLongInt); glcall;
  TglCompileShader = procedure(shader: DWord); glcall;
  TglGetShaderiv = procedure(shader: DWord; pname: DWord;
    params: PLongInt); glcall;
  TglCreateProgram = function: DWord; glcall;
  TglAttachShader = procedure(prog, shader: DWord); glcall;
  TglLinkProgram = procedure(prog: DWord); glcall;
  TglGetProgramiv = procedure(prog: DWord; pname: DWord;
    params: PLongInt); glcall;
  TglUseProgram = procedure(prog: DWord); glcall;
  TglGetUniformLocation = function(prog: DWord; name: PAnsiChar): LongInt; glcall;
  TglUniform1f = procedure(loc: LongInt; v: Single); glcall;
  TglUniform2f = procedure(loc: LongInt; x, y: Single); glcall;
  TglUniform1i = procedure(loc: LongInt; v: LongInt); glcall;
  TglDeleteShader = procedure(shader: DWord); glcall;
  TglDeleteProgram = procedure(prog: DWord); glcall;

{ an extension or post-1.1 entry point; needs a current context on Windows }
function GetGLProc(name: PAnsiChar): Pointer;

implementation

{$IF DEFINED(WINDOWS)}

function wglGetProcAddress(name: PAnsiChar): Pointer; stdcall; external GL_LIB;

function GetGLProc(name: PAnsiChar): Pointer;
begin
  Result := wglGetProcAddress(name);
end;

{$ELSEIF DEFINED(DARWIN)}

uses
  dynlibs;

var
  GLLib: TLibHandle = NilHandle;

{ the framework exports everything up to GL 2.1 directly }
function GetGLProc(name: PAnsiChar): Pointer;
begin
  if GLLib = NilHandle then
    GLLib := LoadLibrary(GL_LIB);
  Result := GetProcedureAddress(GLLib, name);
end;

{$ELSE}

function glXGetProcAddressARB(name: PAnsiChar): Pointer; cdecl; external GL_LIB;

{ context independent with GLX }
function GetGLProc(name: PAnsiChar): Pointer;
begin
  Result := glXGetProcAddressARB(name);
end;

{$ENDIF}

end.
