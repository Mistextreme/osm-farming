-- ESX FARMING SYSTEM - CLIENT SIDE
-- Adapted for ESX-Legacy with ox_lib and ox_inventory

local ESX = exports['es_extended']:getSharedObject()
local PlayerData = {}
local isLoggedIn = false

-- Cache variables
local spawnedCorns = 0
local cornPlants = {}
local isPickingUp, isProcessing = false, false
local water = false
local rented = false
local track = false
local trackspots = {}
local oranges = nil 
local cowmilking = false
local cowobjects = {}
local rentveh = nil
local prog = 0

-- ESX Events
RegisterNetEvent('esx:playerLoaded')
AddEventHandler('esx:playerLoaded', function(xPlayer)
    PlayerData = xPlayer
    isLoggedIn = true
end)

RegisterNetEvent('esx:onPlayerLogout')
AddEventHandler('esx:onPlayerLogout', function()
    isLoggedIn = false
    PlayerData = {}
end)

RegisterNetEvent('esx:setJob')
AddEventHandler('esx:setJob', function(job)
    PlayerData.job = job
end)

-- Initialize blips
CreateThread(function()
    for _, info in pairs(Config.Blips) do
        info.blip = AddBlipForCoord(info.x, info.y, info.z)
        SetBlipSprite(info.blip, info.id)
        SetBlipDisplay(info.blip, 4)
        SetBlipScale(info.blip, 0.8)
        SetBlipColour(info.blip, info.colour)
        SetBlipAsShortRange(info.blip, true)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentString(info.title)
        EndTextCommandSetBlipName(info.blip)
    end
end)

-- Main farming loop
CreateThread(function()
    local sleep = 5000
    
    while true do
        Wait(sleep)
        
        if not isLoggedIn then
            goto continue
        end
        
        local playerPed = PlayerPedId()
        local coords = GetEntityCoords(playerPed)
        
        -- Check farm distance
        local farmDist = #(coords - Config.CircleZones.FarmCoords.coords)
        if farmDist < 100 and not track then
            CreateTrackSpots()
            track = true
        end
        
        -- Check cow farm distance
        local cowDist = #(coords - Config.CircleZones.CowFarm.coords)
        if cowDist < 100 and not cowmilking then
            CreateCows()
            cowmilking = true
        end
        
        -- Orange picking
        if not cowmilking and not track and not oranges then
            for i = 1, #Config.OrangeFarm do
                local orangeDist = #(coords - Config.OrangeFarm[i])
                if orangeDist < 5 then
                    sleep = 5
                    Draw3DText(Config.OrangeFarm[i].x, Config.OrangeFarm[i].y, Config.OrangeFarm[i].z, 
                              '[E] - Start Picking Oranges', 4, 0.08, 0.08, Config.SecondaryColor)
                    
                    if IsControlJustReleased(0, 38) then
                        if not oranges then
                            oranges = true
                            PickOrange()
                        else
                            lib.notify({
                                title = 'Farming',
                                description = 'You just picked some oranges! Wait a few seconds before trying again!',
                                type = 'error'
                            })
                        end
                    end
                    break
                end
            end
        else
            sleep = 5000
        end
        
        ::continue::
    end
end)

