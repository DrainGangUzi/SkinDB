-- Universal cosmetic skin changer, GitHub DB loader, core v0.4.3.
-- Fetches skins.json from the matching SkinDB repository.
-- Optional override: getgenv().SKIN_DB_URL = "https://raw.githubusercontent.com/.../skins.json"
-- Does not execute CustomApply, ClientConfig or ServerConfig.

local G = getgenv()
local DB_URL = G.SKIN_DB_URL or "https://raw.githubusercontent.com/DrainGangUzi/SkinDB/main/skins.json"
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer

local ok, db = pcall(function()
    local raw = game:HttpGet(DB_URL)
    return HttpService:JSONDecode(raw)
end)
if not ok or type(db) ~= "table" or type(db.families) ~= "table" or type(db.skins) ~= "table" then
    warn("[SkinChanger] Could not download/parse " .. DB_URL .. ":", tostring(db))
    return
end
if db.schemaVersion ~= "1.0.0" then
    warn("[SkinChanger] Unexpected DB schema version:", tostring(db.schemaVersion))
    return
end

-- Stop old installers only after the new DB has loaded successfully.
if G.__M4DBTest then pcall(function() G.__M4DBTest:disable() end) end
if G.__M4AppearanceEngine then pcall(function() G.__M4AppearanceEngine:disable() end) end
if G.__GoldFXTest then
    pcall(function() G.__GoldFXTest:stop() end)
    G.__GoldFXTest = nil
end
if G.SkinChanger then pcall(function() G.SkinChanger:disable() end) end

local KEY_MAPS = {"ColorMap", "NormalMap", "RoughnessMap", "MetalnessMap"}
local function ident(value)
    local t = tostring(value or "")
    return t:match("(%d+)%D*$") or ""
end
local function asset(value)
    if not value or value == "" then return "" end
    return "rbxassetid://" .. tostring(value)
end
local function normal(value)
    return tostring(value or ""):lower():gsub("[^%da-z]", "")
end
local function ownContextPart(part)
    return part and part:IsA("MeshPart") and not part:FindFirstAncestor("__SkinChangerOverlay")
end
local function charsRoot()
    local chars = workspace:FindFirstChild("Characters")
    return chars and chars:FindFirstChild(player.Name)
end
local function anchorFor(root)
    if not root then return nil end
    for _, name in ipairs({"WeaponHandle", "Handle", "Base", "Main", "Default", "HandlePart"}) do
        local o = root:FindFirstChild(name, true)
        if o and o:IsA("BasePart") then return o end
    end
    if root:IsA("BasePart") then return root end
    return root:FindFirstChildWhichIsA("BasePart", true)
end
local function countFamilyMeshes(root, family)
    local ids = family.meshIds or {}
    local lookup = {}
    for _, v in ipairs(ids) do lookup[tostring(v)] = true end
    local n = 0
    for _, obj in ipairs(root:GetDescendants()) do
        if ownContextPart(obj) and lookup[ident(obj.MeshId)] then
            n += 1
            if n >= 2 then break end
        end
    end
    return n
