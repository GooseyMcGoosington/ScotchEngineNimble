import tigr
import std/math
import times, pixie, os

{.push boundChecks: off, overflowChecks: off, nilChecks: off, assertions: off, warnings: off, hints: off, optimization: speed, patterns: off.}

var
  runGame = true

const
  W: int = 1920
  H: int = 1080
  uW: uint = uint(W)
  uH: uint = uint(H)
  fH: float = float(H)
  W2: float = W/2
  H2: float = H/2
  W1: int = W-1
  H1: int = H-1
  fH1: float = float(H1)
  fW1: float = float(W1)
  fW: float = float(W)
  f1: float = float(1)
  ar: float = W/H

type
  wall = ref object
    x0: float
    x1: float
    y0: float
    y1: float
    portal: bool
    portal_top: float
    portal_bottom: float
    portal_link: int

  sector = object
    elevation: float
    height: float
    walls: seq[wall]

  player = object
    x: float
    y: float
    z: float
    vx: float = 0
    vy: float = 0
    vz: float = 0
    h: float
    yaw: float
    grounded: bool = false
    currentSector: sector

  portal_render = object
    sector_to_draw: sector
    culling_box: tuple[x0:int, x1:int, y0:float, y1:float, y2: float, y3: float, dxCull: float]
    clipped: bool

  texture = ref object
    name: string
    data: seq[uint32]

# Create a window with the desired dimensions and title
var screen = window(W, H, "Direct Screen Access", 0)
# Access the framebuffer as a pointer to uint32 (RGBA format)
let framebuffer = cast[ptr UncheckedArray[uint32]](screen.pix)

var character = player(x: 25, y: 25, z: 5, h: 5, yaw: 0)
var
  sector1 = sector(elevation: 0, height: 20, walls: @[wall(x0: 50, x1: 0, y0: 0, y1: 0, portal: true, portal_top: 2, portal_bottom: 2, portal_link: 1), wall(x0: 0, x1: 0, y0: 0, y1: 50, portal: false, portal_top: 0, portal_bottom: 0, portal_link: 0), wall(x0: 50, x1: 50, y0: 50, y1: 0, portal: false, portal_top: 0, portal_bottom: 0, portal_link: 0), wall(x0: 0, x1: 50, y0: 50, y1: 50, portal: false, portal_top: 0, portal_bottom: 0, portal_link: 0)])
  sector2 = sector(elevation: 0, height: 20, walls: @[wall(x0: 50, x1: 0, y0: -50, y1: -50, portal: false, portal_top: 2, portal_bottom: 2, portal_link: 1), wall(x0: 0, x1: 0, y0: -50, y1: 0, portal: false, portal_top: 0, portal_bottom: 0, portal_link: 0), wall(x0: 50, x1: 50, y0: 0, y1: -50, portal: false, portal_top: 0, portal_bottom: 0, portal_link: 0), wall(x0: 0, x1: 50, y0: 0, y1: 0, portal: false, portal_top: 0, portal_bottom: 0, portal_link: 0)])
  sectors: seq[sector] = @[sector1, sector2]

## compile as; nim c --cc:gcc -d:threads --d:strip -d:faster -d:release -d:lto -d:useMalloc -d:memProfiler --panics:off --opt:size --mm:arc --passL:"-flto" --passC:"-O3 -finline-functions -flto -ffast-math -mtune=native -ffunction-sections -falign-functions=32 -fdata-sections -fomit-frame-pointer -fno-stack-protector -mno-avx512f" main.nim
## PRECOMPUTED VALUES
var
  sn: array[0..360, float]
  cs: array[0..360, float]
  ceilLut: array[0..W, int] # Store a Y coordinate at X as a uint16.
  floorLut: array[0..W, int] # Store a Y coordinate at X as a uint16.
  ptrCeilLut = cast[ptr UncheckedArray[int]](ceilLut.addr)
  ptrFloorLut = cast[ptr UncheckedArray[int]](floorLut.addr)

