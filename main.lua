local Players      = game:GetService("Players")
local UIS          = game:GetService("UserInputService")
local RS           = game:GetService("RunService")
local Workspace    = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local HttpService  = game:GetService("HttpService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

do
	local old = playerGui:FindFirstChild("GIGAMENU")
	if old then old:Destroy() end
end

local RGB = Color3.fromRGB
local WHITE, BLACK = Color3.new(1, 1, 1), Color3.new(0, 0, 0)

---------------------------------------------------------------
-- НАСТРОЙКИ
---------------------------------------------------------------
local CONFIG = {
	SCOOTER_NAME = "Kukirin G4",

	WHEELIE_KEY  = Enum.KeyCode.F,
	MENU_KEY     = Enum.KeyCode.RightShift,
	WHEELIE_HOLD = false,  -- true = вилли пока держишь клавишу, false = вкл/выкл по нажатию

	WHEELIE_ANGLE = 70,    -- градусов
	WHEELIE_POWER = 8,
	WHEELIE_RAMP  = 80,    -- град/сек

	-- Куда у PrimaryPart смотрит "нос" (локальные координаты).
	-- Используется, только если AUTO_FORWARD не смог определить направление сам.
	-- Если вместо вилли самокат задирает ЗАД — Vector3.new(0, 0, 1).
	FORWARD_LOCAL = Vector3.new(0, 0, -1),
	AUTO_FORWARD  = true,  -- определять "перед" по колёсам и рулю

	-- на время вилли отключать BodyGyro / AlignOrientation самоката (они держат его ровно)
	DISABLE_STABILIZERS = true,

	UNDERGLOW_HEIGHT = 0.08, -- высота источника света (доля высоты модели)
	GLOW_BRIGHTNESS  = 4,
	GLOW_RANGE       = 20,

	TRAIL_WIDTH    = nil,  -- nil = подобрать по колесу (в студах)
	TRAIL_LIFETIME = 1.2,

	STRETCH_VALUE = 0.75,  -- для пресета "Resolution 4:3"

	WHEELIE_BAR_COLLIDE = false, -- true = вилли-бар физически касается земли

	RAINBOW_SPEED  = 0.25, -- скорость радуги
	RAINBOW_SPREAD = 0.6,  -- насколько радуга "растянута" вдоль самоката (0 = весь одним цветом)
	SWEEP_INTERVAL = 0.1,  -- как часто перепроверять цвета (сек) — защита от игры, которая их сбрасывает

	STRIP_TEXTURES        = true, -- убирать SurfaceAppearance/TextureID при покраске (иначе цвет не виден)
	UNCLASSIFIED_TO_FRAME = true, -- если Frame не найден — красить неопознанные детали как раму
}

local PART_NAMES = {
	Frame      = {"Frame", "Body", "Deck"},
	Wheel      = {"FrontWheel", "BackWheel"},
	Handlebar  = {"Handlebar", "Bars", "Steering"},
	Suspension = {"Suspension", "Shock"},
	WheelieBar = {"WheelieBar"},
}

local GROUP_ORDER = {"WheelieBar", "Wheel", "Suspension", "Handlebar", "Frame"}
local GROUP_SET = {}
for _, g in ipairs(GROUP_ORDER) do GROUP_SET[g] = true end

local KEYWORDS = {
	WheelieBar = {"wheeliebar", "wheelie_bar", "wheelie bar"},
	Wheel      = {"wheel", "tire", "tyre", "rim"},
	Suspension = {"suspension", "shock", "spring", "fork"},
	Handlebar  = {"handlebar", "handle", "steer", "grip"},
	Frame      = {"frame", "body", "deck", "chassis", "stem"},
}

local BAR_FOLDER = "WheelieBarAdded"

---------------------------------------------------------------
-- СОСТОЯНИЕ
---------------------------------------------------------------
local state = {
	colors      = {},              -- [группа] = Color3 (nil = заводской)
	materials   = {},              -- [группа] = Enum.Material
	partColors  = {},              -- [путь детали] = Color3 (страница Test)
	underglow   = true,
	glowColor   = RGB(0, 90, 255),
	trail       = false,
	trailColor  = RGB(0, 255, 255),
	smokeColor  = nil,             -- nil = как в игре
	wheelieBar  = false,           -- нажали ADD
}

local settings = {stretch = false}
local rainbow  = {}                -- [цель] = true  (All / Trail / Underglow / Smoke / группа)
local wheelie  = {on = false, target = 0, stab = {}}

local conns = {}
local function connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(conns, c)
	return c
end

-- то, что определяется ниже (GUI), но нужно раньше
local notify, updateStatus, refreshTestList, closeTestPanel
local wheelieToggleUI, wbButtonUpdate
local testVisible = false

-- "перед" самоката в локальных координатах rootPart (обновляется при сканировании)
local FWD = CONFIG.FORWARD_LOCAL

local function getHumanoid()
	local c = player.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

---------------------------------------------------------------
-- ДВИЖОК ПОКРАСКИ
-- Цвет считается из state (деталь > группа), и принудительно
-- возвращается, если игра его сбросила (сразу по сигналу + раз в 0.1с).
---------------------------------------------------------------
local originals     = setmetatable({}, {__mode = "k"})
local partKeyOf     = setmetatable({}, {__mode = "k"})
local partGroupOf   = setmetatable({}, {__mode = "k"})
local phaseOf       = setmetatable({}, {__mode = "k"})
local hooked        = setmetatable({}, {__mode = "k"})

local groups = {}
for _, g in ipairs(GROUP_ORDER) do groups[g] = {} end
local unclassified, allParts, partsByKey, keyList = {}, {}, {}, {}
local scooter, rootPart, dirty, descConn = nil, nil, true, nil
local scanVersion = 0

local rainbowT, rainbowColor = 0, Color3.fromHSV(0, 1, 1)

local function stripTexture(p, force)
	if not CONFIG.STRIP_TEXTURES then return end
	local o = originals[p]
	if not o then return end
	if o.stripped and not force then return end
	o.stripped = true
	for _, ch in ipairs(p:GetChildren()) do
		if ch:IsA("SurfaceAppearance") then
			o.sa = o.sa or {}
			table.insert(o.sa, ch)
			ch.Parent = nil
		end
	end
	if p:IsA("MeshPart") and p.TextureID ~= "" then
		o.tex = p.TextureID
		pcall(function() p.TextureID = "" end)
	end
end

local function restoreTexture(p)
	local o = originals[p]
	if not o or not o.stripped then return end
	o.stripped = false
	if o.sa then
		for _, sa in ipairs(o.sa) do
			pcall(function() sa.Parent = p end)
		end
		o.sa = nil
	end
	if o.tex then
		local t = o.tex
		pcall(function() p.TextureID = t end)
		o.tex = nil
	end
end

local function sameColor(a, b)
	return math.abs(a.R - b.R) < 0.002 and math.abs(a.G - b.G) < 0.002 and math.abs(a.B - b.B) < 0.002
end

local function desiredColor(p)
	if rainbow.All then
		return Color3.fromHSV((rainbowT + (phaseOf[p] or 0)) % 1, 1, 1)
	end
	local pk = partKeyOf[p]
	local pc = pk and state.partColors[pk]
	if pc then return pc end
	local g = partGroupOf[p]
	if g then
		if rainbow[g] then return rainbowColor end
		return state.colors[g]
	end
	return nil
end

local function desiredMaterial(p)
	local g = partGroupOf[p]
	return g and state.materials[g] or nil
end

local function enforcePart(p)
	if not p.Parent then return end
	local want = desiredColor(p)
	if want then
		local o = originals[p]
		if o and not o.stripped then stripTexture(p) end
		if p:IsA("UnionOperation") and not p.UsePartColor then p.UsePartColor = true end
		if not sameColor(p.Color, want) then p.Color = want end
	end
	local m = desiredMaterial(p)
	if m and p.Material ~= m then p.Material = m end
end

local function hasPaint()
	return next(state.colors) ~= nil or next(state.materials) ~= nil
		or next(state.partColors) ~= nil or next(rainbow) ~= nil
end

local function enforceAll()
	if not hasPaint() then return end
	for _, p in ipairs(allParts) do enforcePart(p) end
end

-- вернуть всё в заводское и накатить текущее состояние заново
local function repaintAll()
	for _, p in ipairs(allParts) do
		local o = originals[p]
		if o and p.Parent then
			restoreTexture(p)
			if not sameColor(p.Color, o.Color) then p.Color = o.Color end
			if p.Material ~= o.Material then p.Material = o.Material end
			if o.UsePartColor ~= nil and p:IsA("UnionOperation") then p.UsePartColor = o.UsePartColor end
		end
	end
	enforceAll()
end

local function hookPart(p)
	if hooked[p] then return end
	hooked[p] = true
	local function recheck()
		if p.Parent and not rainbow.All then enforcePart(p) end
	end
	p:GetPropertyChangedSignal("Color"):Connect(recheck)
	p:GetPropertyChangedSignal("Material"):Connect(recheck)
	p.ChildAdded:Connect(function(ch)
		if ch:IsA("SurfaceAppearance") and desiredColor(p) then
			stripTexture(p, true)
		end
	end)
	if p:IsA("MeshPart") then
		p:GetPropertyChangedSignal("TextureID"):Connect(function()
			if desiredColor(p) and p.TextureID ~= "" then stripTexture(p, true) end
		end)
	end
end

---------------------------------------------------------------
-- САМОКАТ: поиск и группы деталей
---------------------------------------------------------------
local lastSearch = -100

local function isFx(obj)
	return obj.Name:sub(1, 5) == "GIGA_" or obj:FindFirstAncestor("GIGA_FX") ~= nil
end

local function classify(part)
	-- детали, которые добавили мы (кнопка ADD), всегда считаются вилли-баром
	if part.Parent and part.Parent.Name == BAR_FOLDER then return "WheelieBar" end
	for _, g in ipairs(GROUP_ORDER) do
		for _, n in ipairs(PART_NAMES[g]) do
			if part.Name == n then return g end
		end
	end
	local node = part
	while node and node ~= scooter do
		local ln = node.Name:lower()
		for _, g in ipairs(GROUP_ORDER) do
			for _, kw in ipairs(KEYWORDS[g]) do
				if ln:find(kw, 1, true) then return g end
			end
		end
		node = node.Parent
	end
	return nil
end

local function relPath(p)
	local names = {}
	local node = p
	while node and node ~= scooter do
		table.insert(names, 1, node.Name)
		node = node.Parent
	end
	if #names == 0 then return p.Name end
	return table.concat(names, "/")
end

local function normName(n)
	return (n:lower():gsub("[^%w]", ""))
end

local function searchScooter()
	local now = os.clock()
	if now - lastSearch < 2 then return nil end
	lastSearch = now
	local s = Workspace:FindFirstChild(CONFIG.SCOOTER_NAME, true)
	if s then return s end
	local needle = normName(CONFIG.SCOOTER_NAME)
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("Model") or d:IsA("BasePart") then
			local n = normName(d.Name)
			if n == needle or n:find("kukirin", 1, true) then return d end
		end
	end
	return nil
end

local function pickNearest(list)
	if #list <= 1 then return list[1] end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return list[1] end
	local best, bd = nil, math.huge
	for _, s in ipairs(list) do
		local pos = s:IsA("Model") and s:GetPivot().Position or s.Position
		local d = (pos - hrp.Position).Magnitude
		if d < bd then best, bd = s, d end
	end
	return best
end

local function directCandidates()
	local list = {}
	for _, c in ipairs(Workspace:GetChildren()) do
		if c.Name == CONFIG.SCOOTER_NAME and (c:IsA("Model") or c:IsA("BasePart")) then
			table.insert(list, c)
		end
	end
	return list
end

local function getScooter()
	local s = scooter
	-- если ты сидишь в самокате — это и есть наш самокат
	local hum = getHumanoid()
	local seat = hum and hum.SeatPart
	local ridden = seat and seat:FindFirstAncestor(CONFIG.SCOOTER_NAME)
	if ridden and ridden ~= scooter and (ridden:IsA("Model") or ridden:IsA("BasePart")) then
		s = ridden
	elseif not (s and s:IsDescendantOf(Workspace)) then
		s = pickNearest(directCandidates()) or searchScooter()
	end
	if s ~= scooter then
		scooter = s
		dirty = true
		if descConn then descConn:Disconnect() descConn = nil end
		if s then
			descConn = s.DescendantAdded:Connect(function() dirty = true end)
		end
	end
	return scooter
end

-- Определяем, куда у самоката "перед": нос = колесо, которое ближе к рулю.
local function detectForward()
	local root = rootPart
	if not root then return nil end
	local wheels = groups.Wheel
	if #wheels < 2 then return nil end

	local first = wheels[1]
	local endA, d1 = first, -1
	for _, w in ipairs(wheels) do
		local d = (w.Position - first.Position).Magnitude
		if d > d1 then endA, d1 = w, d end
	end
	local endB, d2 = endA, -1
	for _, w in ipairs(wheels) do
		local d = (w.Position - endA.Position).Magnitude
		if d > d2 then endB, d2 = w, d end
	end
	if d2 < 0.8 then return nil end

	local cA, nA, cB, nB = Vector3.zero, 0, Vector3.zero, 0
	for _, w in ipairs(wheels) do
		if (w.Position - endA.Position).Magnitude <= (w.Position - endB.Position).Magnitude then
			cA = cA + w.Position
			nA += 1
		else
			cB = cB + w.Position
			nB += 1
		end
	end
	if nA == 0 or nB == 0 then return nil end
	cA = cA / nA
	cB = cB / nB

	-- руль (или вилка) — ориентир переда
	local ref
	for _, g in ipairs({"Handlebar", "Suspension"}) do
		local list = groups[g]
		if #list > 0 then
			local c = Vector3.zero
			for _, p in ipairs(list) do c = c + p.Position end
			ref = c / #list
			break
		end
	end
	if not ref then return nil end

	local front, rear
	if (cA - ref).Magnitude < (cB - ref).Magnitude then
		front, rear = cA, cB
	else
		front, rear = cB, cA
	end

	local lv = root.CFrame:VectorToObjectSpace(front - rear)
	lv = Vector3.new(lv.X, 0, lv.Z)
	if lv.Magnitude < 0.3 then return nil end
	local ax, az = math.abs(lv.X), math.abs(lv.Z)
	if az > ax * 3 then
		return Vector3.new(0, 0, az / lv.Z)
	elseif ax > az * 3 then
		return Vector3.new(ax / lv.X, 0, 0)
	end
	return lv.Unit
end

local function rescan()
	for _, g in ipairs(GROUP_ORDER) do groups[g] = {} end
	unclassified, allParts, partsByKey, keyList = {}, {}, {}, {}
	rootPart = nil
	scanVersion += 1
	local s = scooter
	if not s then
		if updateStatus then updateStatus() end
		return
	end
	local biggest, biggestVol = nil, 0
	local list = s:GetDescendants()
	if s:IsA("BasePart") then table.insert(list, s) end
	for _, obj in ipairs(list) do
		if obj:IsA("BasePart") and not isFx(obj) then
			if not originals[obj] then
				local entry = {Color = obj.Color, Material = obj.Material, Transparency = obj.Transparency}
				if obj:IsA("UnionOperation") then entry.UsePartColor = obj.UsePartColor end
				originals[obj] = entry
			end
			hookPart(obj)
			local g = classify(obj)
			partGroupOf[obj] = g
			if g then table.insert(groups[g], obj) else table.insert(unclassified, obj) end
			table.insert(allParts, obj)
			local key = relPath(obj)
			partKeyOf[obj] = key
			local bucket = partsByKey[key]
			if not bucket then
				bucket = {}
				partsByKey[key] = bucket
				table.insert(keyList, key)
			end
			table.insert(bucket, obj)
			local vol = obj.Size.X * obj.Size.Y * obj.Size.Z
			-- вилли-бар (наш) не может быть корневой деталью
			if vol > biggestVol and obj.Parent and obj.Parent.Name ~= BAR_FOLDER then
				biggest, biggestVol = obj, vol
			end
		end
	end
	table.sort(keyList)
	if s:IsA("Model") and s.PrimaryPart then
		rootPart = s.PrimaryPart
	else
		rootPart = biggest
	end
	if CONFIG.UNCLASSIFIED_TO_FRAME and #groups.Frame == 0 then
		for _, p in ipairs(unclassified) do
			table.insert(groups.Frame, p)
			partGroupOf[p] = "Frame"
		end
	end

	-- куда у самоката "перед"
	FWD = CONFIG.FORWARD_LOCAL
	if CONFIG.AUTO_FORWARD then
		local f = detectForward()
		if f then FWD = f end
	end

	-- фаза радуги: позиция детали вдоль самоката
	if rootPart then
		local f = FWD
		local dist, lo, hi = {}, math.huge, -math.huge
		for _, p in ipairs(allParts) do
			local v = rootPart.CFrame:PointToObjectSpace(p.Position):Dot(f)
			dist[p] = v
			if v < lo then lo = v end
			if v > hi then hi = v end
		end
		local span = math.max(hi - lo, 0.001)
		for p, v in pairs(dist) do
			phaseOf[p] = (v - lo) / span * CONFIG.RAINBOW_SPREAD
		end
	end

	-- новые/пересозданные детали красим сразу же
	enforceAll()
	if updateStatus then updateStatus() end
end

local function ensure()
	getScooter()
	if dirty then
		dirty = false
		rescan()
	end
end

local function getRoot()
	ensure()
	return rootPart
end

local function getFxFolder()
	local s = getScooter()
	if not s then return nil end
	local f = s:FindFirstChild("GIGA_FX")
	if not f then
		f = Instance.new("Folder")
		f.Name = "GIGA_FX"
		f.Parent = s
	end
	return f
end

local function cleanupOld()
	local s = scooter
	if not s then return end
	for _, d in ipairs(s:GetDescendants()) do
		if d.Name:sub(1, 5) == "GIGA_" then d:Destroy() end
	end
end

local function getRearWheel(fwd)
	local rear, best = nil, math.huge
	for _, w in ipairs(groups.Wheel) do
		local d = w.Position:Dot(fwd)
		if d < best then best, rear = d, w end
	end
	return rear
end

local function debugPrint()
	ensure()
	print("[GIGAMENU] scooter:", scooter and scooter:GetFullName() or "НЕ НАЙДЕН (проверь CONFIG.SCOOTER_NAME)")
	print("[GIGAMENU] root part:", rootPart and rootPart:GetFullName() or "nil")
	print("[GIGAMENU] перед (локально):", FWD, CONFIG.AUTO_FORWARD and "(авто)" or "(CONFIG.FORWARD_LOCAL)")
	for _, g in ipairs(GROUP_ORDER) do
		local names = {}
		for _, p in ipairs(groups[g]) do table.insert(names, p.Name) end
		print(string.format("[GIGAMENU] %-10s (%d): %s", g, #names, table.concat(names, ", ")))
	end
	local un = {}
	for _, p in ipairs(unclassified) do table.insert(un, p.Name) end
	print(string.format("[GIGAMENU] без группы (%d): %s", #un, table.concat(un, ", ")))
end

-- следим за появлением нового самоката (респавн / клон при посадке) — ищем без задержки
connect(Workspace.DescendantAdded, function(d)
	if d.Name == CONFIG.SCOOTER_NAME and (d:IsA("Model") or d:IsA("BasePart")) then
		lastSearch = -100
		dirty = true
	end
end)

local function groupDisplayColor(g)
	if state.colors[g] then return state.colors[g] end
	ensure()
	local p = groups[g][1]
	local o = p and originals[p]
	return o and o.Color or RGB(255, 255, 255)
end

---------------------------------------------------------------
-- ГРАНИЦЫ МОДЕЛИ в локальных координатах root (для вилли-бара и андерглоу)
---------------------------------------------------------------
local function localBounds(root, model)
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	local list = model:GetDescendants()
	if model:IsA("BasePart") then table.insert(list, model) end
	for _, p in ipairs(list) do
		if p:IsA("BasePart") and not isFx(p) and not (p.Parent and p.Parent.Name == BAR_FOLDER) then
			local rel = root.CFrame:ToObjectSpace(p.CFrame)
			local h = p.Size / 2
			for _, sx in ipairs({-1, 1}) do
				for _, sy in ipairs({-1, 1}) do
					for _, sz in ipairs({-1, 1}) do
						local c = rel * Vector3.new(h.X * sx, h.Y * sy, h.Z * sz)
						minV = Vector3.new(math.min(minV.X, c.X), math.min(minV.Y, c.Y), math.min(minV.Z, c.Z))
						maxV = Vector3.new(math.max(maxV.X, c.X), math.max(maxV.Y, c.Y), math.max(maxV.Z, c.Z))
					end
				end
			end
		end
	end
	return minV, maxV
end

---------------------------------------------------------------
-- ВИЛЛИ-БАР (кнопка ADD): две распорки назад от заднего колеса + ролик-перекладина
---------------------------------------------------------------
local function newBarPart(folder, root, localCF, size)
	local p = Instance.new("Part")
	p.Name = "WheelieBar"
	p.Size = size
	p.Material = Enum.Material.Metal
	p.Color = RGB(28, 28, 30)
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Anchored = false
	p.CanCollide = CONFIG.WHEELIE_BAR_COLLIDE
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CFrame = root.CFrame * localCF
	p.Parent = folder
	local w = Instance.new("WeldConstraint")
	w.Part0 = root
	w.Part1 = p
	w.Parent = p
	return p
end

local function buildWheelieBar()
	ensure()
	local root, s = rootPart, scooter
	if not root or not s then return false end
	local old = s:FindFirstChild(BAR_FOLDER)
	if old then old:Destroy() end

	local fwd = root.CFrame:VectorToWorldSpace(FWD)
	local rear = getRearWheel(fwd)
	local back = -FWD.Unit
	local side = FWD:Cross(Vector3.yAxis).Unit
	local center, r, halfW
	if rear then
		center = root.CFrame:PointToObjectSpace(rear.Position)
		r = math.max(rear.Size.X, rear.Size.Y, rear.Size.Z) / 2
		halfW = math.min(rear.Size.X, rear.Size.Y, rear.Size.Z) / 2 + 0.2
	else
		local minV, maxV = localBounds(root, s)
		local size = maxV - minV
		local mid = (minV + maxV) / 2
		local half = math.abs(back.X) * size.X / 2 + math.abs(back.Z) * size.Z / 2
		center = Vector3.new(mid.X, minV.Y + 0.4, mid.Z) + back * half
		r, halfW = 0.4, 0.4
	end

	local t = math.clamp(r * 0.18, 0.08, 0.25)
	local a = center + back * (r * 0.4) + Vector3.new(0, r * 0.35, 0)
	local b = center + back * (r * 1.9) + Vector3.new(0, -r * 0.75, 0)

	local folder = Instance.new("Folder")
	folder.Name = BAR_FOLDER
	folder.Parent = s

	for _, sgn in ipairs({-1, 1}) do
		local A = a + side * (sgn * halfW)
		local B = b + side * (sgn * halfW)
		local len = (B - A).Magnitude
		newBarPart(folder, root, CFrame.lookAt((A + B) / 2, B), Vector3.new(t, t, len))
	end

	-- ролик на конце (ось вдоль самоката поперёк)
	local roller = newBarPart(folder, root, CFrame.fromMatrix(b, side, Vector3.yAxis),
		Vector3.new(halfW * 2 + t, t * 3, t * 3))
	roller.Shape = Enum.PartType.Cylinder

	dirty = true -- пересканируем: новые детали попадут в группу WheelieBar и сразу покрасятся
	return true
end

---------------------------------------------------------------
-- АНДЕРГЛОУ: только свет (невидимый источник, приварен к самокату)
---------------------------------------------------------------
local glow = {}

local function destroyGlow()
	if glow.part then glow.part:Destroy() end
	glow = {}
end

local function setGlowColorRaw(c)
	if glow.point   then glow.point.Color = c end
	if glow.surface then glow.surface.Color = c end
end

local function buildGlow()
	destroyGlow()
	if not state.underglow then return end
	local root = getRoot()
	local folder = getFxFolder()
	if not root or not folder then return end

	local minV, maxV = localBounds(root, scooter)
	local size = maxV - minV
	local center = (minV + maxV) / 2
	local y = minV.Y + math.max(size.Y * CONFIG.UNDERGLOW_HEIGHT, 0.12)

	local emitter = Instance.new("Part")
	emitter.Name = "GIGA_Underglow"
	emitter.Size = Vector3.new(0.2, 0.2, 0.2)
	emitter.Transparency = 1          -- блока не видно, светят только лампы
	emitter.CanCollide = false
	emitter.CanQuery = false
	emitter.CanTouch = false
	emitter.CastShadow = false
	emitter.Massless = true
	emitter.Material = Enum.Material.SmoothPlastic
	emitter.CFrame = root.CFrame * CFrame.new(center.X, y, center.Z)
	emitter.Parent = folder

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = emitter
	weld.Parent = emitter

	local c = state.glowColor
	local point = Instance.new("PointLight")
	point.Color = c
	point.Brightness = CONFIG.GLOW_BRIGHTNESS
	point.Range = CONFIG.GLOW_RANGE
	point.Shadows = false
	point.Parent = emitter

	local surf = Instance.new("SurfaceLight")
	surf.Face = Enum.NormalId.Bottom
	surf.Angle = 170
	surf.Color = c
	surf.Brightness = CONFIG.GLOW_BRIGHTNESS
	surf.Range = CONFIG.GLOW_RANGE
	surf.Shadows = false
	surf.Parent = emitter

	glow = {part = emitter, point = point, surface = surf, root = root}
end

---------------------------------------------------------------
-- ТРЕЙЛ: плоская полоса света по земле за задним колесом
---------------------------------------------------------------
local trail = {}

local function destroyTrail()
	for _, o in pairs(trail) do
		if typeof(o) == "Instance" then o:Destroy() end
	end
	trail = {}
end

local function buildTrail()
	destroyTrail()
	if not state.trail then return end
	local root = getRoot()
	if not root then return end

	local fwd = root.CFrame:VectorToWorldSpace(FWD)
	local rear = getRearWheel(fwd)
	local localPos, r, width
	if rear then
		localPos = root.CFrame:PointToObjectSpace(rear.Position)
		r = math.max(rear.Size.X, rear.Size.Y, rear.Size.Z) / 2
		width = math.clamp(math.min(rear.Size.X, rear.Size.Y, rear.Size.Z) * 2.5, 0.8, 3)
	else
		localPos = -FWD * (math.max(root.Size.X, root.Size.Z) / 2) + Vector3.new(0, -root.Size.Y / 2, 0)
		r = 0.3
		width = 1
	end
	width = CONFIG.TRAIL_WIDTH or width

	-- поперёк самоката (локальная "правая" ось) -> лента лежит плоско на земле
	local side = FWD:Cross(Vector3.yAxis).Unit
	local ground = localPos + Vector3.new(0, -r + 0.06, 0)

	local a0 = Instance.new("Attachment")
	a0.Name = "GIGA_TrailA0"
	a0.Position = ground - side * (width / 2)
	a0.Parent = root
	local a1 = Instance.new("Attachment")
	a1.Name = "GIGA_TrailA1"
	a1.Position = ground + side * (width / 2)
	a1.Parent = root

	local t = Instance.new("Trail")
	t.Name = "GIGA_Trail"
	t.Attachment0 = a0
	t.Attachment1 = a1
	t.Color = ColorSequence.new(state.trailColor)
	t.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 1)})
	t.LightEmission = 1
	t.Lifetime = CONFIG.TRAIL_LIFETIME
	t.MinLength = 0.05
	t.FaceCamera = false
	t.Parent = root

	trail = {obj = t, a0 = a0, a1 = a1}
end

---------------------------------------------------------------
-- ДЫМ (Burnout Smoke)
---------------------------------------------------------------
local smoke = {list = {}}
local smokeOrig = setmetatable({}, {__mode = "k"})

local function setSmokeColor(c)
	for _, e in ipairs(smoke.list) do e.Color = ColorSequence.new(c) end
	if smoke.own then smoke.own.Color = ColorSequence.new(c) end
end

local function restoreSmoke()
	for _, e in ipairs(smoke.list) do
		if smokeOrig[e] then e.Color = smokeOrig[e] end
	end
	if smoke.own then smoke.own.Color = ColorSequence.new(RGB(230, 230, 230)) end
end

local function destroySmoke()
	if smoke.own then smoke.own:Destroy() end
	if smoke.att then smoke.att:Destroy() end
	smoke = {list = {}}
end

local function buildSmoke()
	destroySmoke()
	local s = getScooter()
	local root = getRoot()
	if not s or not root then return end

	-- ищем дым, который уже есть в модели игры
	local list = {}
	for _, d in ipairs(s:GetDescendants()) do
		if d:IsA("ParticleEmitter") and not isFx(d) then
			local n = (d.Name .. " " .. (d.Parent and d.Parent.Name or "")):lower()
			if n:find("smoke", 1, true) or n:find("burnout", 1, true) then
				if not smokeOrig[d] then smokeOrig[d] = d.Color end
				table.insert(list, d)
			end
		end
	end
	smoke.list = list

	-- нет своего дыма в модели — делаем дым у заднего колеса (идёт пока включено вилли)
	if #list == 0 then
		local fwd = root.CFrame:VectorToWorldSpace(FWD)
		local rear = getRearWheel(fwd)
		local pos
		if rear then
			local r = math.max(rear.Size.X, rear.Size.Y, rear.Size.Z) / 2
			pos = root.CFrame:PointToObjectSpace(rear.Position) + Vector3.new(0, -r * 0.6, 0)
		else
			pos = -FWD * (math.max(root.Size.X, root.Size.Z) / 2) + Vector3.new(0, -root.Size.Y / 2, 0)
		end
		local att = Instance.new("Attachment")
		att.Name = "GIGA_SmokeAtt"
		att.CFrame = CFrame.lookAt(pos, pos - FWD)
		att.Parent = root

		local e = Instance.new("ParticleEmitter")
		e.Name = "GIGA_Smoke"
		e.Texture = "rbxasset://textures/particles/smoke_main.dds"
		e.Color = ColorSequence.new(RGB(230, 230, 230))
		e.Rate = 45
		e.Lifetime = NumberRange.new(0.7, 1.3)
		e.Speed = NumberRange.new(4, 8)
		e.SpreadAngle = Vector2.new(20, 20)
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-60, 60)
		e.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 4)})
		e.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1)})
		e.EmissionDirection = Enum.NormalId.Front
		e.Enabled = wheelie.on
		e.Parent = att
		smoke.own = e
		smoke.att = att
	end

	if state.smokeColor then setSmokeColor(state.smokeColor) end
