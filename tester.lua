-- BeeEventCollector.lua
-- Bee event → drain all honey (40s max) → queue_on_teleport → serverhop

local RunService         = game:GetService("RunService")
local Players            = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local TeleportService    = game:GetService("TeleportService")
local HttpService        = game:GetService("HttpService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local char   = player.Character or player.CharacterAdded:Wait()
local root   = char:WaitForChild("HumanoidRootPart")
local hum    = char:WaitForChild("Humanoid")

local COLLECT_TIMEOUT = 40
local MIN_PLAYERS     = 1
local MAX_PAGES       = 5
local PAGE_LIMIT      = 100
local RETRY_DELAY     = 3
local MAX_RETRIES     = 5
local BLACKLIST_FILE  = "ServerHop_Visited.json"

------------------------------------------------------------------------
-- Blacklist
------------------------------------------------------------------------
local visited     = {}
local sessionHour = os.date("!*t").hour

local function loadBlacklist()
    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(BLACKLIST_FILE))
    end)
    if not ok or type(data) ~= "table" then return end
    if tonumber(data[1]) ~= sessionHour then
        pcall(function() delfile(BLACKLIST_FILE) end)
        return
    end
    for i = 2, #data do visited[tostring(data[i])] = true end
end

local function saveBlacklist()
    local out = { sessionHour }
    for id in pairs(visited) do table.insert(out, id) end
    pcall(function()
        writefile(BLACKLIST_FILE, HttpService:JSONEncode(out))
    end)
end

local function markVisited(id)
    visited[tostring(id)] = true
    saveBlacklist()
end

------------------------------------------------------------------------
-- Server list + candidate picker
------------------------------------------------------------------------
local function fetchServers()
    local all    = {}
    local cursor = ""
    for _ = 1, MAX_PAGES do
        local url = string.format(
            "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=%d%s",
            game.PlaceId, PAGE_LIMIT,
            cursor ~= "" and ("&cursor=" .. cursor) or ""
        )
        local ok, result = pcall(function()
            return HttpService:JSONDecode(HttpService:GetAsync(url))
        end)
        if not ok or type(result) ~= "table" or type(result.data) ~= "table" then break end
        for _, srv in ipairs(result.data) do table.insert(all, srv) end
        if result.nextPageCursor and result.nextPageCursor ~= "" and result.nextPageCursor ~= "null" then
            cursor = result.nextPageCursor
        else
            break
        end
    end
    return all
end

local function pickTarget(servers)
    local candidates = {}
    local currentId  = game.JobId
    for _, srv in ipairs(servers) do
        local id = tostring(srv.id)
        if  id ~= currentId
        and not visited[id]
        and tonumber(srv.playing) < tonumber(srv.maxPlayers)
        and tonumber(srv.playing) >= MIN_PLAYERS
        then
            table.insert(candidates, srv)
        end
    end
    if #candidates == 0 then return nil end
    table.sort(candidates, function(a, b)
        return tonumber(a.playing) < tonumber(b.playing)
    end)
    return candidates[1]
end

------------------------------------------------------------------------
-- Hop — queue_on_teleport fires the script in the next server
------------------------------------------------------------------------
local SCRIPT_SOURCE = [=[
    -- re-injected by queue_on_teleport
    loadstring(game:HttpGet("https://raw.githubusercontent.com/JbitzISTAKEN/aaa/refs/heads/main/tester.lua"))()
]=]

local function doHop()
    local servers = fetchServers()
    local target  = pickTarget(servers)

    -- queue before teleport fires — executor handles injection on arrival
    queue_on_teleport(SCRIPT_SOURCE)

    if target then
        local id = tostring(target.id)
        markVisited(id)
        pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, id, player)
        end)
        return
    end

    -- fallback: fresh instance
    pcall(function()
        TeleportService:Teleport(game.PlaceId, player)
    end)
end

local function hopWithRetry()
    local attempts = 0
    local hopped   = false
    while not hopped and attempts < MAX_RETRIES do
        attempts += 1
        hopped = pcall(doHop)
        if not hopped then task.wait(RETRY_DELAY) end
    end
end

TeleportService.TeleportInitFailed:Connect(function(plr, _, errMsg)
    if plr ~= player then return end
    warn("[BeeCollect] Teleport failed: " .. tostring(errMsg) .. " — retrying")
    task.wait(RETRY_DELAY)
    pcall(doHop)
end)

------------------------------------------------------------------------
-- ── bodyforce layer
------------------------------------------------------------------------
local isPathing  = false
local pathTarget = Vector3.zero

local bodyForce = Instance.new("BodyForce")
bodyForce.Force  = Vector3.new(0, 0, 0)
bodyForce.Parent = root

