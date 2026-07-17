require ('drivers-common-public.global.lib')
require ('drivers-common-public.global.url')
JSON = require ('drivers-common-public.module.json')

g_UpdateTimer = nil
g_RetryTimer = nil
-- True until OnDriverLateInit finishes. Director fires OnPropertyChanged for each
-- property as the driver loads, before LateInit runs, so this must start true or
-- the guard in OnPropertyChanged lets those startup calls through.
g_Initializing = true
g_RequestId = 0

-- Last values pushed to Director, so unchanged values aren't rewritten every cycle.
g_LastProps = {}
g_LastVars = {}

-- Named wdbg, not dbg: drivers-common-public.global.lib defines a global dbg() that
-- url.lua calls. Defining dbg() here would silently replace it.
function wdbg(message)
    if (Properties['Debug Mode'] == 'On') then
        print('Weather: ' .. tostring(message))
    end
end

-- Every C4:SetVariable fires a variable-change event that customer programming may
-- be bound to, so rewriting unchanged values (sunrise, weather code) would emit
-- spurious events on every update. Write only on an actual change.
function SetProp(name, value)
    value = tostring(value)
    if g_LastProps[name] ~= value then
        g_LastProps[name] = value
        C4:UpdateProperty(name, value)
    end
end

function SetVar(name, value)
    if g_LastVars[name] ~= value then
        g_LastVars[name] = value
        C4:SetVariable(name, value)
    end
end

function OnDriverLateInit()
    local function ensureVar(name, default, kind)
        if not (Variables and Variables[name]) then
            C4:AddVariable(name, default, kind, true, false)
        end
    end

    ensureVar("TODAY_HIGH", "0", "NUMBER")
    ensureVar("TODAY_LOW", "0", "NUMBER")
    ensureVar("FEELS_LIKE_HIGH", "0", "NUMBER")
    ensureVar("FEELS_LIKE_LOW", "0", "NUMBER")
    ensureVar("REMAINING_LOW", "0", "NUMBER")
    ensureVar("REMAINING_FEELS_LIKE_LOW", "0", "NUMBER")
    ensureVar("RAIN_CHANCE", "0", "NUMBER")
    ensureVar("RAIN_TOTAL", "0", "NUMBER")
    ensureVar("RAIN_HOURS", "0", "NUMBER")
    ensureVar("MAX_WIND", "0", "NUMBER")
    ensureVar("MAX_GUST", "0", "NUMBER")
    ensureVar("UV_INDEX", "0", "NUMBER")
    ensureVar("WEATHER_CODE", "0", "NUMBER")
    ensureVar("SUNRISE", "", "STRING")
    ensureVar("SUNSET", "", "STRING")
    ensureVar("DAYLIGHT_MINUTES", "0", "NUMBER")
    ensureVar("CURRENT_TEMP", "0", "NUMBER")
    ensureVar("CURRENT_FEELS_LIKE", "0", "NUMBER")
    ensureVar("CURRENT_WIND", "0", "NUMBER")
    ensureVar("CURRENT_GUST", "0", "NUMBER")
    ensureVar("CURRENT_CLOUD_COVER", "0", "NUMBER")
    ensureVar("LAST_UPDATE", "Never", "STRING")

    StartUpdateTimer()

    g_Initializing = false
    FetchWeather()
end

function OnPropertyChanged(strProperty)
    if (strProperty == 'Debug Mode') then
        if (Properties['Debug Mode'] == 'On') then print("Weather: Debug Mode Enabled") end
    elseif (strProperty == 'Update Interval (minutes)') then
        StartUpdateTimer()
    elseif (strProperty == 'Latitude' or strProperty == 'Longitude' or strProperty == 'Temperature Unit') then
        if not g_Initializing then
            FetchWeather()
        end
    end
end

function StartUpdateTimer()
    if g_UpdateTimer then
        g_UpdateTimer:Cancel()
        g_UpdateTimer = nil
    end

    local intervalMinutes = tonumber(Properties["Update Interval (minutes)"]) or 60
    if intervalMinutes < 15 then intervalMinutes = 15 end
    local intervalMs = intervalMinutes * 60 * 1000

    g_UpdateTimer = C4:SetTimer(intervalMs, function() FetchWeather() end, true)
end