end

---------------------------------------------------------------
-- RAINBOW (All = весь Kukirin, либо по каждой цели отдельно)
---------------------------------------------------------------
local function savedColor(target)
	if target == "Underglow" then return state.glowColor end
	if target == "Trail" then return state.trailColor end
	if target == "Smoke" then return state.smokeColor end
	return state.colors[target]
end

local function setRainbow(target, on)
	rainbow[target] = on or nil
	if on then return end
	if target == "Underglow" then
		setGlowColorRaw(state.glowColor)
	elseif target == "Trail" then
		if trail.obj then trail.obj.Color = ColorSequence.new(state.trailColor) end
	elseif target == "Smoke" then
		if state.smokeColor then setSmokeColor(state.smokeColor) else restoreSmoke() end
	else
		repaintAll() -- All или группа деталей
	end
end

local function stopAllRainbow()
	local had = next(rainbow) ~= nil
	for k in pairs(rainbow) do rainbow[k] = nil end
	if had then
		setGlowColorRaw(state.glowColor)
		if trail.obj then trail.obj.Color = ColorSequence.new(state.trailColor) end
		if state.smokeColor then setSmokeColor(state.smokeColor) else restoreSmoke() end
	end
end

---------------------------------------------------------------
-- ПОДСВЕТКА ДЕТАЛИ НА САМОКАТЕ (страница Test)
---------------------------------------------------------------
local hlList = {}