-- Processing and interaction zones
CreateThread(function()
    local points = {
        {
            coords = Config.CircleZones.CornProcessing.coords,
            distance = 3.0,
            text = '[E] - Start Processing Corn',
            action = function()
                if not isProcessing then
                    TriggerServerEvent('osm-farming:ProcessCorn')
                end
            end
        },
        {
            coords = Config.CircleZones.Boxes.coords,
            distance = 3.0,
            text = '[E] - Get a Box to Pack Items',
            action = function()
                if not isProcessing then
                    if exports.ox_inventory:Search('count', 'box') > 0 then
                        lib.notify({
                            title = 'Farming',
                            description = 'You already have a box!',
                            type = 'error'
                        })
                    else
                        TriggerServerEvent('osm-farming:GivePlayerBox')
                    end
                end
            end
        },
        {
            coords = Config.CircleZones.OrangePack.coords,
            distance = 3.0,
            text = '[E] - Pack Oranges',
            action = function()
                if not isProcessing then
                    TriggerServerEvent('osm-farming:ProcessOranges')
                end
            end
        },
        {
            coords = Config.CircleZones.MilkPack.coords,
            distance = 3.0,
            text = '[E] - Prepare Milk Pack',
            action = function()
                if not isProcessing then
                    TriggerServerEvent('osm-farming:ProcessMilk')
                end
            end
        },
        {
            coords = Config.TractorCoords,
            distance = 3.0,
            text = function()
                return rented and '[E] - Return Tractor' or '[E] - Rent a Tractor for Farming'
            end,
            action = function()
                if not rented then
                    lib.notify({
                        title = 'Farming',
                        description = 'You rented a tractor for farming!',
                        type = 'success'
                    })
                    TriggerServerEvent('osm-farming:server:SpawnTractor')
                else
                    lib.notify({
                        title = 'Farming',
                        description = 'You returned the rented vehicle',
                        type = 'success'
                    })
                    TriggerServerEvent('Server:UnRentTractor')
                end
            end
        }
    }
    
    while true do
        Wait(5)
        
        if not isLoggedIn then
            goto continue
        end
        
        local playerPed = PlayerPedId()
        local coords = GetEntityCoords(playerPed)
        local sleep = 500
        
        for _, point in pairs(points) do
            local distance = #(coords - point.coords)
            if distance < point.distance then
                sleep = 5
                
                -- Draw marker
                DrawMarker(27, point.coords.x, point.coords.y, point.coords.z - 1, 
                          0, 0, 0, 0, 0, 0, 1.0, 1.0, 1.0, 255, 0, 0, 200, 0, 0, 0, 0)
                
                -- Draw text
                local text = type(point.text) == 'function' and point.text() or point.text
                Draw3DText(point.coords.x, point.coords.y, point.coords.z, text, 4, 0.08, 0.08, Config.SecondaryColor)
                
                -- Handle input
                if IsControlJustReleased(0, 38) then
                    point.action()
                end
                
                break
            end
        end
        
        Wait(sleep)
        ::continue::
    end
end)

-- Selling system
CreateThread(function()
    local sellItemsSet = false
    local sellPrice = 0
    
    while true do
        Wait(1)
        
        if not isLoggedIn then
            goto continue
        end
        
        local inRange = false
        local pos = GetEntityCoords(PlayerPedId())
        local distance = #(pos - Config.SellLocation)
        
        if distance < 5.0 then
            inRange = true
            if distance < 1.5 then
                if not sellItemsSet then
                    ESX.TriggerServerCallback('osm-farming:server:GetSellingPrice', function(price)
                        sellPrice = price
                        sellItemsSet = true
                    end)
                elseif sellItemsSet and sellPrice > 0 then
                    DrawText3D(Config.SellLocation.x, Config.SellLocation.y, Config.SellLocation.z, 
                              "~g~E~w~ - Sell Farmed Items (€"..sellPrice..")")
                    
                    if IsControlJustReleased(0, 38) then
                        TaskStartScenarioInPlace(PlayerPedId(), "WORLD_HUMAN_STAND_IMPATIENT", 0, true)
                        
                        if lib.progressBar({
                            duration = math.random(15000, 25000),
                            label = 'Selling items...',
                            useWhileDead = false,
                            canCancel = true,
                            disable = {
                                car = true,
                                move = true,
                                combat = true
                            }
                        }) then
                            ClearPedTasks(PlayerPedId())
                            TriggerServerEvent("osm-farming:server:SellFarmingItems")
                            sellItemsSet = false
                            sellPrice = 0
                        else
                            ClearPedTasks(PlayerPedId())
                            lib.notify({
                                title = 'Farming',
                                description = 'Cancelled',
                                type = 'error'
                            })
                        end
                    end
                else
                    DrawText3D(Config.SellLocation.x, Config.SellLocation.y, Config.SellLocation.z, 
                              "Pawnshop, you don't have anything to sell..")
                end
            end
        end
        
        if not inRange then
            sellPrice = 0
            sellItemsSet = false
            Wait(2500)
        end
        
        ::continue::
    end
end)

