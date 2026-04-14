-- vanadium voidspam + desync
-- localscript → starterplayerscripts

local repo         = 'https://raw.githubusercontent.com/mstudio45/LinoriaLib/main/'
local Library      = loadstring(game:HttpGet(repo .. 'Library.lua'))()
local ThemeManager = loadstring(game:HttpGet(repo .. 'addons/ThemeManager.lua'))()
local SaveManager  = loadstring(game:HttpGet(repo .. 'addons/SaveManager.lua'))()

Library.ShowToggleFrameInKeybinds = true

local Players    = game:GetService('Players')
local RunService = game:GetService('RunService')
local UIS        = game:GetService('UserInputService')
local player     = Players.LocalPlayer

local cfg = {
    interval      = 0.05,
    rangeMin      = -10000,
    rangeMax      =  10000,
    yMin          = -10000,
    yMax          =  10000,
    tpCount       = 7,
    nearEnabled   = false,
    nearDuration  = 3,
    voidDuration  = 2,
    offsetX       = 2,
    offsetY       = 0,
    offsetZ       = 0,
    clickEnabled  = false,
    clickInterval = 0.1,
    clickOffset   = 0,
    -- desync
    desyncMode        = 'main',
    desyncTpCount     = 10,
    desyncVoidX       = 0,
    desyncVoidY       = -999999,
    desyncVoidZ       = 0,
    desyncNearOffsetX = 2,
    desyncNearOffsetY = 0,
    desyncNearOffsetZ = 0,
    desyncMoveSpeed   = 16,
}

local enabled      = false
local loopRunning  = false
local lockedTarget = nil

local character, hrp, humanoid

local function grabChar(char)
    character = char
    hrp       = char:WaitForChild('HumanoidRootPart')
    humanoid  = char:WaitForChild('Humanoid')
end
grabChar(player.Character or player.CharacterAdded:Wait())
player.CharacterAdded:Connect(grabChar)

-- ─── voidspam helpers ────────────────────────────────────────────────────────
local function randInRange()
    return cfg.rangeMin + math.random() * (cfg.rangeMax - cfg.rangeMin)
end
local function randY()
    return cfg.yMin + math.random() * (cfg.yMax - cfg.yMin)
end
local function tpRandom()
    if not hrp or not humanoid or humanoid.Health <= 0 then return end
    for _ = 1, cfg.tpCount do
        hrp.CFrame = CFrame.new(randInRange(), randY(), randInRange())
    end
end
local function targetDead()
    if not lockedTarget then return true end
    if not lockedTarget.Parent then return true end
    local tc  = lockedTarget.Parent
    local th  = tc and tc:FindFirstChildOfClass('Humanoid')
    if not th or th.Health <= 0 then return true end
    return false
end
local function getNearestRoot(fromPos)
    local pos = fromPos or (hrp and hrp.Position)
    if not pos then return nil end
    local best, bestDist = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player then
            local c2 = p.Character
            local r2 = c2 and c2:FindFirstChild('HumanoidRootPart')
            if r2 then
                local d = (r2.Position - pos).Magnitude
                if d < bestDist then bestDist = d; best = r2 end
            end
        end
    end
    return best
end
local function tpToNearest()
    if not hrp or not humanoid or humanoid.Health <= 0 then return end
    if targetDead() then lockedTarget = nil end
    if not lockedTarget then lockedTarget = getNearestRoot() end
    if lockedTarget then
        for _ = 1, cfg.tpCount do
            hrp.CFrame = lockedTarget.CFrame * CFrame.new(cfg.offsetX, cfg.offsetY, cfg.offsetZ)
        end
    else
        tpRandom()
    end
end
local function doClick()
    if mouse1click then
        mouse1click()
    elseif game:GetService('VirtualInputManager') then
        local vim = game:GetService('VirtualInputManager')
        vim:SendMouseButtonEvent(0,0,0,true,game,1)
        vim:SendMouseButtonEvent(0,0,0,false,game,1)
    end
end
local function waitFor(seconds)
    if seconds <= 0 then task.wait(); return end
    local t0 = tick()
    repeat task.wait()
    until not (loopRunning and enabled) or (tick()-t0) >= seconds