local function clearHighlight()
	for _, h in ipairs(hlList) do h:Destroy() end
	hlList = {}
end

local function highlightKey(key)
	clearHighlight()
	local list = partsByKey[key]
	local folder = getFxFolder()
	if not list or not folder then return end
	for i, p in ipairs(list) do
		if i > 30 then break end
		local h = Instance.new("Highlight")
		h.Name = "GIGA_Highlight"
		h.Adornee = p
		h.FillColor = RGB(0, 220, 255)
		h.OutlineColor = WHITE
		h.FillTransparency = 0.8
		h.OutlineTransparency = 0
		h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		h.Parent = folder
		table.insert(hlList, h)
	end
end

---------------------------------------------------------------
-- ГЛАВНЫЙ ЦИКЛ КАДРА: радуга, быстрая проверка цветов, пульс подсветки
---------------------------------------------------------------
local sweepAcc = 0
connect(RS.RenderStepped, function(dt)
	rainbowT = os.clock() * CONFIG.RAINBOW_SPEED
	rainbowColor = Color3.fromHSV(rainbowT % 1, 1, 1)

	-- что-то добавилось/пересоздалось в самокате — пересканируем и красим ДО отрисовки кадра
	if dirty then ensure() end

	local needParts = rainbow.All
	if not needParts then
		for k in pairs(rainbow) do
			if GROUP_SET[k] then needParts = true break end
		end
	end
	sweepAcc += dt
	if needParts or sweepAcc >= CONFIG.SWEEP_INTERVAL then
		sweepAcc = 0
		enforceAll()
	end

	if rainbow.Underglow then setGlowColorRaw(rainbowColor) end
	if rainbow.Trail and trail.obj then
		trail.obj.Color = ColorSequence.new(rainbowColor, Color3.fromHSV((rainbowT - 0.15) % 1, 1, 1))
	end
	if rainbow.Smoke then setSmokeColor(rainbowColor) end

	if #hlList > 0 then
		local k = math.sin(os.clock() * 6) * 0.5 + 0.5
		for _, h in ipairs(hlList) do
			h.FillTransparency = 0.7 + 0.3 * k
			h.OutlineTransparency = 0.3 * (1 - k)
		end
	end
end)

