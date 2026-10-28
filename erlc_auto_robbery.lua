-- Severe Luau | ERLC Auto Robbery (memory build) v3
-- Reads gui state straight from memory because Severe does not expose Gui properties.
-- Defaults are for Roblox version-5a21b87bbc2641cf (offsets.imtheo.lol).
-- If erlc_offsets.txt exists (written by erlc_offset_finder.lua) it overrides them.
-- Run order: finder once after a Roblox update -> this script.

local DEBUG = true
local MOUSE_OFFSET_X, MOUSE_OFFSET_Y = 0, 0

local OFFSETS = {
    VIS = 0x574, VISBIT = 0x100,          -- Visible is the byte at 0x575 -> bit 8 of the dword at 0x574
    POSX = 0xf4, POSY = 0xf8,             -- GuiBase2D::AbsolutePosition
    SIZEX = 0xfc, SIZEY = 0x100,          -- guess: size sits right after position (site says 0x0, unreliable)
    TEXT = 0xe08,
    COLR = 0xeb8, COLG = 0xebc, COLB = 0xec0,
}

------------------------------------------------------------------ helpers
-- Severe's send_notification wants (message, type) and rejects unknown type strings.
-- Try the likely names once, remember the one it accepts.
local NOTIFY_TYPES = { "info", "information", "success", "warning", "error", "notice", "normal" }
local notifyType, notifyErr = nil, nil
local function notify(msg)
    msg = tostring(msg)
    if notifyType then
        pcall(send_notification, msg, notifyType)
        return
    end
    for _, ty in ipairs(NOTIFY_TYPES) do
        local ok, err = pcall(send_notification, msg, ty)
        if ok then
            notifyType = ty
            print("[notify] using type '" .. ty .. "'")
            return
        end
        notifyErr = err
    end
    local ok, err = pcall(send_notification, msg)
    if not ok then print("[notify] send_notification failed: " .. tostring(err)) end
end

local lastDbg = {}
local function dbg(key, msg, every)
    if not DEBUG then return end
    local now = os.clock()
    if now - (lastDbg[key] or 0) >= (every or 1) then
        lastDbg[key] = now
        print("[dbg] " .. msg)
    end
end

if isfile and readfile and isfile("erlc_offsets.txt") then
    local ok, data = pcall(readfile, "erlc_offsets.txt")
    if ok and type(data) == "string" then
        local n = 0
        for k, v in string.gmatch(data, "(%w+)=(0x%x+)") do
            OFFSETS[k] = tonumber(v); n = n + 1
        end
        print("[offsets] loaded " .. n .. " values from erlc_offsets.txt")
    end
else
    print("[offsets] using built-in defaults (no erlc_offsets.txt)")
end

local function u32(i, o) local ok, v = pcall(memory.readu32, i, o); return ok and v or nil end
local function f32(i, o) local ok, v = pcall(memory.readf32, i, o); return ok and v or nil end
local function rstr(i, o) local ok, v = pcall(memory.readstring, i, o); return ok and type(v) == "string" and v or nil end

local function isVisible(inst)
    local v = u32(inst, OFFSETS.VIS)
    return v ~= nil and bit32.band(v, OFFSETS.VISBIT) ~= 0
end

local function rect(inst)
    local x, y = f32(inst, OFFSETS.POSX), f32(inst, OFFSETS.POSY)
    local w, h = f32(inst, OFFSETS.SIZEX), f32(inst, OFFSETS.SIZEY)
    if x and y and w and h then return x, y, w, h end
    return nil
end

local function textOf(inst) return rstr(inst, OFFSETS.TEXT) end

local function isBlack(inst)
    local r, g, b = f32(inst, OFFSETS.COLR), f32(inst, OFFSETS.COLG), f32(inst, OFFSETS.COLB)
    return r ~= nil and r < 0.02 and g < 0.02 and b < 0.02
end

local VPW, VPH = 1920, 1080
do
    local ok, vp = pcall(function() return workspace.CurrentCamera.ViewportSize end)
    if ok and vp then VPW, VPH = vp.X, vp.Y end
end

local lp = game.Players.LocalPlayer
if not lp then print("[dbg] no local player, aborting") return end
local menus
local function acquireMenus()
    local gui = lp:FindFirstChild("PlayerGui")
    menus = gui and gui:FindFirstChild("GameMenus")
    return menus ~= nil