end
local function startLoop()
    if loopRunning then return end
    loopRunning = true
    task.spawn(function()
        while loopRunning and enabled do
            if cfg.nearEnabled then
                local followEnd = tick() + cfg.nearDuration
                repeat
                    if cfg.clickEnabled and cfg.clickOffset > 0 then
                        task.delay(math.max(0, cfg.interval - cfg.clickOffset), function()
                            if loopRunning and enabled and cfg.clickEnabled then doClick() end
                        end)
                    end
                    tpToNearest()
                    if cfg.clickEnabled and cfg.clickOffset <= 0 then doClick() end
                    waitFor(cfg.interval)
                until not (loopRunning and enabled) or tick() >= followEnd
                if not (loopRunning and enabled) then break end
                local voidEnd = tick() + cfg.voidDuration
                repeat tpRandom(); waitFor(cfg.interval)
                until not (loopRunning and enabled) or tick() >= voidEnd
            else
                tpRandom()
                waitFor(cfg.interval)
            end
        end
        loopRunning = false
    end)
end
local function stopLoop()
    loopRunning  = false
    enabled      = false
    lockedTarget = nil
end

-- ═══════════════════════════════════════════════════════════════════════════
--  DESYNC SYSTEM
--
--  Key fix vs previous version:
--  ► player.Character is NEVER changed.
--    The real character keeps full network ownership so every CFrame write
--    to realHRP replicates to the server — friends see it in the void / on
--    the target instantly.
--
--  ► A non-colliding invisible puppet part is spawned locally.
--    The camera CameraSubject is pointed at the puppet.
--    WASD / Space are intercepted and drive the puppet manually.
--    The real character stays server-side at the desync position.
-- ═══════════════════════════════════════════════════════════════════════════

local desyncEnabled    = false
local desyncConn       = nil   -- Heartbeat: force real HRP server-side
local camConn          = nil   -- RenderStepped: puppet movement + camera
local fakeModel        = nil
local fakePart         = nil
local desyncNearTarget = nil
local savedCamSubject  = nil
local savedCamType     = nil

local keysDown = {}
UIS.InputBegan:Connect(function(i, gp)
    if not gp then keysDown[i.KeyCode] = true end
end)
UIS.InputEnded:Connect(function(i)
    keysDown[i.KeyCode] = nil
end)
local KC = Enum.KeyCode

local function cleanupDesync()
    if camConn    then camConn:Disconnect();    camConn    = nil end
    if desyncConn then desyncConn:Disconnect(); desyncConn = nil end

    local cam = workspace.CurrentCamera
    if cam then
        if savedCamSubject then cam.CameraSubject = savedCamSubject; savedCamSubject = nil end
        if savedCamType    then cam.CameraType    = savedCamType;    savedCamType    = nil end
    end

    if fakeModel then pcall(function() fakeModel:Destroy() end); fakeModel = nil; fakePart = nil end
    desyncNearTarget = nil
    desyncEnabled    = false
end

