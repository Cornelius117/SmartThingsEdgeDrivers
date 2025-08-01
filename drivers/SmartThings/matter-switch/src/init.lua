-- Copyright 2025 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local capabilities = require "st.capabilities"
local log = require "log"
local clusters = require "st.matter.clusters"
local im = require "st.matter.interaction_model"
local MatterDriver = require "st.matter.driver"
local lua_socket = require "socket"
local utils = require "st.utils"
local device_lib = require "st.device"
local embedded_cluster_utils = require "embedded-cluster-utils"
local version = require "version"

-- Include driver-side definitions when lua libs api version is < 11
if version.api < 11 then
  clusters.ElectricalEnergyMeasurement = require "ElectricalEnergyMeasurement"
  clusters.ElectricalPowerMeasurement = require "ElectricalPowerMeasurement"
  clusters.ValveConfigurationAndControl = require "ValveConfigurationAndControl"
end

local MOST_RECENT_TEMP = "mostRecentTemp"
local RECEIVED_X = "receivedX"
local RECEIVED_Y = "receivedY"
local HUESAT_SUPPORT = "huesatSupport"
local MIRED_KELVIN_CONVERSION_CONSTANT = 1000000
-- These values are a "sanity check" to check that values we are getting are reasonable
local COLOR_TEMPERATURE_KELVIN_MAX = 15000
local COLOR_TEMPERATURE_KELVIN_MIN = 1000
local COLOR_TEMPERATURE_MIRED_MAX = MIRED_KELVIN_CONVERSION_CONSTANT/COLOR_TEMPERATURE_KELVIN_MIN
local COLOR_TEMPERATURE_MIRED_MIN = MIRED_KELVIN_CONVERSION_CONSTANT/COLOR_TEMPERATURE_KELVIN_MAX
local SWITCH_LEVEL_LIGHTING_MIN = 1
local CURRENT_HUESAT_ATTR_MIN = 0
local CURRENT_HUESAT_ATTR_MAX = 254

-- COMPONENT_TO_ENDPOINT_MAP is here to preserve the endpoint mapping for
-- devices that were joined to this driver as MCD devices before the transition
-- to join switch devices as parent-child. This value will exist in the device
-- table for devices that joined prior to this transition, and is also used for
-- button devices that require component mapping.
local COMPONENT_TO_ENDPOINT_MAP = "__component_to_endpoint_map"
local IS_PARENT_CHILD_DEVICE = "__is_parent_child_device"
local COLOR_TEMP_BOUND_RECEIVED_KELVIN = "__colorTemp_bound_received_kelvin"
local COLOR_TEMP_BOUND_RECEIVED_MIRED = "__colorTemp_bound_received_mired"
local COLOR_TEMP_MIN = "__color_temp_min"
local COLOR_TEMP_MAX = "__color_temp_max"
local LEVEL_BOUND_RECEIVED = "__level_bound_received"
local LEVEL_MIN = "__level_min"
local LEVEL_MAX = "__level_max"
local COLOR_MODE = "__color_mode"

local updated_fields = {
  { current_field_name = "__component_to_endpoint_map_button", updated_field_name = COMPONENT_TO_ENDPOINT_MAP },
  { current_field_name = "__switch_intialized", updated_field_name = nil },
  { current_field_name = "__energy_management_endpoint", updated_field_name = nil }
}

local HUE_SAT_COLOR_MODE = clusters.ColorControl.types.ColorMode.CURRENT_HUE_AND_CURRENT_SATURATION
local X_Y_COLOR_MODE = clusters.ColorControl.types.ColorMode.CURRENTX_AND_CURRENTY

local AGGREGATOR_DEVICE_TYPE_ID = 0x000E
local ON_OFF_LIGHT_DEVICE_TYPE_ID = 0x0100
local DIMMABLE_LIGHT_DEVICE_TYPE_ID = 0x0101
local COLOR_TEMP_LIGHT_DEVICE_TYPE_ID = 0x010C
local EXTENDED_COLOR_LIGHT_DEVICE_TYPE_ID = 0x010D
local ON_OFF_PLUG_DEVICE_TYPE_ID = 0x010A
local DIMMABLE_PLUG_DEVICE_TYPE_ID = 0x010B
local ON_OFF_SWITCH_ID = 0x0103
local ON_OFF_DIMMER_SWITCH_ID = 0x0104
local ON_OFF_COLOR_DIMMER_SWITCH_ID = 0x0105
local MOUNTED_ON_OFF_CONTROL_ID = 0x010F
local MOUNTED_DIMMABLE_LOAD_CONTROL_ID = 0x0110
local GENERIC_SWITCH_ID = 0x000F
local ELECTRICAL_SENSOR_ID = 0x0510
local device_type_profile_map = {
  [ON_OFF_LIGHT_DEVICE_TYPE_ID] = "light-binary",
  [DIMMABLE_LIGHT_DEVICE_TYPE_ID] = "light-level",
  [COLOR_TEMP_LIGHT_DEVICE_TYPE_ID] = "light-level-colorTemperature",
  [EXTENDED_COLOR_LIGHT_DEVICE_TYPE_ID] = "light-color-level",
  [ON_OFF_PLUG_DEVICE_TYPE_ID] = "plug-binary",
  [DIMMABLE_PLUG_DEVICE_TYPE_ID] = "plug-level",
  [ON_OFF_SWITCH_ID] = "switch-binary",
  [ON_OFF_DIMMER_SWITCH_ID] = "switch-level",
  [ON_OFF_COLOR_DIMMER_SWITCH_ID] = "switch-color-level",
  [MOUNTED_ON_OFF_CONTROL_ID] = "switch-binary",
  [MOUNTED_DIMMABLE_LOAD_CONTROL_ID] = "switch-level",
}

local device_type_attribute_map = {
  [ON_OFF_LIGHT_DEVICE_TYPE_ID] = {
    clusters.OnOff.attributes.OnOff
  },
  [DIMMABLE_LIGHT_DEVICE_TYPE_ID] = {
    clusters.OnOff.attributes.OnOff,
    clusters.LevelControl.attributes.CurrentLevel,
    clusters.LevelControl.attributes.MaxLevel,
    clusters.LevelControl.attributes.MinLevel
  },
  [COLOR_TEMP_LIGHT_DEVICE_TYPE_ID] = {
    clusters.OnOff.attributes.OnOff,
    clusters.LevelControl.attributes.CurrentLevel,
    clusters.LevelControl.attributes.MaxLevel,
    clusters.LevelControl.attributes.MinLevel,
    clusters.ColorControl.attributes.ColorTemperatureMireds,
    clusters.ColorControl.attributes.ColorTempPhysicalMaxMireds,
    clusters.ColorControl.attributes.ColorTempPhysicalMinMireds
  },
  [EXTENDED_COLOR_LIGHT_DEVICE_TYPE_ID] = {
    clusters.OnOff.attributes.OnOff,
    clusters.LevelControl.attributes.CurrentLevel,
    clusters.LevelControl.attributes.MaxLevel,
    clusters.LevelControl.attributes.MinLevel,
    clusters.ColorControl.attributes.ColorTemperatureMireds,
    clusters.ColorControl.attributes.ColorTempPhysicalMaxMireds,
    clusters.ColorControl.attributes.ColorTempPhysicalMinMireds,
    clusters.ColorControl.attributes.CurrentHue,
    clusters.ColorControl.attributes.CurrentSaturation,
    clusters.ColorControl.attributes.CurrentX,
    clusters.ColorControl.attributes.CurrentY
  },
  [ON_OFF_PLUG_DEVICE_TYPE_ID] = {
    clusters.OnOff.attributes.OnOff
  },
  [DIMMABLE_PLUG_DEVICE_TYPE_ID] = {
    clusters.OnOff.attributes.OnOff,
    clusters.LevelControl.attributes.CurrentLevel,
    clusters.LevelControl.attributes.MaxLevel,
    clusters.LevelControl.attributes.MinLevel
  },
  [ON_OFF_SWITCH_ID] = {
    clusters.OnOff.attributes.OnOff
  },
  [ON_OFF_DIMMER_SWITCH_ID] = {
    clusters.OnOff.attributes.OnOff,
    clusters.LevelControl.attributes.CurrentLevel,
    clusters.LevelControl.attributes.MaxLevel,
    clusters.LevelControl.attributes.MinLevel
  },
  [ON_OFF_COLOR_DIMMER_SWITCH_ID] = {
    clusters.OnOff.attributes.OnOff,
    clusters.LevelControl.attributes.CurrentLevel,
    clusters.LevelControl.attributes.MaxLevel,
    clusters.LevelControl.attributes.MinLevel,
    clusters.ColorControl.attributes.ColorTemperatureMireds,
    clusters.ColorControl.attributes.ColorTempPhysicalMaxMireds,
    clusters.ColorControl.attributes.ColorTempPhysicalMinMireds,
    clusters.ColorControl.attributes.CurrentHue,
    clusters.ColorControl.attributes.CurrentSaturation,
    clusters.ColorControl.attributes.CurrentX,
    clusters.ColorControl.attributes.CurrentY
  },
  [GENERIC_SWITCH_ID] = {
    clusters.PowerSource.attributes.BatPercentRemaining,
    clusters.Switch.events.InitialPress,
    clusters.Switch.events.LongPress,
    clusters.Switch.events.ShortRelease,
    clusters.Switch.events.MultiPressComplete
  },
  [ELECTRICAL_SENSOR_ID] = {
    clusters.ElectricalPowerMeasurement.attributes.ActivePower,
    clusters.ElectricalEnergyMeasurement.attributes.CumulativeEnergyImported,
    clusters.ElectricalEnergyMeasurement.attributes.PeriodicEnergyImported
  }
}

local device_overrides_per_vendor = {
  [0x1321] = {
    { product_id = 0x000C, target_profile = "switch-binary", initial_profile = "plug-binary" },
    { product_id = 0x000D, target_profile = "switch-binary", initial_profile = "plug-binary" },
  },
  [0x115F] = {
    { product_id = 0x1003, combo_switch_button = false }, -- 2 Buttons(Generic Switch), 1 Channel(On/Off Light)
    { product_id = 0x1004, combo_switch_button = false }, -- 2 Buttons(Generic Switch), 2 Channels(On/Off Light)
    { product_id = 0x1005, combo_switch_button = false }, -- 4 Buttons(Generic Switch), 3 Channels(On/Off Light)
    { product_id = 0x1006, combo_switch_button = false }, -- 3 Buttons(Generic Switch), 1 Channels(Dimmable Light)
    { product_id = 0x1008, combo_switch_button = false }, -- 2 Buttons(Generic Switch), 1 Channel(On/Off Light)
    { product_id = 0x1009, combo_switch_button = false }, -- 4 Buttons(Generic Switch), 2 Channels(On/Off Light)
    { product_id = 0x100A, combo_switch_button = false }, -- 1 Buttons(Generic Switch), 1 Channels(Dimmable Light)
  }

}