-- Corn plant interaction
CreateThread(function()
    while true do
        Wait(5)
        
        if not isLoggedIn then
            goto continue
        end
        
        local playerPed = PlayerPedId()
        local coords = GetEntityCoords(playerPed)
        local nearbyObject, nearbyID
        local nearbySpot, spotID
        
        -- Check corn plants
        for i = 1, #cornPlants do
            if #(coords - GetEntityCoords(cornPlants[i])) < 1 then
                nearbyObject, nearbyID = cornPlants[i], i
                break
            end
        end
        
        -- Check track spots
        for i = 1, #trackspots do
            if #(coords - GetEntityCoords(trackspots[i])) < 3 then
                nearbySpot, spotID = trackspots[i], i
                break
            end
        end
        
        local playerVehicle = GetVehiclePedIsIn(playerPed, false)
        
        if nearbyObject and IsPedOnFoot(playerPed) then
            if not isPickingUp then
                local coord1 = GetEntityCoords(nearbyObject)
                Draw3DText(coord1.x, coord1.y, coord1.z + 1.5, '[E] - Pick Up Corn Kernel', 4, 0.08, 0.08, Config.SecondaryColor)
            end
            
            if IsControlJustReleased(0, 38) and not isPickingUp then
                isPickingUp = true
                TaskStartScenarioInPlace(playerPed, 'world_human_gardener_plant', 0, false)
                
                if lib.progressBar({
                    duration = 5000,
                    label = 'Picking up corn kernel...',
                    useWhileDead = false,
                    canCancel = true,
                    disable = {
                        car = true,
                        move = true,
                        combat = true
                    }
                }) then
                    ClearPedTasks(playerPed)
                    DeleteObject(nearbyObject)
                    table.remove(cornPlants, nearbyID)
                    spawnedCorns = spawnedCorns - 1
                    
                    if #cornPlants == 0 then
                        track = false
                    end
                    
                    TriggerServerEvent('osm-farming:pickedUpCannabis')
                else
                    ClearPedTasks(playerPed)
                end
                
                isPickingUp = false
            end
            
        elseif nearbySpot and GetEntityModel(playerVehicle) == `tractor3` then
            if not isPickingUp then
                local coord = GetEntityCoords(trackspots[spotID])
                Draw3DText(coord.x, coord.y, coord.z + 1.5, '[E] - Mow the Field', 4, 0.2, 0.2, Config.SecondaryColor)
            end
            
            if IsControlJustReleased(0, 38) then
                ClearPedTasks(playerPed)
                DeleteObject(nearbySpot)
                table.remove(trackspots, spotID)
                
                if #trackspots == 0 then
                    water = true
                    lib.notify({
                        title = 'Farming',
                        description = 'Field mowing is complete! Start water supply!',
                        type = 'success'
                    })
                    Wait(100)
                    WaterStart()
                end
            end
        else
            Wait(500)
        end
        
        ::continue::
    end
end)

-- Cow milking interaction
CreateThread(function()
    while true do
        Wait(5)
        
        if not isLoggedIn then
            goto continue
        end
        
        local playerPed = PlayerPedId()
        local coords = GetEntityCoords(playerPed)
        local nearbyCow, cowId
        
        for i = 1, #cowobjects do
            if #(coords - GetEntityCoords(cowobjects[i])) < 2 then
                nearbyCow, cowId = cowobjects[i], i
                break
            end
        end
        
        if nearbyCow and IsPedOnFoot(playerPed) then
            if not isPickingUp then
                local coord1 = GetEntityCoords(nearbyCow)
                Draw3DText(coord1.x, coord1.y, coord1.z + 1.5, '[E] - Milk The Cow', 4, 0.07, 0.07, Config.SecondaryColor)
            end
            
            if IsControlJustReleased(0, 38) and not isPickingUp then
                if math.random(1, 10) > 4 then
                    FreezeEntityPosition(nearbyCow, true)
                    TaskStartScenarioInPlace(playerPed, "PROP_HUMAN_PARKING_METER", 0, true)
                    MilkCow(nearbyCow)
                else
                    lib.notify({
                        title = 'Farming',
                        description = 'You failed to get milk from the cow! Try again later!',
                        type = 'error'
                    })
                end
            end
        else
            Wait(500)
        end
        
        ::continue::
    end
end)

