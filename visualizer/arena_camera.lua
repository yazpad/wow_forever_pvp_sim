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
return camera