---------------------------------------------------------------
-- ВИЛЛИ (F)
-- Каждый кадр (Stepped = ДО физики) доводим тангаж самоката до целевого угла,
-- вращая его вокруг оси заднего колеса, чтобы колесо не вдавливалось в землю.
-- Пока вилли включено, "стабилизаторы" игры (BodyGyro/AlignOrientation) выключены.
---------------------------------------------------------------
function wheelie.hold()
	local s = scooter
	if not s or not CONFIG.DISABLE_STABILIZERS then return end
	for _, d in ipairs(s:GetDescendants()) do
		if not wheelie.stab[d] and not isFx(d) then
			if d:IsA("BodyGyro") then
				wheelie.stab[d] = d.MaxTorque
				d.MaxTorque = Vector3.zero
			elseif d:IsA("AlignOrientation") then
				wheelie.stab[d] = d.Enabled
				d.Enabled = false
			end
		end
	end
end

function wheelie.release()
	for d, saved in pairs(wheelie.stab) do
		if d.Parent then
			pcall(function()
				if typeof(saved) == "Vector3" then
					d.MaxTorque = saved
				else
					d.Enabled = saved
				end
			end)
		end
	end
	wheelie.stab = {}
end

local function setWheelie(on)
	wheelie.on = on
	if wheelieToggleUI then wheelieToggleUI.set(on) end
	if smoke.own then smoke.own.Enabled = on end
	if on then
		ensure()
		if not scooter and notify then notify("Scooter not found") end
		wheelie.hold()
	end
end

local function stepWheelie(dt)
	local goal = wheelie.on and CONFIG.WHEELIE_ANGLE or 0
	local maxStep = CONFIG.WHEELIE_RAMP * dt
	wheelie.target = wheelie.target + math.clamp(goal - wheelie.target, -maxStep, maxStep)
	if not wheelie.on and wheelie.target < 0.05 then
		wheelie.target = 0
		if next(wheelie.stab) then wheelie.release() end
		return
	end

	local root = getRoot()
	if not root or root.Anchored then return end

	local fwd = root.CFrame:VectorToWorldSpace(FWD).Unit
	local right = fwd:Cross(Vector3.yAxis)
	if right.Magnitude < 0.1 then return end
	right = right.Unit

	local pitch = math.deg(math.asin(math.clamp(fwd.Y, -1, 1)))
	local err = wheelie.target - pitch

	local w = root.AssemblyAngularVelocity
	local rate = w:Dot(right)
	local want = math.clamp(math.rad(err) * CONFIG.WHEELIE_POWER, -5, 5)
	local newRate = rate + (want - rate) * math.clamp(dt * 30, 0, 1)
	local newW = w + right * (newRate - rate)

	local rear = getRearWheel(fwd)
	if rear then
		-- скорость заднего колеса не меняем: вращаемся вокруг него
		local com = root.AssemblyCenterOfMass
		local vRear = root.AssemblyLinearVelocity + w:Cross(rear.Position - com)
		root.AssemblyAngularVelocity = newW
		root.AssemblyLinearVelocity = vRear + newW:Cross(com - rear.Position)
	else
		root.AssemblyAngularVelocity = newW
	end
end

connect(RS.Stepped, function(_, dt)
	stepWheelie(dt)
end)

---------------------------------------------------------------
-- ПРИМЕНИТЬ ВСЁ + watchdog (респавн самоката, посадка/слезание)
---------------------------------------------------------------
local printedDebug = false

local function applyAll()
	ensure()
	enforceAll()
	buildGlow()
	buildTrail()
	buildSmoke()
	if state.wheelieBar and scooter and not scooter:FindFirstChild(BAR_FOLDER) then
		buildWheelieBar()
	end
	local total = 0
	for _, g in ipairs(GROUP_ORDER) do total = total + #groups[g] end
	if total == 0 then
		warn("[GIGAMENU] детали самоката не распознаны — смотри вывод ниже и впиши имена в PART_NAMES")
	end
	if not printedDebug then
		printedDebug = true
		debugPrint()
	end
end

local appliedTo, wdAcc = nil, 1
connect(RS.Heartbeat, function(dt)
	wdAcc += dt
	if wdAcc < 0.25 then return end
	wdAcc = 0

	ensure()
	local s = scooter

	if s ~= appliedTo then
		wheelie.stab = {}
		appliedTo = s
		if s then
			cleanupOld()
			dirty = true
			ensure()
			applyAll()
		end
	elseif s then
		if state.underglow and (not glow.part or not glow.part.Parent or glow.root ~= rootPart) then buildGlow() end
		if state.trail and (not trail.obj or not trail.obj.Parent) then buildTrail() end
		if state.wheelieBar and not s:FindFirstChild(BAR_FOLDER) then buildWheelieBar() end
		if wheelie.on then wheelie.hold() end
	end

	if updateStatus then updateStatus() end
	if testVisible and refreshTestList then refreshTestList(false) end
end)

-- посадка / слезание: сразу пересканируем самокат
do
	local function watchCharacter(char)
		local hum = char:WaitForChild("Humanoid", 10)
		if not hum then return end
		hum:GetPropertyChangedSignal("SeatPart"):Connect(function()
			dirty = true
			wdAcc = 1
		end)
	end
	if player.Character then task.spawn(watchCharacter, player.Character) end
	connect(player.CharacterAdded, function(char) task.spawn(watchCharacter, char) end)
end

---------------------------------------------------------------
-- СОХРАНЕНИЕ ТЕМ: данные <-> Cloud key
---------------------------------------------------------------
local ui = {refreshers = {}}
local function syncUI()
	for _, fn in ipairs(ui.refreshers) do fn() end
end

local hex, encodeKey, decodeKey, captureData, applyData
do
function hex(c)
	return string.format("%02x%02x%02x", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

local function unhex(s)
	if type(s) ~= "string" or #s ~= 6 then return nil end
	local r, g, b = tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16)
	if r and g and b then return RGB(r, g, b) end
	return nil
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B64IDX = {}
for i = 1, #B64 do B64IDX[B64:byte(i)] = i - 1 end

local function b64enc(s)
	local out, n = {}, 0
	for i = 1, #s, 3 do
		local a, b, c = s:byte(i, i + 2)
		local v = a * 65536 + (b or 0) * 256 + (c or 0)
		local c1 = bit32.rshift(v, 18) % 64
		local c2 = bit32.rshift(v, 12) % 64
		local c3 = bit32.rshift(v, 6) % 64
		local c4 = v % 64
		local piece = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
		if b then piece = piece .. B64:sub(c3 + 1, c3 + 1) end
		if c then piece = piece .. B64:sub(c4 + 1, c4 + 1) end
		n += 1
		out[n] = piece
	end
	return table.concat(out)
end

local function b64dec(s)
	local out = {}
	for i = 1, #s, 4 do
		local chunk = s:sub(i, i + 3)
		local cnt = #chunk
		if cnt == 1 then return nil end
		local v = 0
		for j = 1, 4 do
			local ch = chunk:byte(j)
			local x = ch and B64IDX[ch]
			if ch and not x then return nil end
			v = v * 64 + (x or 0)
		end
		table.insert(out, string.char(bit32.rshift(v, 16) % 256))
		if cnt >= 3 then table.insert(out, string.char(bit32.rshift(v, 8) % 256)) end
		if cnt == 4 then table.insert(out, string.char(v % 256)) end
	end
	return table.concat(out)
end

local KEY_PREFIX = "GM1"

local function checksum(s)
	local h = 7
	for i = 1, #s do h = (h * 31 + s:byte(i)) % 65521 end
	return string.format("%04x", h)
end

function encodeKey(d)
	local ok, json = pcall(function() return HttpService:JSONEncode(d) end)
	if not ok then return nil end
	local payload = b64enc(json)
	return KEY_PREFIX .. "." .. payload .. "." .. checksum(payload)
