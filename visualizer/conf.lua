function love.conf(t)
    t.identity = "pvp_sim_visualizer"
    t.window.title = "PVP_SIM: 2D Neural Combat Arena"
    t.window.width = 1280
    t.window.height = 720
    t.window.minwidth = 960
    t.window.minheight = 540
    t.window.resizable = true
    t.window.vsync = 1
    t.window.highdpi = true
    t.modules.audio = false
    t.modules.physics = false
end