local detect_matter_thing

local CUMULATIVE_REPORTS_NOT_SUPPORTED = "__cumulative_reports_not_supported"
local FIRST_IMPORT_REPORT_TIMESTAMP = "__first_import_report_timestamp"
local IMPORT_POLL_TIMER_SETTING_ATTEMPTED = "__import_poll_timer_setting_attempted"
local IMPORT_REPORT_TIMEOUT = "__import_report_timeout"
local TOTAL_IMPORTED_ENERGY = "__total_imported_energy"
local LAST_IMPORTED_REPORT_TIMESTAMP = "__last_imported_report_timestamp"
local RECURRING_IMPORT_REPORT_POLL_TIMER = "__recurring_import_report_poll_timer"
local MINIMUM_ST_ENERGY_REPORT_INTERVAL = (15 * 60) -- 15 minutes, reported in seconds
local SUBSCRIPTION_REPORT_OCCURRED = "__subscription_report_occurred"
local CONVERSION_CONST_MILLIWATT_TO_WATT = 1000 -- A milliwatt is 1/1000th of a watt

local ELECTRICAL_SENSOR_EPS = "__ELECTRICAL_SENSOR_EPS"

local profiling_data = {
  ELECTRICAL_TOPOLOGY = "__ELECTRICAL_TOPOLOGY",
}

-- Return an ISO-8061 timestamp in UTC
local function iso8061Timestamp(time)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", time)
end

local function delete_import_poll_schedule(device)
  local import_poll_timer = device:get_field(RECURRING_IMPORT_REPORT_POLL_TIMER)
  if import_poll_timer then
    device.thread:cancel_timer(import_poll_timer)
    device:set_field(RECURRING_IMPORT_REPORT_POLL_TIMER, nil)
    device:set_field(IMPORT_POLL_TIMER_SETTING_ATTEMPTED, nil)
  end
end

local function send_import_poll_report(device, latest_total_imported_energy_wh)
  local current_time = os.time()
  local last_time = device:get_field(LAST_IMPORTED_REPORT_TIMESTAMP) or 0
  device:set_field(LAST_IMPORTED_REPORT_TIMESTAMP, current_time, { persist = true })

  -- Calculate the energy delta between reports
  local energy_delta_wh = 0.0
  local previous_imported_report = device:get_latest_state("main", capabilities.powerConsumptionReport.ID,
    capabilities.powerConsumptionReport.powerConsumption.NAME)
  if previous_imported_report and previous_imported_report.energy then
    energy_delta_wh = math.max(latest_total_imported_energy_wh - previous_imported_report.energy, 0.0)
  end

  -- Report the energy consumed during the time interval on the first device that supports it. The unit of these values should be 'Wh'
  if device:get_parent_device() and device:get_parent_device():supports_capability(capabilities.powerConsumptionReport) then
    device = device:get_parent_device()
  elseif device:get_parent_device() ~= nil then
    device = device:get_parent_device():get_child_list()[1]
  end
  local component = device.profile.components["main"]
  device:emit_component_event(component, capabilities.powerConsumptionReport.powerConsumption({
    start = iso8061Timestamp(last_time),
    ["end"] = iso8061Timestamp(current_time - 1),
    deltaEnergy = energy_delta_wh,
    energy = latest_total_imported_energy_wh
  }))

end

local function create_poll_report_schedule(device)
  local import_timer = device.thread:call_on_schedule(
    device:get_field(IMPORT_REPORT_TIMEOUT), function()
    local total_imported_energy = 0
    for _, energy_report in pairs(device:get_field(TOTAL_IMPORTED_ENERGY)) do
      total_imported_energy = total_imported_energy + energy_report
    end
    send_import_poll_report(device, total_imported_energy)
    end, "polling_import_report_schedule_timer"
  )
  device:set_field(RECURRING_IMPORT_REPORT_POLL_TIMER, import_timer)
end

local function set_poll_report_timer_and_schedule(device, is_cumulative_report)
  local cumul_eps = embedded_cluster_utils.get_endpoints(device,
    clusters.ElectricalEnergyMeasurement.ID,
    {feature_bitmap = clusters.ElectricalEnergyMeasurement.types.Feature.CUMULATIVE_ENERGY })
  if #cumul_eps == 0 then
    device:set_field(CUMULATIVE_REPORTS_NOT_SUPPORTED, true, {persist = true})
  end
  if #cumul_eps > 0 and not is_cumulative_report then
    return
  elseif not device:get_field(SUBSCRIPTION_REPORT_OCCURRED) then
    device:set_field(SUBSCRIPTION_REPORT_OCCURRED, true)
  elseif not device:get_field(FIRST_IMPORT_REPORT_TIMESTAMP) then
    device:set_field(FIRST_IMPORT_REPORT_TIMESTAMP, os.time())
  else
    local first_timestamp = device:get_field(FIRST_IMPORT_REPORT_TIMESTAMP)
    local second_timestamp = os.time()
    local report_interval_secs = second_timestamp - first_timestamp
    device:set_field(IMPORT_REPORT_TIMEOUT, math.max(report_interval_secs, MINIMUM_ST_ENERGY_REPORT_INTERVAL))
    -- the poll schedule is only needed for devices that support powerConsumptionReport
    if device:supports_capability(capabilities.powerConsumptionReport) then
      create_poll_report_schedule(device)
    end
    device:set_field(IMPORT_POLL_TIMER_SETTING_ATTEMPTED, true)
  end
end

local START_BUTTON_PRESS = "__start_button_press"
local TIMEOUT_THRESHOLD = 10 --arbitrary timeout
local HELD_THRESHOLD = 1
-- this is the number of buttons for which we have a static profile already made
local STATIC_BUTTON_PROFILE_SUPPORTED = {1, 2, 3, 4, 5, 6, 7, 8}

-- Some switches will send a MultiPressComplete event as part of a long press sequence. Normally the driver will create a
-- button capability event on receipt of MultiPressComplete, but in this case that would result in an extra event because
-- the "held" capability event is generated when the LongPress event is received. The IGNORE_NEXT_MPC flag is used
-- to tell the driver to ignore MultiPressComplete if it is received after a long press to avoid this extra event.
local IGNORE_NEXT_MPC = "__ignore_next_mpc"

-- These are essentially storing the supported features of a given endpoint
-- TODO: add an is_feature_supported_for_endpoint function to matter.device that takes an endpoint
local EMULATE_HELD = "__emulate_held" -- for non-MSR (MomentarySwitchRelease) devices we can emulate this on the software side
local SUPPORTS_MULTI_PRESS = "__multi_button" -- for MSM devices (MomentarySwitchMultiPress), create an event on receipt of MultiPressComplete
local INITIAL_PRESS_ONLY = "__initial_press_only" -- for devices that support MS (MomentarySwitch), but not MSR (MomentarySwitchRelease)

local TEMP_BOUND_RECEIVED = "__temp_bound_received"
local TEMP_MIN = "__temp_min"
local TEMP_MAX = "__temp_max"

local AQARA_MANUFACTURER_ID = 0x115F
local AQARA_CLIMATE_SENSOR_W100_ID = 0x2004

--helper function to create list of multi press values
local function create_multi_press_values_list(size, supportsHeld)
  local list = {"pushed", "double"}
  if supportsHeld then table.insert(list, "held") end
  -- add multi press values of 3 or greater to the list
  for i=3, size do
    table.insert(list, string.format("pushed_%dx", i))
  end
  return list
end

-- get a list of endpoints for a specified device type.
local function get_endpoints_by_dt(device, device_type_id)
  local dt_eps = {}
  for _, ep in ipairs(device.endpoints) do
    for _, dt in ipairs(ep.device_types) do
      if dt.device_type_id == device_type_id then
        table.insert(dt_eps, ep.endpoint_id)
      end
    end
  end
  return dt_eps
end

local function tbl_contains(array, value)
  for _, element in ipairs(array) do
    if element == value then
      return true
    end
  end
  return false
end

local function get_field_for_endpoint(device, field, endpoint)
  return device:get_field(string.format("%s_%d", field, endpoint))
end

local function set_field_for_endpoint(device, field, endpoint, value, additional_params)
  device:set_field(string.format("%s_%d", field, endpoint), value, additional_params)
end

local function init_press(device, endpoint)
  set_field_for_endpoint(device, START_BUTTON_PRESS, endpoint, lua_socket.gettime(), {persist = false})
end

local function emulate_held_event(device, ep)
  local now = lua_socket.gettime()
  local press_init = get_field_for_endpoint(device, START_BUTTON_PRESS, ep) or now -- if we don't have an init time, assume instant release
  if (now - press_init) < TIMEOUT_THRESHOLD then
    if (now - press_init) > HELD_THRESHOLD then
      device:emit_event_for_endpoint(ep, capabilities.button.button.held({state_change = true}))
    else
      device:emit_event_for_endpoint(ep, capabilities.button.button.pushed({state_change = true}))
    end
  end
  set_field_for_endpoint(device, START_BUTTON_PRESS, ep, nil, {persist = false})
end

local function convert_huesat_st_to_matter(val)
  return utils.clamp_value(math.floor((val * 0xFE) / 100.0 + 0.5), CURRENT_HUESAT_ATTR_MIN, CURRENT_HUESAT_ATTR_MAX)
end

local function mired_to_kelvin(value, minOrMax)
  if value == 0 then -- shouldn't happen, but has
    value = 1
    log.warn(string.format("Received a color temperature of 0 mireds. Using a color temperature of 1 mired to avoid divide by zero"))
  end
  -- We divide inside the rounding and multiply outside of it because we expect these
  -- bounds to be multiples of 100. For the maximum mired value (minimum K value),
  -- add 1 before converting and round up to nearest hundreds. For the minimum mired
  -- (maximum K value) value, subtract 1 before converting and round down to nearest
  -- hundreds. Note that 1 is added/subtracted from the mired value in order to avoid
  -- rounding errors from the conversion of Kelvin to mireds.
  local kelvin_step_size = 100
  local rounding_value = 0.5
  if minOrMax == COLOR_TEMP_MIN then
    return utils.round(MIRED_KELVIN_CONVERSION_CONSTANT / (kelvin_step_size * (value + 1)) + rounding_value) * kelvin_step_size
  elseif minOrMax == COLOR_TEMP_MAX then
    return utils.round(MIRED_KELVIN_CONVERSION_CONSTANT / (kelvin_step_size * (value - 1)) - rounding_value) * kelvin_step_size
  else
    log.warn_with({hub_logs = true}, "Attempted to convert temperature unit for an undefined value")
  end
end

