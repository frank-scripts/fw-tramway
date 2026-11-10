local Models  = Config.Models
local T        = Config.Timings
local CLOSED   = 0.95
local OPENADD  = 0.9
local CYCLE    = (2 * T.idle) + (2 * T.travel)
local Walk = Config.WalkableTrams

local createEntities, deleteEntities, startLoops, updateSubscription

local timeOffset = 0
local function Now() return GetGameTimer() + timeOffset end

local bestRtt = math.huge
RegisterNetEvent('tramway:syncRes', function(t0, serverNow)
    local t1  = GetGameTimer()
    local rtt = t1 - t0
    if rtt > 1000 or rtt >= bestRtt then return end
    bestRtt    = rtt
    timeOffset = (serverNow + rtt * 0.5) - t1
end)

CreateThread(function()
    local function ask() TriggerServerEvent('tramway:syncReq', GetGameTimer()) end
    for _ = 1, 3 do ask(); Wait(500) end
    while true do
        Wait(30000)
        bestRtt = bestRtt + 100
        ask()
    end
end)

local Tracks = {}
do
    for index, nodes in pairs(Config.Tracks) do
        local segs, cum = {}, 0.0
        for i = 1, #nodes - 1 do
            local a, b = nodes[i], nodes[i + 1]
            local len  = #(a - b)
            segs[i] = { a = a, b = b, len = len, cum = cum }
            cum = cum + len
        end
        Tracks[index] = { nodes = nodes, segments = segs, length = cum }
    end
end

local function smoothstep(t) t = lib.math.clamp(t, 0.0, 1.0) return t * t * (3.0 - 2.0 * t) end

