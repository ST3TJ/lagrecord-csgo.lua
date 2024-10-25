-- Либа говно, у меня лучше
local CLagCompensation = { Data = {} }; do
    local hitbox_connections = {
        { 0,  1 },
        { 1,  6 },
        { 6,  5 },
        { 5,  4 },
        { 4,  3 },
        { 3,  2 },
        { 6,  17 },
        { 17, 18 },
        { 18, 14 },
        { 6,  15 },
        { 15, 16 },
        { 16, 13 },
        { 2,  8 },
        { 8,  10 },
        { 10, 12 },
        { 2,  7 },
        { 7,  9 },
        { 9,  11 }
    }

    local w2s = render.world_to_screen

    local cl_interp = cvar.cl_interp
    local cl_updaterate = cvar.cl_updaterate
    local sv_minupdaterate = cvar.sv_minupdaterate
    local sv_maxupdaterate = cvar.sv_maxupdaterate
    local cl_interp_ratio = cvar.cl_interp_ratio
    local sv_min_interp_ratio = cvar.sv_client_min_interp_ratio
    local sv_max_interp_ratio = cvar.sv_client_max_interp_ratio

    function to_ticks(time)
        return math.ceil(time * cl_updaterate:float())
    end

    function to_time(ticks)
        return ticks / cl_updaterate:float()
    end

    function math.clamp(value, min, max)
        return math.min(math.max(value, min), max)
    end

    function table.count(list)
        local count = 0

        for _ in pairs(list) do
            count = count + 1
        end

        return count
    end

    ---@param alive boolean
    ---@param enemy boolean
    ---@param visible boolean
    ---@return player[]
    ---@diagnostic disable-next-line: duplicate-set-field
    function entity.get_players(alive, enemy, visible)
        local entity_list = { entity.get_local_player() }

        for i = 1, globals.max_players do
            local ent = entity.get(i)
            if ent and ent:is_player() then
                ---@cast ent player
                if (not alive or ent:is_alive()) and
                    (not enemy or ent:is_enemy()) and
                    (not visible or not ent:is_dormant()) then
                    table.insert(entity_list, ent)
                end
            end
        end

        return entity_list
    end

    ---@param player player
    ---@return vector[]
    function CLagCompensation:GetPlayerMatrix(player)
        local matrix = {}

        for i = 0, 18 do
            matrix[i] = player:get_hitbox_position(i)
        end

        return matrix
    end

    ---@return player_record_t
    function CLagCompensation:ThrowEmptyData()
        local matrix = {}

        for i = 0, 18 do
            matrix[i] = vector(0, 0, 0)
        end

        ---@class player_record_t
        local data = {
            Player                  = nil,
            Tick                    = 0,
            Matrix                  = matrix,
            Origin                  = vector(0, 0, 0),
            m_flSimulationTime      = 0,
            m_flOldSimulationTime   = 0,
            m_flMaxSimulationTime   = 0,
            Exploiting              = false,
            BreakingLagCompensation = false,
            Lag                     = false,
        }

        return data
    end

    ---@param player player
    ---@return player_record_t
    function CLagCompensation:GetPreviousData(player)
        local id = player:ent_index()

        if not self.Data[id] then
            return self:ThrowEmptyData()
        end

        local tick = globals.tickcount

        return self.Data[id][tick - 1] or self:ThrowEmptyData()
    end

    ---@param player player
    ---@return player_record_t
    function CLagCompensation:Backup(player)
        local id = player:ent_index()

        if not self.Data[id] then
            self.Data[id] = {}
        end

        local tick = globals.tickcount
        local simulation_data = player:get_simulation_time()

        local m_flSimulationTime = simulation_data[1]
        local m_flOldSimulationTime = simulation_data[2]

        local previous = self:GetPreviousData(player)
        local m_flMaxSimulationTime = previous.m_flMaxSimulationTime

        local delta = m_flSimulationTime - m_flMaxSimulationTime
        local exploiting = delta > to_time(1)

        local origin = player:get_abs_origin()
        local distance = previous.Origin:dist(origin)
        local teleport = distance > 64

        local lag = m_flOldSimulationTime == m_flSimulationTime

        self.Data[id][tick] = {
            Player                  = player,
            Tick                    = tick,
            Matrix                  = self:GetPlayerMatrix(player),
            Origin                  = player:get_abs_origin(),
            m_flSimulationTime      = m_flSimulationTime,
            m_flOldSimulationTime   = m_flOldSimulationTime,
            m_flMaxSimulationTime   = math.max(m_flSimulationTime, m_flOldSimulationTime, m_flMaxSimulationTime),
            Exploiting              = exploiting,
            BreakingLagCompensation = teleport,
            Lag                     = lag,
        }

        return self.Data[id][tick]
    end

    ---@param player player
    function CLagCompensation:CollectGarbage(player)
        local tick = globals.tickcount
        local id = player:ent_index()

        for record_tick, _ in pairs(self.Data[id]) do
            if record_tick <= tick - 64 then
                self.Data[id][record_tick] = nil
            end
        end
    end

    ---@return number
    function CLagCompensation:GetLerpTime()
        local update_rate = math.clamp(cl_updaterate:float(), sv_minupdaterate:float(), sv_maxupdaterate:float())
        local interp_ratio = math.clamp(cl_interp_ratio:float(), sv_min_interp_ratio:float(), sv_max_interp_ratio:float())

        return math.clamp(interp_ratio / update_rate, cl_interp:float(), 1)
    end

    ---@param record player_record_t
    ---@return boolean
    function CLagCompensation:IsValidRecord(record)
        if not record or not record.Player or record.Exploiting or record.BreakingLagCompensation then
            return false
        end

        local nci = utils.get_net_channel()

        if not nci then
            return false
        end

        local me = entity.get_local_player()

        local latency = nci:get_latency(1) + nci:get_latency(0)
        local server_tickcount = me.m_nTickBase + to_ticks(latency); -- me.m_nTickBase = ctx.corrected_tickbase ( actually, not really )

        -- no no no mister penguin
        -- if (ctx.fake_duck)
        --     server_tickcount += 14 - ClientState->m_nChokedCommands;

        local lerp_time = self:GetLerpTime();
        local delta_time = math.clamp(latency + lerp_time, 0, cvar.sv_maxunlag:float()) -
            (to_time(me.m_nTickBase) - record.m_flSimulationTime);

        if (math.abs(delta_time) > 0.2) then
            return false;
        end

        -- omg v0lvo broke this check but i want to add it because i want to be like Soufiw
        local dead_time = to_time(server_tickcount) - 0.2
        if (record.m_flSimulationTime + lerp_time < dead_time) then
            return false
        end

        return true;
    end

    function CLagCompensation:Update()
        local me = entity.get_local_player()

        if not (me and me:is_alive()) then
            CLagCompensation.Data = {}
            return
        end

        local players = entity.get_players(true, true, true)

        for _, player in ipairs(players) do
            self:Backup(player)
            self:CollectGarbage(player)
        end
    end

    function CLagCompensation:DrawMatrix(matrix)
        for _, connection in ipairs(hitbox_connections) do
            local start = matrix[connection[1]]
            local finish = matrix[connection[2]]

            if start and finish then
                local start_screen = w2s(start)
                local finish_screen = w2s(finish)

                if start_screen.x < 0 or start_screen.y < 0 or finish_screen.x < 0 or finish_screen.y < 0 then
                    goto continue
                end

                render.line(start_screen, finish_screen, color(255, 255, 255))

                ::continue::
            end
        end
    end

    function CLagCompensation:Draw()
        local me = entity.get_local_player()
        if not (me and me:is_alive()) then
            return
        end

        local players = entity.get_players(true, true, true)

        for _, player in ipairs(players) do
            local id = player:ent_index()
            local records = self.Data[id]

            if not records then
                goto next_player
            end

            local latest = math.huge

            for _, data in pairs(records) do
                if not self:IsValidRecord(data) then
                    goto continue
                end

                if data.Tick < latest then
                    latest = data.Tick
                end

                ::continue::
            end

            if latest ~= math.huge then
                self:DrawMatrix(records[latest].Matrix)
            end

            ::next_player::
        end
    end
end

client.add_callback("render", function()
    local s, m = pcall(CLagCompensation.Draw, CLagCompensation)

    if not s then
        print(m)
    end
end)

client.add_callback("createmove", function()
    local s, m = pcall(CLagCompensation.Update, CLagCompensation)

    if not s then
        print(m)
    end
end)