--- device_type_supports_button_switch_combination helper function used to check
--- whether the device type for an endpoint is currently supported by a profile for
--- combination button/switch devices.
local function device_type_supports_button_switch_combination(device, endpoint_id)
  for _, fingerprint in ipairs(device_overrides_per_vendor[AQARA_MANUFACTURER_ID] or {}) do
    if fingerprint.product_id == device.manufacturer_info.product_id and fingerprint.combo_switch_button == false then
      return false -- For Aqara Dimmer Switch with Button.
    end
  end
  local dimmable_eps = get_endpoints_by_dt(device, DIMMABLE_LIGHT_DEVICE_TYPE_ID)
  return tbl_contains(dimmable_eps, endpoint_id)
end

local function get_first_non_zero_endpoint(endpoints)
  table.sort(endpoints)
  for _,ep in ipairs(endpoints) do
    if ep ~= 0 then -- 0 is the matter RootNode endpoint
      return ep
    end
  end
  return nil
end

--- find_default_endpoint is a helper function to handle situations where
--- device does not have endpoint ids in sequential order from 1
local function find_default_endpoint(device)
  if device.manufacturer_info.vendor_id == AQARA_MANUFACTURER_ID and
     device.manufacturer_info.product_id == AQARA_CLIMATE_SENSOR_W100_ID then
    -- In case of Aqara Climate Sensor W100, in order to sequentially set the button name to button 1, 2, 3
    return device.MATTER_DEFAULT_ENDPOINT
  end

  local switch_eps = device:get_endpoints(clusters.OnOff.ID)
  local button_eps = device:get_endpoints(clusters.Switch.ID, {feature_bitmap=clusters.Switch.types.SwitchFeature.MOMENTARY_SWITCH})

  -- Return the first switch endpoint as the default endpoint if no button endpoints are present
  if #button_eps == 0 and #switch_eps > 0 then
    return get_first_non_zero_endpoint(switch_eps)
  end

  -- Return the first button endpoint as the default endpoint if no switch endpoints are present
  if #switch_eps == 0 and #button_eps > 0 then
    return get_first_non_zero_endpoint(button_eps)
  end

  -- If both switch and button endpoints are present, check the device type on the main switch
  -- endpoint. If it is not a supported device type, return the first button endpoint as the
  -- default endpoint.
  if #switch_eps > 0 and #button_eps > 0 then
    local main_endpoint = get_first_non_zero_endpoint(switch_eps)
    if device_type_supports_button_switch_combination(device, main_endpoint) then
      return main_endpoint
    else
      device.log.warn("The main switch endpoint does not contain a supported device type for a component configuration with buttons")
      return get_first_non_zero_endpoint(button_eps)
    end
  end

  device.log.warn(string.format("Did not find default endpoint, will use endpoint %d instead", device.MATTER_DEFAULT_ENDPOINT))
  return device.MATTER_DEFAULT_ENDPOINT
end

local function component_to_endpoint(device, component)
  local map = device:get_field(COMPONENT_TO_ENDPOINT_MAP) or {}
  if map[component] then
    return map[component]
  end
  return find_default_endpoint(device)
end

local function endpoint_to_component(device, ep)
  local map = device:get_field(COMPONENT_TO_ENDPOINT_MAP) or {}
  for component, endpoint in pairs(map) do
    if endpoint == ep then
      return component
    end
  end
  return "main"
end

local function check_field_name_updates(device)
  for _, field in ipairs(updated_fields) do
    if device:get_field(field.current_field_name) then
      if field.updated_field_name ~= nil then
        device:set_field(field.updated_field_name, device:get_field(field.current_field_name), {persist = true})
      end
      device:set_field(field.current_field_name, nil)
    end
  end
end

local function assign_switch_profile(device, switch_ep, is_child_device, electrical_tags)
  local profile
  for _, ep in ipairs(device.endpoints) do
    if ep.endpoint_id == switch_ep then
      -- Some devices report multiple device types which are a subset of
      -- a superset device type (For example, Dimmable Light is a superset of
      -- On/Off light). This mostly applies to the four light types, so we will want
      -- to match the profile for the superset device type. This can be done by
      -- matching to the device type with the highest ID
      -- Note: Electrical Sensor does not follow the above logic, so it's ignored
      local id = 0
      for _, dt in ipairs(ep.device_types) do
        if dt.device_type_id ~= ELECTRICAL_SENSOR_ID then
          id = math.max(id, dt.device_type_id)
        end
      end
      profile = device_type_profile_map[id]
      break
    end
  end

  if electrical_tags ~= nil and (profile == "plug-binary" or profile == "plug-level" or profile == "light-binary") then
    profile = string.gsub(profile, "-binary", "") .. electrical_tags
  end

  if is_child_device then
      -- Check if child device has an overridden child profile that differs from the child's generic device type profile
      for _, fingerprint in ipairs(device_overrides_per_vendor[device.manufacturer_info.vendor_id] or {}) do
        if device.manufacturer_info.product_id == fingerprint.product_id and profile == fingerprint.initial_profile then
          return fingerprint.target_profile
        end
      end
    -- default to "switch-binary" if no child profile is found
    return profile or "switch-binary"
  end
  return profile
end

local function configure_buttons(device)
  local ms_eps = device:get_endpoints(clusters.Switch.ID, {feature_bitmap=clusters.Switch.types.SwitchFeature.MOMENTARY_SWITCH})
  local msr_eps = device:get_endpoints(clusters.Switch.ID, {feature_bitmap=clusters.Switch.types.SwitchFeature.MOMENTARY_SWITCH_RELEASE})
  local msl_eps = device:get_endpoints(clusters.Switch.ID, {feature_bitmap=clusters.Switch.types.SwitchFeature.MOMENTARY_SWITCH_LONG_PRESS})
  local msm_eps = device:get_endpoints(clusters.Switch.ID, {feature_bitmap=clusters.Switch.types.SwitchFeature.MOMENTARY_SWITCH_MULTI_PRESS})

  for _, ep in ipairs(ms_eps) do
    if device.profile.components[endpoint_to_component(device, ep)] then
      device.log.info_with({hub_logs=true}, string.format("Configuring Supported Values for generic switch endpoint %d", ep))
      local supportedButtonValues_event
      -- this ordering is important, since MSM & MSL devices must also support MSR
      if tbl_contains(msm_eps, ep) then
        supportedButtonValues_event = nil -- deferred to the max press handler
        device:send(clusters.Switch.attributes.MultiPressMax:read(device, ep))
        set_field_for_endpoint(device, SUPPORTS_MULTI_PRESS, ep, true, {persist = true})
      elseif tbl_contains(msl_eps, ep) then
        supportedButtonValues_event = capabilities.button.supportedButtonValues({"pushed", "held"}, {visibility = {displayed = false}})
      elseif tbl_contains(msr_eps, ep) then
        supportedButtonValues_event = capabilities.button.supportedButtonValues({"pushed", "held"}, {visibility = {displayed = false}})
        set_field_for_endpoint(device, EMULATE_HELD, ep, true, {persist = true})
      else -- this switch endpoint only supports momentary switch, no release events
        supportedButtonValues_event = capabilities.button.supportedButtonValues({"pushed"}, {visibility = {displayed = false}})
        set_field_for_endpoint(device, INITIAL_PRESS_ONLY, ep, true, {persist = true})
      end

      if supportedButtonValues_event then
        device:emit_event_for_endpoint(ep, supportedButtonValues_event)
      end
      device:emit_event_for_endpoint(ep, capabilities.button.button.pushed({state_change = false}))
    else
      device.log.info_with({hub_logs=true}, string.format("Component not found for generic switch endpoint %d. Skipping Supported Value configuration", ep))
    end
  end
end

local function find_child(parent, ep_id)
  return parent:get_child_by_parent_assigned_key(string.format("%d", ep_id))
end

local function build_button_component_map(device, main_endpoint, button_eps)
  -- create component mapping on the main profile button endpoints
  table.sort(button_eps)
  local component_map = {}
  component_map["main"] = main_endpoint
  for component_num, ep in ipairs(button_eps) do
    if ep ~= main_endpoint then
      local button_component = "button"
      if #button_eps > 1 then
        button_component = button_component .. component_num
      end
      component_map[button_component] = ep
    end
  end
  device:set_field(COMPONENT_TO_ENDPOINT_MAP, component_map, {persist = true})
end

local function build_button_profile(device, main_endpoint, num_button_eps)
  local profile_name = string.gsub(num_button_eps .. "-button", "1%-", "") -- remove the "1-" in a device with 1 button ep
  if device_type_supports_button_switch_combination(device, main_endpoint) then
    profile_name = "light-level-" .. profile_name
  end
  local battery_supported = #device:get_endpoints(clusters.PowerSource.ID, {feature_bitmap = clusters.PowerSource.types.PowerSourceFeature.BATTERY}) > 0
  if battery_supported then -- battery profiles are configured later, in power_source_attribute_list_handler
    device:send(clusters.PowerSource.attributes.AttributeList:read(device))
  else
    device:try_update_metadata({profile = profile_name})
  end
end

local function build_child_switch_profiles(driver, device, main_endpoint)
  local num_switch_server_eps = 0
  local parent_child_device = false
  local switch_eps = device:get_endpoints(clusters.OnOff.ID)
  table.sort(switch_eps)
  for _, ep in ipairs(switch_eps) do
    if device:supports_server_cluster(clusters.OnOff.ID, ep) then
      num_switch_server_eps = num_switch_server_eps + 1
      if ep ~= main_endpoint then -- don't create a child device that maps to the main endpoint
        local name = string.format("%s %d", device.label, num_switch_server_eps)
        local electrical_tags = device:get_field(profiling_data.ELECTRICAL_TOPOLOGY).tags_on_ep[ep]
        local child_profile = assign_switch_profile(device, ep, true, electrical_tags)
        driver:try_create_device(
          {
            type = "EDGE_CHILD",
            label = name,
            profile = child_profile,
            parent_device_id = device.id,
            parent_assigned_child_key = string.format("%d", ep),
            vendor_provided_label = name
          }
        )
        parent_child_device = true
      end
    end
  end

  -- If the device is a parent child device, set the find_child function on init. This is persisted because initialize_buttons_and_switches
  -- is only run once, but find_child function should be set on each driver init.
  if parent_child_device then
    device:set_field(IS_PARENT_CHILD_DEVICE, true, {persist = true})
  end

  -- this is needed in initialize_buttons_and_switches
  return num_switch_server_eps
end

local function handle_light_switch_with_onOff_server_clusters(device, main_endpoint)
  local cluster_id = 0
  for _, ep in ipairs(device.endpoints) do
    -- main_endpoint only supports server cluster by definition of get_endpoints()
    if main_endpoint == ep.endpoint_id then
      for _, dt in ipairs(ep.device_types) do
        -- no device type that is not in the switch subset should be considered.
        if (ON_OFF_SWITCH_ID <= dt.device_type_id and dt.device_type_id <= ON_OFF_COLOR_DIMMER_SWITCH_ID) then
          cluster_id = math.max(cluster_id, dt.device_type_id)
        end
      end
      break
    end
  end

  if device_type_profile_map[cluster_id] then
    device:try_update_metadata({profile = device_type_profile_map[cluster_id]})
  end
