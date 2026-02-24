require ('drivers-common-public.global.lib')
require ('drivers-common-public.global.timer')
require ('drivers-common-public.global.url')
JSON = require ('drivers-common-public.module.json')

g_UpdateTimer = nil
g_RetryTimer = nil
g_Initializing = false

function dbg(message)
    if (Properties['Debug Mode'] == 'On') then
        print('Weather: ' .. tostring(message))
    end
end

function OnDriverLateInit()
    g_Initializing = true

    -- Initialize variables with simplified checks
    if not Variables["TODAY_HIGH"] then C4:AddVariable("TODAY_HIGH", "0", "NUMBER", true, false) end
    if not Variables["TODAY_LOW"] then C4:AddVariable("TODAY_LOW", "0", "NUMBER", true, false) end
    if not Variables["FEELS_LIKE_HIGH"] then C4:AddVariable("FEELS_LIKE_HIGH", "0", "NUMBER", true, false) end
    if not Variables["FEELS_LIKE_LOW"] then C4:AddVariable("FEELS_LIKE_LOW", "0", "NUMBER", true, false) end
    if not Variables["REMAINING_LOW"] then C4:AddVariable("REMAINING_LOW", "0", "NUMBER", true, false) end
    if not Variables["REMAINING_FEELS_LIKE_LOW"] then C4:AddVariable("REMAINING_FEELS_LIKE_LOW", "0", "NUMBER", true, false) end
    if not Variables["RAIN_CHANCE"] then C4:AddVariable("RAIN_CHANCE", "0", "NUMBER", true, false) end
    if not Variables["RAIN_TOTAL"] then C4:AddVariable("RAIN_TOTAL", "0", "NUMBER", true, false) end
    if not Variables["RAIN_HOURS"] then C4:AddVariable("RAIN_HOURS", "0", "NUMBER", true, false) end
    if not Variables["MAX_WIND"] then C4:AddVariable("MAX_WIND", "0", "NUMBER", true, false) end
    if not Variables["MAX_GUST"] then C4:AddVariable("MAX_GUST", "0", "NUMBER", true, false) end
    if not Variables["UV_INDEX"] then C4:AddVariable("UV_INDEX", "0", "NUMBER", true, false) end
    if not Variables["WEATHER_CODE"] then C4:AddVariable("WEATHER_CODE", "0", "NUMBER", true, false) end
    if not Variables["SUNRISE"] then C4:AddVariable("SUNRISE", "", "STRING", true, false) end
    if not Variables["SUNSET"] then C4:AddVariable("SUNSET", "", "STRING", true, false) end
    if not Variables["DAYLIGHT_MINUTES"] then C4:AddVariable("DAYLIGHT_MINUTES", "0", "NUMBER", true, false) end
    if not Variables["CURRENT_TEMP"] then C4:AddVariable("CURRENT_TEMP", "0", "NUMBER", true, false) end
    if not Variables["CURRENT_FEELS_LIKE"] then C4:AddVariable("CURRENT_FEELS_LIKE", "0", "NUMBER", true, false) end
    if not Variables["CURRENT_WIND"] then C4:AddVariable("CURRENT_WIND", "0", "NUMBER", true, false) end
    if not Variables["CURRENT_GUST"] then C4:AddVariable("CURRENT_GUST", "0", "NUMBER", true, false) end
    if not Variables["CURRENT_CLOUD_COVER"] then C4:AddVariable("CURRENT_CLOUD_COVER", "0", "NUMBER", true, false) end
    if not Variables["LAST_UPDATE"] then C4:AddVariable("LAST_UPDATE", "Never", "STRING", true, false) end

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
        dbg("Missing Latitude or Longitude")
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

    local url = "https://api.open-meteo.com/v1/forecast?latitude=" .. lat .. 
                "&longitude=" .. lon .. 
                "&daily=" .. dailyParams .. 
                "&hourly=" .. hourlyParams ..
                "&current_weather=true" ..
                "&temperature_unit=" .. unitParam .. 
                "&wind_speed_unit=" .. windUnit .. 
                "&precipitation_unit=" .. precipUnit .. 
                "&timezone=auto&forecast_days=1"

    dbg("Fetching: " .. url)

    local options = { 
        fail_on_error = false,
        timeout = 30000  -- 30 second timeout
    }

    local context = { isRetry = isRetry or false }
    urlGet(url, {}, CheckResponse, context, options)