end

function decodeKey(key)
	key = (tostring(key or ""):gsub("%s+", ""))
	if key == "" then return nil, "empty" end
	if #key > 40000 then return nil, "too long" end
	local prefix, payload, sum = key:match("^(%w+)%.([%w%-_]+)%.(%x+)$")
	if prefix ~= KEY_PREFIX then return nil, "wrong format" end
	if checksum(payload) ~= sum then return nil, "key is damaged" end
	local json = b64dec(payload)
	if not json then return nil, "bad data" end
	local ok, d = pcall(function() return HttpService:JSONDecode(json) end)
	if not ok or type(d) ~= "table" then return nil, "bad data" end
	return d
end

-- снимок текущей темы
function captureData(name)
	local d = {v = 1, n = name, c = {}, m = {}, p = {}}
	for g, c in pairs(state.colors) do d.c[g] = hex(c) end
	for g, m in pairs(state.materials) do d.m[g] = m.Name end
	for k, c in pairs(state.partColors) do d.p[k] = hex(c) end
	d.g, d.go = hex(state.glowColor), state.underglow and 1 or 0
	d.t, d.to = hex(state.trailColor), state.trail and 1 or 0
	if state.smokeColor then d.s = hex(state.smokeColor) end
	if rainbow.All then d.r = 1 end
	return d
end

-- применить тему из данных (всё остальное сбрасывается в заводское)
function applyData(d)
	for k in pairs(rainbow) do rainbow[k] = nil end
	state.colors, state.materials, state.partColors = {}, {}, {}

	if type(d.c) == "table" then
		for g, h in pairs(d.c) do
			local c = unhex(h)
			if c and GROUP_SET[g] then state.colors[g] = c end
		end
	end
	if type(d.m) == "table" then
		for g, n in pairs(d.m) do
			local ok, m = pcall(function() return Enum.Material[n] end)
			if ok and m and GROUP_SET[g] then state.materials[g] = m end
		end
	end
	if type(d.p) == "table" then
		for k, h in pairs(d.p) do
			local c = unhex(h)
			if c and type(k) == "string" then state.partColors[k] = c end
		end
	end

	local gc = unhex(d.g)
	if gc then state.glowColor = gc end
	if d.go ~= nil then state.underglow = (d.go == 1) end
	local tc = unhex(d.t)
	if tc then state.trailColor = tc end
	if d.to ~= nil then state.trail = (d.to == 1) end
	state.smokeColor = unhex(d.s)
	if d.r == 1 then rainbow.All = true end

	repaintAll()
	buildGlow()
	buildTrail()
	if state.smokeColor then setSmokeColor(state.smokeColor) else restoreSmoke() end
	syncUI()
end

end -- serialization

---------------------------------------------------------------
-- ПРЕСЕТЫ
---------------------------------------------------------------
local N, M, S = Enum.Material.Neon, Enum.Material.Metal, Enum.Material.SmoothPlastic

-- классические пресеты (красят только раму/колёса, андерглоу — если указан)
local function classic(name, frame, wheel, glowColor)
	return {name = name, kind = "classic", colors = {Frame = frame, Wheel = wheel, WheelieBar = frame}, glow = glowColor}
end

local READY_PRESETS = {
	{name = "Full Black", kind = "classic", colors = {Frame = BLACK, Wheel = BLACK, Handlebar = BLACK, Suspension = BLACK, WheelieBar = BLACK}},
	classic("Black + White", BLACK, WHITE, nil),
	classic("Black + Blue",  BLACK, RGB(0, 90, 255), nil),
	classic("White + Red",   WHITE, RGB(255, 0, 0), nil),
	classic("Black + Purp",  BLACK, RGB(140, 0, 255), nil),
	classic("White + Pink + Underglow", WHITE, RGB(255, 120, 200), RGB(255, 120, 200)),
	classic("Black + Cyan + Underglow", BLACK, RGB(0, 255, 255), RGB(0, 255, 255)),
	{name = "Resolution 4:3", kind = "resolution"},
}

local function classicToData(p)
	local d = {v = 1, n = p.name, c = {}, m = {}, p = {}}
	for g, c in pairs(p.colors) do d.c[g] = hex(c) end
	if p.glow then d.g, d.go = hex(p.glow), 1 end
	return d
end

local function setStretch(on)
	settings.stretch = on
	pcall(function() RS:UnbindFromRenderStep("GIGA_Stretch") end)
	if on then
		RS:BindToRenderStep("GIGA_Stretch", Enum.RenderPriority.Camera.Value + 1, function()
			local cam = Workspace.CurrentCamera
			if cam then
				cam.CFrame = cam.CFrame * CFrame.new(0, 0, 0, 1, 0, 0, 0, CONFIG.STRETCH_VALUE, 0, 0, 0, 1)
			end
		end)
	end
end

local function applyPreset(p)
	if p.kind == "resolution" then
		setStretch(not settings.stretch)
		if notify then notify("Resolution 4:3 " .. (settings.stretch and "ON" or "OFF")) end
		return
	end

	stopAllRainbow()
	state.materials = {}
	state.partColors = {}
	for g, c in pairs(p.colors) do state.colors[g] = c end
	if p.glow then
		state.underglow = true
		state.glowColor = p.glow
	end
	repaintAll()
	if p.glow then buildGlow() end
	syncUI()
end

---------------------------------------------------------------
-- GUI: палитра и хелперы (стиль как в видео)
---------------------------------------------------------------
local C = {
	bg     = RGB(18, 22, 28),
	row    = RGB(24, 28, 37),
	rowHi  = RGB(30, 35, 45),
	btn    = RGB(34, 40, 50),
	tabOff = RGB(14, 18, 22),
	tabOn  = RGB(26, 31, 40),
	text   = RGB(235, 238, 245),
	dim    = RGB(110, 118, 130),
	head   = RGB(74, 128, 150),
	accent = RGB(60, 124, 152),
	red    = RGB(226, 84, 80),
	track  = RGB(30, 35, 44),
}

local function new(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	if parent then o.Parent = parent end
	return o
end

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 6)
	c.Parent = inst
	return c
end

local counters = setmetatable({}, {__mode = "k"})
local function bump(parent)
	counters[parent] = (counters[parent] or 0) + 1
	return counters[parent]
end

local function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local gui = new("ScreenGui", {
	Name = "GIGAMENU", ResetOnSpawn = false, DisplayOrder = 50,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)

-- всплывающая подсказка снизу
local toast = new("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -28), Size = UDim2.fromOffset(0, 28),
	AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = C.bg, BackgroundTransparency = 0.1,
	Text = "", TextColor3 = C.text, Font = Enum.Font.GothamMedium, TextSize = 12, Visible = false, ZIndex = 10,
	BorderSizePixel = 0,
}, gui)
corner(toast, 8)
new("UIPadding", {PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14)}, toast)
local toastToken = 0
notify = function(text)
	toastToken += 1
	local my = toastToken
	toast.Text = text
	toast.Visible = true
	task.delay(2.2, function()
		if my == toastToken then toast.Visible = false end
	end)
end

local function makeDraggable(frame, handle)
	local dragging, dragStart, startPos = false, nil, nil
	handle.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = frame.Position
		end
	end)
	connect(UIS.InputChanged, function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	connect(UIS.InputEnded, function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

-- слайдер 0..255 (как R/G/B в видео)
local function makeSlider(parent, position, size, initial, fillColor, onChange, scrollFrame)
	local hit = new("Frame", {Position = position, Size = size, BackgroundTransparency = 1, Active = true}, parent)
	local bar = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.new(1, 0, 0, 6),
		BackgroundColor3 = C.track, BorderSizePixel = 0,
	}, hit)
	corner(bar, 3)
	local fill = new("Frame", {Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = fillColor, BorderSizePixel = 0}, bar)
	corner(fill, 3)
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(12, 12), Position = UDim2.new(0, 0, 0.5, 0),
		BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 2,
	}, bar)
	corner(knob, 6)

	local function visual(v)
		local a = math.clamp(v / 255, 0, 1)
		fill.Size = UDim2.new(a, 0, 1, 0)
		knob.Position = UDim2.new(a, 0, 0.5, 0)
	end
	visual(initial)

	local dragging = false
	local function update(x)
		local a = math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
		local v = math.floor(a * 255 + 0.5)
		visual(v)
		onChange(v)
	end
	local function lock(l)
		if scrollFrame then scrollFrame.ScrollingEnabled = not l end
	end

	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			lock(true)
			update(input.Position.X)
		end
	end)
	connect(UIS.InputChanged, function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			update(input.Position.X)
		end
	end)
	connect(UIS.InputEnded, function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			lock(false)
		end
	end)

	return {set = function(v) visual(v) end}
end

-- три слайдера R/G/B внутри panel; onChange вызывается только когда двигает пользователь
local CHANS = {{"R", RGB(240, 80, 84)}, {"G", RGB(80, 250, 81)}, {"B", RGB(83, 80, 238)}}
local function makeRGBSliders(panel, page, onChange, startOrder)
	local draft = {255, 255, 255}
	local sliders, labels = {}, {}
	for i, ch in ipairs(CHANS) do
		local line = new("Frame", {Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1, LayoutOrder = startOrder + i - 1}, panel)
		new("TextLabel", {
			Size = UDim2.fromOffset(14, 18), BackgroundTransparency = 1, Text = ch[1], TextColor3 = ch[2],
			Font = Enum.Font.GothamBold, TextSize = 10,
		}, line)
		labels[i] = new("TextLabel", {
			AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(30, 18),
			BackgroundTransparency = 1, Text = "255", TextColor3 = C.dim, Font = Enum.Font.Gotham, TextSize = 10,
			TextXAlignment = Enum.TextXAlignment.Right,
		}, line)
		sliders[i] = makeSlider(line, UDim2.fromOffset(20, 0), UDim2.new(1, -56, 1, 0), 255, ch[2], function(v)
			draft[i] = v
			labels[i].Text = tostring(v)
			onChange(RGB(draft[1], draft[2], draft[3]))
		end, page)
	end
	return {
		get = function() return RGB(draft[1], draft[2], draft[3]) end,
		set = function(c)
			draft = {math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5)}
			for i = 1, 3 do
				sliders[i].set(draft[i])
				labels[i].Text = tostring(draft[i])
			end
		end,
	}
end

local function textBox(parent, props)
	local tb = new("TextBox", {
		BackgroundColor3 = C.btn, TextColor3 = C.text, PlaceholderColor3 = C.dim, Font = Enum.Font.Gotham,
		TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false, BorderSizePixel = 0,
		ClipsDescendants = true, Text = "",
	}, nil)
	for k, v in pairs(props) do tb[k] = v end
	corner(tb, 6)
	new("UIPadding", {PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8)}, tb)
	tb.Parent = parent
	return tb