RunService.RenderStepped:Connect(function(dt)
    if not isPathing then
        bodyForce.Force = Vector3.new(0, 0, 0)
        return
    end
    local hrpPos = root.Position
    local dir    = Vector3.new(pathTarget.X - hrpPos.X, 0, pathTarget.Z - hrpPos.Z)
    if dir.Magnitude > 0.5 then
        local vel       = root.AssemblyLinearVelocity
        local targetVel = dir.Unit * 100
        local diff      = targetVel - Vector3.new(vel.X, 0, vel.Z)
        local mass      = root:GetMass() or 2
        local f         = diff * mass / dt
        bodyForce.Force = Vector3.new(f.X, 0, f.Z)
    else
        bodyForce.Force = Vector3.new(0, 0, 0)
    end
end)

player.CharacterAdded:Connect(function(newChar)
    char  = newChar
    root  = newChar:WaitForChild("HumanoidRootPart")
    hum   = newChar:WaitForChild("Humanoid")
    bodyForce.Parent = root
    bodyForce.Force  = Vector3.new(0, 0, 0)
    isPathing        = false
    pathTarget       = Vector3.zero
end)

------------------------------------------------------------------------
-- ── waverider lock
------------------------------------------------------------------------
local WAVERIDER_NAME = "Waverider"
local waveriderConn: RBXScriptConnection? = nil

local function equipWaverider()
    if char:FindFirstChild(WAVERIDER_NAME) then return end
    local bp   = player:FindFirstChild("Backpack")
    local tool = bp and bp:FindFirstChild(WAVERIDER_NAME)
    if tool then hum:EquipTool(tool) end
end

local function lockWaverider()
    equipWaverider()
    waveriderConn = char.ChildRemoved:Connect(function(child)
        if child.Name == WAVERIDER_NAME and isPathing then
            task.defer(equipWaverider)
        end
    end)
end

local function unlockWaverider()
    if waveriderConn then waveriderConn:Disconnect() waveriderConn = nil end
end

------------------------------------------------------------------------
-- ── honey pathfinder
------------------------------------------------------------------------
local currentTarget:  Model?               = nil
local moveConnection: RBXScriptConnection? = nil
local isDestroying   = false
local collectActive  = false
local collectDone    = false

local DESTINATION_THRESHOLD = 3.5
local REPATH_INTERVAL       = 2

local function getPrompt(honey: Model): ProximityPrompt?
    local r = honey.PrimaryPart or honey:FindFirstChildWhichIsA("BasePart", true)
    if not r then return nil end
    return r:FindFirstChildOfClass("ProximityPrompt")
end

local function isReady(honey: Model): boolean
    local p = getPrompt(honey)
    return p ~= nil and p.Enabled
end

local function isGone(honey: Model): boolean
    if not honey.Parent then return true end
    local p = getPrompt(honey)
    return p == nil or not p.Enabled
end

local function getHoneyPosition(honey: Model): Vector3?
    local r = honey.PrimaryPart or honey:FindFirstChildWhichIsA("BasePart", true)
    return r and r.Position or nil
end

local function closestReady(): Model?
    local best: Model? = nil
    local bestDist     = math.huge
    local origin       = root.Position
    for _, obj in ipairs(workspace:GetChildren()) do
        if obj.Name == "Honey" and obj:IsA("Model") and isReady(obj) then
            local pos = getHoneyPosition(obj)
            if pos then
                local d = (pos - origin).Magnitude
                if d < bestDist then bestDist = d; best = obj end
            end
        end
    end
    return best
end

local beginWalkToHoney

local function stopMove()
    if moveConnection then moveConnection:Disconnect() moveConnection = nil end
    isPathing  = false
    pathTarget = Vector3.zero
    unlockWaverider()
end

local function acquireNext()
    currentTarget = nil
    local nxt = closestReady()
    if nxt then
        currentTarget = nxt
        beginWalkToHoney(nxt)
    else
        -- defer one tick — catches jars that spawned the same frame as last collect
        task.defer(function()
            local check = closestReady()
            if check then
                currentTarget = check
                beginWalkToHoney(check)
            elseif collectActive then
                collectDone = true
            end
        end)
    end
end

local function tryPreempt()
    local best = closestReady()
    if not best or best == currentTarget then return end
    local newPos = getHoneyPosition(best)
    local hrpPos = root.Position
    if not newPos then return end
    if not currentTarget then
        currentTarget = best
        beginWalkToHoney(best)
        return
    end
    local curPos = getHoneyPosition(currentTarget)
    if curPos and (newPos - hrpPos).Magnitude < (curPos - hrpPos).Magnitude then
        currentTarget = best
        beginWalkToHoney(best)
    end
end

