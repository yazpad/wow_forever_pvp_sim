-- One atlas: warlock schools across the top, mage schools across the bottom.
local backgrounds = {}
local image, attempted = nil, false
local schools = {
    Affliction={0,0,{0.34,0.14,0.45}}, Demonology={1,0,{0.12,0.38,0.24}},
    Destruction={2,0,{0.48,0.18,0.10}}, Arcane={0,1,{0.30,0.19,0.48}},
    Fire={1,1,{0.48,0.22,0.08}}, Frost={2,1,{0.12,0.32,0.48}},
}
local function load()
    if attempted then return end
    attempted=true
    for _,path in ipairs({'art/talent_schools.png','visualizer/art/talent_schools.png'}) do
        if love.filesystem.getInfo(path) then
            local ok,result=pcall(love.graphics.newImage,path)
            if ok then image=result; image:setFilter('linear','linear'); return end
        end
    end
end
function backgrounds.draw(school,x,y,w,h)
    load()
    local g=love.graphics
    local info=schools[school]
    if not info then return end
    g.setColor(info[3][1],info[3][2],info[3][3],1)
    g.rectangle('fill',x,y,w,h,5)
    if image then
        local iw,ih=image:getDimensions()
        local cw,ch=iw/3,ih/2
        local scale=math.max(w/cw,h/ch)
        local sw,sh=w/scale,h/scale
        local quad=g.newQuad(info[1]*cw+(cw-sw)/2,info[2]*ch+(ch-sh)/2,sw,sh,iw,ih)
        g.setColor(1,1,1,0.8)
        g.draw(image,quad,x,y,0,scale,scale)
    end
    -- Darken the illustration, preserving enough contrast for icons and text.
    g.setColor(0.025,0.035,0.06,0.35)
    g.rectangle('fill',x,y,w,h,5)
    g.setColor(info[3][1]+0.2,info[3][2]+0.2,info[3][3]+0.2,0.8)
    g.setLineWidth(1)
    g.rectangle('line',x,y,w,h,5)
end
return backgrounds
