-- driver.lua

require ('drivers-common-public.global.lib')
require ('drivers-common-public.global.timer')
require ('drivers-common-public.global.url')
JSON = require ('drivers-common-public.module.json')

g_UpdateTimer = nil

function dbg(message)
    if (Properties['Debug Mode'] == 'On') then
        print('Weather: ' .. tostring(message))
    end
end

function OnDriverLateInit()
    if (not (Variables and Variables.TODAY_HIGH)) then C4:AddVariable("TODAY_HIGH", "0", "NUMBER", true, false) end
    if (not (Variables and Variables.TODAY_LOW)) then C4:AddVariable("TODAY_LOW", "0", "NUMBER", true, false) end
    if (not (Variables and Variables.FEELS_LIKE_HIGH)) then C4:AddVariable("FEELS_LIKE_HIGH", "0", "NUMBER", true, false) end
    if (not (Variables and Variables.FEELS_LIKE_LOW)) then C4:AddVariable("FEELS_LIKE_LOW", "0", "NUMBER", true, false) end
    if (not (Variables and Variables.RAIN_CHANCE)) then C4:AddVariable("RAIN_CHANCE", "0", "NUMBER", true, false) end
    if (not (Variables and Variables.RAIN_TOTAL)) then C4:AddVariable("RAIN_TOTAL", "0", "NUMBER", true, false) end
    if (not (Variables and Variables.RAIN_HOURS)) then C4:AddVariable("RAIN_HOURS", "0", "NUMBER", true, false) end
    if (not (Variables and Variables.MAX_WIND)) then C4:AddVariable("MAX_WIND", "0", "NUMBER", true, false) end
    if (not (Variables and Variables.UV_INDEX)) then C4:AddVariable("UV_INDEX", "0", "NUMBER", true, false) end
    if (not (Variables and Variables.LAST_UPDATE)) then C4:AddVariable("LAST_UPDATE", "Never", "STRING", true, false) end


    for property, _ in pairs(Properties) do
        OnPropertyChanged(property)
    end

    StartUpdateTimer()
    FetchWeather()
end

function OnPropertyChanged(strProperty)
    if (strProperty == 'Debug Mode') then
        if (Properties['Debug Mode'] == 'On') then print("Weather: Debug Mode Enabled") end
    elseif (strProperty == 'Update Interval (minutes)') then
        StartUpdateTimer()
    elseif (strProperty == 'Latitude' or strProperty == 'Longitude' or strProperty == 'Temperature Unit') then
        FetchWeather()
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

function FetchWeather()
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
                        "wind_speed_10m_max,uv_index_max"

    local url = "https://api.open-meteo.com/v1/forecast?latitude=" .. lat .. 
                "&longitude=" .. lon .. 
                "&daily=" .. dailyParams .. 
                "&temperature_unit=" .. unitParam .. 
                "&wind_speed_unit=" .. windUnit .. 
                "&precipitation_unit=" .. precipUnit .. 
                "&timezone=auto&forecast_days=1"
    
    dbg("Fetching: " .. url)
    
    local options = { fail_on_error = false }
    urlGet(url, {}, CheckResponse, {}, options)
end

function CheckResponse(strError, responseCode, tHeaders, data, context, url)
    if (strError) then
        dbg("Network Error: " .. strError)
        C4:FireEvent("Update Failed") 
        return
    end

    if (responseCode ~= 200) then
        dbg("HTTP Error Code: " .. tostring(responseCode))
        C4:FireEvent("Update Failed")
        return
    end

    local tData = data
    if (type(data) == "string") then
        tData = JSON:decode(data)
    end
    
    if (tData and tData.daily) then
        local d = tData.daily
        local timeStr = os.date("%Y-%m-%d %H:%M:%S")
        
        local function round(num) return math.floor(num + 0.5) end
        
        local high = round(d.temperature_2m_max[1])
        local low = round(d.temperature_2m_min[1])
        local feelsHigh = round(d.apparent_temperature_max[1])
        local feelsLow = round(d.apparent_temperature_min[1])
        
        local rainChance = d.precipitation_probability_max[1]
        local rainTotal = d.precipitation_sum[1]
        local rainHrs = d.precipitation_hours[1]
        local wind = d.wind_speed_10m_max[1]
        local uv = d.uv_index_max[1]

        local distLabel = (Properties["Temperature Unit"] == "Celsius") and " km/h" or " mph"
        local rainLabel = (Properties["Temperature Unit"] == "Celsius") and " mm" or " in"

        C4:UpdateProperty("Last Update:", timeStr)
        C4:UpdateProperty("Today High:", high .. "°")
        C4:UpdateProperty("Today Low:", low .. "°")
        C4:UpdateProperty("Feels Like High:", feelsHigh .. "°")
        C4:UpdateProperty("Feels Like Low:", feelsLow .. "°")
        
        C4:UpdateProperty("Rain Chance:", rainChance .. "%")
        C4:UpdateProperty("Rain Total:", rainTotal .. rainLabel)
        C4:UpdateProperty("Rain Hours:", rainHrs .. " hrs")
        C4:UpdateProperty("Max Wind:", wind .. distLabel)
        C4:UpdateProperty("UV Index:", uv)

   
        C4:SetVariable("LAST_UPDATE", timeStr)
        C4:SetVariable("TODAY_HIGH", high)
        C4:SetVariable("TODAY_LOW", low)
        C4:SetVariable("FEELS_LIKE_HIGH", feelsHigh)
        C4:SetVariable("FEELS_LIKE_LOW", feelsLow)
        C4:SetVariable("RAIN_CHANCE", rainChance)
        C4:SetVariable("RAIN_TOTAL", rainTotal)
        C4:SetVariable("RAIN_HOURS", rainHrs)
        C4:SetVariable("MAX_WIND", wind)
        C4:SetVariable("UV_INDEX", uv)

        dbg("Weather Updated Successfully")
        C4:FireEvent("Weather Updated")
    else
        dbg("JSON Decoding Failed or Invalid Structure")
        C4:FireEvent("Update Failed")
    end
end

function ExecuteCommand(strCommand, tParams)
    if strCommand == "REFRESH_WEATHER" then 
        FetchWeather() 
    end
end

function OnDriverDestroyed()
    if g_UpdateTimer then
        g_UpdateTimer:Cancel()
        g_UpdateTimer = nil
    end
end