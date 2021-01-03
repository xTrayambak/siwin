import macros, strformat, strutils, unicode, tables, sequtils, algorithm, utils, sugar, sinim
import window

type
  SomeWindow = Window|PictureWindow

proc kindStrings(a: typedesc): seq[string] {.compileTime.} =
  let b = a.getTypeImpl
  b.expectKind nnkEnumTy
  for c in b:
    if c.kind == nnkSym: result.add c.strVal.toNimUniversal

const keyKindStrings = Key.kindStrings
const mouseButtonKindStrings = MouseButton.kindStrings

proc ofEnum(a: NimNode, b: typedesc): NimNode =
  template possible: seq[string] =
    when b is typedesc[Key]: keyKindStrings
    elif b is typedesc[MouseButton]: mouseButtonKindStrings
    else: b.kindStrings

  if a.kind == nnkIdent and a.strVal.toNimUniversal in possible:
    nnkDotExpr.newTree(quote do: `b`, a)
  else:
    a


proc check*(a, b: Key): bool = a == b
proc check*(a: Key, b: openarray[Key]): bool = a in b
proc check*(a: Key, b: proc(a: Key): bool): bool = b(a)
proc check*(a, b: MouseButton): bool = a == b
proc check*(a: MouseButton, b: openarray[MouseButton]): bool = a in b
proc check*(a: MouseButton, b: proc(a: MouseButton): bool): bool = b(a)


var keyNameBindings* {.compileTime.}: Table[string, seq[Key]]

macro makeKeyNameBinding*(name: untyped, match: static[openarray[Key]]): untyped =
  name.expectKind nnkIdent
  let matchLit = newArrayLit match
  keyNameBindings[name.strVal.toNimUniversal] = match.toSeq

  result = quote do:
    proc `name`*(a: Key): bool = a in `matchLit`
    proc `name`*(a: array[Key.a..Key.pause, bool]): bool =
      for k in `matchLit`:
        result = result or a[k]

makeKeyNameBinding control, [lcontrol, rcontrol]
makeKeyNameBinding ctrl,    [lcontrol, rcontrol]

makeKeyNameBinding shift,   [lshift, rshift]

makeKeyNameBinding alt,     [lalt, ralt]

makeKeyNameBinding system,  [lsystem, rsystem]
makeKeyNameBinding meta,    [lsystem, rsystem]
makeKeyNameBinding super,   [lsystem, rsystem]
makeKeyNameBinding windows, [lsystem, rsystem]
makeKeyNameBinding win,     [lsystem, rsystem]

makeKeyNameBinding esc,     [Key.escape]

proc genPressedKeyCheck(a: NimNode): NimNode = quote do:
  when compiles(`a`(e.keyboard.pressed)) and `a`(e.keyboard.pressed) is bool:
    `a`(e.keyboard.pressed)
  else:
    e.keyboard.pressed[`a`]

proc contains*(a: array[Key.a..Key.pause, bool], b: openArray[Key]): bool =
  for k in b:
    if a[k]:
      result = true
      return

proc nameToKeys(a: string): seq[Key] {.compileTime.} =
  let a = a.toNimUniversal
  if keyNameBindings.hasKey a: keyNameBindings[a]
  else: @[parseEnum[Key](a)]

proc genExPressedKeySeq(a: seq[NimNode]): seq[Key] {.compileTime.} =
  for k in Key.a..Key.pause:
    result.add k
  var r: seq[Key]
  for b in a:
    b.expectKind nnkIdent
    r.add nameToKeys(b.strVal)
  sort r
  r = r.deduplicate(true)
  for v in r.reversed:
    result.delete v.ord