local function startDesync()
    if desyncEnabled then return end
    if not hrp then return end
    desyncEnabled = true

    -- build invisible puppet
    local model     = Instance.new('Model'); model.Name = 'DesyncPuppet'
    local root      = Instance.new('Part');  root.Name  = 'HumanoidRootPart'
    root.Size        = Vector3.new(2,2,1)
    root.CFrame      = hrp.CFrame
    root.Anchored    = false
    root.CanCollide  = false
    root.Transparency= 1
    root.CastShadow  = false
    root.Parent      = model
    local hum        = Instance.new('Humanoid'); hum.WalkSpeed = 0; hum.JumpHeight = 0; hum.Parent = model
    model.PrimaryPart= root
    model.Parent     = workspace
    fakeModel        = model
    fakePart         = root

    -- redirect camera to puppet
    local cam        = workspace.CurrentCamera
    savedCamSubject  = cam.CameraSubject
    savedCamType     = cam.CameraType
    cam.CameraSubject= root

    -- puppet physics state
    local velY       = 0
    local grounded   = true
    local floorY     = root.CFrame.Y
    local facing     = root.CFrame

    -- RenderStepped: drive puppet with WASD
    camConn = RunService.RenderStepped:Connect(function(dt)
        if not desyncEnabled or not fakePart then return end

        local camCF  = workspace.CurrentCamera.CFrame
        local fwd    = Vector3.new(camCF.LookVector.X, 0, camCF.LookVector.Z)
        local rgt    = Vector3.new(camCF.RightVector.X, 0, camCF.RightVector.Z)
        if fwd.Magnitude > 0 then fwd = fwd.Unit end
        if rgt.Magnitude > 0 then rgt = rgt.Unit end

        local dir = Vector3.zero
        if keysDown[KC.W] or keysDown[KC.Up]    then dir = dir + fwd end
        if keysDown[KC.S] or keysDown[KC.Down]  then dir = dir - fwd end
        if keysDown[KC.D] or keysDown[KC.Right] then dir = dir + rgt end
        if keysDown[KC.A] or keysDown[KC.Left]  then dir = dir - rgt end
        if dir.Magnitude > 0 then dir = dir.Unit end

        if keysDown[KC.Space] and grounded then
            velY     = 50
            grounded = false
        end
        velY = velY - 196 * dt

        local cur  = fakePart.Position
        local newP = cur + Vector3.new(dir.X * cfg.desyncMoveSpeed, velY, dir.Z * cfg.desyncMoveSpeed) * dt

        if newP.Y <= floorY and velY < 0 then
            newP     = Vector3.new(newP.X, floorY, newP.Z)
            velY     = 0
            grounded = true
        end

        if dir.Magnitude > 0 then
            facing = CFrame.new(newP, newP + dir)
        else
            local _, fy, _ = facing:ToEulerAnglesYXZ()
            facing = CFrame.new(newP) * CFrame.Angles(0, fy, 0)
        end
        fakePart.CFrame = facing
    end)

    -- Heartbeat: force real HRP server-side (replicates because player.Character unchanged)
    desyncConn = RunService.Heartbeat:Connect(function()
        if not desyncEnabled then return end
        local realHRP = character and character:FindFirstChild('HumanoidRootPart')
        if not realHRP then return end

        if cfg.desyncMode == 'near' then
            if not desyncNearTarget or not desyncNearTarget.Parent then
                desyncNearTarget = getNearestRoot(fakePart and fakePart.Position)
            end
            local targetCF
            if desyncNearTarget then
                targetCF = desyncNearTarget.CFrame
                         * CFrame.new(cfg.desyncNearOffsetX, cfg.desyncNearOffsetY, cfg.desyncNearOffsetZ)
            else
                targetCF = CFrame.new(cfg.desyncVoidX, cfg.desyncVoidY, cfg.desyncVoidZ)
            end
            for _ = 1, cfg.desyncTpCount do realHRP.CFrame = targetCF end
        else
            local voidCF = CFrame.new(cfg.desyncVoidX, cfg.desyncVoidY, cfg.desyncVoidZ)
            for _ = 1, cfg.desyncTpCount do realHRP.CFrame = voidCF end
        end
    end)
end

local function stopDesync()
    if not desyncEnabled then return end
    -- snap real char back to puppet position before cleaning up
    local realHRP = character and character:FindFirstChild('HumanoidRootPart')
    if realHRP and fakePart then realHRP.CFrame = fakePart.CFrame end
    cleanupDesync()
end

-- ─────────────────────────────────────────────────────────────────────────
--  WINDOW
-- ─────────────────────────────────────────────────────────────────────────
local Window = Library:CreateWindow({
    Title        = 'vanadium voidspam',
    Center       = true,
    AutoShow     = true,
    TabPadding   = 8,
    MenuFadeTime = 0.2,
})

local Tabs = {
    Main            = Window:AddTab('main'),
    Near            = Window:AddTab('near player'),
    Desync          = Window:AddTab('desync'),
    ['UI Settings'] = Window:AddTab('settings'),
}

local Options = Library.Options
local Toggles = Library.Toggles

-- ─────────────────────────────────────
--  tab: main
-- ─────────────────────────────────────
local BoxMain = Tabs.Main:AddLeftGroupbox('void spam')

BoxMain:AddToggle('GhostEnabled', {
    Text    = 'enable voidspam',
    Default = false,
    Tooltip = 'teleports your character to random positions in the set range',
    Callback = function(val)
        enabled = val
        if val then startLoop() else stopLoop() end
    end,
})

BoxMain:AddDivider()
BoxMain:AddLabel('interval')