-- Cow movement
CreateThread(function()
    while true do
        Wait(60000)
        
        if #cowobjects > 0 then
            for _, cow in pairs(cowobjects) do
                TaskPedSlideToCoord(cow, 2540.9519042969, 4788.830078125, 33.564464569092, 50, 10)
            end
            
            Wait(60000)
            
            for _, cow in pairs(cowobjects) do
                TaskPedSlideToCoord(cow, 2463.6857910156, 4734.30078125, 34.303768157959, 50, 10)
            end
        end
    end
end)

-- Events
RegisterNetEvent('SpawnTractor')
AddEventHandler('SpawnTractor', function()
    SetNewWaypoint(Config.TractorSpawn.x, Config.TractorSpawn.y)
    
    ESX.Game.SpawnVehicle(Config.Tractor, Config.TractorSpawn, Config.TractorSpawnHeading, function(vehicle)
        exports['LegacyFuel']:SetFuel(vehicle, 100)
        SetVehicleNumberPlateText(vehicle, 'FARMVEH')
        SetEntityAsMissionEntity(vehicle, true, true)
        TriggerEvent("vehiclekeys:client:SetOwner", GetVehicleNumberPlateText(vehicle))
        rentveh = vehicle
        rented = true
    end)
end)

RegisterNetEvent('UnRentTractor')
AddEventHandler('UnRentTractor', function()
    if DoesEntityExist(rentveh) then
        DeleteEntity(rentveh)
    end
    rented = false
end)

-- Functions
function ProcessCorn()
    isProcessing = true
    local playerPed = PlayerPedId()
    
    TaskStartScenarioInPlace(playerPed, "PROP_HUMAN_PARKING_METER", 0, true)
    
    if lib.progressBar({
        duration = 15000,
        label = 'Processing corn...',
        useWhileDead = false,
        canCancel = true,
        disable = {
            car = true,
            move = true,
            combat = true
        }
    }) then
        TriggerServerEvent('osm-farming:ProcessCorn')
        local timeLeft = Config.Delays.CornProcessing / 1000
        
        while timeLeft > 0 do
            Wait(1000)
            timeLeft = timeLeft - 1
            
            if #(GetEntityCoords(playerPed) - Config.CircleZones.CornProcessing.coords) > 4 then
                TriggerServerEvent('osm-farming:cancelProcessing')
                break
            end
        end
        
        ClearPedTasks(playerPed)
    else
        ClearPedTasks(playerPed)
    end
    
    isProcessing = false
end

function MilkCow(nearbyCow)
    isPickingUp = true
    prog = 0
    
    CreateThread(function()
        while prog < 100 do
            prog = prog + 1
            Wait(100)
        end
        
        if prog >= 100 then
            TriggerServerEvent('osm-farming:CowMilked')
            isPickingUp = false
            ClearPedTasks(PlayerPedId())
            FreezeEntityPosition(nearbyCow, false)
            prog = 0
        end
    end)
    
    -- Progress display
    CreateThread(function()
        while isPickingUp and prog < 100 do
            Wait(5)
            DrawText(0.9605, 0.962, "~y~[~w~".. prog .. "%~y~]", 0.4, 4, 255, 255, 255, 255)
        end
    end)
end