let
  fov: float = 120
  tanFOV: float = math.tan(math.degToRad(fov/2))
  focalLength: float = W2/tanFOV
  fovWidth: float = tanFOV*1
  fovWidthAtY: float = fovWidth*ar
  screen_size = W*H-1

proc convertToRGB565(r: int, g: int, b: int): uint16 =
  let red565 = (r shr 3)       # Keep the top 5 bits
  let green565 = (g shr 2)     # Keep the top 6 bits
  let blue565 = (b shr 3)      # Keep the top 5 bits
  return uint16((red565 shl 11) + (green565 shl 5) + blue565)

const RED = 255#convertToRGB565(0xFF, 0x00, 0x00)
const BLANK = 0#convertToRGB565(0x00, 0x00, 0x00)
const GREY = 127#convertToRGB565(0x77, 0x77, 0x77)
const BLUE = 0#convertToRGB565(0x00, 0x00, 0xFF)

var textureList: seq[texture] = @[]
let exeDir = getCurrentDir()
let texturesDir = exeDir / "textures"

for i in 0..360:
  let a = math.degToRad(float(i))
  sn[i] = math.sin(a)
  cs[i] = math.cos(a)

## TEXTURES
for file in walkFiles(texturesDir / "*"):
  let textureData = readImage(file)
  var textureTbl = texture(name:splitFile(file).name)
  # initialize colours
  for colortbl in textureData.data:
    textureTbl.data.add(colortbl.r.int + (colortbl.g.int shl 8) + (colortbl.b.int shl 16))#convertToRGB565(colortbl.r.int, colortbl.g.int, colortbl.b.int)
  textureList.add(textureTbl)

proc locate_texture(texture_name: string): int =
  var i = 0
  for texture in textureList:
    if texture.name == texture_name:
      return i
    i += 1
  return 0

## ENGINE
proc clip(ax: float, ay: float, bx: float, by: float, px1: float, py1: float, px2: float, py2: float): (float, float, float) =
  var
    a = (px1 - px2) * (ay - py2) - (py1 - py2) * (ax - px2)
    b = (py1 - py2) * (ax - bx) - (px1 - px2) * (ay - by)
    t = a / (b+1)
    ax = ax - t * (bx - ax)
    ay = ay - t * (by - ay)
  return (ax, ay, t)

proc drawFlat(flat: uint8, culling_box: tuple, check_buffer: bool): void {.inline.} =
  let X0 = max(min(0, culling_box[1]), culling_box[0])
  let X1 = max(min(W1, culling_box[1]), culling_box[0])
  
  let dxCull = culling_box[6]
  
  var COLOUR: int
  if check_buffer:
    COLOUR = 66
  else:
    COLOUR = 127

  case check_buffer:
  of false:
    if flat == 1:
      # access ceiling LUT
      for x in X0..X1:
        let st = (x - culling_box[0]).float / dxCull
        let LUT_Y = ptrCeilLut[x]
        

        let yTop = ((1 - st) * culling_box[2] + st * culling_box[3]).int
        let yBottom = ((1 - st) * culling_box[4] + st * culling_box[5]).int

        let Y0 = max(min(1, yBottom), yTop)
        let Y1 = max(min(LUT_Y, yBottom), yTop)
        var index = Y0 * W + x
        for Y in Y0..Y1:
          framebuffer[index] = COLOUR
          index += W
    elif flat == 2:
      ## access floor LUT
      for x in X0..X1:
        let st = (x - culling_box[0]).float / dxCull
        let LUT_Y = ptrFloorLut[x]
        

        let yTop = ((1 - st) * culling_box[2] + st * culling_box[3]).int
        let yBottom = ((1 - st) * culling_box[4] + st * culling_box[5]).int

        let Y0 = max(min(LUT_Y, yBottom), yTop)
        let Y1 = max(min(H1, yBottom), yTop)
        var index = Y0 * W + x
        for Y in Y0..Y1:
          framebuffer[index] = COLOUR
          index += W
  else:
    if flat == 1:
      # access ceiling LUT
      for x in X0..X1:
        let st = (x - culling_box[0]).float / dxCull
        let LUT_Y = ptrCeilLut[x]
        

        let yTop = ((1 - st) * culling_box[2] + st * culling_box[3]).int
        let yBottom = ((1 - st) * culling_box[4] + st * culling_box[5]).int

        let Y0 = max(min(1, yBottom), yTop)
        let Y1 = max(min(LUT_Y, yBottom), yTop)
        var index = Y0 * W + x
        for Y in Y0..Y1:
          if framebuffer[index] == BLANK:
            framebuffer[index] = COLOUR
          index += W
    elif flat == 2:
      ## access floor LUT
      for x in X0..X1:
        let st = (x - culling_box[0]).float / dxCull
        let LUT_Y = ptrFloorLut[x]
        

        let yTop = ((1 - st) * culling_box[2] + st * culling_box[3]).int
        let yBottom = ((1 - st) * culling_box[4] + st * culling_box[5]).int

        let Y0 = max(min(LUT_Y, yBottom), yTop)
        let Y1 = max(min(H1, yBottom), yTop)
        var index = Y0 * W + x
        for Y in Y0..Y1:
          if framebuffer[index] == BLANK:
            framebuffer[index] = COLOUR
          index += W