end

local function initialize_buttons(driver, device, main_endpoint)
  local button_eps = device:get_endpoints(clusters.Switch.ID, {feature_bitmap=clusters.Switch.types.SwitchFeature.MOMENTARY_SWITCH})
  if tbl_contains(STATIC_BUTTON_PROFILE_SUPPORTED, #button_eps) then
    build_button_profile(device, main_endpoint, #button_eps)
    -- All button endpoints found will be added as additional components in the profile containing the main_endpoint.
    -- The resulting endpoint to component map is saved in the COMPONENT_TO_ENDPOINT_MAP field
    build_button_component_map(device, main_endpoint, button_eps)
    configure_buttons(device)
    return true
  end
end

local function collect_and_store_electrical_sensor_info(driver, device)
  local el_dt_eps = get_endpoints_by_dt(device, ELECTRICAL_SENSOR_ID)
  local electrical_sensor_eps = {}
  local avail_eps_req = im.InteractionRequest(im.InteractionRequest.RequestType.READ, {})
  for _, ep in ipairs(device.endpoints) do
    if tbl_contains(el_dt_eps, ep.endpoint_id) then
      local electrical_ep_info = {}
      electrical_ep_info.endpoint_id = ep.endpoint_id
      for _, cluster in ipairs(ep.clusters) do
        if cluster.cluster_id == clusters.ElectricalEnergyMeasurement.ID then
          electrical_ep_info.energy = true
        elseif cluster.cluster_id == clusters.ElectricalPowerMeasurement.ID then
          electrical_ep_info.power = true
        elseif cluster.cluster_id == clusters.PowerTopology.ID then
          electrical_ep_info.topology = cluster.feature_map
          if cluster.feature_map == clusters.PowerTopology.types.Feature.SET_TOPOLOGY then
            avail_eps_req:merge(clusters.PowerTopology.attributes.AvailableEndpoints:read(device, ep.endpoint_id))
            electrical_ep_info.availableEndpoints = false
          end
        end
      end
      table.insert(electrical_sensor_eps, electrical_ep_info)
    end
  end
  if #avail_eps_req.info_blocks ~= 0 then
    device:send(avail_eps_req)
  end
  device:set_field(ELECTRICAL_SENSOR_EPS, electrical_sensor_eps)
end

local function initialize_switches(driver, device, main_endpoint)
  -- Without support for bindings, only clusters that are implemented as server are counted. This count is handled
  -- while building switch child profiles
  local num_switch_server_eps = build_child_switch_profiles(driver, device, main_endpoint)
  if device:get_field(IS_PARENT_CHILD_DEVICE) then
    device:set_find_child(find_child)
  end

  -- We do not support the Light Switch device types because they require OnOff to be implemented as 'client', which requires us to support bindings.
  -- However, this workaround profiles devices that claim to be Light Switches, but that break spec and implement OnOff as 'server'.
  -- Note: since their device type isn't supported, these devices join as a matter-thing.
  if num_switch_server_eps > 0 and detect_matter_thing(device) then
    handle_light_switch_with_onOff_server_clusters(device, main_endpoint)
    return true
  end
end

local function detect_bridge(device)
  return #get_endpoints_by_dt(device, AGGREGATOR_DEVICE_TYPE_ID) > 0
end

local function device_init(driver, device)
  if device.network_type == device_lib.NETWORK_TYPE_MATTER then
    check_field_name_updates(device)
    device:set_component_to_endpoint_fn(component_to_endpoint)
    device:set_endpoint_to_component_fn(endpoint_to_component)
    if device:get_field(IS_PARENT_CHILD_DEVICE) then
      device:set_find_child(find_child)
    end
    local main_endpoint = find_default_endpoint(device)
    -- ensure subscription to all endpoint attributes- including those mapped to child devices
    for _, ep in ipairs(device.endpoints) do
      if ep.endpoint_id ~= main_endpoint then
        local id = 0
        for _, dt in ipairs(ep.device_types) do
          if dt.device_type_id == ELECTRICAL_SENSOR_ID then
            for _, attr in pairs(device_type_attribute_map[ELECTRICAL_SENSOR_ID]) do
              device:add_subscribed_attribute(attr)
            end
          end
          id = math.max(id, dt.device_type_id)
        end
        for _, attr in pairs(device_type_attribute_map[id] or {}) do
          if id == GENERIC_SWITCH_ID and
             attr ~= clusters.PowerSource.attributes.BatPercentRemaining and
             attr ~= clusters.PowerSource.attributes.BatChargeLevel then
            device:add_subscribed_event(attr)
          else
            device:add_subscribed_attribute(attr)
          end
        end
      end
    end
    device:subscribe()
  end
end

local function profiling_data_still_required(device)
  for _, field in pairs(profiling_data) do
    if device:get_field(field) == nil then
      return true -- data still required if a field is nil
    end
  end
  return false
end

local function match_profile(driver, device)
  if profiling_data_still_required(device) then return end

  local main_endpoint = find_default_endpoint(device)

  -- initialize the main device card with buttons if applicable, and create child devices as needed for multi-switch devices.
  local button_profile_found = initialize_buttons(driver, device, main_endpoint)
  local switch_profile_found = initialize_switches(driver, device, main_endpoint)
  if button_profile_found or switch_profile_found then
    return
  end

  local fan_eps = device:get_endpoints(clusters.FanControl.ID)
  local valve_eps = embedded_cluster_utils.get_endpoints(device, clusters.ValveConfigurationAndControl.ID)
  local profile_name = nil
  if #valve_eps > 0 then
    profile_name = "water-valve"
    if #embedded_cluster_utils.get_endpoints(device, clusters.ValveConfigurationAndControl.ID,
      {feature_bitmap = clusters.ValveConfigurationAndControl.types.Feature.LEVEL}) > 0 then
      profile_name = profile_name .. "-level"
    end
  elseif #fan_eps > 0 then
    profile_name = "light-color-level-fan"
  end
  if profile_name then
    device:try_update_metadata({ profile = profile_name })
    return
  end

  -- after doing all previous profiling steps, attempt to re-profile main/parent switch/plug device
  local electrical_tags = device:get_field(profiling_data.ELECTRICAL_TOPOLOGY).tags_on_ep[main_endpoint]
  profile_name = assign_switch_profile(device, main_endpoint, false, electrical_tags)
  -- ignore attempts to dynamically profile light-level-colorTemperature and light-color-level devices for now, since
  -- these may lose fingerprinted Kelvin ranges when dynamically profiled.
  if profile_name and profile_name ~= "light-level-colorTemperature" and profile_name ~= "light-color-level" then
    if profile_name == "light-level" and #device:get_endpoints(clusters.OccupancySensing.ID) > 0 then
      profile_name = "light-level-motion"
    end
    device:try_update_metadata({profile = profile_name})
  end

  -- clear all profiling data fields after profiling is complete.
  for _, field in pairs(profiling_data) do
    device:set_field(field, nil)
  end
end

local function do_configure(driver, device)
  if device.network_type == device_lib.NETWORK_TYPE_MATTER and not detect_bridge(device) then
    match_profile(driver, device)
  end
end

local function driver_switched(driver, device)
  if device.network_type == device_lib.NETWORK_TYPE_MATTER and not detect_bridge(device) then
    match_profile(driver, device)
  end
end

local function device_removed(driver, device)
  log.info("device removed")
  delete_import_poll_schedule(device)
end

local function handle_switch_on(driver, device, cmd)
  if type(device.register_native_capability_cmd_handler) == "function" then
    device:register_native_capability_cmd_handler(cmd.capability, cmd.command)
  end
  local endpoint_id = device:component_to_endpoint(cmd.component)
  --TODO use OnWithRecallGlobalScene for devices with the LT feature
  local req = clusters.OnOff.server.commands.On(device, endpoint_id)
  device:send(req)
end

local function handle_switch_off(driver, device, cmd)
  if type(device.register_native_capability_cmd_handler) == "function" then
    device:register_native_capability_cmd_handler(cmd.capability, cmd.command)
  end
  local endpoint_id = device:component_to_endpoint(cmd.component)
  local req = clusters.OnOff.server.commands.Off(device, endpoint_id)
  device:send(req)
end

local function handle_set_switch_level(driver, device, cmd)
  if type(device.register_native_capability_cmd_handler) == "function" then
    device:register_native_capability_cmd_handler(cmd.capability, cmd.command)
  end
  local endpoint_id = device:component_to_endpoint(cmd.component)
  local level = math.floor(cmd.args.level/100.0 * 254)
  local req = clusters.LevelControl.server.commands.MoveToLevelWithOnOff(device, endpoint_id, level, cmd.args.rate, 0, 0)
  device:send(req)
end

local TRANSITION_TIME = 0 --1/10ths of a second
-- When sent with a command, these options mask and override bitmaps cause the command
-- to take effect when the switch/light is off.
local OPTIONS_MASK = 0x01
local OPTIONS_OVERRIDE = 0x01

local function handle_set_color(driver, device, cmd)
  local endpoint_id = device:component_to_endpoint(cmd.component)
  local req
  local huesat_endpoints = device:get_endpoints(clusters.ColorControl.ID, {feature_bitmap = clusters.ColorControl.FeatureMap.HUE_AND_SATURATION})
  if tbl_contains(huesat_endpoints, endpoint_id) then
    local hue = convert_huesat_st_to_matter(cmd.args.color.hue)
    local sat = convert_huesat_st_to_matter(cmd.args.color.saturation)
    req = clusters.ColorControl.server.commands.MoveToHueAndSaturation(device, endpoint_id, hue, sat, TRANSITION_TIME, OPTIONS_MASK, OPTIONS_OVERRIDE)
  else
    local x, y, _ = utils.safe_hsv_to_xy(cmd.args.color.hue, cmd.args.color.saturation)
    req = clusters.ColorControl.server.commands.MoveToColor(device, endpoint_id, x, y, TRANSITION_TIME, OPTIONS_MASK, OPTIONS_OVERRIDE)
  end
  device:send(req)
end

local function handle_set_hue(driver, device, cmd)
  local endpoint_id = device:component_to_endpoint(cmd.component)
  local huesat_endpoints = device:get_endpoints(clusters.ColorControl.ID, {feature_bitmap = clusters.ColorControl.FeatureMap.HUE_AND_SATURATION})
  if tbl_contains(huesat_endpoints, endpoint_id) then
    local hue = convert_huesat_st_to_matter(cmd.args.hue)
    local req = clusters.ColorControl.server.commands.MoveToHue(device, endpoint_id, hue, 0, TRANSITION_TIME, OPTIONS_MASK, OPTIONS_OVERRIDE)
    device:send(req)
  else
    log.warn("Device does not support huesat features on its color control cluster")
  end
end

local function handle_set_saturation(driver, device, cmd)
  local endpoint_id = device:component_to_endpoint(cmd.component)
  local huesat_endpoints = device:get_endpoints(clusters.ColorControl.ID, {feature_bitmap = clusters.ColorControl.FeatureMap.HUE_AND_SATURATION})
  if tbl_contains(huesat_endpoints, endpoint_id) then
    local sat = convert_huesat_st_to_matter(cmd.args.saturation)
    local req = clusters.ColorControl.server.commands.MoveToSaturation(device, endpoint_id, sat, TRANSITION_TIME, OPTIONS_MASK, OPTIONS_OVERRIDE)
    device:send(req)
  else
    log.warn("Device does not support huesat features on its color control cluster")
  end
end

local function handle_set_color_temperature(driver, device, cmd)
  local endpoint_id = device:component_to_endpoint(cmd.component)
  local temp_in_kelvin = cmd.args.temperature
  local min_temp_kelvin = get_field_for_endpoint(device, COLOR_TEMP_BOUND_RECEIVED_KELVIN..COLOR_TEMP_MIN, endpoint_id)
  local max_temp_kelvin = get_field_for_endpoint(device, COLOR_TEMP_BOUND_RECEIVED_KELVIN..COLOR_TEMP_MAX, endpoint_id)

  local temp_in_mired = utils.round(MIRED_KELVIN_CONVERSION_CONSTANT/temp_in_kelvin)
  if min_temp_kelvin ~= nil and temp_in_kelvin <= min_temp_kelvin then
    temp_in_mired = get_field_for_endpoint(device, COLOR_TEMP_BOUND_RECEIVED_MIRED..COLOR_TEMP_MAX, endpoint_id)
  elseif max_temp_kelvin ~= nil and temp_in_kelvin >= max_temp_kelvin then
    temp_in_mired = get_field_for_endpoint(device, COLOR_TEMP_BOUND_RECEIVED_MIRED..COLOR_TEMP_MIN, endpoint_id)
  end
  local req = clusters.ColorControl.server.commands.MoveToColorTemperature(device, endpoint_id, temp_in_mired, TRANSITION_TIME, OPTIONS_MASK, OPTIONS_OVERRIDE)
  device:set_field(MOST_RECENT_TEMP, cmd.args.temperature, {persist = true})
  device:send(req)
end

local function handle_valve_open(driver, device, cmd)
  local endpoint_id = device:component_to_endpoint(cmd.component)
  local req = clusters.ValveConfigurationAndControl.server.commands.Open(device, endpoint_id)
  device:send(req)
end

local function handle_valve_close(driver, device, cmd)
  local endpoint_id = device:component_to_endpoint(cmd.component)
  local req = clusters.ValveConfigurationAndControl.server.commands.Close(device, endpoint_id)
  device:send(req)
end

local function handle_set_level(driver, device, cmd)
  local commands = clusters.ValveConfigurationAndControl.server.commands
  local endpoint_id = device:component_to_endpoint(cmd.component)
  local level = cmd.args.level
  if not level then
    return
  elseif level == 0 then
    device:send(commands.Close(device, endpoint_id))
  else
    device:send(commands.Open(device, endpoint_id, nil, level))
  end
end

local function set_fan_mode(driver, device, cmd)
  local fan_mode_id
  if cmd.args.fanMode == capabilities.fanMode.fanMode.low.NAME then
    fan_mode_id = clusters.FanControl.attributes.FanMode.LOW
  elseif cmd.args.fanMode == capabilities.fanMode.fanMode.medium.NAME then
    fan_mode_id = clusters.FanControl.attributes.FanMode.MEDIUM
  elseif cmd.args.fanMode == capabilities.fanMode.fanMode.high.NAME then
    fan_mode_id = clusters.FanControl.attributes.FanMode.HIGH
  elseif cmd.args.fanMode == capabilities.fanMode.fanMode.auto.NAME then
    fan_mode_id = clusters.FanControl.attributes.FanMode.AUTO
  else
    fan_mode_id = clusters.FanControl.attributes.FanMode.OFF
  end
  if fan_mode_id then
    local fan_ep = device:get_endpoints(clusters.FanControl.ID)[1]
    device:send(clusters.FanControl.attributes.FanMode:write(device, fan_ep, fan_mode_id))
  end
end

local function set_fan_speed_percent(driver, device, cmd)
  local speed = math.floor(cmd.args.percent)
  local fan_ep = device:get_endpoints(clusters.FanControl.ID)[1]
  device:send(clusters.FanControl.attributes.PercentSetting:write(device, fan_ep, speed))
end

-- Fallback handler for responses that dont have their own handler
local function matter_handler(driver, device, response_block)
  log.info(string.format("Fallback handler for %s", response_block))
end

local function on_off_attr_handler(driver, device, ib, response)
  if ib.data.value then
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.switch.switch.on())
  else
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.switch.switch.off())
  end
  if type(device.register_native_capability_attr_handler) == "function" then
    device:register_native_capability_attr_handler("switch", "switch")
  end