BoxMain:AddSlider('Interval', {
    Text = 'interval (s)  —  0 = every frame', Default = 2, Min = 0, Max = 60, Rounding = 2,
    Callback = function(val) cfg.interval = val end,
})
BoxMain:AddInput('IntervalText', {
    Text = 'interval manual (enter to apply)', Default = '2',
    Numeric = true, Finished = true, ClearTextOnFocus = false,
    Callback = function(val)
        local n = tonumber(val); if not n then return end
        cfg.interval = math.max(0, n)
        task.defer(function() if Options.Interval then Options.Interval:SetValue(math.min(cfg.interval,60)) end end)
    end,
})

BoxMain:AddDivider()
BoxMain:AddLabel('tps per tick')

BoxMain:AddSlider('TpCount', {
    Text = 'tps per interval', Default = 7, Min = 1, Max = 100, Rounding = 0,
    Callback = function(val) cfg.tpCount = val end,
})
BoxMain:AddInput('TpCountText', {
    Text = 'tps per tick manual (enter)', Default = '7', Numeric = true,
    Finished = true, ClearTextOnFocus = false, Placeholder = 'e.g. 20',
    Callback = function(val)
        local n = tonumber(val); if not n then return end
        cfg.tpCount = math.max(1, math.floor(n))
        task.defer(function() if Options.TpCount then Options.TpCount:SetValue(math.clamp(cfg.tpCount,1,100)) end end)
    end,
})

BoxMain:AddDivider()
BoxMain:AddLabel('teleport range (x / z)')

BoxMain:AddSlider('RangeMin', {
    Text = 'range min', Default = -10000, Min = -999999, Max = 0, Rounding = 0,
    Callback = function(val) cfg.rangeMin = math.min(val, cfg.rangeMax-1) end,
})
BoxMain:AddInput('RangeMinText', {
    Text = 'range min manual', Default = '-10000', Numeric = true, Finished = true, ClearTextOnFocus = false,
    Callback = function(val)
        local n = tonumber(val); if not n then return end
        cfg.rangeMin = math.floor(math.min(n, cfg.rangeMax-1))
        task.defer(function() if Options.RangeMin then Options.RangeMin:SetValue(math.clamp(cfg.rangeMin,-999999,0)) end end)
    end,
})
BoxMain:AddSlider('RangeMax', {
    Text = 'range max', Default = 10000, Min = 0, Max = 999999, Rounding = 0,
    Callback = function(val) cfg.rangeMax = math.max(val, cfg.rangeMin+1) end,
})
BoxMain:AddInput('RangeMaxText', {
    Text = 'range max manual', Default = '10000', Numeric = true, Finished = true, ClearTextOnFocus = false,
    Callback = function(val)
        local n = tonumber(val); if not n then return end
        cfg.rangeMax = math.floor(math.max(n, cfg.rangeMin+1))
        task.defer(function() if Options.RangeMax then Options.RangeMax:SetValue(math.clamp(cfg.rangeMax,0,999999)) end end)
    end,
})

BoxMain:AddDivider()
BoxMain:AddLabel('y axis range')

BoxMain:AddSlider('YMin', {
    Text = 'y min', Default = -10000, Min = -999999, Max = 0, Rounding = 0,
    Callback = function(val) cfg.yMin = math.min(val, cfg.yMax-1) end,
})
BoxMain:AddInput('YMinText', {
    Text = 'y min manual', Default = '-10000', Numeric = true, Finished = true,
    ClearTextOnFocus = false, Placeholder = 'e.g. -500',
    Callback = function(val)
        local n = tonumber(val); if not n then return end
        cfg.yMin = math.floor(math.min(n, cfg.yMax-1))
        task.defer(function() if Options.YMin then Options.YMin:SetValue(math.clamp(cfg.yMin,-999999,0)) end end)
    end,
})
BoxMain:AddSlider('YMax', {
    Text = 'y max', Default = 10000, Min = 0, Max = 999999, Rounding = 0,
    Callback = function(val) cfg.yMax = math.max(val, cfg.yMin+1) end,
})
BoxMain:AddInput('YMaxText', {
    Text = 'y max manual', Default = '10000', Numeric = true, Finished = true,
    ClearTextOnFocus = false, Placeholder = 'e.g. 500',
    Callback = function(val)
        local n = tonumber(val); if not n then return end
        cfg.yMax = math.floor(math.max(n, cfg.yMin+1))
        task.defer(function() if Options.YMax then Options.YMax:SetValue(math.clamp(cfg.yMax,0,999999)) end end)
    end,
})

