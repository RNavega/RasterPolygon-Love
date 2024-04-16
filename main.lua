-- ==========================================================
-- Example of rasterizing a simple polyline polygon.
-- By Rafael Navega (2024)
--
-- License: Public Domain
-- ==========================================================

io.stdout:setvbuf('no')


local ffi = require('ffi')

local UINT8_PTR_TYPEOF = ffi.typeof('uint8_t*')
local FLOAT_PTR_TYPEOF = ffi.typeof('float*')
local SIZEOF_FLOAT     = ffi.sizeof('float')


local polygonImage1
local polygonImage2
local r8Shader


-- Returns a LÖVE ByteData object, as well as its uint8_t FFI pointer.
-- The pointer is for modifying the contents.
-- Use makeFloatData() when you need it for a GLSL uniform.
local function makeByteData(totalBytes)
    local data = love.data.newByteData(totalBytes)
    return data, UINT8_PTR_TYPEOF(data:getFFIPointer())
end

-- For use with GLSL uniforms. Unused in this demo.
local function makeFloatData(totalFloats)
    local data = love.data.newByteData(totalFloats * SIZEOF_FLOAT)
    return data, FLOAT_PTR_TYPEOF(data:getFFIPointer())
end


local function svgPolygonPointsString()
    -- From the Inkscape XML editor (Ctrl + Shift + X), copy-pasting
    -- the text from the "d" attribute (the SVG draw commands).
    return [[
        M 0,0
        V 32
        H 32
        V 0
        Z
        M 2,2
        H 30
        V 30
        H 2
        Z
        M 9.49,3 9.11,3.03 8.76,3.21 4.06,6.89 3.8,7.2 3.69,7.56 3.71,7.94
        3.89,8.29 10.66,16.91
        l -2.35,1.85 -0.16,0.22 -0.01,0.26 0.12,0.23 0.24,0.13 10.47,2.46
        h 0.36
        l 0.31,-0.15 0.22,-0.27 0.08,-0.35 0.1,-10.76 -0.08,-0.26 -0.19,-0.17
        -0.25,-0.05 -0.25,0.1 -2.35,1.84
        L 10.16,3.37 9.86,3.12
        Z
        M 20.5,24 17.58,24.2 15.2,24.73 13.59,25.53 13,26.5
        l 0.59,0.97 1.61,0.79 2.38,0.54
        L 20.5,29 23.42,28.8 25.8,28.27 27.41,27.47 28,26.5 27.41,25.53
        25.8,24.73 23.42,24.2
        Z
    ]]
end


-- Pixel shader to draw an image in the format "r8" (only a red channel).
-- This is needed because if no shader is used, the result is tinted red.
local R8_PIXEL_SOURCE = [[
vec4 effect( vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords )
{
    float alpha = Texel(tex, texture_coords).r;
    const vec4 HALF_GREY = vec4(vec3(0.5), 1.0);
    return mix(HALF_GREY, vec4(color.xyz, 1.0), alpha);
}
]]


-- Parses the SVG "d" attribute draw command list.
-- Only linear drawings are supported (M/m, L/l, H/h and V/v).
-- Curve, arc (C/c, S/s, A/a) etc commands would need to be flattened to lines
-- to be supported.
local function parseSVGDrawCommands(commandString)
    local tableInsert = table.insert

    local state, lowerState
    local shapeData = {shapes={}}
    local currentShape = {}
    local length = 0
    local position = {0.0, 0.0}

    -- Split the "d" string by whitespace, go through each non-whitespace piece.
    for piece in commandString:gmatch('%s*([^%s]+)%s*') do
        lowerPiece = piece:lower()
        if (lowerPiece == 'm' or lowerPiece == 'l'
            or lowerPiece == 'h' or lowerPiece == 'v') then
            state      = piece
            lowerState = lowerPiece
        elseif lowerPiece == 'z' then
            currentShape.length = length
            tableInsert(shapeData.shapes, currentShape)
            currentShape = {}
            length = 0
        else
            -- Try to read a single number ("135.002"), or a comma-separated
            -- pair of numbers ("135.002,-99.71"), with the numbers possibly
            -- having decimal points and/or preceded by a negative sign.
            local valueA, valueB = piece:match('([%-%d%.]+)[,]*([%-%d%.]*)')
            if valueA then
                valueA = tonumber(valueA)
                if lowerState == 'l' or lowerState == 'm' then
                    if valueB then
                        valueB = tonumber(valueB)
                        if state == 'M' or state == 'L' then
                            position[1] = valueA
                            position[2] = valueB
                        else
                            position[1] = position[1] + valueA
                            position[2] = position[2] + valueB
                        end
                        currentShape[length + 1] = position[1]
                        currentShape[length + 2] = position[2]
                        length = length + 2
                    else
                        error(('Bad "%s" command parameters: %s'):format(state, piece), 2)
                    end
                elseif lowerState == 'h' or lowerState == 'v' then
                    local axisIndex = (lowerState == 'h') and 1 or 2
                    if state == 'H' or state == 'V' then
                        position[axisIndex] = valueA
                    else
                        position[axisIndex] = position[axisIndex] + valueA
                    end
                    currentShape[length + 1] = position[1]
                    currentShape[length + 2] = position[2]
                    length = length + 2
                else
                    error('No active SVG drawing state', 2)
                end
            else
                error('Unsupported SVG draw command: '.. piece, 2)
            end
        end
    end
    return shapeData