end

---------------------------------------------------------------
-- GUI: окно
---------------------------------------------------------------
local W, H, HEAD_H = 480, 330, 46

local main = new("Frame", {
	Name = "Main", Size = UDim2.fromOffset(W, H), Position = UDim2.new(0.5, -W / 2, 0.5, -H / 2),
	BackgroundColor3 = C.bg, BackgroundTransparency = 0.08, BorderSizePixel = 0,
	ClipsDescendants = true, Active = true,
}, gui)
corner(main, 10)
new("UIStroke", {Color = WHITE, Transparency = 0.92, Thickness = 1}, main)

local sidebar, content, setMenuVisible
do
local topBar = new("Frame", {Name = "TopBar", Size = UDim2.new(1, 0, 0, HEAD_H), BackgroundTransparency = 1, Active = true}, main)
makeDraggable(main, topBar)

local dot = new("Frame", {Position = UDim2.fromOffset(12, 18), Size = UDim2.fromOffset(8, 8), BackgroundColor3 = C.accent, BorderSizePixel = 0}, topBar)
corner(dot, 4)
new("TextLabel", {
	Position = UDim2.fromOffset(28, 6), Size = UDim2.fromOffset(86, 18), BackgroundTransparency = 1,
	Text = "GIGAMENU", TextColor3 = C.text, Font = Enum.Font.GothamBold, TextSize = 14,
	TextXAlignment = Enum.TextXAlignment.Left,
}, topBar)
new("TextLabel", {
	Position = UDim2.fromOffset(28, 23), Size = UDim2.fromOffset(80, 14), BackgroundTransparency = 1,
	Text = "by матвейбадяг", TextColor3 = C.dim, Font = Enum.Font.Gotham, TextSize = 10,
	TextXAlignment = Enum.TextXAlignment.Left,
}, topBar)
local badge = new("TextLabel", {
	Position = UDim2.fromOffset(114, 12), Size = UDim2.fromOffset(36, 15), BackgroundColor3 = C.accent,
	Text = "v2.0", TextColor3 = WHITE, Font = Enum.Font.GothamBold, TextSize = 9,
}, topBar)
corner(badge, 4)

local minBtn = new("TextButton", {
	Position = UDim2.new(1, -58, 0, 11), Size = UDim2.fromOffset(24, 24), BackgroundTransparency = 1,
	Text = "—", TextColor3 = C.dim, Font = Enum.Font.GothamBold, TextSize = 13,
}, topBar)
local closeBtn = new("TextButton", {
	Position = UDim2.new(1, -30, 0, 14), Size = UDim2.fromOffset(18, 18), BackgroundColor3 = RGB(70, 100, 114),
	Text = "X", TextColor3 = WHITE, Font = Enum.Font.GothamBold, TextSize = 10, AutoButtonColor = true,
}, topBar)
corner(closeBtn, 9)

sidebar = new("Frame", {Position = UDim2.fromOffset(10, 50), Size = UDim2.new(0, 112, 1, -60), BackgroundTransparency = 1}, main)
new("UIListLayout", {Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder}, sidebar)

content = new("Frame", {Position = UDim2.fromOffset(130, 50), Size = UDim2.new(1, -140, 1, -60), BackgroundTransparency = 1}, main)

local opener = new("TextButton", {
	Name = "Opener", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.fromOffset(84, 22),
	BackgroundColor3 = C.bg, BackgroundTransparency = 0.25, Text = "GIGAMENU", TextColor3 = C.text,
	Font = Enum.Font.GothamBold, TextSize = 10, BorderSizePixel = 0, Visible = false,
}, gui)
corner(opener, 11)

function setMenuVisible(v)
	main.Visible = v
	opener.Visible = not v
end
closeBtn.MouseButton1Click:Connect(function() setMenuVisible(false) end)
opener.MouseButton1Click:Connect(function() setMenuVisible(true) end)

-- свернуть в полоску
local minimized = false
local function setMinimized(v)
	minimized = v
	if v then
		sidebar.Visible = false
		content.Visible = false
	end
	TweenService:Create(main, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromOffset(W, v and HEAD_H or H),
	}):Play()
	if not v then
		task.delay(0.18, function()
			if not minimized then
				sidebar.Visible = true
				content.Visible = true
			end
		end)
	end
end
minBtn.MouseButton1Click:Connect(function() setMinimized(not minimized) end)
end -- window

---------------------------------------------------------------
-- GUI: страницы и элементы
---------------------------------------------------------------
local PAGE_ORDER = {"Presets", "Customization", "Underglow", "Test", "Test2"}
local pages = {}
for _, name in ipairs(PAGE_ORDER) do
	local p = new("ScrollingFrame", {
		Name = name, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0,
		ScrollBarThickness = 3, ScrollBarImageColor3 = RGB(70, 110, 130), ScrollBarImageTransparency = 0.3,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false,
	}, content)
	new("UIListLayout", {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder}, p)
	new("UIPadding", {PaddingBottom = UDim.new(0, 8), PaddingRight = UDim.new(0, 8)}, p)
	pages[name] = p
end
local presetsPage, customPage, glowPage = pages.Presets, pages.Customization, pages.Underglow
local testPage, test2Page = pages.Test, pages.Test2

local sideButtons = {}
local function showPage(name)
	for n, p in pairs(pages) do p.Visible = (n == name) end
	for n, b in pairs(sideButtons) do
		local active = (n == name)
		b.BackgroundColor3 = active and C.tabOn or C.tabOff
		b.TextColor3 = active and C.text or C.dim
	end
	testVisible = (name == "Test")
	if testVisible then
		if refreshTestList then refreshTestList(false) end
	elseif closeTestPanel then
		closeTestPanel()
	end
end

for i, name in ipairs(PAGE_ORDER) do
	local b = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 29), BackgroundColor3 = C.tabOff, Text = name, TextColor3 = C.dim,
		Font = Enum.Font.GothamMedium, TextSize = 11, AutoButtonColor = false, BorderSizePixel = 0, LayoutOrder = i,
	}, sidebar)
	corner(b, 7)
	sideButtons[name] = b
	b.MouseButton1Click:Connect(function() showPage(name) end)
end

local function sectionTitle(parent, text)
	return new("TextLabel", {
		Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1, Text = "|  " .. text,
		TextColor3 = C.head, Font = Enum.Font.GothamBold, TextSize = 10,
		TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = bump(parent),
	}, parent)
end

local function presetButton(parent, text, callback)
	local b = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 35), BackgroundColor3 = C.row, Text = text, TextColor3 = C.text,
		Font = Enum.Font.Gotham, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left,
		AutoButtonColor = false, BorderSizePixel = 0, LayoutOrder = bump(parent),
	}, parent)
	corner(b, 7)
	new("UIPadding", {PaddingLeft = UDim.new(0, 12)}, b)
	b.MouseEnter:Connect(function() b.BackgroundColor3 = C.rowHi end)
	b.MouseLeave:Connect(function() b.BackgroundColor3 = C.row end)
	b.MouseButton1Click:Connect(callback)
	return b
end

local function row(parent, text)
	local r = new("Frame", {
		Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = C.row, BorderSizePixel = 0, LayoutOrder = bump(parent),
	}, parent)
	corner(r, 7)
	local l = new("TextLabel", {
		Size = UDim2.new(1, -150, 1, 0), Position = UDim2.fromOffset(12, 0), BackgroundTransparency = 1,
		Text = text, TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, r)
	return r, l
end

local function makeToggle(r, initial, callback)
	local b = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(55, 22),
		Font = Enum.Font.GothamBold, TextSize = 10, AutoButtonColor = false, BorderSizePixel = 0,
	}, r)
	corner(b, 6)
	local on = initial
	local function render()
		b.Text = on and "ON" or "OFF"
		b.BackgroundColor3 = on and C.accent or C.btn
		b.TextColor3 = on and WHITE or C.dim
	end
	render()
	b.MouseButton1Click:Connect(function()
		on = not on
		render()
		callback(on)
	end)
	return {set = function(v) on = v render() end}
end

-- строка выбора цвета: swatch + EDIT, внутри разворачивается пикер R/G/B + SAVE + RAINBOW
local closeOpenPicker = nil

local function colorRow(parent, page, labelText, target, getColor, onSave)
	local wrap = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = bump(parent),
	}, parent)
	new("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder}, wrap)

	local r = new("Frame", {Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = C.row, BorderSizePixel = 0, LayoutOrder = 1}, wrap)
	corner(r, 7)
	new("TextLabel", {
		Size = UDim2.new(1, -150, 1, 0), Position = UDim2.fromOffset(12, 0), BackgroundTransparency = 1,
		Text = labelText, TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, r)
	local sw = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -74, 0.5, 0), Size = UDim2.fromOffset(43, 18),
		BackgroundColor3 = getColor(), BorderSizePixel = 0,
	}, r)
	corner(sw, 5)
	local editBtn = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(55, 22),
		BackgroundColor3 = C.btn, Text = "EDIT", TextColor3 = RGB(200, 205, 212), Font = Enum.Font.GothamBold, TextSize = 10,
		AutoButtonColor = false,
	}, r)
	corner(editBtn, 6)

	local panel = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = C.row,
		BorderSizePixel = 0, Visible = false, LayoutOrder = 2,
	}, wrap)
	corner(panel, 7)
	new("UIPadding", {
		PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
	}, panel)
	new("UIListLayout", {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder}, panel)

	local picker = makeRGBSliders(panel, page, function(c) sw.BackgroundColor3 = c end, 1)

	local saveBtn = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = C.accent, Text = "SAVE", TextColor3 = WHITE,
		Font = Enum.Font.GothamBold, TextSize = 10, AutoButtonColor = true, LayoutOrder = 4,
	}, panel)
	corner(saveBtn, 6)
	local rainbowBtn = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = C.btn, Text = "RAINBOW", TextColor3 = C.text,
		Font = Enum.Font.GothamBold, TextSize = 10, AutoButtonColor = true, LayoutOrder = 5,
	}, panel)
	corner(rainbowBtn, 6)

	local function renderRainbow()
		if rainbow[target] then
			rainbowBtn.Text = "STOP"
			rainbowBtn.BackgroundColor3 = C.red
			rainbowBtn.TextColor3 = WHITE
		else
			rainbowBtn.Text = "RAINBOW"
			rainbowBtn.BackgroundColor3 = C.btn
			rainbowBtn.TextColor3 = C.text
		end
	end

	local function close()
		panel.Visible = false
		editBtn.Text = "EDIT"
		sw.BackgroundColor3 = getColor()
		if closeOpenPicker == close then closeOpenPicker = nil end
	end

	editBtn.MouseButton1Click:Connect(function()
		if panel.Visible then
			close()
			return
		end
		if closeOpenPicker then closeOpenPicker() end
		closeOpenPicker = close
		picker.set(getColor())
		sw.BackgroundColor3 = getColor()
		renderRainbow()
		panel.Visible = true
		editBtn.Text = "CLOSE"
	end)

	saveBtn.MouseButton1Click:Connect(function()
		local c = picker.get()
		if rainbow[target] then setRainbow(target, false) end
		onSave(c)
		panel.Visible = false
		editBtn.Text = "EDIT"
		sw.BackgroundColor3 = c
		if closeOpenPicker == close then closeOpenPicker = nil end
	end)

	rainbowBtn.MouseButton1Click:Connect(function()
		setRainbow(target, not rainbow[target])
		renderRainbow()
	end)

	table.insert(ui.refreshers, function()
		if not panel.Visible then sw.BackgroundColor3 = getColor() end
		renderRainbow()
	end)
