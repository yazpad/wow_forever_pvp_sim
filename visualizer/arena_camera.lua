-- Shared by the renderer and setup hit testing, in viewport-local pixels.
local camera = {
    worldScale=25, x=0, y=0, zoom=1, minZoom=0.45, maxZoom=3,
    isDragging=false, dragButton=2,
    dragStartX=0, dragStartY=0, origPanX=0, origPanY=0,
}
function camera.worldPoint(view, x, y)
    return view.virtualW*0.5+camera.x+x*camera.worldScale*camera.zoom,
        view.virtualH*0.48+camera.y+y*camera.worldScale*camera.zoom
end
function camera.screenPoint(view, x, y)
    return (x-view.virtualW*0.5-camera.x)/(camera.worldScale*camera.zoom),
        (y-view.virtualH*0.48-camera.y)/(camera.worldScale*camera.zoom)
end
-- Hold the separation direction through close contact. Release farther out than
-- we engage, so tiny position changes cannot swap portraits or toggle the layout.
local tokenAxisX,tokenAxisY
-- Presentation coordinates in arena pixels, before zoom. Never write these to frames.
function camera.tokenPositions(ax, ay, bx, by)
    local dx,dy=bx-ax,by-ay
    local distance=math.sqrt(dx*dx+dy*dy)
    local separation,release=100,120
    if distance>=release then
        tokenAxisX,tokenAxisY=nil,nil
        return ax,ay,bx,by
    end
    if not tokenAxisX then
        if distance>=separation then return ax,ay,bx,by end
        tokenAxisX,tokenAxisY=1,0
        if distance>1 then tokenAxisX,tokenAxisY=dx/distance,dy/distance end
    end
    local nx,ny=tokenAxisX,tokenAxisY
    -- Project onto the held direction so crossing the same position does not
    -- reverse the visual order. Ease the displacement away before releasing it.
    local projected=dx*nx+dy*ny
    local fade=math.min(1,(release-distance)/(release-separation))
    local offset=math.max(0,(separation-projected)*0.5)*fade
    return ax-nx*offset,ay-ny*offset,bx+nx*offset,by+ny*offset
end
-- Filter only small close-contact motion. State lives in presentation pixels;
-- replay coordinates and the overlap separation rules remain untouched.
local tokenMotion
function camera.resetTokenMotion()
    tokenMotion=nil
    tokenAxisX,tokenAxisY=nil,nil
end
function camera.smoothTokenPositions(ax,ay,bx,by,close,context,time,dt,bypass)
    local target={ax,ay,bx,by}
    local previous=tokenMotion
    local reset=not previous or previous.context~=context or bypass
        or time<previous.time or time-previous.time>0.25 or not close
    if not reset then
        local deadzone=1.5/math.max(camera.zoom,0.01)
        local alpha=1-math.exp(-math.min(dt,0.05)/0.06)
        for i=1,4,2 do
            local dx,dy=target[i]-previous[i],target[i+1]-previous[i+1]
            local distance=math.sqrt(dx*dx+dy*dy)
            if distance<24/math.max(camera.zoom,0.01) then
                -- Leave tiny fluctuations inside a screen-space dead zone.
                local amount=distance>deadzone and alpha*(distance-deadzone)/distance or 0
                target[i]=previous[i]+dx*amount
                target[i+1]=previous[i+1]+dy*amount
            end
        end
    end
    target.context,target.time=context,time
    tokenMotion=target
    return target[1],target[2],target[3],target[4]
end
return camera