function FetchWeather(isRetry)
    local lat = Properties["Latitude"]
    local lon = Properties["Longitude"]

    if (lat == "" or lon == "") then
        wdbg("Missing Latitude or Longitude")
        return
    end

    local tempUnitProp = Properties["Temperature Unit"] or "Fahrenheit"
    local unitParam = "fahrenheit"
    local windUnit = "mph"
    local precipUnit = "inch"

    if tempUnitProp == "Celsius" then
        unitParam = "celsius"
        windUnit = "kmh"
        precipUnit = "mm"
    end

    local dailyParams = "temperature_2m_max,temperature_2m_min," ..
                        "apparent_temperature_max,apparent_temperature_min," ..
                        "precipitation_probability_max,precipitation_sum,precipitation_hours," ..
                        "wind_speed_10m_max,wind_gusts_10m_max,uv_index_max,weather_code," ..
                        "sunrise,sunset,daylight_duration"

    local hourlyParams = "temperature_2m,apparent_temperature"
    local currentParams = "temperature_2m,apparent_temperature,wind_speed_10m," ..
                          "wind_gusts_10m,cloud_cover"

    -- forecast_days=2 so the overnight low can see past midnight into tomorrow's
    -- dawn. Every daily field below still reads index [1], which remains today.
    local url = "https://api.open-meteo.com/v1/forecast?latitude=" .. lat ..
                "&longitude=" .. lon ..
                "&daily=" .. dailyParams ..
                "&hourly=" .. hourlyParams ..
                "&current=" .. currentParams ..
                "&temperature_unit=" .. unitParam ..
                "&wind_speed_unit=" .. windUnit ..
                "&precipitation_unit=" .. precipUnit ..
                "&timezone=auto&forecast_days=2"

    wdbg("Fetching: " .. url)

    local options = {
        fail_on_error = false,
        timeout = 30000  -- 30 second timeout
    }

    if not isRetry then
        g_RequestId = g_RequestId + 1
    end

    local context = { isRetry = isRetry or false, requestId = g_RequestId }
    urlGet(url, {}, CheckResponse, context, options)
end