end

local function level_attr_handler(driver, device, ib, response)
  if ib.data.value ~= nil then
    local level = math.floor((ib.data.value / 254.0 * 100) + 0.5)
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.switchLevel.level(level))
    if type(device.register_native_capability_attr_handler) == "function" then
      device:register_native_capability_attr_handler("switchLevel", "level")
    end
  end
end

local function hue_attr_handler(driver, device, ib, response)
  if device:get_field(COLOR_MODE) == X_Y_COLOR_MODE  or ib.data.value == nil then
    return
  end
  local hue = math.floor((ib.data.value / 0xFE * 100) + 0.5)
  device:emit_event_for_endpoint(ib.endpoint_id, capabilities.colorControl.hue(hue))
end

local function sat_attr_handler(driver, device, ib, response)
  if device:get_field(COLOR_MODE) == X_Y_COLOR_MODE  or ib.data.value == nil then
    return
  end
  local sat = math.floor((ib.data.value / 0xFE * 100) + 0.5)
  device:emit_event_for_endpoint(ib.endpoint_id, capabilities.colorControl.saturation(sat))
end

local function temp_attr_handler(driver, device, ib, response)
  local temp_in_mired = ib.data.value
  if temp_in_mired == nil then
    return
  end
  if (temp_in_mired < COLOR_TEMPERATURE_MIRED_MIN or temp_in_mired > COLOR_TEMPERATURE_MIRED_MAX) then
    device.log.warn_with({hub_logs = true}, string.format("Device reported color temperature %d mired outside of sane range of %.2f-%.2f", temp_in_mired, COLOR_TEMPERATURE_MIRED_MIN, COLOR_TEMPERATURE_MIRED_MAX))
    return
  end
  local min_temp_mired = get_field_for_endpoint(device, COLOR_TEMP_BOUND_RECEIVED_MIRED..COLOR_TEMP_MIN, ib.endpoint_id)
  local max_temp_mired = get_field_for_endpoint(device, COLOR_TEMP_BOUND_RECEIVED_MIRED..COLOR_TEMP_MAX, ib.endpoint_id)

  local temp = utils.round(MIRED_KELVIN_CONVERSION_CONSTANT/temp_in_mired)
  if min_temp_mired ~= nil and temp_in_mired <= min_temp_mired then
    temp = get_field_for_endpoint(device, COLOR_TEMP_BOUND_RECEIVED_KELVIN..COLOR_TEMP_MAX, ib.endpoint_id)
  elseif max_temp_mired ~= nil and temp_in_mired >= max_temp_mired then
    temp = get_field_for_endpoint(device, COLOR_TEMP_BOUND_RECEIVED_KELVIN..COLOR_TEMP_MIN, ib.endpoint_id)
  end

  local temp_device = device
  if device:get_field(IS_PARENT_CHILD_DEVICE) == true then
    temp_device = find_child(device, ib.endpoint_id) or device
  end
  local most_recent_temp = temp_device:get_field(MOST_RECENT_TEMP)
  -- this is to avoid rounding errors from the round-trip conversion of Kelvin to mireds
  if most_recent_temp ~= nil and
    most_recent_temp <= utils.round(MIRED_KELVIN_CONVERSION_CONSTANT/(temp_in_mired - 1)) and
    most_recent_temp >= utils.round(MIRED_KELVIN_CONVERSION_CONSTANT/(temp_in_mired + 1)) then
      temp = most_recent_temp
  end
  device:emit_event_for_endpoint(ib.endpoint_id, capabilities.colorTemperature.colorTemperature(temp))
end

local mired_bounds_handler_factory = function(minOrMax)
  return function(driver, device, ib, response)
    local temp_in_mired = ib.data.value
    if temp_in_mired == nil then
      return
    end
    if (temp_in_mired < COLOR_TEMPERATURE_MIRED_MIN or temp_in_mired > COLOR_TEMPERATURE_MIRED_MAX) then
      device.log.warn_with({hub_logs = true}, string.format("Device reported a color temperature %d mired outside of sane range of %.2f-%.2f", temp_in_mired, COLOR_TEMPERATURE_MIRED_MIN, COLOR_TEMPERATURE_MIRED_MAX))
      return
    end
    local temp_in_kelvin = mired_to_kelvin(temp_in_mired, minOrMax)
    set_field_for_endpoint(device, COLOR_TEMP_BOUND_RECEIVED_KELVIN..minOrMax, ib.endpoint_id, temp_in_kelvin)
    -- the minimum color temp in kelvin corresponds to the maximum temp in mireds
    if minOrMax == COLOR_TEMP_MIN then
      set_field_for_endpoint(device, COLOR_TEMP_BOUND_RECEIVED_MIRED..COLOR_TEMP_MAX, ib.endpoint_id, temp_in_mired)
    else
      set_field_for_endpoint(device, COLOR_TEMP_BOUND_RECEIVED_MIRED..COLOR_TEMP_MIN, ib.endpoint_id, temp_in_mired)
    end
    local min = get_field_for_endpoint(device, COLOR_TEMP_BOUND_RECEIVED_KELVIN..COLOR_TEMP_MIN, ib.endpoint_id)
    local max = get_field_for_endpoint(device, COLOR_TEMP_BOUND_RECEIVED_KELVIN..COLOR_TEMP_MAX, ib.endpoint_id)
    if min ~= nil and max ~= nil then
      if min < max then
        device:emit_event_for_endpoint(ib.endpoint_id, capabilities.colorTemperature.colorTemperatureRange({ value = {minimum = min, maximum = max} }))
      else
        device.log.warn_with({hub_logs = true}, string.format("Device reported a min color temperature %d K that is not lower than the reported max color temperature %d K", min, max))
      end
    end
  end