proc drawPortal(x0, x1, y0, y1, y2, y3: int, culling_box: tuple): void {.inline.} =
  # Unpack the tuple
  let (cullMinX, cullMaxX, cullYTop, cullYTop2, cullYBottom, cullYBottom2, dxCull) = culling_box
  let dx = max(x1 - x0, 1)
  let X0 = int(max(min(x0, cullMaxX), cullMinX))
  let X1 = int(max(min(x1, cullMaxX), cullMinX))
  
  for x in X0 .. X1:
    let t = (x - x0).float / dx.float
    let st = (x - cullMinX).float / dxCull
    let wY1 = (1 - t) * y0.float + t * y1.float
    let wY2 = (1 - t) * y2.float + t * y3.float
    # Precompute the interpolated culling values outside inner loops
    let yTop = (1 - st) * cullYTop + st * cullYTop2
    let yBottom = (1 - st) * cullYBottom + st * cullYBottom2
    let CULL_Y1 = (max(min(wY1, yBottom), yTop)).int
    let CULL_Y2 = (max(min(wY2, yBottom), yTop)).int
    # Precompute x contribution to the index once per x iteration
    var index = CULL_Y1 * W + x
    for y in CULL_Y1..CULL_Y2:
      # Precompute y*W once per inner loop iteration
      framebuffer[index] = BLANK
      index += W

proc lerp(a: float, b: float, c: float): float =
  return (1 - a) * b + a * c