end
local function matchesRoot(root, family)
    if not root or not family then return false end
    for _, name in ipairs(family.runtimeNames or {}) do
        if normal(root.Name) == normal(name) then return true end
    end
    -- This fallback identifies a differently named equipped Tool from known body meshes.
    -- Require two matches for multi-piece firearms to avoid a shared bullet false positive.
    local ids = family.meshIds or {}
    if #ids == 0 then return false end
    local count = countFamilyMeshes(root, family)
    return count >= math.min(#ids, 2)
end
local function findRoots(family)
    local ch = charsRoot()
    if not ch then return {} end
    local roots = {}
    for _, obj in ipairs(ch:GetChildren()) do
        if obj.Name ~= "DisplayItems" and (obj:IsA("Model") or obj:IsA("Tool"))
            and matchesRoot(obj, family) then
            roots.equipped = obj
            break
        end
    end
    local display = ch:FindFirstChild("DisplayItems")
    if display then
        local models = {}
        for _, obj in ipairs(display:GetDescendants()) do
            if obj:IsA("Model") or obj:IsA("Tool") then models[#models + 1] = obj end
        end
        -- Prefer exact runtime names before mesh fallback. Otherwise a broad
        -- holster-container Model could accidentally include unrelated weapons.
        for _, obj in ipairs(models) do
            for _, name in ipairs(family.runtimeNames or {}) do
                if normal(obj.Name) == normal(name) then
                    roots.holstered = obj
                    break
                end
            end
            if roots.holstered then break end
        end
        if not roots.holstered then
            for i = #models, 1, -1 do
                if matchesRoot(models[i], family) then
                    roots.holstered = models[i]
                    break
                end
            end
        end
    end
    if roots.equipped then
        local cam = workspace.CurrentCamera
        local vm = cam and cam:FindFirstChild("ViewModel")
        local vmTool = vm and vm:FindFirstChild("Tool")
        if vmTool and matchesRoot(vmTool, family) then
            roots.firstPerson = vmTool
        elseif vmTool and #family.meshIds > 0 and countFamilyMeshes(vmTool, family) >= 1 then
            roots.firstPerson = vmTool
        end
    end
    return roots
end

local engine = {
    running = true,
    database = db,
    selections = {},  -- family -> skin ID; G18 can independently select a G17 skin
    baseline = setmetatable({}, {__mode = "k"}),
    overlays = {},    -- family -> context -> {root, skinId, holder, sourceKey}
    hidden = {},      -- family -> part -> original LocalTransparencyModifier
    lastStatus = {},
    warned = {},
    fxOriginals = setmetatable({}, {__mode = "k"}), -- emitter -> original cosmetic properties
    hideStepName = "SkinChangerCosmeticHide_" .. tostring(player.UserId),
    hideStepConnected = false,
    renderConnection = nil,
}
local function warnOnce(key, ...)
    if engine.warned[key] then return end
    engine.warned[key] = true
    warn(...)
end

function engine:remember(part)
    if self.baseline[part] then return end
    local sa = part:FindFirstChildOfClass("SurfaceAppearance")
    self.baseline[part] = {
        texture = part.TextureID,
        color = part.Color,
        material = part.Material,
        reflectance = part.Reflectance,
        sa = sa and sa:Clone() or false,
        transparency = part.LocalTransparencyModifier,
    }
end
function engine:applySurface(part, wanted, remove)
    local current = part:FindFirstChildOfClass("SurfaceAppearance")
    if remove then
        if current then current:Destroy() end
        return
    end
    if not wanted then return end
    if not current then
        current = Instance.new("SurfaceAppearance")
        current.Parent = part
    end
    for _, key in ipairs(KEY_MAPS) do
        local id = wanted[key]
        if id then
            if ident(current[key]) ~= ident(id) then
                current[key] = asset(id)
            end
        else
            -- Partial PBR record: a LIVE mesh must not inherit missing
            -- map fields from the previously selected skin.
            -- For exact cosmetic clones, preserve the source's own maps.
            local original = self.baseline[part]
            if original then
                local baselineMap = original.sa and original.sa[key] or ""
                if current[key] ~= baselineMap then
                    current[key] = baselineMap
                end
            end
        end
    end
end

function engine:applyAppearance(part, record, isClone)
    if not isClone then self:remember(part) end
    local override = record.meshOverrides and record.meshOverrides[ident(part.MeshId)]
    local wantedTexture = (override and override.TextureID) or record.textureID
    if wantedTexture then
        if ident(part.TextureID) ~= ident(wantedTexture) then
            part.TextureID = asset(wantedTexture)
        end
    else
        -- The new PBR-only skin has no known base texture. Restore the
        -- original baseline instead of leaving the previous skin's TextureID.
        local original = self.baseline[part]
        if original and part.TextureID ~= original.texture then
            part.TextureID = original.texture
        end
    end
    -- Do NOT mutate MeshId, Size, CFrame, SpecialMesh.Scale, or physical state.
    self:applySurface(part, record.surfaceAppearance, record.removeSurfaceAppearance)
end

function engine:restorePart(part)
    local old = self.baseline[part]
    if not old or not part.Parent then return end
    pcall(function()
        part.TextureID = old.texture
        part.Color = old.color
        part.Material = old.material
        part.Reflectance = old.reflectance
        part.LocalTransparencyModifier = old.transparency
        local current = part:FindFirstChildOfClass("SurfaceAppearance")
        if current then current:Destroy() end
        if old.sa then old.sa:Clone().Parent = part end
    end)
end
function engine:restoreFamilyAppearance(familyName)
    local family = db.families[familyName]
    if not family then return end
    local ids = {}
    for _, mesh in ipairs(family.meshIds or {}) do ids[tostring(mesh)] = true end
    for part, _ in pairs(self.baseline) do
        if part.Parent and ids[ident(part.MeshId)] then self:restorePart(part) end
    end
end
function engine:clearOverlays(familyName)
    local overlays = self.overlays[familyName]
    if overlays then
        for _, entry in pairs(overlays) do
            if entry.holder and entry.holder.Parent then entry.holder:Destroy() end
        end
    end
    self.overlays[familyName] = nil
    local hidden = self.hidden[familyName]
    if hidden then
        for part, old in pairs(hidden) do
            if part.Parent then pcall(function() part.LocalTransparencyModifier = old end) end
        end
    end
    self.hidden[familyName] = nil
end
local function sourcePreview(name)
    local playerGui = player:FindFirstChild("PlayerGui")
    if not playerGui then return nil end
    for _, obj in ipairs(playerGui:GetDescendants()) do
        if obj.Name == name and (obj:IsA("Model") or obj:IsA("Folder") or obj:IsA("Frame")) then
            local found = obj:FindFirstChildWhichIsA("MeshPart", true)
            if found then return obj end
        end
    end
    return nil
end
local function sourceVariant(path)
    if type(path) ~= "string" or not path:match("^ReplicatedStorage%.") then return nil end
    local node = RS
    for component in path:gmatch("[^%.]+") do
        if component ~= "ReplicatedStorage" then
            node = node:FindFirstChild(component)
            if not node then return nil end
        end
    end
    if node:IsA("Model") then return node end
    return nil
end
local function cleanCosmetic(root)
    -- Never permit modules/scripts or source welds to execute/attach gameplay.
    for _, obj in ipairs(root:GetDescendants()) do
        if obj:IsA("LuaSourceContainer") or obj:IsA("JointInstance") or obj:IsA("WeldConstraint") then
            obj:Destroy()
        end
    end
    local visualParts = root:GetDescendants()
    if root:IsA("BasePart") then table.insert(visualParts, root) end
    for _, obj in ipairs(visualParts) do
        if obj:IsA("BasePart") then
            obj.Anchored = false
            obj.CanCollide = false
            obj.CanTouch = false
            obj.CanQuery = false
            obj.Massless = true
        end
    end
end
local function cosmeticsHolder(root)
    local holder = Instance.new("Model")
    holder.Name = "__SkinChangerOverlay"
    return holder
end
local function placeAndWeld(part, liveAnchor, rel)
    part.CFrame = liveAnchor.CFrame * rel
    local weld = Instance.new("WeldConstraint")
    weld.Name = "__SkinChangerCosmeticWeld"
    weld.Part0 = liveAnchor
    weld.Part1 = part
    weld.Parent = part
end
function engine:buildVariant(root, record)
    local src = sourceVariant(record.sourcePath)
    local liveAnchor = anchorFor(root)
    if not src or not liveAnchor then return nil, "missing source model or live anchor" end
    local srcAnchor = anchorFor(src)
    if not srcAnchor then return nil, "missing source anchor" end
    local sourceParts = {}
    for _, obj in ipairs(src:GetDescendants()) do
        if obj:IsA("BasePart") then sourceParts[#sourceParts+1] = obj end
    end
    if #sourceParts == 0 then return nil, "source has no parts" end
    -- Clone while unparented; strip source scripts/joints before adding to Workspace.
    local holder = cosmeticsHolder(root)
    local replica = src:Clone()
    replica.Parent = holder
    cleanCosmetic(replica)
    local copiedParts = {}
    for _, obj in ipairs(replica:GetDescendants()) do
        if obj:IsA("BasePart") then copiedParts[#copiedParts+1] = obj end
    end
    if #copiedParts ~= #sourceParts then holder:Destroy() return nil, "source/clone parts differ" end
    for i, clonePart in ipairs(copiedParts) do
        local original = sourceParts[i]
        local overrides = record.sourceMeshOverrides
        local perMesh = overrides and overrides[ident(original.MeshId)]
        if perMesh and clonePart:IsA("MeshPart") then
            if perMesh.textureID and ident(clonePart.TextureID) ~= ident(perMesh.textureID) then
                clonePart.TextureID = asset(perMesh.textureID)
            end
            self:applySurface(clonePart, perMesh.surfaceAppearance, false)
        elseif record.missingSurfaceFallback and clonePart:IsA("MeshPart")
            and not clonePart:FindFirstChildOfClass("SurfaceAppearance") then
            self:applySurface(clonePart, record.missingSurfaceFallback, false)
        end
        placeAndWeld(clonePart, liveAnchor, srcAnchor.CFrame:ToObjectSpace(original.CFrame))
    end
    holder.Parent = root
    return holder
end
function engine:buildModelSwap(root, record)
    local geom = db.modelSwapGeometry[record.geometryRef]
    if not geom then return nil, "missing geometry record" end
    local preview = sourcePreview(record.sourcePreviewName)
    local liveAnchor = anchorFor(root)
    if not preview or not liveAnchor then return nil, "missing preview geometry or live anchor" end
    local holder = cosmeticsHolder(root)
    for _, partRecord in ipairs(geom.parts or {}) do
        local wantedMesh = ident(partRecord.MeshId)
        local sourcePart
        for _, obj in ipairs(preview:GetDescendants()) do
            if obj:IsA("MeshPart") and ident(obj.MeshId) == wantedMesh then
                sourcePart = obj
                break
            end
        end
        if not sourcePart then
            holder:Destroy()
            return nil, "missing imported preview MeshPart " .. wantedMesh
        end
        local cosmetic = sourcePart:Clone()
        cleanCosmetic(cosmetic)
        -- The exact imported mesh is cloned; no MeshId+Size reconstruction.
        cosmetic.Parent = holder
        if record.surfaceAppearance then self:applySurface(cosmetic, record.surfaceAppearance, false) end
        local rel = partRecord.relativeCFrame
        if not rel or #rel ~= 12 then
            holder:Destroy()
            return nil, "invalid relative transform"
        end
        placeAndWeld(cosmetic, liveAnchor, CFrame.new(table.unpack(rel)))
    end
    holder.Parent = root
    return holder
end
-- Record original LTM once, and never hide a cosmetic overlay as if it were the source.
-- `holder == nil` is intentional for a persistent holstered original while the
-- equipped cosmetic replaces it; the old holstered clone is destroyed separately.
function engine:hideOriginal(familyName, root, holder)
    if not root then return end
    self.hidden[familyName] = self.hidden[familyName] or setmetatable({}, {__mode = "k"})
    local tracked = self.hidden[familyName]
    for _, part in ipairs(root:GetDescendants()) do
        if part:IsA("MeshPart") and not part:FindFirstAncestor("__SkinChangerOverlay")
            and (not holder or not part:IsDescendantOf(holder)) then
            if tracked[part] == nil then tracked[part] = part.LocalTransparencyModifier end
            part.LocalTransparencyModifier = 1
        end
    end
end

-- Camera/weapon scripts can overwrite LocalTransparencyModifier every frame.
-- A 0.35-second polling loop alone permits a brief flash of the old skin.
-- Force existing tracked originals invisible late in the local render frame;
-- no geometry, gameplay or replicated Transparency property is changed here.
function engine:enforceHidden()
    if not self.running then return end
    for familyName, tracked in pairs(self.hidden) do
        local skinId = self.selections[familyName]
        local record = skinId and db.skins[skinId]
        if record and (record.kind == "variantModel" or record.kind == "modelSwap") then
            for part in pairs(tracked) do
                if part.Parent then
                    if part.LocalTransparencyModifier ~= 1 then
                        part.LocalTransparencyModifier = 1
                    end
                else
                    tracked[part] = nil
                end
            end
        end
    end
end

function engine:refreshFamily(familyName)
    local skinId = self.selections[familyName]
    local record = skinId and db.skins[skinId]
    local family = db.families[familyName]
    if not record or not family or not record.available then return end
    local roots = findRoots(family)
    if record.kind == "appearance" then
        if self.overlays[familyName] then self:clearOverlays(familyName) end
        local allowed = {}
        for _, mid in ipairs(record.meshIds or {}) do allowed[tostring(mid)] = true end
        -- Family selectors add previously tested holstered/reload alternatives
        -- not present in a store-preview candidate's exact MeshId list.
        for _, mid in ipairs(family.meshIds or {}) do allowed[tostring(mid)] = true end
        for _, mid in ipairs(family.excludedMeshIds or {}) do allowed[tostring(mid)] = nil end
        local counts = {}
        for ctx, root in pairs(roots) do
            local n = 0
            for _, part in ipairs(root:GetDescendants()) do
                if ownContextPart(part) and allowed[ident(part.MeshId)] then
                    self:applyAppearance(part, record, false)
                    n += 1
                end
            end
            counts[ctx] = n
        end
        self.lastStatus[familyName] = counts
        return
    end
    if record.kind ~= "variantModel" and record.kind ~= "modelSwap" then return end
    local overlays = self.overlays[familyName] or {}
    self.overlays[familyName] = overlays
    -- Holster clone is destroyed while equipped.  Also hide the original
    -- holstered gun in this state: the game may still render it during a
    -- first-person/third-person zoom transition.
    local activeContexts = roots.equipped and {equipped = roots.equipped, firstPerson = roots.firstPerson}
        or {holstered = roots.holstered}
    for ctx, entry in pairs(overlays) do
        if entry.root ~= activeContexts[ctx] or entry.skinId ~= skinId
            or not entry.holder or not entry.holder.Parent then
            if entry.holder and entry.holder.Parent then entry.holder:Destroy() end
            overlays[ctx] = nil
        end
    end
    for ctx, root in pairs(activeContexts) do
        if root and not overlays[ctx] then
            local holder, err
            if record.kind == "variantModel" then
                holder, err = self:buildVariant(root, record)
            else
                holder, err = self:buildModelSwap(root, record)
            end
            if holder then
                overlays[ctx] = {root = root, holder = holder, skinId = skinId}
            else
                warnOnce("source:" .. skinId .. ":" .. ctx,
                    "[SkinChanger] Could not build " .. skinId .. " " .. ctx .. ": " .. tostring(err))
            end
        end
    end

    -- Track which originals must stay invisible. Never hide a new live weapon
    -- when its corresponding replacement was not successfully constructed.
    local hideRoots = {}
    for ctx, root in pairs(activeContexts) do
        local entry = overlays[ctx]
        if root and entry and entry.holder and entry.holder.Parent then
            hideRoots[root] = true
            self:hideOriginal(familyName, root, entry.holder)
        end
    end
    if roots.equipped and roots.holstered and overlays.equipped
        and overlays.equipped.holder and overlays.equipped.holder.Parent then
        -- The actual back model can persist briefly even when equipped.
        hideRoots[roots.holstered] = true
        self:hideOriginal(familyName, roots.holstered, nil)
    end

    -- Unhide parts from roots that should no longer be hidden. This ensures
    -- the holstered gun isn't left invisible if the overlay cannot be built.
    local tracked = self.hidden[familyName]
    if tracked then
        for part, old in pairs(tracked) do
            local shouldHide = false
            if part.Parent then
                for root in pairs(hideRoots) do
                    if part:IsDescendantOf(root) then
                        shouldHide = true
                        break
                    end
                end
            end
            if not shouldHide then
                if part.Parent then part.LocalTransparencyModifier = old end
                tracked[part] = nil
            end
        end
    end
    self:enforceHidden()
end
-- Optional purely local, data-driven cosmetics. The Gold SKS record sets
-- particle tint only; no gameplay modules, firing hooks, or sounds are run.
function engine:restoreCosmeticEffects()
    for emitter, previous in pairs(self.fxOriginals) do
        if emitter.Parent then
            pcall(function()
                emitter.Color = previous.Color
                emitter.Brightness = previous.Brightness
                emitter.LightEmission = previous.LightEmission
            end)
        end
        self.fxOriginals[emitter] = nil
    end
end

function engine:refreshCosmeticEffects()
    local seen = {}
    for familyName, skinId in pairs(self.selections) do
        local record = db.skins[skinId]
        local fx = record and record.cosmeticEffects
        local tint = fx and fx.particleTint
        if tint and type(tint.rgb) == "table" and #tint.rgb == 3 then
            local family = db.families[familyName]
            local roots = family and findRoots(family) or {}
            local desired = ColorSequence.new(Color3.fromRGB(
                tint.rgb[1], tint.rgb[2], tint.rgb[3]
            ))
            -- Only currently held weapon and its first-person counterpart.
            -- Do not change the on-back model, other weapons, or cloned overlays.
            for _, context in ipairs({"equipped", "firstPerson"}) do
                local root = roots[context]
                if root then
                    for _, emitter in ipairs(root:GetDescendants()) do
                        if emitter:IsA("ParticleEmitter")
                            and not emitter:FindFirstAncestor("__SkinChangerOverlay") then
                            seen[emitter] = true
                            if not self.fxOriginals[emitter] then
                                self.fxOriginals[emitter] = {
                                    Color = emitter.Color,
                                    Brightness = emitter.Brightness,
                                    LightEmission = emitter.LightEmission,
                                }
                            end
                            -- The game's own effect logic may replace these values.
                            -- Reapply only when needed, preserving the original snapshot.
                            local ok = pcall(function()
                                emitter.Color = desired
                                emitter.Brightness = tint.brightness or 15
                                emitter.LightEmission = tint.lightEmission or 1
                            end)
                            if not ok then
                                warnOnce("fx:" .. skinId,
                                    "[SkinChanger] Could not tint a cosmetic particle emitter for " .. skinId)
                            end
                        end
                    end
                end
            end
        end
    end
    -- Change to another skin, holster, switch weapons, or lose the old VM:
    -- the original emitter properties must be restored promptly.
    for emitter, previous in pairs(self.fxOriginals) do
        if not seen[emitter] then
            if emitter.Parent then
                pcall(function()
                    emitter.Color = previous.Color
                    emitter.Brightness = previous.Brightness
                    emitter.LightEmission = previous.LightEmission
                end)
            end
            self.fxOriginals[emitter] = nil
        end
    end
end

function engine:refresh()
    if not self.running then return end
    for familyName in pairs(self.selections) do
        local okRefresh, err = pcall(function() self:refreshFamily(familyName) end)
        if not okRefresh then
            warnOnce("refresh:" .. familyName .. ":" .. tostring(err),
                "[SkinChanger] Refresh error for " .. familyName .. ": " .. tostring(err))
        end
    end
    local okFx, fxErr = pcall(function() self:refreshCosmeticEffects() end)
    if not okFx then warnOnce("fx-refresh:" .. tostring(fxErr),
        "[SkinChanger] Cosmetic FX refresh error:", fxErr) end
end
function engine:setSkin(skinId, familyOverride)
    if not self.running then warn("[SkinChanger] Disabled; reinstall to enable.") return false end
    local record = db.skins[skinId]
    if not record or not record.available then
        warn("[SkinChanger] Skin not available:", skinId)
        return false
    end
    local target = familyOverride or record.family
    local family = db.families[target]
    if not family or (target ~= record.family and family.skinSourceFamily ~= record.family) then
        warn("[SkinChanger] Skin/family mismatch:", tostring(skinId), tostring(target))
        return false
    end
    if self.selections[target] ~= skinId then
        self:clearOverlays(target)
        self.selections[target] = skinId
    end
    self:refreshFamily(target)
    self:refreshCosmeticEffects()
    self:enforceHidden()
    local counts = self.lastStatus[target] or {}
    print("[SkinChanger]", skinId, "->", target,
        "equipped:", counts.equipped or 0,
        "FP:", counts.firstPerson or 0,
        "holstered:", counts.holstered or 0)
    if record.multiAppearanceNeedsReview then
        warnOnce("multi:" .. skinId, "[SkinChanger] This skin has additional per-part PBR maps awaiting mapping:", skinId)
    end
    return true
end
function engine:listSkins(familyName)
    local source = db.families[familyName] and (db.families[familyName].skinSourceFamily or familyName)
    if not source then warn("[SkinChanger] Unknown family:", familyName) return {} end
    local names = {}
    for id, rec in pairs(db.skins) do
        if rec.family == source and rec.available then names[#names+1] = id end
    end
    table.sort(names)
    print("[SkinChanger]", familyName, #names, "available skins:\n" .. table.concat(names, "\n"))
    return names
end
function engine:revert(familyName)
    if not self.running then return end
    if familyName then
        self:clearOverlays(familyName)
        self.selections[familyName] = nil
        -- All captured original appearances are restored. Other selected families
        -- are immediately reapplied by the next refresh tick.
    else
        for f in pairs(self.selections) do self:clearOverlays(f) end
        self.selections = {}
    end
    for part in pairs(self.baseline) do self:restorePart(part) end
    self:refreshCosmeticEffects()
    if familyName then self:refresh() end
    print("[SkinChanger] Reverted", familyName or "all families")
end
function engine:disable()
    if not self.running then return end
    self.running = false
    self:restoreCosmeticEffects()
    if self.hideStepConnected then
        pcall(function() RunService:UnbindFromRenderStep(self.hideStepName) end)
        self.hideStepConnected = false
    end
    if self.renderConnection then
        self.renderConnection:Disconnect()
        self.renderConnection = nil
    end
    for f in pairs(self.overlays) do self:clearOverlays(f) end
    for part, old in pairs(self.baseline) do
        self:restorePart(part)
        if old.sa then old.sa:Destroy() end
    end
    self.baseline = setmetatable({}, {__mode = "k"})
    self.selections = {}
    self.overlays = {}
    self.hidden = {}
    print("[SkinChanger] Disabled; originals restored.")
end

-- Late-frame visual masking prevents zoom/equip scripts from showing the
-- original underneath the replacement between normal refresh ticks.
local bound = pcall(function()
    RunService:BindToRenderStep(engine.hideStepName, Enum.RenderPriority.Last.Value + 10, function()
        engine:enforceHidden()
    end)
end)
if bound then
    engine.hideStepConnected = true
else
    engine.renderConnection = RunService.RenderStepped:Connect(function()
        engine:enforceHidden()
    end)
end

function engine:status(familyName)
    local family = db.families[familyName]
    if not family then warn("[SkinChanger] Unknown family:", tostring(familyName)) return end
    local roots = findRoots(family)
    local overlays = self.overlays[familyName] or {}
    print("[SkinChanger status]", familyName, "skin:", tostring(self.selections[familyName]),
        "equipped:", roots.equipped and roots.equipped:GetFullName() or "none",
        "FP:", roots.firstPerson and roots.firstPerson:GetFullName() or "none",
        "holster:", roots.holstered and roots.holstered:GetFullName() or "none")
    for _, ctx in ipairs({"equipped", "firstPerson", "holstered"}) do
        local entry = overlays[ctx]
        print("[SkinChanger overlay]", ctx, entry and entry.holder and entry.holder.Parent and "ACTIVE" or "none")
    end
end

G.SkinChanger = engine
task.spawn(function()
    while engine.running do
        engine:refresh()
        local hasReplacement = false
        for _, skinId in pairs(engine.selections) do
            local record = db.skins[skinId]
            if record and (record.kind == "variantModel" or record.kind == "modelSwap") then
                hasReplacement = true
                break
            end
        end
        task.wait(hasReplacement and 0.08 or 0.25)
    end
end)
print("[SkinChanger] GitHub core v0.4.3 started, database", db.version,
      "| select with getgenv().SkinChanger:setSkin('sks_m1garand')")