end

local function sanity()
    -- a full-screen child should report a size close to the viewport
    local cam = workspace.CurrentCamera
    local ok, vp = pcall(function() return cam.ViewportSize end)
    if not (ok and vp) then return end
    for _, c in ipairs(menus:GetChildren()) do
        if c.Name == "Vignette" then
            local _, _, w, h = rect(c)
            if w and math.abs(w - vp.X) < 2 and math.abs(h - vp.Y) < 130 then
                print("[offsets] size check OK on Vignette")
            else
                print("[offsets] WARNING size check failed (" .. tostring(w) .. "x" .. tostring(h) ..
                    " vs " .. vp.X .. "x" .. vp.Y .. "). run erlc_offset_finder.lua")
            end
            return
        end
    end
end

------------------------------------------------------------------ lockpick
local pl = { hist = {}, lastClick = 0, waitStop = nil,
             LEAD = 0.040, TOL = 2.0, STOP = 1.5, COOLDOWN = 0.25, WINDOW = 0.15 }

pl.SETTLE = 0.5        -- line must be on screen and still for this long before we arm
pl.MAX_SPEED = 3000    -- px/s; anything faster is a UI tween or a bad read, never a pin
local function plReset() pl.hist, pl.lastClick, pl.waitStop = {}, 0, nil; pl.stableSince, pl.lastLineY = nil, nil end

local function velocity(h)
    -- px/sec over the last ~WINDOW seconds
    local n = #h
    if n < 2 then return 0 end
    local last = h[n]
    local first = last
    for i = n - 1, 1, -1 do
        first = h[i]
        if last.t - h[i].t >= pl.WINDOW then break end
    end
    local dt = last.t - first.t
    if dt <= 0 then return 0 end
    return (last.y - first.y) / dt
end