end

---------------------------------------------------------------
-- СТРАНИЦА: PRESETS (без Imba)
---------------------------------------------------------------
local warnLabel = new("TextLabel", {
	Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = RGB(60, 28, 28), BorderSizePixel = 0, TextWrapped = true,
	TextColor3 = RGB(255, 170, 160), Font = Enum.Font.Gotham, TextSize = 10, Visible = false, LayoutOrder = 0,
	TextXAlignment = Enum.TextXAlignment.Left,
}, presetsPage)
corner(warnLabel, 7)
new("UIPadding", {PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10)}, warnLabel)

sectionTitle(presetsPage, "READY PRESETS")
for _, p in ipairs(READY_PRESETS) do
	presetButton(presetsPage, p.name, function() applyPreset(p) end)
end

---------------------------------------------------------------
-- СТРАНИЦА: CUSTOMIZATION
---------------------------------------------------------------
sectionTitle(customPage, "MODIFICATIONS")

do
	local r = row(customPage, "Auto Wheelie [" .. CONFIG.WHEELIE_KEY.Name .. "]")
	wheelieToggleUI = makeToggle(r, false, function(on) setWheelie(on) end)
end

local wbButton
do
	local r = row(customPage, "Wheelie Bar")
	wbButton = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(55, 22),
		BackgroundColor3 = C.accent, BackgroundTransparency = 1, Text = "N/A", TextColor3 = C.dim,
		Font = Enum.Font.GothamBold, TextSize = 10, AutoButtonColor = false, BorderSizePixel = 0,
	}, r)
	corner(wbButton, 6)
	wbButton.MouseButton1Click:Connect(function()
		ensure()
		if not scooter then
			notify("Scooter not found")
			return
		end
		if scooter:FindFirstChild(BAR_FOLDER) then return end -- уже добавлен
		if buildWheelieBar() then
			state.wheelieBar = true
			ensure()
			if wbButtonUpdate then wbButtonUpdate() end
			notify("Wheelie bar added")
		else
			notify("Could not add the wheelie bar")
		end
	end)
end

wbButtonUpdate = function()
	if not wbButton then return end
	if scooter and scooter:FindFirstChild(BAR_FOLDER) then
		wbButton.Text = "DONE"
		wbButton.BackgroundTransparency = 1
		wbButton.TextColor3 = C.text
	elseif scooter then
		wbButton.Text = "ADD"
		wbButton.BackgroundTransparency = 0
		wbButton.BackgroundColor3 = C.accent
		wbButton.TextColor3 = WHITE
	else
		wbButton.Text = "N/A"
		wbButton.BackgroundTransparency = 1
		wbButton.TextColor3 = C.dim
	end
end

do
	local r = row(customPage, "Light Trail")
	local t = makeToggle(r, state.trail, function(on)
		state.trail = on
		buildTrail()
	end)
	table.insert(ui.refreshers, function() t.set(state.trail) end)
end

do
	local r = row(customPage, "Rainbow Kukirin G4")
	local t = makeToggle(r, false, function(on) setRainbow("All", on) end)
	table.insert(ui.refreshers, function() t.set(rainbow.All == true) end)
end

local function colorOf(target)
	return savedColor(target) or (target == "Smoke" and WHITE) or groupDisplayColor(target)
end

local function saveColor(target, c)
	if target == "Trail" then
		state.trailColor = c
		if trail.obj then trail.obj.Color = ColorSequence.new(c) end
	elseif target == "Underglow" then
		state.glowColor = c
		setGlowColorRaw(c)
	elseif target == "Smoke" then
		state.smokeColor = c
		setSmokeColor(c)
	else
		state.colors[target] = c
		for _, p in ipairs(groups[target] or {}) do enforcePart(p) end
	end
end

local COLOR_ROWS = {
	{"Trail Color", "Trail"},
	{"Suspension Color", "Suspension"},
	{"Handlebar Color", "Handlebar"},
	{"Wheelie Bar Color", "WheelieBar"},
	{"Burnout Smoke Color", "Smoke"},
}
for _, cr in ipairs(COLOR_ROWS) do
	local target = cr[2]
	colorRow(customPage, customPage, cr[1], target, function() return colorOf(target) end, function(c) saveColor(target, c) end)
end

---------------------------------------------------------------
-- СТРАНИЦА: UNDERGLOW
---------------------------------------------------------------
sectionTitle(glowPage, "UNDERGLOW LIGHTING")
do
	local r = row(glowPage, "Underglow State")
	local t = makeToggle(r, state.underglow, function(on)
		state.underglow = on
		buildGlow()
	end)
	table.insert(ui.refreshers, function() t.set(state.underglow) end)
end
colorRow(glowPage, glowPage, "Underglow Color", "Underglow", function() return state.glowColor end, function(c) saveColor("Underglow", c) end)

---------------------------------------------------------------
-- СТРАНИЦА: TEST (детали самоката)
---------------------------------------------------------------
do -- Test page
local testRows = {}   -- [путь] = {row, swatch, order, title}
local testToken, testSig = 0, ""
local selectedKey = nil

sectionTitle(testPage, "SCOOTER PARTS")
new("TextLabel", {
	Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, TextWrapped = true,
	Text = "Click a part: it lights up on the scooter and you can change its color live.",
	TextColor3 = C.dim, Font = Enum.Font.Gotham, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top, LayoutOrder = bump(testPage),
}, testPage)
local testSearch = textBox(testPage, {
	Size = UDim2.new(1, 0, 0, 28), PlaceholderText = "Search parts...", LayoutOrder = bump(testPage),
})
local testEmpty = new("TextLabel", {
	Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, TextWrapped = true, Visible = false,
	Text = "No parts found. Make sure the scooter exists in workspace.",
	TextColor3 = RGB(255, 170, 160), Font = Enum.Font.Gotham, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left,
	LayoutOrder = bump(testPage),
}, testPage)

local testPanel = new("Frame", {
	Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = C.rowHi,
	BorderSizePixel = 0, Visible = false, LayoutOrder = 100000,
}, testPage)
corner(testPanel, 7)
new("UIPadding", {
	PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
}, testPanel)
new("UIListLayout", {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder}, testPanel)
local testTitle = new("TextLabel", {
	Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, Text = "", TextColor3 = C.text,
	Font = Enum.Font.GothamBold, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd, LayoutOrder = 1,
}, testPanel)

local function currentKeyColor(key)
	local c = state.partColors[key]
	if c then return c end
	local list = partsByKey[key]
	local p = list and list[1]
	return p and p.Color or WHITE
end

local testPicker = makeRGBSliders(testPanel, testPage, function(c)
	if not selectedKey then return end
	state.partColors[selectedKey] = c
	for _, p in ipairs(partsByKey[selectedKey] or {}) do enforcePart(p) end
	local r = testRows[selectedKey]
	if r then r.swatch.BackgroundColor3 = c end
end, 2)

local testBtns = new("Frame", {Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, LayoutOrder = 6}, testPanel)
local resetBtn = new("TextButton", {
	Size = UDim2.new(0.5, -3, 1, 0), BackgroundColor3 = C.btn, Text = "RESET", TextColor3 = C.text,
	Font = Enum.Font.GothamBold, TextSize = 10, AutoButtonColor = true, BorderSizePixel = 0,
}, testBtns)
corner(resetBtn, 6)
local closePanelBtn = new("TextButton", {
	Position = UDim2.new(0.5, 3, 0, 0), Size = UDim2.new(0.5, -3, 1, 0), BackgroundColor3 = C.accent, Text = "CLOSE",
	TextColor3 = WHITE, Font = Enum.Font.GothamBold, TextSize = 10, AutoButtonColor = true, BorderSizePixel = 0,
}, testBtns)
corner(closePanelBtn, 6)

closeTestPanel = function()
	selectedKey = nil
	testPanel.Visible = false
	clearHighlight()
end

local function selectKey(key)
	local r = testRows[key]
	if not r then return end
	if selectedKey == key then
		closeTestPanel()
		return
	end
	selectedKey = key
	testPanel.LayoutOrder = r.order + 1
	testTitle.Text = r.title
	testPicker.set(currentKeyColor(key))
	testPanel.Visible = true
	highlightKey(key)
end

resetBtn.MouseButton1Click:Connect(function()
	if not selectedKey then return end
	state.partColors[selectedKey] = nil
	repaintAll()
	local c = currentKeyColor(selectedKey)
	testPicker.set(c)
	local r = testRows[selectedKey]
	if r then r.swatch.BackgroundColor3 = c end
end)
closePanelBtn.MouseButton1Click:Connect(function() closeTestPanel() end)

local function applyFilter()
	local q = testSearch.Text:lower()
	for key, r in pairs(testRows) do
		r.row.Visible = (q == "" or key:lower():find(q, 1, true) ~= nil)
	end
	if selectedKey and testRows[selectedKey] and not testRows[selectedKey].row.Visible then
		closeTestPanel()
	end
end
testSearch:GetPropertyChangedSignal("Text"):Connect(applyFilter)