beginWalkToHoney = function(target: Model)
    stopMove()
    isDestroying = false
    isPathing    = true
    lockWaverider()

    local currentWaypoints     = {}
    local currentWaypointIndex = 1
    local lastRepath           = 0

    local function computePath()
        local destination = getHoneyPosition(target)
        if not destination then return end
        local path = PathfindingService:CreatePath({
            AgentCanJump = true,
            AgentRadius  = 2,
            AgentHeight  = 5,
        })
        local ok = pcall(function()
            path:ComputeAsync(root.Position, destination)
        end)
        if ok and path.Status == Enum.PathStatus.Success then
            currentWaypoints     = path:GetWaypoints()
            currentWaypointIndex = 1
            for i = 1, math.min(5, #currentWaypoints) do
                if (currentWaypoints[i].Position - root.Position).Magnitude < 3 then
                    currentWaypointIndex = i + 1
                else
                    break
                end
            end
        else
            currentWaypoints     = {}
            currentWaypointIndex = 1
        end
        lastRepath = tick()
    end

    computePath()

    moveConnection = RunService.Heartbeat:Connect(function()
        if isDestroying then stopMove() return end
        if isGone(target) then
            stopMove()
            task.defer(acquireNext)
            return
        end

        local hrpPos      = root.Position
        local destination = getHoneyPosition(target)
        if not destination then return end

        if (destination - hrpPos).Magnitude < DESTINATION_THRESHOLD then
            stopMove()
            task.defer(acquireNext)
            return
        end

        local targetPosition: Vector3

        if #currentWaypoints > 0 and currentWaypointIndex <= #currentWaypoints then
            targetPosition = currentWaypoints[currentWaypointIndex].Position
            local hDist = Vector3.new(
                targetPosition.X - hrpPos.X, 0, targetPosition.Z - hrpPos.Z
            ).Magnitude
            if hDist < 2 then
                currentWaypointIndex += 1
                if currentWaypointIndex > #currentWaypoints then
                    currentWaypoints     = {}
                    currentWaypointIndex = 1
                end
                return
            end
        else
            targetPosition = destination
            if tick() - lastRepath > REPATH_INTERVAL then computePath() end
        end

        if #currentWaypoints > 0
            and currentWaypointIndex <= #currentWaypoints
            and currentWaypoints[currentWaypointIndex].Action == Enum.PathWaypointAction.Jump
        then
            hum.Jump = true
        end

        pathTarget = targetPosition
        hum:MoveTo(targetPosition)
    end)
end

------------------------------------------------------------------------
-- ── scan loop + new-honey watcher
------------------------------------------------------------------------
task.spawn(function()
    while true do
        task.wait(0.5)
        if collectActive then tryPreempt() end
    end
end)

workspace.ChildAdded:Connect(function(child)
    if child.Name ~= "Honey" or not child:IsA("Model") or not collectActive then return end
    task.spawn(function()
        local r2 = child:FindFirstChildWhichIsA("BasePart", true)
        if not r2 then child.DescendantAdded:Wait() r2 = child:FindFirstChildWhichIsA("BasePart", true) end
        if not r2 then return end
        local prompt = r2:FindFirstChildOfClass("ProximityPrompt")
        if not prompt then
            local found = false
            r2.ChildAdded:Connect(function(c)
                if c:IsA("ProximityPrompt") then prompt = c; found = true end
            end)
            local t0 = tick()
            while not found and tick() - t0 < 10 do task.wait() end
        end
        if not prompt then return end
        if not prompt.Enabled then prompt:GetPropertyChangedSignal("Enabled"):Wait() end
        if prompt.Enabled then
            collectDone = false  -- new jar confirmed — un-trip the done flag
            tryPreempt()
        end
    end)
end)

------------------------------------------------------------------------
-- ── collection runner
------------------------------------------------------------------------
local function runCollection()
    if collectActive then return end
    collectActive = true
    collectDone   = false

    print("[BeeCollect] Bee event active — starting honey drain")

    local first = closestReady()
    if first then
        currentTarget = first
        beginWalkToHoney(first)
    else
        collectDone = true
    end

    local deadline = tick() + COLLECT_TIMEOUT
    while not collectDone and tick() < deadline do
        task.wait(0.25)
    end

    stopMove()
    collectActive = false

    if collectDone then
        print("[BeeCollect] All honey collected — hopping")
    else
        print("[BeeCollect] Timeout reached — hopping")
    end

    task.wait(5)
    hopWithRetry()
end

------------------------------------------------------------------------
-- ── Bee event listener
------------------------------------------------------------------------
local Synchronizer = require(ReplicatedStorage.Packages.Synchronizer)

Synchronizer:WaitAndCall("Events", function(events)
    for _, activeEvent in ipairs(events:Get("ActiveEvents") or {}) do
        if activeEvent.eventName == "Bee" then
            print("[BeeCollect] Bee event already active on load")
            task.spawn(runCollection)
        end
    end

    events:OnArrayInserted("ActiveEvents", function(activeEvent)
        if activeEvent.eventName == "Bee" then
            print("[BeeCollect] Bee event started")
            task.spawn(runCollection)
        end
    end)

    events:OnArrayRemoved("ActiveEvents", function(activeEvent)
        if activeEvent.eventName == "Bee" and collectActive then
            print("[BeeCollect] Bee event ended mid-collect — forcing drain complete")
            collectDone = true
        end
    end)
end)

------------------------------------------------------------------------
-- ── init
------------------------------------------------------------------------
loadBlacklist()
markVisited(game.JobId)