end

function CheckResponse(strError, responseCode, tHeaders, data, context, url)
    if (strError) then
        dbg("Network Error: " .. strError)

        -- Retry once if this wasn't already a retry
        if not context.isRetry then
            dbg("Scheduling retry in 30 seconds...")
            if g_RetryTimer then g_RetryTimer:Cancel() end
            g_RetryTimer = C4:SetTimer(30000, function() 
                FetchWeather(true)
                g_RetryTimer = nil
            end, false)
            return
        end

        C4:FireEvent("Update Failed") 
        return
    end

    if (responseCode ~= 200) then
        dbg("HTTP Error Code: " .. tostring(responseCode))
        C4:FireEvent("Update Failed")
        return
    end

    -- Use pcall for safe JSON decoding
    local success, tData
    if (type(data) == "string") then
        success, tData = pcall(function() return JSON:decode(data) end)
        if not success then
            dbg("JSON Decoding Failed: " .. tostring(tData))
            C4:FireEvent("Update Failed")
            return
        end
    else
        tData = data
    end

    -- Validate data structure
    if not (tData and tData.daily) then
        dbg("Invalid JSON structure - missing daily data")
        C4:FireEvent("Update Failed")
        return
    end

    local d = tData.daily

    -- Validate all required fields exist and have data
    if not (d.temperature_2m_max and d.temperature_2m_max[1] and
            d.temperature_2m_min and d.temperature_2m_min[1] and
            d.apparent_temperature_max and d.apparent_temperature_max[1] and
            d.apparent_temperature_min and d.apparent_temperature_min[1]) then
        dbg("Missing required temperature data in API response")
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
    local timeStr = os.date("%Y-%m-%d %H:%M:%S")

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
    local daylightSeconds = safeNumber(d.daylight_duration and d.daylight_duration[1], 0)
    local daylightMinutes = round(daylightSeconds / 60)

    -- Calculate remaining-day low using hourly data.
    -- The API returns utc_offset_seconds for the requested timezone, so we use
    -- that to determine the current local hour without relying on the controller's TZ.
    local remainingLow = low
    local remainingFeelsLow = feelsLow
    local h = tData.hourly
    if h and h.time and h.temperature_2m and h.apparent_temperature and tData.utc_offset_seconds then
        local utcNow = os.time()  -- seconds since epoch, always UTC
        local localNow = utcNow + tData.utc_offset_seconds
        local currentHour = math.floor(localNow / 3600) % 24  -- 0-23 local hour

        dbg("Current local hour (from API offset): " .. currentHour)

        local minTemp = nil
        local minFeels = nil

        for i, timeStr in ipairs(h.time) do
            -- timestamps are "2026-02-24T14:00" — extract the hour
            local hourStr = string.match(timeStr, "T(%d%d):%d%d$")
            local hourVal = tonumber(hourStr)
            if hourVal and hourVal >= currentHour then
                local t = h.temperature_2m[i]
                local f = h.apparent_temperature[i]
                if type(t) == "number" then
                    if minTemp == nil or t < minTemp then minTemp = t end
                end
                if type(f) == "number" then
                    if minFeels == nil or f < minFeels then minFeels = f end
                end
            end
        end

        if minTemp ~= nil then
            remainingLow = round(minTemp)
            dbg("Remaining low (from hour " .. currentHour .. " onward): " .. remainingLow)
        end
        if minFeels ~= nil then
            remainingFeelsLow = round(minFeels)
            dbg("Remaining feels-like low: " .. remainingFeelsLow)
        end
    else
        dbg("Hourly data unavailable, falling back to daily low for remaining low")
    end

    -- Current conditions
    local currentTemp = 0
    local currentFeels = 0
    local currentWind = 0
    local currentGust = 0
    local currentCloudCover = 0

    if tData.current_weather then
        local cw = tData.current_weather
        currentTemp = safeNumber(cw.temperature, 0)
        currentFeels = safeNumber(cw.apparent_temperature, currentTemp)
        currentWind = safeNumber(cw.wind_speed_10m, 0)
        currentGust = safeNumber(cw.wind_gusts_10m, 0)
        currentCloudCover = safeNumber(cw.cloud_cover, 0)
    else
        dbg("Current weather data unavailable")
    end

    local distLabel = (Properties["Temperature Unit"] == "Celsius") and " km/h" or " mph"
    local rainLabel = (Properties["Temperature Unit"] == "Celsius") and " mm" or " in"

    -- Update properties
    C4:UpdateProperty("Last Update:", timeStr)
    C4:UpdateProperty("Today High:", high .. "°")
    C4:UpdateProperty("Today Low:", low .. "°")
    C4:UpdateProperty("Feels Like High:", feelsHigh .. "°")
    C4:UpdateProperty("Feels Like Low:", feelsLow .. "°")
    C4:UpdateProperty("Remaining Low:", remainingLow .. "°")
    C4:UpdateProperty("Remaining Feels Like Low:", remainingFeelsLow .. "°")
    C4:UpdateProperty("Rain Chance:", rainChance .. "%")
    C4:UpdateProperty("Rain Total:", rainTotal .. rainLabel)
    C4:UpdateProperty("Rain Hours:", rainHrs .. " hrs")
    C4:UpdateProperty("Max Wind:", wind .. distLabel)
    C4:UpdateProperty("Max Gust:", maxGust .. distLabel)
    C4:UpdateProperty("UV Index:", uv)
    C4:UpdateProperty("Weather Code:", tostring(weatherCode))
    C4:UpdateProperty("Sunrise:", formatIsoTime(sunriseIso))
    C4:UpdateProperty("Sunset:", formatIsoTime(sunsetIso))
    C4:UpdateProperty("Daylight (min):", tostring(daylightMinutes))
    C4:UpdateProperty("Current Temp:", tostring(round(currentTemp)) .. "°")
    C4:UpdateProperty("Current Feels Like:", tostring(round(currentFeels)) .. "°")
    C4:UpdateProperty("Current Wind:", currentWind .. distLabel)
    C4:UpdateProperty("Current Gust:", currentGust .. distLabel)
    C4:UpdateProperty("Cloud Cover:", currentCloudCover .. "%")

    -- Update variables
    C4:SetVariable("LAST_UPDATE", timeStr)
    C4:SetVariable("TODAY_HIGH", high)
    C4:SetVariable("TODAY_LOW", low)
    C4:SetVariable("FEELS_LIKE_HIGH", feelsHigh)
    C4:SetVariable("FEELS_LIKE_LOW", feelsLow)
    C4:SetVariable("REMAINING_LOW", remainingLow)
    C4:SetVariable("REMAINING_FEELS_LIKE_LOW", remainingFeelsLow)
    C4:SetVariable("RAIN_CHANCE", rainChance)
    C4:SetVariable("RAIN_TOTAL", rainTotal)
    C4:SetVariable("RAIN_HOURS", rainHrs)
    C4:SetVariable("MAX_WIND", wind)
    C4:SetVariable("MAX_GUST", maxGust)
    C4:SetVariable("UV_INDEX", uv)
    C4:SetVariable("WEATHER_CODE", weatherCode)
    C4:SetVariable("SUNRISE", formatIsoTime(sunriseIso))
    C4:SetVariable("SUNSET", formatIsoTime(sunsetIso))
    C4:SetVariable("DAYLIGHT_MINUTES", daylightMinutes)
    C4:SetVariable("CURRENT_TEMP", round(currentTemp))
    C4:SetVariable("CURRENT_FEELS_LIKE", round(currentFeels))
    C4:SetVariable("CURRENT_WIND", currentWind)
    C4:SetVariable("CURRENT_GUST", currentGust)
    C4:SetVariable("CURRENT_CLOUD_COVER", currentCloudCover)

    dbg("Weather Updated Successfully")
    C4:FireEvent("Weather Updated")
end

function ExecuteCommand(strCommand, tParams)
    dbg("ExecuteCommand called: " .. tostring(strCommand))

    -- Handle actions from UI buttons
    if strCommand == "LUA_ACTION" then
        if tParams and tParams.ACTION then
            dbg("Action received: " .. tostring(tParams.ACTION))
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
    if g_UpdateTimer then
        g_UpdateTimer:Cancel()
        g_UpdateTimer = nil
    end
    if g_RetryTimer then
        g_RetryTimer:Cancel()
        g_RetryTimer = nil
    end
end