-- ─────────────────────────────────────
--  tab: near player
-- ─────────────────────────────────────
local BoxNear = Tabs.Near:AddLeftGroupbox('nearest player mode')

BoxNear:AddToggle('NearEnabled', {
    Text    = 'enable near-player mode',
    Default = false,
    Tooltip = 'alternates between tping on the nearest player and tping to void',
    Callback = function(val)
        cfg.nearEnabled = val
        if enabled then loopRunning = false; task.wait(0.06); startLoop() end
    end,
})

local DepNear = BoxNear:AddDependencyBox()

DepNear:AddSlider('NearDuration', {
    Text = 'stay near player (s)', Default = 3, Min = 0, Max = 60, Rounding = 2,
    Tooltip = '0 = instantly switch to void phase',
    Callback = function(val) cfg.nearDuration = val end,
})
DepNear:AddInput('NearDurationText', {
    Text = 'near duration manual', Default = '3', Numeric = true, Finished = true, ClearTextOnFocus = false,
    Callback = function(val)
        local n = tonumber(val); if not n then return end
        cfg.nearDuration = math.max(0,n)
        task.defer(function() if Options.NearDuration then Options.NearDuration:SetValue(math.min(cfg.nearDuration,60)) end end)
    end,
})
DepNear:AddSlider('VoidDuration', {
    Text = 'stay in void (s)', Default = 2, Min = 0, Max = 60, Rounding = 2,
    Callback = function(val) cfg.voidDuration = val end,
})
DepNear:AddInput('VoidDurationText', {
    Text = 'void duration manual', Default = '2', Numeric = true, Finished = true, ClearTextOnFocus = false,
    Callback = function(val)
        local n = tonumber(val); if not n then return end
        cfg.voidDuration = math.max(0,n)
        task.defer(function() if Options.VoidDuration then Options.VoidDuration:SetValue(math.min(cfg.voidDuration,60)) end end)
    end,
})

DepNear:AddDivider()
DepNear:AddLabel('position offset (target space)')

DepNear:AddSlider('OffsetX', {Text='offset x (left / right)',Default=2,Min=-50,Max=50,Rounding=1,Callback=function(v) cfg.offsetX=v end})
DepNear:AddInput('OffsetXText',{Text='offset x manual',Default='2',Numeric=true,Finished=true,ClearTextOnFocus=false,Placeholder='e.g. -2.5',
    Callback=function(v) local n=tonumber(v);if not n then return end;cfg.offsetX=n;task.defer(function() if Options.OffsetX then Options.OffsetX:SetValue(math.clamp(n,-50,50)) end end) end})
DepNear:AddSlider('OffsetY', {Text='offset y (up / down)',Default=0,Min=-50,Max=50,Rounding=1,Callback=function(v) cfg.offsetY=v end})
DepNear:AddInput('OffsetYText',{Text='offset y manual',Default='0',Numeric=true,Finished=true,ClearTextOnFocus=false,Placeholder='e.g. 2',
    Callback=function(v) local n=tonumber(v);if not n then return end;cfg.offsetY=n;task.defer(function() if Options.OffsetY then Options.OffsetY:SetValue(math.clamp(n,-50,50)) end end) end})
DepNear:AddSlider('OffsetZ', {Text='offset z (behind / ahead)',Default=0,Min=-50,Max=50,Rounding=1,Callback=function(v) cfg.offsetZ=v end})
DepNear:AddInput('OffsetZText',{Text='offset z manual',Default='0',Numeric=true,Finished=true,ClearTextOnFocus=false,Placeholder='e.g. 3',
    Callback=function(v) local n=tonumber(v);if not n then return end;cfg.offsetZ=n;task.defer(function() if Options.OffsetZ then Options.OffsetZ:SetValue(math.clamp(n,-50,50)) end end) end})

DepNear:AddDivider()
DepNear:AddLabel('clicker')

DepNear:AddToggle('ClickEnabled', {Text='enable clicker',Default=false,
    Tooltip='fires a mouse1click each tp during near player phase',
    Callback=function(v) cfg.clickEnabled=v end})