#
proc drawWall(x0, x1, y0, y1, y2, y3: int, culling_box: tuple, flat: uint8, check_buffer: bool, t0: float, t1: float, wy0: float, wy1: float): void {.inline.} =
  # Unpack the tuple
  let (cullMinX, cullMaxX, cullYTop, cullYTop2, cullYBottom, cullYBottom2, dxCull) = culling_box
  let dx = max(x1 - x0, 1)
  let X0 = int(max(min(x0, cullMaxX), cullMinX))
  let X1 = int(max(min(x1, cullMaxX), cullMinX))

  var
    sf = 1.0
    texH = 1.0
    texLeft = lerp(t0, 0, sf)
    texRight = lerp(t1, 0, sf)
    z0 = 1/wy0
    z1 = 1/wy1

  var currentTex: int = 0
  var lastTex: int = currentTex
  var intTexX: int = 0
  var texStep = 0
  let texLeftZ0 = texLeft/z0
  let texRightZ1 = texRight/z1
  
  let wall_texture = textureList[locate_texture("tile021")] # No Textures Folder will cause a SIGSEGV: Illegal Storage Access.
  let wall_texture_data = wall_texture.data

  if not check_buffer:
    for x in X0 .. X1:
      let t: float = (x - x0) / dx
      let v = (1-t)
      let st: float = float(x-culling_box[0])/dxCull
      let wyScale = (1-v)*wy0 + v*wy1
      let wY1 = (1 - t) * y0.float + t * y1.float
      let wY2 = (1 - t) * y2.float + t * y3.float

      # Precompute the interpolated culling values outside inner loops
      let yTop = (1 - st) * cullYTop + st * cullYTop2
      let yBottom = (1 - st) * cullYBottom + st * cullYBottom2
      let CULL_Y1 = (max(min(wY1, yBottom), yTop)).int
      let CULL_Y2 = (max(min(wY2, yBottom), yTop)).int
      
      if x mod 8 == 0:
        # initialize our tex values, and setup affine integer interpolation
        currentTex = intTexX
        intTexX = int(((1-v) * texLeftZ0 + v*texRightZ1) / wyScale * 64) mod 64
        texStep = (intTexX-currentTex) div 8
      currentTex += texStep
      # If 'y' index is too high or low, the program will have a SIGSEGV: Illegal Storage Access.
      case flat
      of 0:
        ptrCeilLut[x] = CULL_Y1
        ptrFloorLut[x] = CULL_Y2
      of 1:
        ptrCeilLut[x] = CULL_Y1
      of 2:
        ptrFloorLut[x] = CULL_Y2
      else:
        discard

      let dxWY = (wY2.int - wY1.int)
      var index = CULL_Y1 * W + x
      for y in CULL_Y1..CULL_Y2:
        # Precompute y*W once per inner loop iteration
        
        var
          a: float = (y - wY1.int) / dxWY
          v: float = a*texH
          texY: int = int(v*64) mod 64
          texture_index: int = (texY*64+currentTex)
        let colour: uint32 = wall_texture_data[texture_index]
        framebuffer[index] = colour
        index += W
  else:
    for x in X0 .. X1:
      let t: float = (x - x0) / dx
      let v = (1-t)
      let st: float = float(x-culling_box[0])/dxCull
      let wyScale = lerp(1 - t, wy0, wy1)
      let wY1 = (1 - t) * y0.float + t * y1.float
      let wY2 = (1 - t) * y2.float + t * y3.float

      # Precompute the interpolated culling values outside inner loops
      let yTop = (1 - st) * cullYTop + st * cullYTop2
      let yBottom = (1 - st) * cullYBottom + st * cullYBottom2
      let CULL_Y1 = (max(min(wY1, yBottom), yTop)).int
      let CULL_Y2 = (max(min(wY2, yBottom), yTop)).int
      
      if x mod 16 == 0:
        # initialize our tex values, and setup affine integer interpolation
        currentTex = intTexX
        intTexX = int(((1-v) * texLeftZ0 + v*texRightZ1) / wyScale * 64) mod 64
        texStep = (intTexX-currentTex) div 16
      currentTex += texStep
      # If 'y' index is too high or low, the program will have a SIGSEGV: Illegal Storage Access.
      case flat
      of 0:
        ptrCeilLut[x] = CULL_Y1
        ptrFloorLut[x] = CULL_Y2
      of 1:
        ptrCeilLut[x] = CULL_Y1
      of 2:
        ptrFloorLut[x] = CULL_Y2
      else:
        discard
      
      let dxWY = (wY2.int - wY1.int)
      var index = CULL_Y1 * W + x
      for y in CULL_Y1..CULL_Y2:
        # Precompute y*W once per inner loop iteration
        if framebuffer[index] == BLANK:
          var
            a: float = (y - wY1.int) / dxWY
            v: float = a*texH
            texY: int = int(v*64) mod 64
            texture_index: int = (texY*64+currentTex)
          let colour: uint32 = wall_texture_data[texture_index]
          framebuffer[index] = colour
        index += W

