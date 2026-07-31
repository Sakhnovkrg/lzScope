unit gl_min;

{ Minimal OpenGL 1.1 + WGL bindings, just what the renderer needs.
  Self-contained so there is no dependency on the FPC OpenGL package. }

{$mode objfpc}{$H+}

interface

uses
  Windows;

const
  GL_COLOR_BUFFER_BIT = $00004000;
  GL_PROJECTION       = $1701;
  GL_MODELVIEW        = $1700;
  GL_LINES            = $0001;
  GL_LINE_STRIP       = $0003;
  GL_TRIANGLES        = $0004;
  GL_TRIANGLE_STRIP   = $0005;
  GL_QUADS            = $0007;
  GL_BLEND            = $0BE2;
  GL_LINE_SMOOTH      = $0B20;
  GL_LINE_SMOOTH_HINT = $0C52;
  GL_NICEST           = $1102;
  GL_MULTISAMPLE      = $809D;
  GL_SRC_ALPHA        = $0302;
  GL_ONE_MINUS_SRC_ALPHA = $0303;
  GL_UNSIGNED_BYTE    = $1401;

  { shader objects (GL 2.0, loaded via wglGetProcAddress) }
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

  { WGL_ARB_pixel_format attributes (for multisample formats) }
  WGL_DRAW_TO_WINDOW_ARB    = $2001;
  WGL_ACCELERATION_ARB      = $2003;
  WGL_SUPPORT_OPENGL_ARB    = $2010;
  WGL_DOUBLE_BUFFER_ARB     = $2011;
  WGL_PIXEL_TYPE_ARB        = $2013;
  WGL_COLOR_BITS_ARB        = $2014;
  WGL_FULL_ACCELERATION_ARB = $2027;
  WGL_TYPE_RGBA_ARB         = $202B;
  WGL_SAMPLE_BUFFERS_ARB    = $2041;
  WGL_SAMPLES_ARB           = $2042;

procedure glViewport(x, y, width, height: LongInt); stdcall; external 'opengl32.dll';
procedure glClearColor(r, g, b, a: Single); stdcall; external 'opengl32.dll';
procedure glClear(mask: DWORD); stdcall; external 'opengl32.dll';
procedure glMatrixMode(mode: DWORD); stdcall; external 'opengl32.dll';
procedure glLoadIdentity; stdcall; external 'opengl32.dll';
procedure glOrtho(left, right, bottom, top, zNear, zFar: Double); stdcall; external 'opengl32.dll';
procedure glBegin(mode: DWORD); stdcall; external 'opengl32.dll';
procedure glEnd; stdcall; external 'opengl32.dll';
procedure glVertex2f(x, y: Single); stdcall; external 'opengl32.dll';
procedure glTexCoord2f(s, t: Single); stdcall; external 'opengl32.dll';
procedure glColor4f(r, g, b, a: Single); stdcall; external 'opengl32.dll';
procedure glLineWidth(width: Single); stdcall; external 'opengl32.dll';
procedure glEnable(cap: DWORD); stdcall; external 'opengl32.dll';
procedure glDisable(cap: DWORD); stdcall; external 'opengl32.dll';
procedure glBlendFunc(sfactor, dfactor: DWORD); stdcall; external 'opengl32.dll';
procedure glHint(target, mode: DWORD); stdcall; external 'opengl32.dll';

{ textures (GL 1.1 core — used to grab the scene for the about warp) }
procedure glGenTextures(n: LongInt; textures: PDWORD); stdcall; external 'opengl32.dll';
procedure glDeleteTextures(n: LongInt; textures: PDWORD); stdcall; external 'opengl32.dll';
procedure glBindTexture(target, texture: DWORD); stdcall; external 'opengl32.dll';
procedure glTexImage2D(target: DWORD; level, internalformat, width, height,
  border: LongInt; format, atype: DWORD; pixels: Pointer); stdcall; external 'opengl32.dll';
procedure glTexParameteri(target, pname: DWORD; param: LongInt); stdcall; external 'opengl32.dll';
procedure glCopyTexSubImage2D(target: DWORD; level, xoffset, yoffset,
  x, y, width, height: LongInt); stdcall; external 'opengl32.dll';

{ display lists + raster text (used with wglUseFontBitmaps) }
function glGenLists(range: LongInt): DWORD; stdcall; external 'opengl32.dll';
procedure glDeleteLists(list: DWORD; range: LongInt); stdcall; external 'opengl32.dll';
procedure glListBase(base: DWORD); stdcall; external 'opengl32.dll';
procedure glCallLists(n: LongInt; atype: DWORD; lists: Pointer); stdcall; external 'opengl32.dll';
procedure glRasterPos2f(x, y: Single); stdcall; external 'opengl32.dll';

function wglCreateContext(dc: HDC): HGLRC; stdcall; external 'opengl32.dll';
function wglDeleteContext(rc: HGLRC): BOOL; stdcall; external 'opengl32.dll';
function wglMakeCurrent(dc: HDC; rc: HGLRC): BOOL; stdcall; external 'opengl32.dll';
function wglGetProcAddress(name: PAnsiChar): Pointer; stdcall; external 'opengl32.dll';
function wglUseFontBitmapsW(dc: HDC; first, count, listBase: DWORD): BOOL; stdcall; external 'opengl32.dll';

type
  { WGL_EXT_swap_control; fetch via wglGetProcAddress with a current context }
  TWglSwapIntervalEXT = function(interval: Integer): BOOL; stdcall;

  { WGL_ARB_pixel_format }
  TWglChoosePixelFormatARB = function(dc: HDC; piAttribIList: PLongInt;
    pfAttribFList: PSingle; nMaxFormats: UINT; piFormats: PLongInt;
    nNumFormats: PUINT): BOOL; stdcall;

  { GL 2.0 shader entry points (fetch with a current context) }
  TglCreateShader = function(shaderType: DWORD): DWORD; stdcall;
  TglShaderSource = procedure(shader: DWORD; count: LongInt;
    src: PPAnsiChar; lengths: PLongInt); stdcall;
  TglCompileShader = procedure(shader: DWORD); stdcall;
  TglGetShaderiv = procedure(shader: DWORD; pname: DWORD;
    params: PLongInt); stdcall;
  TglCreateProgram = function: DWORD; stdcall;
  TglAttachShader = procedure(prog, shader: DWORD); stdcall;
  TglLinkProgram = procedure(prog: DWORD); stdcall;
  TglGetProgramiv = procedure(prog: DWORD; pname: DWORD;
    params: PLongInt); stdcall;
  TglUseProgram = procedure(prog: DWORD); stdcall;
  TglGetUniformLocation = function(prog: DWORD; name: PAnsiChar): LongInt; stdcall;
  TglUniform1f = procedure(loc: LongInt; v: Single); stdcall;
  TglUniform2f = procedure(loc: LongInt; x, y: Single); stdcall;
  TglUniform1i = procedure(loc: LongInt; v: LongInt); stdcall;
  TglDeleteShader = procedure(shader: DWORD); stdcall;
  TglDeleteProgram = procedure(prog: DWORD); stdcall;

implementation

end.