DepNear:AddSlider('ClickOffset', {Text='click offset (s before tp)',Default=0,Min=0,Max=2,Rounding=2,
    Callback=function(v) cfg.clickOffset=v end})
DepNear:AddInput('ClickOffsetText',{Text='click offset manual',Default='0',Numeric=true,Finished=true,ClearTextOnFocus=false,Placeholder='e.g. 0.05',
    Callback=function(v) local n=tonumber(v);if not n then return end;cfg.clickOffset=math.max(0,n)
        task.defer(function() if Options.ClickOffset then Options.ClickOffset:SetValue(math.min(cfg.clickOffset,2)) end end) end})

task.defer(function()
    DepNear:SetupDependencies({{ Toggles.NearEnabled, true }})
end)

local BoxNearInfo = Tabs.Near:AddRightGroupbox('how it works')
BoxNearInfo:AddLabel('loop when enabled:')
BoxNearInfo:AddLabel('')
BoxNearInfo:AddLabel('① tp onto nearest player')
BoxNearInfo:AddLabel('   at x/y/z offset')
BoxNearInfo:AddLabel('   wait "near" seconds')
BoxNearInfo:AddLabel('')
BoxNearInfo:AddLabel('② tp to random void pos')
BoxNearInfo:AddLabel('   wait "void" seconds')
BoxNearInfo:AddLabel('')
BoxNearInfo:AddLabel('③ repeat')
BoxNearInfo:AddLabel('')
BoxNearInfo:AddLabel('x = left / right')
BoxNearInfo:AddLabel('y = up / down')
BoxNearInfo:AddLabel('z = behind / ahead')
BoxNearInfo:AddLabel('')
BoxNearInfo:AddLabel('no nearby players?')
BoxNearInfo:AddLabel('falls back to random tp.')

-- ─────────────────────────────────────
--  tab: desync
-- ─────────────────────────────────────
local BoxDesyncMain = Tabs.Desync:AddLeftGroupbox('desync main')

BoxDesyncMain:AddToggle('DesyncEnabled', {
    Text    = 'enable desync',
    Default = false,
    Tooltip = 'puppet gets camera + WASD. server sees real char at desync position.',
    Callback = function(val)
        if val then startDesync() else stopDesync() end
    end,
})

BoxDesyncMain:AddDivider()
BoxDesyncMain:AddLabel('mode')

BoxDesyncMain:AddDropdown('DesyncMode', {
    Text    = 'desync mode',
    Default = 'main',
    Values  = { 'main', 'near' },
    Tooltip = 'main = real char frozen in void  |  near = real char on nearest player',
    Callback = function(val)
        cfg.desyncMode   = val
        desyncNearTarget = nil
    end,
})

BoxDesyncMain:AddDivider()
BoxDesyncMain:AddLabel('server-side force')

BoxDesyncMain:AddSlider('DesyncTpCount', {
    Text     = 'force tps per heartbeat',
    Default  = 10, Min = 1, Max = 100, Rounding = 0,
    Tooltip  = 'higher = harder for server to correct position',
    Callback = function(val) cfg.desyncTpCount = val end,
})

BoxDesyncMain:AddDivider()
BoxDesyncMain:AddLabel('puppet speed')

BoxDesyncMain:AddSlider('DesyncMoveSpeed', {
    Text     = 'puppet walk speed',
    Default  = 16, Min = 1, Max = 200, Rounding = 0,
    Tooltip  = 'WASD speed of the fake puppet you control locally',
    Callback = function(val) cfg.desyncMoveSpeed = val end,
})

BoxDesyncMain:AddDivider()
BoxDesyncMain:AddLabel('void position (main mode)')

BoxDesyncMain:AddInput('DesyncVoidY', {
    Text = 'void y  (default -999999)', Default = '-999999',
    Numeric = true, Finished = true, ClearTextOnFocus = false,
    Tooltip = 'y coord server sees your real char at',
    Callback = function(v) local n=tonumber(v);if n then cfg.desyncVoidY=n end end,
})
BoxDesyncMain:AddInput('DesyncVoidX', {
    Text = 'void x  (default 0)', Default = '0',
    Numeric = true, Finished = true, ClearTextOnFocus = false,
    Callback = function(v) local n=tonumber(v);if n then cfg.desyncVoidX=n end end,
})
BoxDesyncMain:AddInput('DesyncVoidZ', {
    Text = 'void z  (default 0)', Default = '0',
    Numeric = true, Finished = true, ClearTextOnFocus = false,
    Callback = function(v) local n=tonumber(v);if n then cfg.desyncVoidZ=n end end,
})