proc runImpl(w: NimNode, a: NimNode, wt: static[RenderEngine]): NimNode =
  a.expectKind nnkStmtList
  result = nnkStmtList.newTree()

  var res: Table[string, NimNode]
  proc resadd(e: string, body: NimNode) =
    if e notin res: res[e] = nnkStmtList.newTree()
    res[e].add quote do:
      block: `body`

  for b in a:
    var b = b
    var eventName = ""
    var pars: seq[NimNode]
    var body: NimNode
    

    if b.kind == nnkPrefix:
      b[0].expectIdent "not"
      eventName &= "not"
      let c = b[2..^1]
      b = b[1]
      b &= c
    

    var asNode = nil.NimNode
    if b.kind == nnkInfix:
      b.expectLen 4
      b[0].expectIdent "as"
      
      asNode = b[2]
      let body = b[3]
      b = if b[1].kind == nnkIdent: nnkCall.newTree(b[1]) else: b[1]
      b.add body


    var genAs: proc(v: NimNode): NimNode = proc(v: NimNode): NimNode = discard
    var asKind = nnkEmpty
    if asNode != nil:
      asKind = asNode.kind
      
      case asKind
      of nnkIdent: discard
      of nnkPar:
        var r = nnkVarTuple.newTree
        for c in asNode:
          r &= nnkPragmaExpr.newTree(c, nnkPragma.newTree(ident"inject"))
        r &= nnkEmpty.newNimNode
        asNode = r
      of nnkBracketExpr:
        asNode.expectLen 1
        asNode = asNode[0]
        asNode.expectKind nnkIdent
      else: error(&"got {asNode.kind}, but expected ident, ident[] or tuple", asNode)

      case asKind
      of nnkIdent, nnkBracketExpr:
        genAs = proc(v: NimNode): NimNode = quote do:
          let `asNode` {.inject.} = `v`
      of nnkPar:
        genAs = proc(v: NimNode): NimNode =
          var r = asNode
          r.add v
          return nnkLetSection.newTree(r)
      else: discard

    proc sellectAs(a: NimNode, arr: NimNode): NimNode =
      if asKind == nnkBracketExpr: genAs(arr)
      else: genAs(a)
    proc sellectAs(a: NimNode): NimNode =
      if asKind == nnkBracketExpr: error(&"can't get event val as array", asNode)
      else: return genAs(a)
    
    
    b.expectKind {nnkCall, nnkCommand}
    
    case b[0].kind
    of nnkIdent: eventName &= b[0].strVal
    of nnkDotExpr:
      b[0][1].expectKind nnkIdent
      eventName &= b[0][1].strVal
      pars.add b[0][0]
    else: error(&"got {b[0].kind}, but expected ident or dotExpr", b[0])

    pars.add b[1..^2]
    body = b[^1]
    
    if not eventName.startsWith("on"):
      eventName = "on" & eventName.capitalize


    let e = ident"e"
    
    template resaddas(ename: string; a, arr, body: untyped) =
      let asl {.inject.} = sellectAs(quote do: a, quote do: arr)
      if asl != nil:
        ename.resadd quote do:
          `asl`
          body
      else:
        ename.resadd quote do:
          body

    template resaddas(ename: string; a, body: untyped) =
      let asl {.inject.} = sellectAs(quote do: a)
      if asl != nil:
        ename.resadd quote do:
          `asl`
          body
      else:
        ename.resadd quote do:
          body
    
    proc parseKeyCombination(a: NimNode): tuple[key: NimNode, cond: NimNode] = withExcl result, []:
      var keys = flattenInfix a
      key = keys[^1].ofEnum(Key)

      let needEx = ident"_" in keys or keys.len > 1
      keys.delete ident"_"

      if needEx:
        let ex = genExPressedKeySeq(keys).newLit
        cond = quote do: `ex` notin `e`.keyboard.pressed
        for c in keys[0..^2].map(a => a.ofEnum(Key).genPressedKeyCheck):
          cond = quote do: `c` and `cond`
      else:
        cond = newLit true

    case eventName[2..^1].toLower
    of "keydown", "keyup":
      if pars.len == 1 and pars[0] != ident"any":
        var (k, c) = pars[0].parseKeyCombination
        eventName.resadd quote do:
          if check(`e`.key, `k`) and `c`:
            `body`
      elif pars.len > 1:
        var cond = newLit true
        for (k, c) in pars.map(a => parseKeyCombination a):
          cond = quote do: `cond` or (`c` and check(`e`.key, `k`))
        eventName.resadd quote do:
          if `cond`:
            `body`
      else: eventName.resadd body

    of "mousedown", "mouseup":
      if pars.len == 1 and pars[0] != ident"any":
        var k = pars[0].ofEnum(MouseButton)
        eventName.resadd quote do:
          if check(e.button, `k`):
            `body`
      elif pars.len > 1:
        var kk = nnkBracket.newTree()
        for v in pars:
          kk.add v.ofEnum(MouseButton)
        eventName.resadd quote do:
          if e.button in `kk`:
            `body`
      else: eventName.resadd body

    of "pressingkey", "keypressing", "pressing":
      if pars.len == 1 and pars[0] != ident"any":
        var k = pars[0].ofEnum(Key)
        "onTick".resaddas `k`:
          if `e`.keyboard.pressed[`k`]:
            `body`
      elif pars.len > 1:
        var kk = nnkBracket.newTree()
        for v in pars:
          kk.add v.ofEnum(Key)
        case asKind
        of nnkEmpty:
          "onTick".resadd quote do:
            var prs = false
            for k in `kk`:
              if e.keyboard.pressed[k]: prs = true; break
            if prs:
              `body`
        of nnkIdent:
          "onTick".resadd quote do:
            var `asNode` {.inject.} = Key.unknown
            for k in `kk`:
              if e.keyboard.pressed[k]: `asNode` = k; break
            if `asNode` != Key.unknown:
              `body`
        of nnkBracketExpr:
          "onTick".resadd quote do:
            var `asNode` {.inject.}: seq[Key]
            for k in `kk`:
              if e.keyboard.pressed[k]: `asNode`.add k
            if `asNode`.len > 0:
              `body`
        else: error(&"got {asNode.kind}, but expected ident or ident[]", asNode)
      else:
        case asKind
        of nnkEmpty:
          "onTick".resadd quote do:
            if true in `e`.keyboard.pressed:
              `body`
        of nnkIdent:
          "onTick".resadd quote do:
            var `asNode` {.inject.} = Key.unknown
            for k, v in `e`.keyboard.pressed:
              if v: `asNode` = k; break
            if `asNode` != Key.unknown:
              `body`
        of nnkBracketExpr:
          "onTick".resadd quote do:
            var `asNode` {.inject.}: seq[Key]
            for k, v in `e`.keyboard.pressed:
              if v: `asNode`.add k
            if `asNode`.len > 0:
              `body`
        else: error(&"got {asNode.kind}, but expected ident or ident[]", asNode)

    of "notpressingkey", "notkeypressing", "notpressing":
      if pars.len == 1 and pars[0] != ident"any":
        var k = pars[0].ofEnum(Key)
        "onTick".resadd quote do:
          if not `e`.keyboard.pressed[`k`]:
            `body`
      elif pars.len > 1:
        var kk = nnkBracket.newTree()
        for v in pars:
          kk.add v.ofEnum(Key)
        "onTick".resadd quote do:
          var prs = false
          for k in `kk`:
            if `e`.keyboard.pressed[k]: prs = true
          if not prs:
            `body`
      else:
        "onTick".resadd quote do:
          if true notin `e`.keyboard.pressed:
            `body`

    of "click":
      if pars.len == 1 and pars[0] != ident"any":
        var k = pars[0].ofEnum(MouseButton)
        eventName.resaddas `e`.position:
          if `e`.button == `k`:
            `body`
      if pars.len > 1:
        var kk = nnkBracket.newTree()
        for v in pars:
          kk.add v.ofEnum(MouseButton)
        eventName.resaddas `e`.position:
          if `e`.button in `kk`:
            `body`
      else:
        eventName.resaddas `e`.position: `body`

    of "textenter":
      eventName.resaddas `e`.text, `e`.text.toRunes: `body`
    of "render":
      when wt == RenderEngine.picture:
        eventName.resaddas `w`.render: `body`
      else:
        error "can't render on window (no render engine)", b
    of "focus":
      eventName.resaddas `e`.focused: `body`
    of "fullscreen", "fullscreenchanged":
      if pars.len == 1:
        let c = pars[0]
        "onFullscreenChanged".resaddas `e`.state:
          if `e`.state == `c`:
            `body`
      elif pars.len > 1:
        error(&"got {pars.len} parametrs, but expected one of (), (state)", pars[1])
      else:
        "onFullscreenChanged".resaddas `e`.state: `body`

    of "scroll":
      eventName.resaddas `e`.delta: `body`
    of "mousemove", "mouseleave", "mouseenter", "windowmove":
      eventName.resaddas `e`.position: `body`
    of "resize":
      eventName.resaddas `e`.size: `body`

    else: eventName.resadd body

  for eventName, body in res:
    let eventNameIdent = ident eventName

    template eproc(t: typedesc) {.dirty.} =
      result.add quote do:
        `w`.`eventNameIdent` = proc(e {.inject.}: t) =
          `body`

    case eventName[2..^1].toLower
    of "close":  eproc CloseEvent
    of "render":
      when wt == RenderEngine.picture:
        eproc PictureRenderEvent
    of "tick":   eproc TickEvent
    of "resize": eproc ResizeEvent
    of "windowmove": eproc WindowMoveEvent
    
    of "focus":  eproc FocusEvent
    of "fullscreenchanged": eproc StateChangedEvent
    
    of "mousemove", "mouseleave", "mouseenter": eproc MouseMoveEvent
    of "mousedown", "mouseup": eproc MouseButtonEvent
    of "click", "doubleclick": eproc ClickEvent
    of "scroll": eproc ScrollEvent

    of "keydown", "keyup": eproc KeyEvent
    of "textenter": eproc TextEnterEvent

    of "init":
      result.add quote do:
        `body`
    else: error(&"unknown event: {eventName[2..^1]}")

  result.add quote do:
    run `w`

macro run*(w: var Window, a: untyped) =
  ## run window macro
  runImpl w, a, RenderEngine.none
macro run*(w: var PictureWindow, a: untyped) =
  ## run window macro
  runImpl w, a, RenderEngine.picture

template run*(w: SomeWindow, a: untyped) =
  var window {.inject, used.} = w
  run window, a