end

local level_bounds_handler_factory = function(minOrMax)
  return function(driver, device, ib, response)
    if ib.data.value == nil then
      return
    end
    local lighting_endpoints = device:get_endpoints(clusters.LevelControl.ID, {feature_bitmap = clusters.LevelControl.FeatureMap.LIGHTING})
    local lighting_support = tbl_contains(lighting_endpoints, ib.endpoint_id)
    -- If the lighting feature is supported then we should check if the reported level is at least 1.
    if lighting_support and ib.data.value < SWITCH_LEVEL_LIGHTING_MIN then
      device.log.warn_with({hub_logs = true}, string.format("Lighting device reported a switch level %d outside of supported capability range", ib.data.value))
      return
    end
    -- Convert level from given range of 0-254 to range of 0-100.
    local level = utils.round(ib.data.value / 254.0 * 100)
    -- If the device supports the lighting feature, the minimum capability level should be 1 so we do not send a 0 value for the level attribute
    if lighting_support and level == 0 then
      level = 1
    end
    set_field_for_endpoint(device, LEVEL_BOUND_RECEIVED..minOrMax, ib.endpoint_id, level)
    local min = get_field_for_endpoint(device, LEVEL_BOUND_RECEIVED..LEVEL_MIN, ib.endpoint_id)
    local max = get_field_for_endpoint(device, LEVEL_BOUND_RECEIVED..LEVEL_MAX, ib.endpoint_id)
    if min ~= nil and max ~= nil then
      if min < max then
        device:emit_event_for_endpoint(ib.endpoint_id, capabilities.switchLevel.levelRange({ value = {minimum = min, maximum = max} }))
      else
        device.log.warn_with({hub_logs = true}, string.format("Device reported a min level value %d that is not lower than the reported max level value %d", min, max))
      end
      set_field_for_endpoint(device, LEVEL_BOUND_RECEIVED..LEVEL_MAX, ib.endpoint_id, nil)
      set_field_for_endpoint(device, LEVEL_BOUND_RECEIVED..LEVEL_MIN, ib.endpoint_id, nil)
    end
  end
end

local color_utils = require "color_utils"

local function x_attr_handler(driver, device, ib, response)
  if device:get_field(COLOR_MODE) == HUE_SAT_COLOR_MODE then
    return
  end
  local y = device:get_field(RECEIVED_Y)
  --TODO it is likely that both x and y attributes are in the response (not guaranteed though)
  -- if they are we can avoid setting fields on the device.
  if y == nil then
    device:set_field(RECEIVED_X, ib.data.value)
  else
    local x = ib.data.value
    local h, s, _ = color_utils.safe_xy_to_hsv(x, y)
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.colorControl.hue(h))
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.colorControl.saturation(s))
    device:set_field(RECEIVED_Y, nil)
  end
end

local function y_attr_handler(driver, device, ib, response)
  if device:get_field(COLOR_MODE) == HUE_SAT_COLOR_MODE then
    return
  end
  local x = device:get_field(RECEIVED_X)
  if x == nil then
    device:set_field(RECEIVED_Y, ib.data.value)
  else
    local y = ib.data.value
    local h, s, _ = color_utils.safe_xy_to_hsv(x, y)
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.colorControl.hue(h))
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.colorControl.saturation(s))
    device:set_field(RECEIVED_X, nil)
  end
end

local function color_mode_attr_handler(driver, device, ib, response)
  if ib.data.value == device:get_field(COLOR_MODE) or (ib.data.value ~= HUE_SAT_COLOR_MODE and ib.data.value ~= X_Y_COLOR_MODE) then
    return
  end
  device:set_field(COLOR_MODE, ib.data.value)
  local req = im.InteractionRequest(im.InteractionRequest.RequestType.READ, {})
  if ib.data.value == HUE_SAT_COLOR_MODE then
    req:merge(clusters.ColorControl.attributes.CurrentHue:read())
    req:merge(clusters.ColorControl.attributes.CurrentSaturation:read())
  elseif ib.data.value == X_Y_COLOR_MODE then
    req:merge(clusters.ColorControl.attributes.CurrentX:read())
    req:merge(clusters.ColorControl.attributes.CurrentY:read())
  end
  if #req.info_blocks > 0 then
    device:send(req)
  end
end

--TODO setup configure handler to read this attribute.
local function color_cap_attr_handler(driver, device, ib, response)
  if ib.data.value ~= nil then
    if ib.data.value & 0x1 then
      device:set_field(HUESAT_SUPPORT, true)
    end
  end
end

local function illuminance_attr_handler(driver, device, ib, response)
  local lux = math.floor(10 ^ ((ib.data.value - 1) / 10000))
  device:emit_event_for_endpoint(ib.endpoint_id, capabilities.illuminanceMeasurement.illuminance(lux))
end

local function occupancy_attr_handler(driver, device, ib, response)
  device:emit_event(ib.data.value == 0x01 and capabilities.motionSensor.motion.active() or capabilities.motionSensor.motion.inactive())
end

local function available_endpoints_handler(driver, device, ib, response)
  local electrical_sensor_eps = device:get_field(ELECTRICAL_SENSOR_EPS)
  local avail_eps_req_complete = true
  local electrical_tags_per_ep = {}
  table.sort(ib.data.elements)
  for _, info in ipairs(electrical_sensor_eps or {}) do
    if info.endpoint_id == ib.endpoint_id then
      info.availableEndpoints = ib.data.elements
    elseif info.availableEndpoints == false then -- an endpoint is found that hasn't been updated through this handler.
      avail_eps_req_complete = false
    end
    if avail_eps_req_complete then
      local electrical_tags = ""
      if info.power then electrical_tags = electrical_tags .. "-power" end
      if info.energy then electrical_tags = electrical_tags .. "-energy-powerConsumption" end
      electrical_tags_per_ep[info.availableEndpoints[1].value] = electrical_tags -- set tags on first available endpoint
    end
  end
  if avail_eps_req_complete == false then
    device:set_field(ELECTRICAL_SENSOR_EPS, electrical_sensor_eps)
  else
    local topology_data = {}
    topology_data.topology = clusters.PowerTopology.types.Feature.SET_TOPOLOGY
    topology_data.tags_on_ep = electrical_tags_per_ep
    device:set_field(profiling_data.ELECTRICAL_TOPOLOGY, topology_data)
    device:set_field(ELECTRICAL_SENSOR_EPS, nil)
    match_profile(driver, device)
  end
end

local function cumul_energy_imported_handler(driver, device, ib, response)
  if ib.data.elements.energy then
    local component = device.profile.components["main"]
    local watt_hour_value = ib.data.elements.energy.value / CONVERSION_CONST_MILLIWATT_TO_WATT
    local total_imported_energy = device:get_field(TOTAL_IMPORTED_ENERGY) or {}
    total_imported_energy[ib.endpoint_id] = watt_hour_value
    device:set_field(TOTAL_IMPORTED_ENERGY, total_imported_energy, {persist = true})
    device:emit_component_event(component, capabilities.energyMeter.energy({ value = watt_hour_value, unit = "Wh" }))
  end
end

local function per_energy_imported_handler(driver, device, ib, response)
  if ib.data.elements.energy then
    local component = device.profile.components["main"]
    local watt_hour_value = ib.data.elements.energy.value / CONVERSION_CONST_MILLIWATT_TO_WATT
    local total_imported_energy = device:get_field(TOTAL_IMPORTED_ENERGY) or {}
    local latest_energy_report = total_imported_energy[ib.endpoint_id] or 0
    total_imported_energy[ib.endpoint_id] = latest_energy_report + watt_hour_value
    device:set_field(TOTAL_IMPORTED_ENERGY, total_imported_energy, {persist = true})
    device:emit_component_event(component, capabilities.energyMeter.energy({ value = total_imported_energy[ib.endpoint_id], unit = "Wh" }))
  end
end

local function energy_report_handler_factory(is_cumulative_report)
  return function(driver, device, ib, response)
    if not device:get_field(IMPORT_POLL_TIMER_SETTING_ATTEMPTED) then
      set_poll_report_timer_and_schedule(device, is_cumulative_report)
    end
    if is_cumulative_report then
      cumul_energy_imported_handler(driver, device, ib, response)
    elseif device:get_field(CUMULATIVE_REPORTS_NOT_SUPPORTED) then
      per_energy_imported_handler(driver, device, ib, response)
    end
  end
end

local function initial_press_event_handler(driver, device, ib, response)
  if get_field_for_endpoint(device, SUPPORTS_MULTI_PRESS, ib.endpoint_id) then
    -- Receipt of an InitialPress event means we do not want to ignore the next MultiPressComplete event
    -- or else we would potentially not create the expected button capability event
    set_field_for_endpoint(device, IGNORE_NEXT_MPC, ib.endpoint_id, nil)
  elseif get_field_for_endpoint(device, INITIAL_PRESS_ONLY, ib.endpoint_id) then
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.button.button.pushed({state_change = true}))
  elseif get_field_for_endpoint(device, EMULATE_HELD, ib.endpoint_id) then
    -- if our button doesn't differentiate between short and long holds, do it in code by keeping track of the press down time
    init_press(device, ib.endpoint_id)
  end
end

-- if the device distinguishes a long press event, it will always be a "held"
-- there's also a "long release" event, but this event is required to come first
local function long_press_event_handler(driver, device, ib, response)
  device:emit_event_for_endpoint(ib.endpoint_id, capabilities.button.button.held({state_change = true}))
  if get_field_for_endpoint(device, SUPPORTS_MULTI_PRESS, ib.endpoint_id) then
    -- Ignore the next MultiPressComplete event if it is sent as part of this "long press" event sequence
    set_field_for_endpoint(device, IGNORE_NEXT_MPC, ib.endpoint_id, true)
  end
end

local function short_release_event_handler(driver, device, ib, response)
  if not get_field_for_endpoint(device, SUPPORTS_MULTI_PRESS, ib.endpoint_id) then
    if get_field_for_endpoint(device, EMULATE_HELD, ib.endpoint_id) then
      emulate_held_event(device, ib.endpoint_id)
    else
      device:emit_event_for_endpoint(ib.endpoint_id, capabilities.button.button.pushed({state_change = true}))
    end
  end
end

local function active_power_handler(driver, device, ib, response)
  local component = device.profile.components["main"]
  if ib.data.value then
    local watt_value = ib.data.value / CONVERSION_CONST_MILLIWATT_TO_WATT
    device:emit_component_event(component, capabilities.powerMeter.power({ value = watt_value, unit = "W"}))
  else
    device:emit_component_event(component, capabilities.powerMeter.power({ value = 0, unit = "W"}))
  end
end

local function valve_state_attr_handler(driver, device, ib, response)
  if ib.data.value == 0 then
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.valve.valve.closed())
  else
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.valve.valve.open())
  end