refreshTestList = function(force)
	ensure()
	local sig = #keyList .. ":" .. #allParts
	if not force and sig == testSig then return end
	testSig = sig
	testToken += 1
	local token = testToken
	local keepSel = selectedKey
	closeTestPanel()
	for _, r in pairs(testRows) do r.row:Destroy() end
	testRows = {}
	testEmpty.Visible = (#keyList == 0)

	local keys = keyList
	task.spawn(function()
		for i, key in ipairs(keys) do
			if token ~= testToken then return end
			local list = partsByKey[key]
			if list and #list > 0 then
				local leaf = key:match("([^/]+)$") or key
				local title = leaf .. (#list > 1 and ("  x" .. #list) or "")
				local grp = partGroupOf[list[1]] or "no group"
				local order = 100 + i * 2

				local b = new("TextButton", {
					Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = C.row, Text = "", AutoButtonColor = false,
					BorderSizePixel = 0, LayoutOrder = order,
				}, testPage)
				corner(b, 7)
				new("TextLabel", {
					Position = UDim2.fromOffset(12, 3), Size = UDim2.new(1, -70, 0, 18), BackgroundTransparency = 1,
					Text = title, TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 12,
					TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
				}, b)
				new("TextLabel", {
					Position = UDim2.fromOffset(12, 21), Size = UDim2.new(1, -70, 0, 13), BackgroundTransparency = 1,
					Text = grp .. "  ·  " .. key, TextColor3 = C.dim, Font = Enum.Font.Gotham, TextSize = 9,
					TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
				}, b)
				local sw = new("Frame", {
					AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(40, 16),
					BackgroundColor3 = currentKeyColor(key), BorderSizePixel = 0,
				}, b)
				corner(sw, 5)
				b.MouseEnter:Connect(function() b.BackgroundColor3 = C.rowHi end)
				b.MouseLeave:Connect(function() b.BackgroundColor3 = C.row end)
				b.MouseButton1Click:Connect(function() selectKey(key) end)

				testRows[key] = {row = b, swatch = sw, order = order, title = title}
			end
			if i % 15 == 0 then task.wait() end
		end
		if token == testToken then
			applyFilter()
			if keepSel and testRows[keepSel] then selectKey(keepSel) end
		end
	end)
end

end -- Test page

---------------------------------------------------------------
-- СТРАНИЦА: TEST2 (PUBLIC / PRIVATE пресеты + Cloud key)
---------------------------------------------------------------
do -- Test2 page
local privatePresets = {}
local FILE = "GIGAMENU_presets.json"

local function savePrivate()
	if typeof(writefile) ~= "function" then return end
	pcall(function() writefile(FILE, HttpService:JSONEncode(privatePresets)) end)
end

local function loadPrivate()
	if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" then return end
	local ok, data = pcall(function()
		if isfile(FILE) then return HttpService:JSONDecode(readfile(FILE)) end
		return nil
	end)
	if ok and type(data) == "table" then
		for _, e in ipairs(data) do
			if type(e) == "table" and type(e.name) == "string" and type(e.data) == "table" then
				table.insert(privatePresets, e)
			end
		end
	end
end
loadPrivate()

-- строка пресета: название слева, кнопки справа. actions = {{текст, ширина, функция, фон?, цвет текста?}, ...}
local function presetRow(parent, title, actions)
	local r = new("Frame", {Size = UDim2.new(1, 0, 0, 38), BackgroundColor3 = C.row, BorderSizePixel = 0, LayoutOrder = bump(parent)}, parent)
	corner(r, 7)
	local x, total = -8, 0
	for i = #actions, 1, -1 do
		local a = actions[i]
		local b = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, x, 0.5, 0), Size = UDim2.fromOffset(a[2], 22),
			BackgroundColor3 = a[4] or C.btn, Text = a[1], TextColor3 = a[5] or C.text, Font = Enum.Font.GothamBold,
			TextSize = 10, AutoButtonColor = true, BorderSizePixel = 0,
		}, r)
		corner(b, 6)
		b.MouseButton1Click:Connect(a[3])
		x = x - a[2] - 4
		total = total + a[2] + 4
	end
	new("TextLabel", {
		Size = UDim2.new(1, -(total + 20), 1, 0), Position = UDim2.fromOffset(12, 0), BackgroundTransparency = 1,
		Text = title, TextColor3 = C.text, Font = Enum.Font.Gotham, TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
	}, r)
	return r
end

local keyBox -- создаётся ниже
local function showKey(key, name)
	if not key then
		notify("Could not build the key")
		return
	end
	keyBox.Text = key
	if typeof(setclipboard) == "function" then
		pcall(setclipboard, key)
		notify("Key copied: " .. name)
	else
		notify("Key is in the box below: select it and press Ctrl+C")
	end
	pcall(function()
		keyBox:CaptureFocus()
		task.defer(function()
			keyBox.SelectionStart = 1
			keyBox.CursorPosition = #keyBox.Text + 1
		end)
	end)
end

-- PUBLIC: общие (готовые) пресеты
sectionTitle(test2Page, "PUBLIC PRESETS")
for _, p in ipairs(READY_PRESETS) do
	if p.kind == "classic" then
		presetRow(test2Page, p.name, {
			{"APPLY", 52, function()
				applyPreset(p)
				notify("Applied: " .. p.name)
			end, C.accent, WHITE},
			{"KEY", 38, function() showKey(encodeKey(classicToData(p)), p.name) end},
		})
	end
end

-- PRIVATE: свои пресеты
sectionTitle(test2Page, "PRIVATE PRESETS")

local nameBox = textBox(test2Page, {Size = UDim2.new(1, -78, 0, 28), PlaceholderText = "Name for current look..."})
local saveRow = new("Frame", {Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, LayoutOrder = bump(test2Page)}, test2Page)
nameBox.Parent = saveRow
local saveNowBtn = new("TextButton", {
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(72, 28),
	BackgroundColor3 = C.accent, Text = "SAVE", TextColor3 = WHITE, Font = Enum.Font.GothamBold, TextSize = 10,
	AutoButtonColor = true, BorderSizePixel = 0,
}, saveRow)
corner(saveNowBtn, 6)

local privHolder = new("Frame", {
	Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = bump(test2Page),
}, test2Page)
new("UIListLayout", {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder}, privHolder)

local rebuildPrivate
rebuildPrivate = function()
	for _, ch in ipairs(privHolder:GetChildren()) do
		if not ch:IsA("UIListLayout") then ch:Destroy() end
	end
	counters[privHolder] = 0
	if #privatePresets == 0 then
		new("TextLabel", {
			Size = UDim2.new(1, 0, 0, 24), BackgroundTransparency = 1, Text = "No private presets yet.",
			TextColor3 = C.dim, Font = Enum.Font.Gotham, TextSize = 10, TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = bump(privHolder),
		}, privHolder)
		return
	end
	for i, e in ipairs(privatePresets) do
		presetRow(privHolder, e.name, {
			{"APPLY", 52, function()
				applyData(e.data)
				notify("Applied: " .. e.name)
			end, C.accent, WHITE},
			{"KEY", 38, function() showKey(encodeKey(e.data), e.name) end},
			{"X", 26, function()
				table.remove(privatePresets, i)
				savePrivate()
				rebuildPrivate()
			end, C.red, WHITE},
		})
	end
end
rebuildPrivate()

saveNowBtn.MouseButton1Click:Connect(function()
	local name = trim(nameBox.Text):sub(1, 24)
	if name == "" then name = "Preset " .. (#privatePresets + 1) end
	table.insert(privatePresets, {name = name, data = captureData(name)})
	savePrivate()
	rebuildPrivate()
	nameBox.Text = ""
	notify("Saved: " .. name)
end)

-- CLOUD KEY: импорт / экспорт
sectionTitle(test2Page, "CLOUD KEY")

local importRow = new("Frame", {Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, LayoutOrder = bump(test2Page)}, test2Page)
local importBox = textBox(importRow, {Size = UDim2.new(1, -78, 1, 0), PlaceholderText = "Paste a Cloud key here..."})
local importBtn = new("TextButton", {
	AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(72, 28),
	BackgroundColor3 = C.accent, Text = "IMPORT", TextColor3 = WHITE, Font = Enum.Font.GothamBold, TextSize = 10,
	AutoButtonColor = true, BorderSizePixel = 0,
}, importRow)
corner(importBtn, 6)

keyBox = textBox(test2Page, {
	Size = UDim2.new(1, 0, 0, 28), PlaceholderText = "Press KEY on a preset to get its Cloud key here",
	LayoutOrder = bump(test2Page),
})

importBtn.MouseButton1Click:Connect(function()
	local d, err = decodeKey(importBox.Text)
	if not d then
		notify("Invalid key: " .. tostring(err))
		return
	end
	local name = (type(d.n) == "string" and trim(d.n) ~= "") and trim(d.n):sub(1, 24) or "Imported"
	applyData(d)
	table.insert(privatePresets, {name = name, data = captureData(name)})
	savePrivate()
	rebuildPrivate()
	importBox.Text = ""
	notify("Imported: " .. name)
end)

end -- Test2 page

---------------------------------------------------------------
-- статус (показывается только если что-то не так) + кнопка Wheelie Bar
---------------------------------------------------------------
updateStatus = function()
	local txt
	if not scooter then
		txt = 'Самокат не найден: workspace["' .. CONFIG.SCOOTER_NAME .. '"]. Проверь CONFIG.SCOOTER_NAME.'
	else
		local total = 0
		for _, g in ipairs(GROUP_ORDER) do total = total + #groups[g] end
		if total == 0 then txt = "Детали самоката не распознаны — смотри Output (F9), впиши имена в PART_NAMES." end
	end
	warnLabel.Visible = (txt ~= nil)
	if txt then warnLabel.Text = txt end
	if wbButtonUpdate then wbButtonUpdate() end
end
updateStatus()

---------------------------------------------------------------
-- ВВОД: F = вилли, RightShift = меню
-- (клавиши работают, даже если игра сама "съела" нажатие; не работают только во время ввода в TextBox)
---------------------------------------------------------------
connect(UIS.InputBegan, function(input)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	if UIS:GetFocusedTextBox() then return end

	if input.KeyCode == CONFIG.MENU_KEY then
		setMenuVisible(not main.Visible)
	elseif input.KeyCode == CONFIG.WHEELIE_KEY then
		if CONFIG.WHEELIE_HOLD then
			setWheelie(true)
		else
			setWheelie(not wheelie.on)
		end
	end
end)

connect(UIS.InputEnded, function(input)
	if CONFIG.WHEELIE_HOLD
		and input.UserInputType == Enum.UserInputType.Keyboard
		and input.KeyCode == CONFIG.WHEELIE_KEY then
		setWheelie(false)
	end
end)

---------------------------------------------------------------
-- СТАРТ
---------------------------------------------------------------
showPage("Presets")
warn("[GIGAMENU v2.1] loaded — by zyru | " .. CONFIG.WHEELIE_KEY.Name .. " = wheelie, "
	.. CONFIG.MENU_KEY.Name .. " = menu")