local function posAtArc(track, s)
    local nodes = track.nodes
    if s <= 0.0 then return nodes[1] end
    if s >= track.length then return nodes[#nodes] end
    for i = 1, #track.segments do
        local seg = track.segments[i]
        if s <= seg.cum + seg.len then
            local lt  = (s - seg.cum) / seg.len
            local pos = lib.math.interp(seg.a, seg.b, lt)
            if seg.len > Config.SagMinLength then
                return vector3(pos.x, pos.y, pos.z + (math.abs(lt - 0.5) * 2.0 - 1.0) * Config.SagAmount)
            end
            return pos
        end
    end
    return nodes[#nodes]
end

local function doorOpenAt(tIn, tOut)
    return math.min(lib.math.clamp(tIn / T.doorTransition, 0.0, 1.0), lib.math.clamp(tOut / T.doorTransition, 0.0, 1.0))
end

local function getCarState(trackIndex, now)
    local track = Tracks[trackIndex]
    local phase = now % CYCLE
    if phase < T.idle then
        return posAtArc(track, 0.0), 'idle_a', doorOpenAt(phase, T.idle - phase), false
    elseif phase < T.idle + T.travel then
        local p = smoothstep((phase - T.idle) / T.travel)
        return posAtArc(track, p * track.length), 'up', 0.0, true
    elseif phase < (2 * T.idle) + T.travel then
        local tIn = phase - (T.idle + T.travel)
        return posAtArc(track, track.length), 'idle_b', doorOpenAt(tIn, T.idle - tIn), false
    else
        local p = smoothstep((phase - ((2 * T.idle) + T.travel)) / T.travel)
        return posAtArc(track, (1.0 - p) * track.length), 'down', 0.0, true
    end
end

local active     = false
local zoneCount  = 0
local ridingCar  = nil   -- nil or track index (0 and 1 are both valid)
local cars       = {}
local gen        = 0

-- Do not attach the player to a seat. Each client carries its own ped by the
-- cabin's world-space movement while leaving normal on-foot locomotion enabled.
local function setRidingCar(index)
    if ridingCar == index then return end
    ridingCar = index
    LocalPlayer.state:set('tramCar', index, true)
    -- Clear obsolete seat state from older versions of this resource.
    LocalPlayer.state:set('tramSeat', nil, true)
    TriggerServerEvent('tramway:riding', index ~= nil)
    updateSubscription()
end

local function isPlayerOnFoot(ped)
    return ped ~= 0
        and DoesEntityExist(ped)
        and not IsEntityDead(ped)
        and not IsPedInAnyVehicle(ped, false)
        and not IsEntityAttached(ped)
end

-- Check the cabin floor in its LOCAL coordinate system. Z is the ped's feet,
-- not its head. Spatial bounds ensure players on the nearby station platform,
-- roof or underneath a car are NOT dragged along with it.
local function isInsideCabin(c, pedPos, keepRider)
    if not c or not c.entity or not DoesEntityExist(c.entity) then return false end
    local pos = GetOffsetFromEntityGivenWorldCoords(c.entity, pedPos.x, pedPos.y, pedPos.z)
    local padding = keepRider and Walk.exitPadding or 0.0
    local relativeHeight = pos.z - Walk.floorZ
    if math.abs(pos.x) > Walk.halfWidth + padding then return false end
    if math.abs(pos.y) > Walk.halfLength + padding then return false end
    if relativeHeight < Walk.minFootHeight or relativeHeight > Walk.maxFootHeight then return false end
    return true
end

local function findCabinForPed(ped, pos)
    if not Walk.enabled or not isPlayerOnFoot(ped) then return nil end

    -- A little horizontal hysteresis prevents a rider from flickering in/out
    -- when walking near the cabin walls or standing by a door.
    local current = ridingCar ~= nil and cars[ridingCar] or nil
    if current and isInsideCabin(current, pos, true) then return ridingCar end

    local bestIndex, nearest = nil, math.huge
    for idx, c in pairs(cars) do
        if isInsideCabin(c, pos, false) then
            local d = #(pos - GetEntityCoords(c.entity))
            if d < nearest then
                nearest, bestIndex = d, idx
            end
        end
    end
    return bestIndex
end

local function requestAudio()
    RequestScriptAudioBank('CABLE_CAR', false, -1)
    RequestScriptAudioBank('CABLE_CAR_SOUNDS', false, -1)
end
local function releaseAudio()
    ReleaseNamedScriptAudioBank('CABLE_CAR')
    ReleaseNamedScriptAudioBank('CABLE_CAR_SOUNDS')
end
local function stopRunningSound(c)
    if c.runningSound then
        StopSound(c.runningSound); ReleaseSoundId(c.runningSound); c.runningSound = nil
    end
end
local function updateCarSound(c, region, traveling)
    if not (c.entity and DoesEntityExist(c.entity)) then return end
    if traveling then
        if not c.runningSound then
            c.runningSound = GetSoundId()
            PlaySoundFromEntity(c.runningSound, 'Running', c.entity, 'CABLE_CAR_SOUNDS', false, 0)
        end
    else
        stopRunningSound(c)
    end
    if c.lastRegion ~= region then
        if region == 'up' or region == 'down' then
            PlaySoundFromEntity(-1, 'Leave_Station', c.entity, 'CABLE_CAR_SOUNDS', false, 0)
            PlaySoundFromEntity(-1, 'DOOR_CLOSE',     c.entity, 'CABLE_CAR_SOUNDS', false, 0)
        else
            PlaySoundFromEntity(-1, 'Arrive_Station', c.entity, 'CABLE_CAR_SOUNDS', false, 0)
            PlaySoundFromEntity(-1, 'DOOR_OPEN',       c.entity, 'CABLE_CAR_SOUNDS', false, 0)
        end
        c.lastRegion = region
    end
end

local function setDoorPos(c, doorPos)
    local e, d = c.entity, c.doors
    if not (e and DoesEntityExist(e)) then return end
    for _, dr in pairs(d) do
        if dr and dr ~= 0 and DoesEntityExist(dr) then DetachEntity(dr, false, false) end
    end
    if d.LL ~= 0 then AttachEntityToEntity(d.LL, e, 0, 0.0, -doorPos, 0.0, 0.0, 0.0,   0.0, false, false, true, false, 2, true) end
    if d.LR ~= 0 then AttachEntityToEntity(d.LR, e, 0, 0.0,  doorPos, 0.0, 0.0, 0.0,   0.0, false, false, true, false, 2, true) end
    if d.RL ~= 0 then AttachEntityToEntity(d.RL, e, 0, 0.0,  doorPos, 0.0, 0.0, 0.0, 180.0, false, false, true, false, 2, true) end
    if d.RR ~= 0 then AttachEntityToEntity(d.RR, e, 0, 0.0, -doorPos, 0.0, 0.0, 0.0, 180.0, false, false, true, false, 2, true) end
end

createEntities = function()
    for _, h in ipairs({ Models.car, Models.doorL, Models.doorR }) do RequestModel(h) end
    local started = GetGameTimer()
    while not (HasModelLoaded(Models.car) and HasModelLoaded(Models.doorL) and HasModelLoaded(Models.doorR)) do
        Wait(0)
        if GetGameTimer() - started > 10000 then break end
    end

    local now = Now()

    local function mkObject(model, pos)
        local e = CreateObjectNoOffset(model, pos.x, pos.y, pos.z, false, false, false)
        while not DoesEntityExist(e) do Wait(0) end
        SetEntityAsMissionEntity(e, true, true)
        return e
    end

    for index, carCfg in pairs(Config.Cars) do
        local pos, region = getCarState(index, now)
        local spawnPos = pos + carCfg.offset
        local e = mkObject(Models.car, spawnPos)
        FreezeEntityPosition(e, true)
        SetEntityRotation(e, 0.0, 0.0, carCfg.heading, 2, true)

        local doors = {
            LL = mkObject(Models.doorL, spawnPos), LR = mkObject(Models.doorR, spawnPos),
            RL = mkObject(Models.doorL, spawnPos), RR = mkObject(Models.doorR, spawnPos),
        }

        local c = {
            entity = e, trackIndex = index, doors = doors,
            region = region, lastRegion = region,
            doorApplied = nil, doorOpen = 0.0, runningSound = nil,
            lastPos = spawnPos,
        }
        cars[index] = c
    end

    SetModelAsNoLongerNeeded(Models.car)
    SetModelAsNoLongerNeeded(Models.doorL)
    SetModelAsNoLongerNeeded(Models.doorR)
end

deleteEntities = function()
    for _, c in pairs(cars) do
        stopRunningSound(c)
        for _, d in pairs(c.doors) do
            if d and d ~= 0 and DoesEntityExist(d) then DeleteEntity(d) end
        end
        if c.entity and DoesEntityExist(c.entity) then DeleteEntity(c.entity) end
    end
    cars = {}
end

startLoops = function()
    gen = gen + 1
    local myGen = gen

    CreateThread(function()
        while active and myGen == gen do
            local now = Now()
            local ped = PlayerPedId()
            local pedPos = GetEntityCoords(ped)
            local passengerIndex = findCabinForPed(ped, pedPos)
            local nearCar = passengerIndex ~= nil

            for idx in pairs(Config.Cars) do
                local pos, region, doorOpen, traveling = getCarState(idx, now)
                local c = cars[idx]
                if c and c.entity and DoesEntityExist(c.entity) then
                    c.region = region
                    c.doorOpen = doorOpen

                    local nextPos = pos + Config.Cars[idx].offset
                    if not nearCar and #(pedPos - nextPos) < 150.0 then
                        nearCar = true
                    end

                    local moved = not c.lastPos or #(nextPos - c.lastPos) > 0.00001

                    -- Capture the ped's offset BEFORE moving the tram. Walking
                    -- this frame has already changed this offset normally.
                    local passengerLocalPos
                    if moved and passengerIndex == idx and c.lastPos then
                        passengerLocalPos = GetOffsetFromEntityGivenWorldCoords(
                            c.entity, pedPos.x, pedPos.y, pedPos.z
                        )
                    end

                    if moved then
                        SetEntityCoords(c.entity, nextPos.x, nextPos.y, nextPos.z,
                            false, false, false, false)
                        c.lastPos = nextPos
                    end

                    if passengerLocalPos then
                        -- Convert the pre-move local offset back to world space
                        -- on the new cabin transform. Correct only what the game
                        -- hasn't already carried, preventing double movement.
                        local expected = GetOffsetFromEntityInWorldCoords(
                            c.entity, passengerLocalPos.x, passengerLocalPos.y, passengerLocalPos.z
                        )
                        local actual = GetEntityCoords(ped)
                        if #(expected - actual) > 0.00001 then
                            -- keepTasks and keepIK preserve walking/animations;
                            -- doWarp=false avoids clearing ped/ground contacts.
                            SetEntityCoordsNoOffset(ped,
                                expected.x, expected.y, expected.z,
                                true, true, false)
                        end
                    end

                    if not c.doorApplied or math.abs(doorOpen - c.doorApplied) > 0.01 then
                        setDoorPos(c, CLOSED + OPENADD * doorOpen)
                        c.doorApplied = doorOpen
                    end

                    if Config.Sounds then updateCarSound(c, region, traveling) end
                end
            end

            -- Each player syncs the position of their OWN ped to other players
            -- through FiveM. Never teleport remote player peds locally.
            if passengerIndex ~= ridingCar then
                setRidingCar(passengerIndex)
            end

            Wait(nearCar and 0 or 50)
        end
    end)
end

updateSubscription = function()
    local should = (zoneCount > 0) or (ridingCar ~= nil)
    if should and not active then
        active = true
        if Config.Sounds then requestAudio() end
        createEntities()
        startLoops()
    elseif not should and active then
        active = false
        gen = gen + 1
        deleteEntities()
        if Config.Sounds then releaseAudio() end
    end
end

local function resetRiding()
    if ridingCar ~= nil then
        setRidingCar(nil)
    else
        LocalPlayer.state:set('tramCar', nil, true)
        LocalPlayer.state:set('tramSeat', nil, true)
    end
end

RegisterNetEvent('QBX:Client:OnPlayerUnload', resetRiding)
RegisterNetEvent('QBCore:Client:OnPlayerUnload', resetRiding)

-- A disconnect mid-ride is handled by the original server-side safety system.
RegisterNetEvent('tramway:goToStation', function()
    CreateThread(function()
        resetRiding()
        local ped = PlayerPedId()
        local returns = Config.LogoutReturns or {}
        local here = GetEntityCoords(ped)
        local r, best = returns[1], math.huge
        for _, p in ipairs(returns) do
            local d = #(here - p)
            if d < best then best = d; r = p end
        end
        if not r then return end

        SetEntityInvincible(ped, true)
        FreezeEntityPosition(ped, true)
        local t0 = GetGameTimer()
        while GetGameTimer() - t0 < 1000 do
            SetEntityCoords(ped, r.x, r.y, r.z, false, false, false, false)
            Wait(100)
        end
        FreezeEntityPosition(ped, false)
        SetEntityInvincible(ped, false)
    end)
end)

CreateThread(function()
    lib.zones.poly({
        points    = Config.Zone.points,
        thickness = Config.Zone.thickness,
        debug     = Config.Debug,
        onEnter   = function() zoneCount = zoneCount + 1; updateSubscription() end,
        onExit    = function()
            zoneCount = zoneCount - 1
            if zoneCount < 0 then zoneCount = 0 end
            updateSubscription()
        end,
    })
end)

CreateThread(function()
    if not (Config.Blip and Config.Blip.enabled) then return end
    for _, c in ipairs(Config.Blip.coords) do
        local blip = AddBlipForCoord(c.x, c.y, c.z)
        SetBlipSprite(blip, Config.Blip.sprite)
        SetBlipScale(blip, Config.Blip.scale + 0.0)
        SetBlipColour(blip, Config.Blip.color)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(Config.Blip.label)
        EndTextCommandSetBlipName(blip)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if ridingCar ~= nil then TriggerServerEvent('tramway:riding', false) end
    ridingCar = nil
    LocalPlayer.state:set('tramCar', nil, true)
    LocalPlayer.state:set('tramSeat', nil, true)
    deleteEntities()
end)