end

local function valve_level_attr_handler(driver, device, ib, response)
  if ib.data.value then
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.level.level(ib.data.value))
  end
end

local function multi_press_complete_event_handler(driver, device, ib, response)
  -- in the case of multiple button presses
  -- emit number of times, multiple presses have been completed
  if ib.data and not get_field_for_endpoint(device, IGNORE_NEXT_MPC, ib.endpoint_id) then
    local press_value = ib.data.elements.total_number_of_presses_counted.value
    --capability only supports up to 6 presses
    if press_value < 7 then
      local button_event = capabilities.button.button.pushed({state_change = true})
      if press_value == 2 then
        button_event = capabilities.button.button.double({state_change = true})
      elseif press_value > 2 then
        button_event = capabilities.button.button(string.format("pushed_%dx", press_value), {state_change = true})
      end

      device:emit_event_for_endpoint(ib.endpoint_id, button_event)
    else
      log.info(string.format("Number of presses (%d) not supported by capability", press_value))
    end
  end
  set_field_for_endpoint(device, IGNORE_NEXT_MPC, ib.endpoint_id, nil)
end

local function battery_percent_remaining_attr_handler(driver, device, ib, response)
  if ib.data.value then
    device:emit_event(capabilities.battery.battery(math.floor(ib.data.value / 2.0 + 0.5)))
  end
end

local function battery_charge_level_attr_handler(driver, device, ib, response)
  if ib.data.value == clusters.PowerSource.types.BatChargeLevelEnum.OK then
    device:emit_event(capabilities.batteryLevel.battery.normal())
  elseif ib.data.value == clusters.PowerSource.types.BatChargeLevelEnum.WARNING then
    device:emit_event(capabilities.batteryLevel.battery.warning())
  elseif ib.data.value == clusters.PowerSource.types.BatChargeLevelEnum.CRITICAL then
    device:emit_event(capabilities.batteryLevel.battery.critical())
  end
end

local function power_source_attribute_list_handler(driver, device, ib, response)
  local profile_name = ""

  local button_eps = device:get_endpoints(clusters.Switch.ID, {feature_bitmap=clusters.Switch.types.SwitchFeature.MOMENTARY_SWITCH})
  for _, attr in ipairs(ib.data.elements) do
    -- Re-profile the device if BatPercentRemaining (Attribute ID 0x0C) or
    -- BatChargeLevel (Attribute ID 0x0E) is present.
    if attr.value == 0x0C then
      profile_name = "button-battery"
      break
    elseif attr.value == 0x0E then
      profile_name = "button-batteryLevel"
      break
    end
  end
  if profile_name ~= "" then
    if #button_eps > 1 then
      profile_name = string.format("%d-", #button_eps) .. profile_name
    end

    if device.manufacturer_info.vendor_id == AQARA_MANUFACTURER_ID and
       device.manufacturer_info.product_id == AQARA_CLIMATE_SENSOR_W100_ID then
      profile_name = profile_name .. "-temperature-humidity"
    end
    device:try_update_metadata({ profile = profile_name })
  end
end

local function max_press_handler(driver, device, ib, response)
  local max = ib.data.value or 1 --get max number of presses
  device.log.debug("Device supports "..max.." presses")
  -- capability only supports up to 6 presses
  if max > 6 then
    log.info("Device supports more than 6 presses")
    max = 6
  end
  local MSL = device:get_endpoints(clusters.Switch.ID, {feature_bitmap=clusters.Switch.types.SwitchFeature.MOMENTARY_SWITCH_LONG_PRESS})
  local supportsHeld = tbl_contains(MSL, ib.endpoint_id)
  local values = create_multi_press_values_list(max, supportsHeld)
  device:emit_event_for_endpoint(ib.endpoint_id, capabilities.button.supportedButtonValues(values, {visibility = {displayed = false}}))
end

local function info_changed(driver, device, event, args)
  if device.profile.id ~= args.old_st_store.profile.id then
    device:subscribe()
    local button_eps = device:get_endpoints(clusters.Switch.ID, {feature_bitmap=clusters.Switch.types.SwitchFeature.MOMENTARY_SWITCH})
    if #button_eps > 0 and device.network_type == device_lib.NETWORK_TYPE_MATTER then
      configure_buttons(device)
    end
  end
end

local function device_added(driver, device)
  -- refresh child devices to get an initial attribute state for OnOff in case child device
  -- was created after the initial subscription report
  if device.network_type == device_lib.NETWORK_TYPE_CHILD then
    local req = clusters.OnOff.attributes.OnOff:read(device)
    device:send(req)
  elseif device.network_type == device_lib.NETWORK_TYPE_MATTER then
    collect_and_store_electrical_sensor_info(driver, device)
    local electrical_sensor_eps = device:get_field(ELECTRICAL_SENSOR_EPS)
    if #electrical_sensor_eps == 0 then
      device:set_field(profiling_data.ELECTRICAL_TOPOLOGY, {topology = false, tags_on_ep = {}})
      device:set_field(ELECTRICAL_SENSOR_EPS, nil)
    elseif electrical_sensor_eps[1].topology == clusters.PowerTopology.types.Feature.NODE_TOPOLOGY then
      local switch_eps = device:get_endpoints(clusters.OnOff.ID)
      table.sort(switch_eps)
      local electrical_tags = ""
      if electrical_sensor_eps[1].power then electrical_tags = electrical_tags .. "-power" end
      if electrical_sensor_eps[1].energy then electrical_tags = electrical_tags .. "-energy-powerConsumption" end
      device:set_field(profiling_data.ELECTRICAL_TOPOLOGY, {topology = clusters.PowerTopology.types.Feature.NODE_TOPOLOGY, tags_on_ep = {[switch_eps[1]] = electrical_tags}})
      device:set_field(ELECTRICAL_SENSOR_EPS, nil)
    end
  end
  -- call device init in case init is not called after added due to device caching
  device_init(driver, device)
end

local function temperature_attr_handler(driver, device, ib, response)
  local measured_value = ib.data.value
  if measured_value ~= nil then
    local temp = measured_value / 100.0
    local unit = "C"
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.temperatureMeasurement.temperature({value = temp, unit = unit}))
  end
end

local temp_attr_handler_factory = function(minOrMax)
  return function(driver, device, ib, response)
    if ib.data.value == nil then
      return
    end
    local temp = ib.data.value / 100.0
    local unit = "C"
    set_field_for_endpoint(device, TEMP_BOUND_RECEIVED..minOrMax, ib.endpoint_id, temp)
    local min = get_field_for_endpoint(device, TEMP_BOUND_RECEIVED..TEMP_MIN, ib.endpoint_id)
    local max = get_field_for_endpoint(device, TEMP_BOUND_RECEIVED..TEMP_MAX, ib.endpoint_id)
    if min ~= nil and max ~= nil then
      if min < max then
        -- Only emit the capability for RPC version >= 5 (unit conversion for
        -- temperature range capability is only supported for RPC >= 5)
        if version.rpc >= 5 then
          device:emit_event_for_endpoint(ib.endpoint_id, capabilities.temperatureMeasurement.temperatureRange({ value = { minimum = min, maximum = max }, unit = unit }))
        end
        set_field_for_endpoint(device, TEMP_BOUND_RECEIVED..TEMP_MIN, ib.endpoint_id, nil)
        set_field_for_endpoint(device, TEMP_BOUND_RECEIVED..TEMP_MAX, ib.endpoint_id, nil)
      else
        device.log.warn_with({hub_logs = true}, string.format("Device reported a min temperature %d that is not lower than the reported max temperature %d", min, max))
      end
    end
  end
end

local function humidity_attr_handler(driver, device, ib, response)
  local measured_value = ib.data.value
  if measured_value ~= nil then
    local humidity = utils.round(measured_value / 100.0)
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.relativeHumidityMeasurement.humidity(humidity))
  end
end

local function fan_mode_handler(driver, device, ib, response)
  if ib.data.value == clusters.FanControl.attributes.FanMode.OFF then
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.fanMode.fanMode("off"))
  elseif ib.data.value == clusters.FanControl.attributes.FanMode.LOW then
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.fanMode.fanMode("low"))
  elseif ib.data.value == clusters.FanControl.attributes.FanMode.MEDIUM then
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.fanMode.fanMode("medium"))
  elseif ib.data.value == clusters.FanControl.attributes.FanMode.HIGH then
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.fanMode.fanMode("high"))
  else
    device:emit_event_for_endpoint(ib.endpoint_id, capabilities.fanMode.fanMode("auto"))
  end
end

local function fan_mode_sequence_handler(driver, device, ib, response)
  local supportedFanModes
  if ib.data.value == clusters.FanControl.attributes.FanModeSequence.OFF_LOW_MED_HIGH then
    supportedFanModes = {
      capabilities.fanMode.fanMode.off.NAME,
      capabilities.fanMode.fanMode.low.NAME,
      capabilities.fanMode.fanMode.medium.NAME,
      capabilities.fanMode.fanMode.high.NAME
    }
  elseif ib.data.value == clusters.FanControl.attributes.FanModeSequence.OFF_LOW_HIGH then
    supportedFanModes = {
      capabilities.fanMode.fanMode.off.NAME,
      capabilities.fanMode.fanMode.low.NAME,
      capabilities.fanMode.fanMode.high.NAME
    }
  elseif ib.data.value == clusters.FanControl.attributes.FanModeSequence.OFF_LOW_MED_HIGH_AUTO then
    supportedFanModes = {
      capabilities.fanMode.fanMode.off.NAME,
      capabilities.fanMode.fanMode.low.NAME,
      capabilities.fanMode.fanMode.medium.NAME,
      capabilities.fanMode.fanMode.high.NAME,
      capabilities.fanMode.fanMode.auto.NAME
    }
  elseif ib.data.value == clusters.FanControl.attributes.FanModeSequence.OFF_LOW_HIGH_AUTO then
    supportedFanModes = {
      capabilities.fanMode.fanMode.off.NAME,
      capabilities.fanMode.fanMode.low.NAME,
      capabilities.fanMode.fanMode.high.NAME,
      capabilities.fanMode.fanMode.auto.NAME
    }
  elseif ib.data.value == clusters.FanControl.attributes.FanModeSequence.OFF_ON_AUTO then
    supportedFanModes = {
      capabilities.fanMode.fanMode.off.NAME,
      capabilities.fanMode.fanMode.high.NAME,
      capabilities.fanMode.fanMode.auto.NAME
    }
  else
    supportedFanModes = {
      capabilities.fanMode.fanMode.off.NAME,
      capabilities.fanMode.fanMode.high.NAME
    }
  end
  local event = capabilities.fanMode.supportedFanModes(supportedFanModes, {visibility = {displayed = false}})
  device:emit_event_for_endpoint(ib.endpoint_id, event)