function CheckResponse(strError, responseCode, tHeaders, data, context, url)
    context = context or {}
    if context.requestId ~= g_RequestId then
        wdbg("Ignoring stale weather response")
        return
    end

    if (strError) then
        wdbg("Network Error: " .. strError)

        -- Retry once if this wasn't already a retry
        if not context.isRetry then
            wdbg("Scheduling retry in 30 seconds...")
            if g_RetryTimer then g_RetryTimer:Cancel() end
            local retryRequestId = context.requestId
            g_RetryTimer = C4:SetTimer(30000, function()
                if retryRequestId == g_RequestId then
                    FetchWeather(true)
                else
                    wdbg("Skipping stale weather retry")
                end
                g_RetryTimer = nil
            end, false)
            return
        end

        C4:FireEvent("Update Failed")
        return
    end

    if (responseCode ~= 200) then
        wdbg("HTTP Error Code: " .. tostring(responseCode))
        C4:FireEvent("Update Failed")
        return
    end

    -- Use pcall for safe JSON decoding
    local success, tData
    if (type(data) == "string") then
        success, tData = pcall(function() return JSON:decode(data) end)
        if not success then
            wdbg("JSON Decoding Failed: " .. tostring(tData))
            C4:FireEvent("Update Failed")
            return
        end
    else
        tData = data
    end

    -- Validate data structure
    if not (tData and tData.daily) then
        wdbg("Invalid JSON structure - missing daily data")
        C4:FireEvent("Update Failed")
        return
    end

    local d = tData.daily

    -- Validate all required fields exist and have data
    if not (d.temperature_2m_max and d.temperature_2m_max[1] and
            d.temperature_2m_min and d.temperature_2m_min[1] and
            d.apparent_temperature_max and d.apparent_temperature_max[1] and
            d.apparent_temperature_min and d.apparent_temperature_min[1]) then
        wdbg("Missing required temperature data in API response")
        C4:FireEvent("Update Failed")
        return
    end

    -- Helper functions
    local function round(num)
        if type(num) ~= "number" then return 0 end
        return math.floor(num + 0.5)
    end

    local function safeNumber(val, default)
        if type(val) == "number" then
            return val
        end
        return (default or 0)
    end

    local function formatIsoTime(iso)
        if type(iso) ~= "string" then return "" end
        local date, time = iso:match("^(%d%d%d%d%-%d%d%-%d%d)T(%d%d:%d%d)")
        if date and time then
            return date .. " " .. time
        end
        return iso
    end

    -- Extract and validate data
    local updatedAt = os.date("%Y-%m-%d %H:%M:%S")

    local high = round(d.temperature_2m_max[1])
    local low = round(d.temperature_2m_min[1])
    local feelsHigh = round(d.apparent_temperature_max[1])
    local feelsLow = round(d.apparent_temperature_min[1])

    local rainChance = safeNumber(d.precipitation_probability_max and d.precipitation_probability_max[1], 0)
    local rainTotal = safeNumber(d.precipitation_sum and d.precipitation_sum[1], 0)
    local rainHrs = safeNumber(d.precipitation_hours and d.precipitation_hours[1], 0)
    local wind = safeNumber(d.wind_speed_10m_max and d.wind_speed_10m_max[1], 0)
    local maxGust = safeNumber(d.wind_gusts_10m_max and d.wind_gusts_10m_max[1], 0)
    local uv = safeNumber(d.uv_index_max and d.uv_index_max[1], 0)
    local weatherCode = safeNumber(d.weather_code and d.weather_code[1], 0)

    local sunriseIso = d.sunrise and d.sunrise[1] or ""
    local sunsetIso = d.sunset and d.sunset[1] or ""
    local sunriseStr = formatIsoTime(sunriseIso)
    local sunsetStr = formatIsoTime(sunsetIso)
    local daylightSeconds = safeNumber(d.daylight_duration and d.daylight_duration[1], 0)
    local daylightMinutes = round(daylightSeconds / 60)

    -- Overnight low: scan from the API's current local time forward to the next
    -- sunrise, plus one hour of margin since the minimum often lags dawn slightly.
    -- Because this is a minimum, warm hours inside the window can never win it, so
    -- overshooting is harmless -- the only thing that would corrupt the result is
    -- reaching the *following* night, which the sunrise bound prevents.
    -- ISO 8601 timestamps sort lexicographically, so plain string compares work and
    -- current.time is already local wall-clock, so no controller clock is involved.
    local remainingLow = low
    local remainingFeelsLow = feelsLow

    local h = tData.hourly
    local nowIso = tData.current and tData.current.time

    if (h and h.time and h.temperature_2m and h.apparent_temperature and
        type(nowIso) == "string" and d.sunrise) then

        local nextSunrise
        for _, s in ipairs(d.sunrise) do
            if type(s) == "string" and s > nowIso then
                nextSunrise = s
                break
            end
        end

        if nextSunrise then
            -- last hourly slot at or before dawn, +1 for the post-dawn margin
            local lastIdx = 0
            for i, ts in ipairs(h.time) do
                if ts <= nextSunrise then lastIdx = i end
            end
            lastIdx = lastIdx + 1

            local minTemp = nil
            local minFeels = nil

            for i, ts in ipairs(h.time) do
                if i > lastIdx then break end
                if ts >= nowIso then
                    local t = h.temperature_2m[i]
                    local f = h.apparent_temperature[i]
                    if type(t) == "number" and (minTemp == nil or t < minTemp) then minTemp = t end
                    if type(f) == "number" and (minFeels == nil or f < minFeels) then minFeels = f end
                end
            end

            if minTemp ~= nil then remainingLow = round(minTemp) end
            if minFeels ~= nil then remainingFeelsLow = round(minFeels) end

            wdbg("Overnight window " .. nowIso .. " -> " .. nextSunrise ..
                 " | low " .. remainingLow .. ", feels " .. remainingFeelsLow)
        else
            wdbg("No upcoming sunrise in forecast, falling back to daily low")
        end
    else
        wdbg("Hourly/current data unavailable, falling back to daily low")
    end

    -- Current conditions
    local currentTemp = 0
    local currentFeels = 0
    local currentWind = 0
    local currentGust = 0
    local currentCloudCover = 0

    if tData.current then
        local cw = tData.current
        currentTemp = safeNumber(cw.temperature_2m, 0)
        currentFeels = safeNumber(cw.apparent_temperature, currentTemp)
        currentWind = safeNumber(cw.wind_speed_10m, 0)
        currentGust = safeNumber(cw.wind_gusts_10m, 0)
        currentCloudCover = safeNumber(cw.cloud_cover, 0)
    else
        wdbg("Current weather data unavailable")
    end

    local distLabel = (Properties["Temperature Unit"] == "Celsius") and " km/h" or " mph"
    local rainLabel = (Properties["Temperature Unit"] == "Celsius") and " mm" or " in"

    -- Update properties
    SetProp("Last Update:", updatedAt)
    SetProp("Today High:", high .. "°")
    SetProp("Today Low:", low .. "°")
    SetProp("Feels Like High:", feelsHigh .. "°")
    SetProp("Feels Like Low:", feelsLow .. "°")
    SetProp("Remaining Low:", remainingLow .. "°")
    SetProp("Remaining Feels Like Low:", remainingFeelsLow .. "°")
    SetProp("Rain Chance:", rainChance .. "%")
    SetProp("Rain Total:", rainTotal .. rainLabel)
    SetProp("Rain Hours:", rainHrs .. " hrs")
    SetProp("Max Wind:", wind .. distLabel)
    SetProp("Max Gust:", maxGust .. distLabel)
    SetProp("UV Index:", uv)
    SetProp("Weather Code:", weatherCode)
    SetProp("Sunrise:", sunriseStr)
    SetProp("Sunset:", sunsetStr)
    SetProp("Daylight (min):", daylightMinutes)
    SetProp("Current Temp:", round(currentTemp) .. "°")
    SetProp("Current Feels Like:", round(currentFeels) .. "°")
    SetProp("Current Wind:", currentWind .. distLabel)
    SetProp("Current Gust:", currentGust .. distLabel)
    SetProp("Cloud Cover:", currentCloudCover .. "%")

    -- Update variables
    SetVar("LAST_UPDATE", updatedAt)
    SetVar("TODAY_HIGH", high)
    SetVar("TODAY_LOW", low)
    SetVar("FEELS_LIKE_HIGH", feelsHigh)
    SetVar("FEELS_LIKE_LOW", feelsLow)
    SetVar("REMAINING_LOW", remainingLow)
    SetVar("REMAINING_FEELS_LIKE_LOW", remainingFeelsLow)
    SetVar("RAIN_CHANCE", rainChance)
    SetVar("RAIN_TOTAL", rainTotal)
    SetVar("RAIN_HOURS", rainHrs)
    SetVar("MAX_WIND", wind)
    SetVar("MAX_GUST", maxGust)
    SetVar("UV_INDEX", uv)
    SetVar("WEATHER_CODE", weatherCode)
    SetVar("SUNRISE", sunriseStr)
    SetVar("SUNSET", sunsetStr)
    SetVar("DAYLIGHT_MINUTES", daylightMinutes)
    SetVar("CURRENT_TEMP", round(currentTemp))
    SetVar("CURRENT_FEELS_LIKE", round(currentFeels))
    SetVar("CURRENT_WIND", currentWind)
    SetVar("CURRENT_GUST", currentGust)
    SetVar("CURRENT_CLOUD_COVER", currentCloudCover)

    wdbg("Weather Updated Successfully")
    C4:FireEvent("Weather Updated")
end

function ExecuteCommand(strCommand, tParams)
    wdbg("ExecuteCommand called: " .. tostring(strCommand))

    -- Handle actions from UI buttons
    if strCommand == "LUA_ACTION" then
        if tParams and tParams.ACTION then
            wdbg("Action received: " .. tostring(tParams.ACTION))
            if tParams.ACTION == "REFRESH_WEATHER" then
                FetchWeather()
            end
        end
    -- Direct command support (for programming or other drivers)
    elseif strCommand == "REFRESH_WEATHER" then
        FetchWeather()
    end
end

function OnDriverDestroyed()
    -- Bump the request id so any in-flight response is discarded as stale
    g_RequestId = g_RequestId + 1

    if g_UpdateTimer then
        g_UpdateTimer:Cancel()
        g_UpdateTimer = nil
    end
    if g_RetryTimer then
        g_RetryTimer:Cancel()
        g_RetryTimer = nil
    end
end