-- ─────────────────────────────────────
--  desync: near player (right groupbox)
-- ─────────────────────────────────────
local BoxDesyncNear = Tabs.Desync:AddRightGroupbox('desync near player')

BoxDesyncNear:AddLabel('used when mode = "near"')
BoxDesyncNear:AddLabel('server sees you locked onto')
BoxDesyncNear:AddLabel('the nearest player.')
BoxDesyncNear:AddLabel('puppet moves freely.')
BoxDesyncNear:AddDivider()
BoxDesyncNear:AddLabel('offset from target')

BoxDesyncNear:AddSlider('DesyncNearOffsetX',{Text='offset x',Default=2,Min=-50,Max=50,Rounding=1,Callback=function(v) cfg.desyncNearOffsetX=v end})
BoxDesyncNear:AddInput('DesyncNearOffsetXText',{Text='offset x manual',Default='2',Numeric=true,Finished=true,ClearTextOnFocus=false,
    Callback=function(v) local n=tonumber(v);if not n then return end;cfg.desyncNearOffsetX=n
        task.defer(function() if Options.DesyncNearOffsetX then Options.DesyncNearOffsetX:SetValue(math.clamp(n,-50,50)) end end) end})

BoxDesyncNear:AddSlider('DesyncNearOffsetY',{Text='offset y',Default=0,Min=-50,Max=50,Rounding=1,Callback=function(v) cfg.desyncNearOffsetY=v end})
BoxDesyncNear:AddInput('DesyncNearOffsetYText',{Text='offset y manual',Default='0',Numeric=true,Finished=true,ClearTextOnFocus=false,
    Callback=function(v) local n=tonumber(v);if not n then return end;cfg.desyncNearOffsetY=n
        task.defer(function() if Options.DesyncNearOffsetY then Options.DesyncNearOffsetY:SetValue(math.clamp(n,-50,50)) end end) end})

BoxDesyncNear:AddSlider('DesyncNearOffsetZ',{Text='offset z',Default=0,Min=-50,Max=50,Rounding=1,Callback=function(v) cfg.desyncNearOffsetZ=v end})
BoxDesyncNear:AddInput('DesyncNearOffsetZText',{Text='offset z manual',Default='0',Numeric=true,Finished=true,ClearTextOnFocus=false,
    Callback=function(v) local n=tonumber(v);if not n then return end;cfg.desyncNearOffsetZ=n
        task.defer(function() if Options.DesyncNearOffsetZ then Options.DesyncNearOffsetZ:SetValue(math.clamp(n,-50,50)) end end) end})

BoxDesyncNear:AddDivider()
BoxDesyncNear:AddLabel('no nearby players?')
BoxDesyncNear:AddLabel('auto-falls back to void freeze.')

-- UI Settings
local MenuGroup = Tabs["UI Settings"]:AddLeftGroupbox("Menu")

MenuGroup:AddToggle("KeybindMenuOpen", { Default = Library.KeybindFrame.Visible, Text = "Open Keybind Menu", Callback = function(value) Library.KeybindFrame.Visible = value end})
MenuGroup:AddToggle("ShowCustomCursor", {Text = "Custom Cursor", Default = true, Callback = function(Value) Library.ShowCustomCursor = Value end})
MenuGroup:AddDivider()
MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "RightShift", NoUI = true, Text = "Menu keybind" })
MenuGroup:AddButton("Unload", function() Library:Unload() end)

Library.ToggleKeybind = Options.MenuKeybind -- Allows you to have a custom keybind for the menu

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)

SaveManager:IgnoreThemeSettings()

SaveManager:SetIgnoreIndexes({ "MenuKeybind" })

SaveManager:BuildConfigSection(Tabs["UI Settings"])

ThemeManager:ApplyToTab(Tabs["UI Settings"])

SaveManager:LoadAutoloadConfig()

Library:OnUnload(function()
    stopLoop()
    stopDesync()
    print('[vanadium voidspam] unloaded')
end)

print('[vanadium] loaded')