end

local function fan_speed_percent_attr_handler(driver, device, ib, response)
  if ib.data.value == nil or ib.data.value < 0 or ib.data.value > 100 then
    return
  end
  device:emit_event_for_endpoint(ib.endpoint_id, capabilities.fanSpeedPercent.percent(ib.data.value))
end

local matter_driver_template = {
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    removed = device_removed,
    infoChanged = info_changed,
    doConfigure = do_configure,
    driverSwitched = driver_switched
  },
  matter_handlers = {
    attr = {
      [clusters.OnOff.ID] = {
        [clusters.OnOff.attributes.OnOff.ID] = on_off_attr_handler,
      },
      [clusters.LevelControl.ID] = {
        [clusters.LevelControl.attributes.CurrentLevel.ID] = level_attr_handler,
        [clusters.LevelControl.attributes.MaxLevel.ID] = level_bounds_handler_factory(LEVEL_MAX),
        [clusters.LevelControl.attributes.MinLevel.ID] = level_bounds_handler_factory(LEVEL_MIN),
      },
      [clusters.ColorControl.ID] = {
        [clusters.ColorControl.attributes.CurrentHue.ID] = hue_attr_handler,
        [clusters.ColorControl.attributes.CurrentSaturation.ID] = sat_attr_handler,
        [clusters.ColorControl.attributes.ColorTemperatureMireds.ID] = temp_attr_handler,
        [clusters.ColorControl.attributes.CurrentX.ID] = x_attr_handler,
        [clusters.ColorControl.attributes.CurrentY.ID] = y_attr_handler,
        [clusters.ColorControl.attributes.ColorMode.ID] = color_mode_attr_handler,
        [clusters.ColorControl.attributes.ColorCapabilities.ID] = color_cap_attr_handler,
        [clusters.ColorControl.attributes.ColorTempPhysicalMaxMireds.ID] = mired_bounds_handler_factory(COLOR_TEMP_MIN), -- max mireds = min kelvin
        [clusters.ColorControl.attributes.ColorTempPhysicalMinMireds.ID] = mired_bounds_handler_factory(COLOR_TEMP_MAX), -- min mireds = max kelvin
      },
      [clusters.IlluminanceMeasurement.ID] = {
        [clusters.IlluminanceMeasurement.attributes.MeasuredValue.ID] = illuminance_attr_handler
      },
      [clusters.OccupancySensing.ID] = {
        [clusters.OccupancySensing.attributes.Occupancy.ID] = occupancy_attr_handler,
      },
      [clusters.ElectricalPowerMeasurement.ID] = {
        [clusters.ElectricalPowerMeasurement.attributes.ActivePower.ID] = active_power_handler,
      },
      [clusters.ElectricalEnergyMeasurement.ID] = {
        [clusters.ElectricalEnergyMeasurement.attributes.CumulativeEnergyImported.ID] = energy_report_handler_factory(true),
        [clusters.ElectricalEnergyMeasurement.attributes.PeriodicEnergyImported.ID] = energy_report_handler_factory(false),
      },
      [clusters.PowerTopology.ID] = {
        [clusters.PowerTopology.attributes.AvailableEndpoints.ID] = available_endpoints_handler,
      },
      [clusters.ValveConfigurationAndControl.ID] = {
        [clusters.ValveConfigurationAndControl.attributes.CurrentState.ID] = valve_state_attr_handler,
        [clusters.ValveConfigurationAndControl.attributes.CurrentLevel.ID] = valve_level_attr_handler
      },
      [clusters.PowerSource.ID] = {
        [clusters.PowerSource.attributes.AttributeList.ID] = power_source_attribute_list_handler,
        [clusters.PowerSource.attributes.BatChargeLevel.ID] = battery_charge_level_attr_handler,
        [clusters.PowerSource.attributes.BatPercentRemaining.ID] = battery_percent_remaining_attr_handler,
      },
      [clusters.Switch.ID] = {
        [clusters.Switch.attributes.MultiPressMax.ID] = max_press_handler
      },
      [clusters.RelativeHumidityMeasurement.ID] = {
        [clusters.RelativeHumidityMeasurement.attributes.MeasuredValue.ID] = humidity_attr_handler
      },
      [clusters.TemperatureMeasurement.ID] = {
        [clusters.TemperatureMeasurement.attributes.MeasuredValue.ID] = temperature_attr_handler,
        [clusters.TemperatureMeasurement.attributes.MinMeasuredValue.ID] = temp_attr_handler_factory(TEMP_MIN),
        [clusters.TemperatureMeasurement.attributes.MaxMeasuredValue.ID] = temp_attr_handler_factory(TEMP_MAX),
      },
      [clusters.FanControl.ID] = {
        [clusters.FanControl.attributes.FanModeSequence.ID] = fan_mode_sequence_handler,
        [clusters.FanControl.attributes.FanMode.ID] = fan_mode_handler,
        [clusters.FanControl.attributes.PercentCurrent.ID] = fan_speed_percent_attr_handler
      }
    },
    event = {
      [clusters.Switch.ID] = {
        [clusters.Switch.events.InitialPress.ID] = initial_press_event_handler,
        [clusters.Switch.events.LongPress.ID] = long_press_event_handler,
        [clusters.Switch.events.ShortRelease.ID] = short_release_event_handler,
        [clusters.Switch.events.MultiPressComplete.ID] = multi_press_complete_event_handler
      }
    },
    fallback = matter_handler,
  },
  subscribed_attributes = {
    [capabilities.switch.ID] = {
      clusters.OnOff.attributes.OnOff
    },
    [capabilities.switchLevel.ID] = {
      clusters.LevelControl.attributes.CurrentLevel,
      clusters.LevelControl.attributes.MaxLevel,
      clusters.LevelControl.attributes.MinLevel,
    },
    [capabilities.colorControl.ID] = {
      clusters.ColorControl.attributes.ColorMode,
      clusters.ColorControl.attributes.CurrentHue,
      clusters.ColorControl.attributes.CurrentSaturation,
      clusters.ColorControl.attributes.CurrentX,
      clusters.ColorControl.attributes.CurrentY,
    },
    [capabilities.colorTemperature.ID] = {
      clusters.ColorControl.attributes.ColorTemperatureMireds,
      clusters.ColorControl.attributes.ColorTempPhysicalMaxMireds,
      clusters.ColorControl.attributes.ColorTempPhysicalMinMireds,
    },
    [capabilities.illuminanceMeasurement.ID] = {
      clusters.IlluminanceMeasurement.attributes.MeasuredValue
    },
    [capabilities.motionSensor.ID] = {
      clusters.OccupancySensing.attributes.Occupancy
    },
    [capabilities.valve.ID] = {
      clusters.ValveConfigurationAndControl.attributes.CurrentState
    },
    [capabilities.level.ID] = {
      clusters.ValveConfigurationAndControl.attributes.CurrentLevel
    },
    [capabilities.battery.ID] = {
      clusters.PowerSource.attributes.BatPercentRemaining,
    },
    [capabilities.batteryLevel.ID] = {
      clusters.PowerSource.attributes.BatChargeLevel,
    },
    [capabilities.energyMeter.ID] = {
      clusters.ElectricalEnergyMeasurement.attributes.CumulativeEnergyImported,
      clusters.ElectricalEnergyMeasurement.attributes.PeriodicEnergyImported
    },
    [capabilities.powerMeter.ID] = {
      clusters.ElectricalPowerMeasurement.attributes.ActivePower
    },
    [capabilities.relativeHumidityMeasurement.ID] = {
      clusters.RelativeHumidityMeasurement.attributes.MeasuredValue
    },
    [capabilities.temperatureMeasurement.ID] = {
      clusters.TemperatureMeasurement.attributes.MeasuredValue,
      clusters.TemperatureMeasurement.attributes.MinMeasuredValue,
      clusters.TemperatureMeasurement.attributes.MaxMeasuredValue
    },
    [capabilities.fanMode.ID] = {
      clusters.FanControl.attributes.FanModeSequence,
      clusters.FanControl.attributes.FanMode
    },
    [capabilities.fanSpeedPercent.ID] = {
      clusters.FanControl.attributes.PercentCurrent
    }
  },
  subscribed_events = {
    [capabilities.button.ID] = {
      clusters.Switch.events.InitialPress,
      clusters.Switch.events.LongPress,
      clusters.Switch.events.ShortRelease,
      clusters.Switch.events.MultiPressComplete,
    },
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_switch_on,
      [capabilities.switch.commands.off.NAME] = handle_switch_off,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = handle_set_switch_level
    },
    [capabilities.colorControl.ID] = {
      [capabilities.colorControl.commands.setColor.NAME] = handle_set_color,
      [capabilities.colorControl.commands.setHue.NAME] = handle_set_hue,
      [capabilities.colorControl.commands.setSaturation.NAME] = handle_set_saturation,
    },
    [capabilities.colorTemperature.ID] = {
      [capabilities.colorTemperature.commands.setColorTemperature.NAME] = handle_set_color_temperature,
    },
    [capabilities.valve.ID] = {
      [capabilities.valve.commands.open.NAME] = handle_valve_open,
      [capabilities.valve.commands.close.NAME] = handle_valve_close
    },
    [capabilities.level.ID] = {
      [capabilities.level.commands.setLevel.NAME] = handle_set_level
    },
    [capabilities.fanMode.ID] = {
      [capabilities.fanMode.commands.setFanMode.NAME] = set_fan_mode
    },
    [capabilities.fanSpeedPercent.ID] = {
      [capabilities.fanSpeedPercent.commands.setPercent.NAME] = set_fan_speed_percent
    }
  },
  supported_capabilities = {
    capabilities.switch,
    capabilities.switchLevel,
    capabilities.colorControl,
    capabilities.colorTemperature,
    capabilities.level,
    capabilities.motionSensor,
    capabilities.illuminanceMeasurement,
    capabilities.powerMeter,
    capabilities.energyMeter,
    capabilities.powerConsumptionReport,
    capabilities.valve,
    capabilities.button,
    capabilities.battery,
    capabilities.batteryLevel,
    capabilities.temperatureMeasurement,
    capabilities.relativeHumidityMeasurement,
    capabilities.fanMode,
    capabilities.fanSpeedPercent
  },
  sub_drivers = {
    require("eve-energy"),
    require("aqara-cube"),
    require("third-reality-mk1")
  }
}

function detect_matter_thing(device)
  for _, capability in ipairs(matter_driver_template.supported_capabilities) do
    if device:supports_capability(capability) then
      return false
    end
  end
  return device:supports_capability(capabilities.refresh)
end

local matter_driver = MatterDriver("matter-switch", matter_driver_template)
log.info_with({hub_logs=true}, string.format("Starting %s driver, with dispatcher: %s", matter_driver.NAME, matter_driver.matter_dispatcher))
matter_driver:run()
