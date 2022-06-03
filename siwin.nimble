version       = "0.6.3"
author        = "levovix0"
description   = "Simple Window Maker"
license       = "MIT"
srcDir        = "src"

requires "nim >= 1.4"
requires "chroma >= 0.2.5"
requires "vmath >= 1.1.4"

when defined linux:
  requires "x11 >= 1.1"
when defined windows:
  requires "winim >= 3.6"

task testDeps, "install test dependencies":
  exec "nimble install opengl"
  exec "nimble install pixie"
  exec "nimble install https://github.com/levovix0/wayland"

task test, "test":
  withDir "tests":
    try:    exec "nim c -r tests"
    except: discard

task testWayland, "test wayland":
  withDir "tests":
    try:    exec "nim c -d:wayland -r tests"
    except: discard