end


local function makeRasterPolygon(shapeData, scaleX, scaleY)
    -- Default scale values if omitted.
    scaleX = scaleX or 1.0
    scaleY = scaleY or 1.0

    local rasterPolygon = {length=nil, width=nil, height=nil}

    local bbx1  = math.huge
    local bby1  = math.huge
    local bbx2 = -math.huge
    local bby2 = -math.huge

    local totalSegments = 0

    -- The p0 and p1 below are from "p1 = p0 + v . t"
    for shapeIndex = 1, #shapeData.shapes do
        local pointData = shapeData.shapes[shapeIndex]
        local p0 = {pointData[pointData.length - 1] * scaleX,
                    pointData[pointData.length] * scaleY}
        for pairIndex = 1, pointData.length, 2 do
            local p1 = {pointData[pairIndex] * scaleX,
                        pointData[pairIndex + 1] * scaleY}
            -- Find the bounding box.
            if p1[1] < bbx1 then
                bbx1 = p1[1]
            elseif p1[1] > bbx2 then
                bbx2 = p1[1]
            end
            if p1[2] < bby1 then
                bby1 = p1[2]
            elseif p1[2] > bby2 then
                bby2 = p1[2]
            end
            -- Store a new line segment object into the polygon table.
            local deltaX = p1[1] - p0[1]
            local deltaY = p1[2] - p0[2]
            local segmentData = {p0 = p0,
                                 p1 = p1,
                                 v = {deltaX, deltaY},
                                 lengthSq = (deltaX * deltaX + deltaY * deltaY)}
            totalSegments = totalSegments + 1
            rasterPolygon[totalSegments] = segmentData
            p0 = p1
        end
    end
    rasterPolygon.length = totalSegments
    rasterPolygon.width = bbx2
    rasterPolygon.height = bby2
    return rasterPolygon
end