function PickOrange()
    local animDict = "amb@prop_human_movie_bulb@base"
    local animName = "base"
    local player = PlayerPedId()
    
    if DoesEntityExist(player) and not IsEntityDead(player) then
        lib.requestAnimDict(animDict)
        
        if IsEntityPlayingAnim(player, animDict, animName, 8) then
            TaskPlayAnim(player, animDict, "exit", 8.0, 8.0, 1.0, 1, 1, 0, 0, 0)
            ClearPedSecondaryTask(player)
        else
            Wait(50)
            TaskPlayAnim(player, animDict, animName, 8.0, 8.0, 1.0, 1, 1, 0, 0, 0)
        end
    end
    
    if lib.progressBar({
        duration = 15000,
        label = 'Picking oranges...',
        useWhileDead = false,
        canCancel = true,
        disable = {
            car = true,
            move = true,
            combat = true
        }
    }) then
        TriggerServerEvent('osm-farming:GiveOranges')
        ClearPedTasks(PlayerPedId())
        Wait(5000)
        oranges = false
    else
        ClearPedTasks(PlayerPedId())
    end
end

function WaterStart()
    CreateThread(function()
        while water do
            Wait(5)
            local playerCoords = GetEntityCoords(PlayerPedId())
            local distance = #(playerCoords - Config.CircleZones.Water.coords)
            
            if distance < 5 then
                Draw3DText(Config.CircleZones.Water.coords.x, Config.CircleZones.Water.coords.y, Config.CircleZones.Water.coords.z, 
                          '[E] - Start Water Supply', 4, 0.08, 0.08, Config.SecondaryColor)
                
                if IsControlJustReleased(0, 38) then
                    TaskStartScenarioInPlace(PlayerPedId(), "PROP_HUMAN_PARKING_METER", 0, true)
                    
                    if lib.progressBar({
                        duration = 15000,
                        label = 'Starting water supply...',
                        useWhileDead = false,
                        canCancel = true,
                        disable = {
                            car = true,
                            move = true,
                            combat = true
                        }
                    }) then
                        SpawnCornPlants()
                        lib.notify({
                            title = 'Farming',
                            description = 'Water supply started! Plants should start growing!',
                            type = 'success'
                        })
                        water = false
                    else
                        ClearPedTasks(PlayerPedId())
                    end
                end
            else
                Wait(500)
            end
        end
    end)
end

function SpawnCornPlants()
    local random = math.random(30, 40)
    local hash = GetHashKey(Config.CornPlant)
    
    lib.requestModel(hash)
    
    local spawned = 0
    while spawned < random do
        Wait(1)
        local coords = GenerateWeedCoords(Config.CircleZones.FarmCoords.coords)
        local plant = CreateObject(hash, coords.x, coords.y, coords.z, false, false, true)
        
        PlaceObjectOnGroundProperly(plant)
        FreezeEntityPosition(plant, true)
        table.insert(cornPlants, plant)
        spawned = spawned + 1
    end
    
    SetModelAsNoLongerNeeded(hash)
end

function CreateTrackSpots()
    local random = math.random(5, 10)
    local hash = GetHashKey(Config.MowProp)
    
    lib.requestModel(hash)
    
    local spawned = 0
    while spawned < random do
        Wait(1)
        local coords = GenerateWeedCoords(Config.CircleZones.FarmCoords.coords)
        local spot = CreateObject(hash, coords.x, coords.y, coords.z, false, false, true)
        
        PlaceObjectOnGroundProperly(spot)
        FreezeEntityPosition(spot, true)
        table.insert(trackspots, spot)
        spawned = spawned + 1
    end
    
    SetModelAsNoLongerNeeded(hash)
end

function CreateCows()
    local random = math.random(5, 10)
    local hash = GetHashKey(Config.CowProp)
    
    lib.requestModel(hash)
    
    local spawned = 0
    while spawned < random do
        Wait(1)
        local coords = GenerateWeedCoords(Config.CircleZones.CowFarm.coords)
        local cow = CreatePed(4, hash, coords.x, coords.y, coords.z, -149.404, false, true)
        
        SetEntityInvincible(cow, true)
        PlaceObjectOnGroundProperly(cow)
        Wait(1000)
        table.insert(cowobjects, cow)
        spawned = spawned + 1
    end
    
    SetModelAsNoLongerNeeded(hash)
end

function ValidateWeedCoord(plantCoord)
    if spawnedCorns > 0 then
        for _, plant in pairs(cornPlants) do
            if #(plantCoord - GetEntityCoords(plant)) < 5 then
                return false
            end
        end
        
        if #(plantCoord - Config.CircleZones.FarmCoords.coords) > 50 then
            return false
        end
    end
    
    return true