local function stepLockpick(root)
    local pick = root:FindFirstChild("Pick"); if not pick then return end
    local red = pick:FindFirstChild("RedLine"); if not red then return end
    local rx, ry, rw, rh = rect(red)
    if not ry then dbg("pl", "[pl] RedLine rect read failed") return end
    local line = ry + rh / 2
    if DEBUG then
        local s = string.format("[pl] RedLine x=%.1f y=%.1f w=%.1f h=%.1f |", rx, ry, rw, rh)
        local n = 0
        for _, c in ipairs(pick:GetChildren()) do
            if c ~= red and n < 4 then
                local px, py, pw, ph = rect(c)
                if px then s = s .. string.format(" %s x=%.1f y=%.1f w=%.1f h=%.1f;", c.Name, px, py, pw, ph) end
                n = n + 1
            end
        end
        dbg("pl", s, 0.5)
    end
    local now = os.clock()

    -- arm only once the UI has finished sliding in: red line on screen and not moving
    local onScreen = ry > 0 and ry < VPH and rx > 0 and rx < VPW
    if not onScreen or (pl.lastLineY and math.abs(line - pl.lastLineY) > 1.5) then
        pl.stableSince = nil
        pl.hist = {}
    elseif not pl.stableSince then
        pl.stableSince = now
    end
    pl.lastLineY = line
    if not pl.stableSince or now - pl.stableSince < pl.SETTLE then
        dbg("plw", string.format("[pl] waiting for UI to settle (line y=%.0f)", line), 0.5)
        return
    end

    local pins = {}
    for _, p in ipairs(pick:GetChildren()) do
        if p.Name ~= "RedLine" then
            local x, y, w, h = rect(p)
            if x then
                local key = p
                local h_ = pl.hist[key]
                if not h_ then h_ = {}; pl.hist[key] = h_ end
                h_[#h_ + 1] = { t = now, y = y + h / 2 }
                while #h_ > 40 do table.remove(h_, 1) end
                pins[#pins + 1] = { inst = p, x = x, y = y + h / 2, h = h_ }
            end
        end
    end
    table.sort(pins, function(a, b) return a.x < b.x end)

    -- after a click, give the pin time to stop before aiming at the next one
    if now - pl.lastClick < pl.COOLDOWN then return end

    for _, p in ipairs(pins) do
        local v = velocity(p.h)
        local moving = math.abs(v) * pl.WINDOW > pl.STOP and math.abs(v) < pl.MAX_SPEED
        if moving and #p.h >= 3 then
            local d = p.y - line
            local pred = p.y + v * pl.LEAD
            if d * (pred - line) <= 0 or math.abs(d) <= pl.TOL then
                mouse1click()
                pl.lastClick = now
                print(string.format("[lockpick] CLICK d=%.1f v=%.0f pinY=%.1f line=%.1f", d, v, p.y, line))
            end
            return   -- only ever aim at the leftmost moving pin
        end
    end
end

------------------------------------------------------------------ ATM
local atm = { lastClick = 0, COOLDOWN = 0.30 }
local function stepATM(root)
    local hack = root:FindFirstChild("Hacking"); if not hack then return end
    local cycle = hack:FindFirstChild("CycleFrame")
    local sel = hack:FindFirstChild("SelectingCode")
    if not (cycle and sel) then return end
    local target = textOf(sel)
    if not target or target == "" then return end
    if os.clock() - atm.lastClick < atm.COOLDOWN then return end
    for _, list in ipairs(cycle:GetChildren()) do
        if list.ClassName == "Frame" then
            for _, lbl in ipairs(list:GetChildren()) do
                if lbl.ClassName == "TextLabel" and isBlack(lbl) and textOf(lbl) == target then
                    mouse1click()
                    atm.lastClick = os.clock()
                    return
                end
            end
        end
    end
end

------------------------------------------------------------------ car (crowbar)
local car = { lastClick = 0, COOLDOWN = 0.20 }
local function stepCar(root)
    local main = root:FindFirstChild("Main"); if not main then return end
    local g = main:FindFirstChild("Game"); if not g then return end
    local ind, tgt = g:FindFirstChild("Indicator"), g:FindFirstChild("Target")
    if not (ind and tgt) then return end
    local ix = rect(ind)
    local tx, _, tw = rect(tgt)
    if ix and tx and ix >= tx and ix <= tx + tw and os.clock() - car.lastClick > car.COOLDOWN then
        mouse1click()
        car.lastClick = os.clock()
    end
end

------------------------------------------------------------------ jewelry
-- The green box orbits a circle at a constant angular speed (~45 deg/s, measured from video).
-- So: fit a circle to the box's recent positions, measure its angular speed, and aim
-- JEWEL_LEAD seconds ahead ALONG THE CIRCLE. This ignores per-frame noise.
-- JEWEL_LEAD covers read->cursor latency: raise if the cursor trails the box, lower if it runs ahead.
local JEWEL_LEAD = 0.01          -- measured from video: cursor latency is ~10ms
-- Measured from video: the cursor sat ~37% of a box-height ABOVE the box centre (the position read from
-- memory doesn't include Roblox's top-bar inset). Correction = JEWEL_Y_FRAC * box height, so it scales
-- with your window. If the cursor is still above the centre raise it; below, lower it. 0 = off.
local JEWEL_Y_FRAC = 0.37
local JEWEL_USE_MODEL = false -- false = put the cursor exactly on the box centre every frame (simple, steady)
                              -- true  = circle-fit prediction (experimental)
local JEWEL_DEADZONE = 1   -- px: ignore cursor moves smaller than this (stops micro-twitching)
local JEWEL_HIST = 2.5          -- seconds of positions used for the circle fit
local jw = { h = {}, fitAt = 0, cx = nil, cy = nil, R = nil, omega = 0 }
local vpW, vpH = 1920, 1080
do
    local ok, vp = pcall(function() return workspace.CurrentCamera.ViewportSize end)
    if ok and vp then vpW, vpH = vp.X, vp.Y end
end

local function fitCircle(h)
    -- Kasa fit: x^2+y^2 + D*x + E*y + F = 0 (normal equations, centered for stability)
    local n, mx, my = #h, 0, 0
    for i = 1, n do mx = mx + h[i].x; my = my + h[i].y end
    mx, my = mx / n, my / n
    local suu, suv, svv, suuu, svvv, suvv, svuu = 0, 0, 0, 0, 0, 0, 0
    for i = 1, n do
        local u, v = h[i].x - mx, h[i].y - my
        suu = suu + u * u; suv = suv + u * v; svv = svv + v * v
        suuu = suuu + u * u * u; svvv = svvv + v * v * v
        suvv = suvv + u * v * v; svuu = svuu + v * u * u
    end
    local det = suu * svv - suv * suv
    if math.abs(det) < 1e-6 then return nil end
    local b1, b2 = 0.5 * (suuu + suvv), 0.5 * (svvv + svuu)
    local uc = (b1 * svv - b2 * suv) / det
    local vc = (suu * b2 - suv * b1) / det
    local R = math.sqrt(uc * uc + vc * vc + (suu + svv) / n)
    return mx + uc, my + vc, R
end

local function refit(now)
    local h = jw.h
    if #h < 12 or h[#h].t - h[1].t < 0.5 then return end
    local cx, cy, R = fitCircle(h)
    if not cx or R < 40 or R > 900 then return end
    -- angle(t) = a0 + omega*(t - t0), regression over the last 1s (unwrapped angles)
    local t0 = h[#h].t - 1.0
    if t0 < h[1].t then t0 = h[1].t end
    local prev, sx, sy, sxx, sxy, n = nil, 0, 0, 0, 0, 0
    for i = 1, #h do
        local a = math.atan2(h[i].y - cy, h[i].x - cx)
        if prev then
            while a - prev > math.pi do a = a - 2 * math.pi end
            while a - prev < -math.pi do a = a + 2 * math.pi end
        end
        prev = a
        if h[i].t >= t0 then
            local tt = h[i].t - t0
            sx = sx + tt; sy = sy + a; sxx = sxx + tt * tt; sxy = sxy + tt * a; n = n + 1
        end
    end
    local d = n * sxx - sx * sx
    if n < 8 or math.abs(d) < 1e-9 then return end
    -- need enough arc for a trustworthy circle (a short arc gives a wild centre/radius)
    local first = math.atan2(h[1].y - cy, h[1].x - cx)
    local arc = math.abs((prev or first) - first)
    if arc < 1.4 then jw.cx = nil return end
    local omega = (n * sxy - sx * sy) / d
    local a0 = (sy - omega * sx) / n
    jw.cx, jw.cy, jw.R = cx, cy, R
    jw.omega, jw.a0, jw.t0 = omega, a0, t0
    jw.fitAt = now
end

local function stepJewelry(root)
    local box = root:FindFirstChild("GreenBox"); if not box then return end
    local x, y, w, h = rect(box); if not x then return end
    local now = os.clock()
    local cx, cy = x + w / 2, y + h / 2
    local hist = jw.h
    hist[#hist + 1] = { t = now, x = cx, y = cy }
    while #hist > 0 and now - hist[1].t > JEWEL_HIST do table.remove(hist, 1) end
    if JEWEL_USE_MODEL and now - jw.fitAt > 0.1 then refit(now) end

    -- aim from the fitted time model (smooth), not from the latest raw sample (steppy)
    local mx, my = cx, cy
    if JEWEL_USE_MODEL and jw.cx and now - jw.fitAt < 0.5 then
        local a = jw.a0 + jw.omega * (now + JEWEL_LEAD - jw.t0)
        local px, py = jw.cx + jw.R * math.cos(a), jw.cy + jw.R * math.sin(a)
        -- safety net: the model may only differ from the real box by ~0.3 box heights.
        -- A bad/early circle fit lands far away, so then we just follow the real box.
        if (px - cx) ^ 2 + (py - cy) ^ 2 <= (0.3 * h) ^ 2 then
            -- glide from the raw box position to the model over 0.4s so there is no jump
            if not jw.mStart then jw.mStart = now end
            local k = math.min(1, (now - jw.mStart) / 0.4)
            mx, my = cx + (px - cx) * k, cy + (py - cy) * k
        else
            jw.mStart = nil
        end
    else
        jw.mStart = nil
    end
    dbg("jw", string.format("[jw] box w=%.0f h=%.0f | R=%.0f omega=%.1f deg/s | yfix=%.0fpx", w, h, jw.R or 0,
        math.deg(jw.omega), JEWEL_Y_FRAC * h), 0.5)
    my = my + JEWEL_Y_FRAC * h
    if mx > 0 and my > 0 and mx < vpW and my < vpH then
        mx, my = math.floor(mx + 0.5), math.floor(my + 0.5)
        -- dead zone: skip moves smaller than ~1px so the cursor never twitches
        if not jw.sx or math.abs(mx - jw.sx) + math.abs(my - jw.sy) >= JEWEL_DEADZONE then
            jw.sx, jw.sy = mx, my
            mousemoveabs(mx + MOUSE_OFFSET_X, my + MOUSE_OFFSET_Y)
        end
    end
end

-- tight loop: runs only the jewelry step every frame until the minigame closes
local function jewelryFast(root)
    jw.h, jw.fitAt, jw.cx, jw.omega, jw.sx, jw.mStart = {}, 0, nil, 0, nil, nil
    while root.Parent and isVisible(root) do
        pcall(stepJewelry, root)
        task.wait()
    end
end

------------------------------------------------------------------ ECU (number capture)
local ecu = { acc = "", last = "", count = 0, PER_LINE = 6 }
local function stepECU(root)
    local node = root
    for _, n in ipairs({ "Background", "ScreenBase", "ScreenUIBase", "MainScreen", "CurrentNumber", "Number" }) do
        node = node and node:FindFirstChild(n)
    end
    if not node then return end
    local txt = textOf(node) or ""
    if txt ~= "" and txt ~= ecu.last then
        ecu.last = txt
        ecu.acc = ecu.acc .. (ecu.count > 0 and " " or "") .. txt
        ecu.count = ecu.count + 1
        if ecu.count >= ecu.PER_LINE then
            notify(ecu.acc); print("[ECU] " .. ecu.acc)
            ecu.acc, ecu.count = "", 0
        end
    elseif txt == "" then
        ecu.last = ""
    end
end

------------------------------------------------------------------ safe (stub)
local function stepSafe(root)
    local top2 = root:FindFirstChild("Top2")
    local num = top2 and top2:FindFirstChild("TargetNum")
    if num then dbg("safe", "[safe] TargetNum text: " .. tostring(textOf(num))) end
end

------------------------------------------------------------------ registry + loop
local minigames = {
    { name = "Jewelry", ui = "GlassCutting", step = stepJewelry, fast = jewelryFast },
    { name = "Lockpick", ui = "Lockpick", step = stepLockpick, reset = plReset },
    { name = "ATM", ui = "ATM", step = stepATM },
    { name = "ECU", label = "ECU", ui = "NumbersHack", step = stepECU,
      reset = function() ecu.acc, ecu.last, ecu.count = "", "", 0 end },
    { name = "Car", label = "Car (crowbar)", ui = "Crowbar", step = stepCar },
    { name = "Safe", ui = "Safe", step = stepSafe },
}

print("[dbg] ERLC memory solver v3 started | build: notify-rchl")
notify("ERLC autorob patched by rchl")
print("[dbg] startup notification sent")
local active, lastErr, sanityDone = nil, "", false
local lastDetect = {}

while true do
    if not (menus and menus.Parent) then
        if not acquireMenus() then
            dbg("menus", "GameMenus not found, retrying")
            task.wait(1)
        else
            print("[dbg] GameMenus acquired")
            sanityDone = false
        end
    end
    if menus and menus.Parent then
        if not sanityDone then sanity(); sanityDone = true end
        local current = nil
        for _, g in ipairs(minigames) do
            local root = menus:FindFirstChild(g.ui)
            if root and isVisible(root) then
                current = g
                if active ~= g and g.reset then g.reset() end
                local ok, err
                if g.fast then ok, err = pcall(g.fast, root) else ok, err = pcall(g.step, root) end
                if not ok and tostring(err) ~= lastErr then
                    lastErr = tostring(err)
                    print("[" .. g.name .. "] ERROR " .. lastErr)
                end
                break
            end
        end
        if active ~= current then
            print("[dbg] active minigame: " .. (current and current.name or "none"))
            if current then
                -- one notification per detection; the 2s guard stops a flickering UI from spamming
                local now = os.clock()
                if now - (lastDetect[current.name] or -10) > 2 then
                    notify((current.label or current.name) .. " detected")
                end
                lastDetect[current.name] = now
            end
        end
        active = current
        dbg("beat", "beat active=" .. (current and current.name or "none"), 3)
    end
    task.wait()
end