-- Returns the (estimated) coverage of the polygon over the point, as a
-- value in the range [0.0, 1.0], with 1.0 being "fully covered".
local function sampleRasterPolygon(x, y, rasterPolygon)
    -- Sample from the pixel centers.
    x = x + 0.5
    y = y + 0.5

    local isInside = false
    local nearestDistance = math.huge
    local distanceTG = 0.0

    for segmentIndex = 1, rasterPolygon.length do
        local segmentData = rasterPolygon[segmentIndex]
        local p0 = segmentData.p0
        local p1 = segmentData.p1
        local v  = segmentData.v
        local deltaX = x - p0[1]
        local deltaY = y - p0[2]
        -- Only raycast on non-horizontal segments, and segments where
        -- the point is contained in the vertical span of the segment.
        -- This initial test condition is based on W. Randolph Franklin's
        -- point-in-poly algorithm (MIT licensed) from:
        -- https://wrfranklin.org/Research/Short_Notes/pnpoly.html#The%20C%20Code
        if ((p0[2] > y) ~= (p1[2] > y)) then
            local tX = deltaY / v[2]
            local intersectX = p0[1] + v[1] * tX
            if x < intersectX then
                isInside = not isInside
            end
        end

        local otherX, otherY
        local dot = (deltaX * v[1] + deltaY * v[2]) / segmentData.lengthSq
        if dot <= 0.0 then
            otherX = p0[1]
            otherY = p0[2]
        elseif dot >= 1.0 then
            otherX = p1[1]
            otherY = p1[2]
        else
            otherX = p0[1] + v[1] * dot
            otherY = p0[2] + v[2] * dot
        end
        local deltaX = x - otherX
        local deltaY = y - otherY
        local distance = math.sqrt(deltaX * deltaX + deltaY * deltaY)
        if distance < nearestDistance then
            nearestDistance = distance
            -- A pixel is shaped like a square, so there's two possible distances
            -- to its center: from its sides (half the square side) or from its
            -- corners (half the diagonal of the square).
            -- When coming from a corner to its center, that distance measures
            -- "half of the side, multiplied by the square root of two".
            --
            -- We find the slope ratio (like a tangent function) of the vector from
            -- the nearest point of the polygon towards the center of the pixel.
            -- This slope goes from 0.0 when it's orthogonal to the square sides, and
            -- up to 1.0 when it's orthogonal to the diagonals / square corners.
            -- Later this tangent value is used as a weight to mix between the
            -- "half-side" and "half-diagonal" lengths, so that the interpolated length
            -- is the reference length to estimate how far that the polygon is covering
            -- the square shape of the pixel.
            -- See 'baseDistance' below.
            deltaX = math.abs(deltaX)
            deltaY = math.abs(deltaY)
            if deltaX > deltaY then
                distanceTG = deltaX ~= 0.0 and (deltaY / deltaX) or 0.0
            else
                distanceTG = deltaY ~= 0.0 and (deltaX / deltaY) or 0.0
            end
        end
    end

    local CENTER_DISTANCE = 0.5
    -- Do a linear blending between 1.0 and sqrt(2), that is,
    -- a + (b - a) * t.
    -- Then use it to scale the half pixel distance, so it's in the
    -- range [0.5, 0.5 * sqrt(2)].
    local DIAG_OFFSET = 1.4142135623731 - 1.0
    local scaleFactor = 1.0 + DIAG_OFFSET * distanceTG
    local baseDistance = CENTER_DISTANCE * scaleFactor

    -- Map the nearest distance to the estimated "coverage" on the pixel, a
    -- value in the range [0.0, 1.0], in this way:
    --     - From 0.0 when the pixel square is fully outside the polygon;
    --     - Up to 0.5 when the pixel center is exactly at the polygon edge;
    --     - Up to 1.0 when the pixel square is fully inside the polygon.
    local coverage
    if isInside then
        coverage = (1.0 + nearestDistance / baseDistance) / 2.0
    else
        coverage = (1.0 - nearestDistance / baseDistance) / 2.0
    end
    -- Debug:
    --local coverage = isInside and 1.0 or 0.0
    -- Finally, clamp to the [0.0, 1.0] range
    return coverage < 0.0 and 0.0 or (coverage > 1.0 and 1.0 or coverage)
end


local function rasterizePolygon(rasterPolygon)
    local width = math.floor(rasterPolygon.width + 0.5)
    local height = math.floor(rasterPolygon.height + 0.5)
    local bytesPerPixel = 1
    local bytesPerRow = width * bytesPerPixel
    local data, ptr = makeByteData(height * bytesPerRow)

    for y = 0, height - 1 do
        local ptrOffset = y * bytesPerRow
        for x = 0, width - 1 do
            local fill = sampleRasterPolygon(x, y, rasterPolygon)
            local byteX = x * bytesPerPixel
            ptr[ptrOffset + byteX] = math.floor(fill * 255.0)
        end
    end

    local imageData = love.image.newImageData(width, height, 'r8', data)
    local image = love.graphics.newImage(imageData)
    image:setWrap('clamp', 'clamp')
    return image
end


function love.load()
    local shapeData = parseSVGDrawCommands(svgPolygonPointsString())
    local rasterPolygon = makeRasterPolygon(shapeData, 1.0, 1.0)
    local rasterPolygon3x = makeRasterPolygon(shapeData, 3.0, 3.0)

    love.window.setTitle('Polygon Rasterization Demo')
    local contentWidth  = rasterPolygon.width + rasterPolygon3x.width + 4 + 4 + 4
    local contentHeight = rasterPolygon3x.height + 4 + 4
    love.window.setMode(math.floor(contentWidth * 4.0 + 0.5),
                        math.floor(contentHeight * 4.0 + 0.5))

    love.graphics.setDefaultFilter('nearest', 'nearest')
    polygonImage1 = rasterizePolygon(rasterPolygon)
    polygonImage2 = rasterizePolygon(rasterPolygon3x)
    r8Shader = love.graphics.newShader(R8_PIXEL_SOURCE)
    love.graphics.setShader(r8Shader)
end


function love.draw()
    love.graphics.scale(4.0, 4.0)
    love.graphics.draw(polygonImage1, 4, 4)
    love.graphics.draw(polygonImage2, polygonImage1:getPixelWidth() + 4 + 4, 4)
end


function love.keypressed(key)
    if key == 'escape' then
        love.event.quit()
    end
end