end

function GenerateWeedCoords(data)
    local attempts = 0
    local maxAttempts = 100
    
    while attempts < maxAttempts do
        attempts = attempts + 1
        
        local modX = math.random(-30, 30)
        local modY = math.random(-30, 30)
        
        local cornCoordX = data.x + modX
        local cornCoordY = data.y + modY
        local coordZ = GetCoordZ(cornCoordX, cornCoordY)
        
        local coord = vector3(cornCoordX, cornCoordY, coordZ)
        
        if ValidateWeedCoord(coord) then
            return coord
        end
        
        Wait(1)
    end
    
    -- Fallback to original position if no valid coord found
    return data
end

function GetCoordZ(x, y)
    local groundCheckHeights = { 18.0, 19.0, 20.0, 21.0, 22.0, 23.0, 24.0, 25.0, 26.0, 27.0, 28.0 }
    
    for _, height in ipairs(groundCheckHeights) do
        local foundGround, z = GetGroundZFor_3dCoord(x, y, 900.0, 1)
        if foundGround then
            return z
        end
    end
    
    return 31.0
end

function Draw3DText(x, y, z, textInput, fontId, scaleX, scaleY, color)
    local onScreen, _x, _y = World3dToScreen2d(x, y, z)
    
    if onScreen then
        local px, py, pz = table.unpack(GetGameplayCamCoords())
        local dist = GetDistanceBetweenCoords(px, py, pz, x, y, z, 1)
        local scale = (1 / dist) * 20
        local fov = (1 / GetGameplayCamFov()) * 100
        scale = scale * fov
        
        SetTextScale(scaleX * scale, scaleY * scale)
        SetTextFont(fontId)
        SetTextProportional(1)
        SetTextColour(color.r, color.g, color.b, color.a)
        SetTextDropshadow(1, 1, 1, 1, 255)
        SetTextEdge(2, 0, 0, 0, 150)
        SetTextDropShadow()
        SetTextOutline()
        SetTextEntry("STRING")
        SetTextCentre(1)
        AddTextComponentString(textInput)
        SetDrawOrigin(x, y, z, 0)
        DrawText(0.0, 0.0)
        ClearDrawOrigin()
    end
end

function DrawText3D(x, y, z, text)
    local onScreen, _x, _y = World3dToScreen2d(x, y, z)
    
    if onScreen then
        SetTextScale(0.35, 0.35)
        SetTextFont(4)
        SetTextProportional(1)
        SetTextColour(255, 255, 255, 215)
        SetTextEntry("STRING")
        SetTextCentre(true)
        AddTextComponentString(text)
        SetDrawOrigin(x, y, z, 0)
        DrawText(0.0, 0.0)
        local factor = (string.len(text)) / 370
        DrawRect(0.0, 0.0 + 0.0125, 0.017 + factor, 0.03, 0, 0, 0, 75)
        ClearDrawOrigin()
    end
end

function DrawText(x, y, text, scale, font, r, g, b, a)
    SetTextFont(font)
    SetTextProportional(0)
    SetTextScale(scale, scale)
    SetTextColour(r, g, b, a)
    SetTextDropShadow(0, 0, 0, 0, 255)
    SetTextEdge(2, 0, 0, 0, 255)
    SetTextDropShadow()
    SetTextOutline()
    SetTextEntry("STRING")
    AddTextComponentString(text)
    DrawText(x, y)
end

-- Cleanup on resource stop
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        for _, plant in pairs(cornPlants) do
            if DoesEntityExist(plant) then
                DeleteObject(plant)
            end
        end
        
        for _, spot in pairs(trackspots) do
            if DoesEntityExist(spot) then
                DeleteObject(spot)
            end
        end
        
        for _, cow in pairs(cowobjects) do
            if DoesEntityExist(cow) then
                DeleteObject(cow)
            end
        end
        
        if DoesEntityExist(rentveh) then
            DeleteEntity(rentveh)
        end
    end
end)