type buffer = array[W * H, uint16]
type buffer_lut = array[0..W, int]

proc fill(x: var buffer) =
  for i in low(x)..high(x):
    x[i] = 0'u16

proc fill_lut(x: var buffer_lut) =
  for i in low(x)..high(x):
    x[i] = 0
    
proc drawSector(sector_to_draw: sector, pSn: float, pCs: float, raw_culling_box: tuple, check_buffer: bool): void {.inline.} =
  var culling_box: tuple = (0, 0, 0.0, 0.0, 0.0, 0.0, 0.0)
  if check_buffer:
    culling_box = (raw_culling_box[0].int, raw_culling_box[1].int, raw_culling_box[2].float, raw_culling_box[3].float, raw_culling_box[4].float, raw_culling_box[5].float, raw_culling_box[6].float)
  else:
    culling_box = raw_culling_box
  
  let sector_walls = sector_to_draw.walls
  let px = character.x
  let py = character.y
  let pz = character.z

  let wz1 = pz - sector_to_draw.elevation
  let wz0 = pz - sector_to_draw.height - sector_to_draw.elevation

  var portalQueue: seq[portal_render] = @[] 
  
  for wall in sector_walls:
    let rx0 = wall.x0 - px
    let ry0 = wall.y0 - py
    let rx1 = wall.x1 - px
    let ry1 = wall.y1 - py
    
    var tx0 = rx0 * pCs - ry0 * pSn
    var ty0 = ry0 * pCs + rx0 * pSn
    var tx1 = rx1 * pCs - ry1 * pSn
    var ty1 = ry1 * pCs + rx1 * pSn

    var t: float
    var t0: float = 0
    var t1: float = 1
    var has_clipped: bool = false
    var side: uint = 0

    if ty0 < 1 and ty1 < 1:
      continue
    if check_buffer:
      if ((wall.y1 - wall.y0) * rx1) + (-(wall.x1 - wall.x0) * ry1) > -1 and not wall.portal:
        continue  # Wall not visible
    if ty0 < 1:
      (tx0, ty0, t) = clip(tx0, ty0, tx1, ty1, 1.0, 1.0, fW, 1.0)
      t1 += t / fovWidthAtY * ar
      has_clipped = true
      side = 1
    if ty1 < 1:
      (tx1, ty1, t) = clip(tx1, ty1, tx0, ty0, 1.0, 1.0, fW, 1.0)
      t0 -= t / fovWidthAtY * ar
      has_clipped = true
      side = 2

    let
      inv_ty0 = 1/ty0
      inv_ty1 = 1/ty1
      
      inv_ty0F = inv_ty0*focalLength
      inv_ty1F = inv_ty1*focalLength

    if wall.portal == false:
      let
        sx0 = tx0 * inv_ty0F + W2
        sx1 = tx1 * inv_ty1F + W2
        x0 = sx0
        x1 = sx1

        sy0 = wz0 * inv_ty0F + H2
        sy1 = wz0 * inv_ty1F + H2
        sy2 = wz1 * inv_ty0F + H2
        sy3 = wz1 * inv_ty1F + H2
      drawWall(int(x0), int(x1), int(sy0), int(sy1), int(sy2), int(sy3), culling_box, 0'u8, check_buffer, t0, t1, ty0, ty1) # 0 = Both, 1 = Ceiling, 2 = Floor
    else:
      var
        pz1 = wz0 + sector_to_draw.height
        pz0 = pz1 - wall.portal_bottom
        pz2 = wz0
        pz3 = pz2 + wall.portal_top
        inv_ty0 = 1 / ty0
        inv_ty1 = 1 / ty1

      let
        inv_ty1F_pz0 = inv_ty0F * pz0
        inv_ty2F_pz0 = inv_ty0F * pz1
        inv_ty3F_pz0 = inv_ty0F * pz2
        inv_ty4F_pz0 = inv_ty0F * pz3

      ## bottom
      let
        (sx0, sy0) = (tx0 * inv_ty0F + W2, pz0 * inv_ty0F + H2)
        (sx1, sy1) = (tx1 * inv_ty1F + W2, pz0 * inv_ty1F + H2)
        sy2 = pz1 * inv_ty0F + H2
        sy3 = pz1 * inv_ty1F + H2

        sy4 = pz2 * inv_ty0F + H2
        sy5 = pz2 * inv_ty1F + H2
        sy6 = pz3 * inv_ty0F + H2
        sy7 = pz3 * inv_ty1F + H2   

        sy8 = pz1 * inv_ty0F + H2
        sy9 = pz1 * inv_ty1F + H2
        sy10 = pz3 * inv_ty0F + H2
        sy11 = pz3 * inv_ty1F + H2
      var
        px0 = int(sx0)
        px1 = int(sx1)
      let
        py0 = int(sy0)
        py1 = int(sy1)
        py2 = int(sy2)
        py3 = int(sy3)

        py4 = int(sy4)
        py5 = int(sy5)
        py6 = int(sy6)
        py7 = int(sy7)

        py8 = int(sy8)
        py9 = int(sy9)
        py10 = int(sy10)
        py11 = int(sy11)
        wh_top = wall.portal_top
        wh_bot = wall.portal_bottom
      
      drawWall(px0, px1, py0, py1, py2, py3, culling_box, 2'u8, check_buffer, t0, t1, ty0, ty1)
      drawWall(px0, px1, py4, py5, py6, py7, culling_box, 1'u8, check_buffer, t0, t1, ty0, ty1)
      let
        mx0 = px0
        mx1 = px1
        my0 = py6
        my1 = py7
        my2 = py0
        my3 = py1

      drawPortal(px0, px1, py6, py7, py0, py1, culling_box)
      let sector = sectors[wall.portal_link]
      var my_portal = portal_render(
        sector_to_draw: sector, 
        culling_box: (
          max(min(px0, W1), 1), 
          max(min(px1, W1), 1), 
          max(min(py6, H1), 1).float, 
          max(min(py7, H1), 1).float, 
          max(min(py0, H1), 1).float, 
          max(min(py1, H1), 1).float, 
          float(px1-px0),
          ),
        clipped: has_clipped
        )
      portalQueue.add(my_portal)
  drawFlat(1'u8, culling_box, check_buffer)
  drawFlat(2'u8, culling_box, check_buffer)
  for queued_portal in portalQueue:
    drawSector(queued_portal.sector_to_draw, pSn, pCs, culling_box, true)

proc beginDrawSector(index: int, pSn: float, pCs: float, culling_box: tuple): void =
  let mySector = sectors[index]
  drawSector(mySector, pSn, pCs, culling_box, false)

## MAIN
var lastTime = epochTime()

var i = 0.0
var avg = 0.0
var avg2 = 0.0

while screen.closed() == 0:
  character.yaw = 180
  if character.yaw < 0:
    character.yaw = 359
  character.yaw = character.yaw mod 360
  
  let pSn = sn[int(character.yaw)]
  let pCs = cs[int(character.yaw)]

  #let st = epochTime()
  beginDrawSector(0, pSn, pCs, (1, W1, 1.0, 1.0, fH1, fH1, fW1-1.0))
  update(screen)  # Refresh the screen
  #let et_s = epochTime()
  #let st_f = (et_s-st)*1000
  #echo st_f
  
  #[let et = epochTime()
  let ft = (et-st)*1000
  i += 1
  avg += st_f
  avg2 += ft
  if i > 60:
    echo "Sector Draw Rate: ", $int(avg/i), "/s Actual Frame Rate: ", $int(avg2/i)
    avg = 0.0
    avg2 = 0.0
    i = 0]#
  fill_lut(ceilLut)
  fill_lut(floorLut)
  
{.pop.}