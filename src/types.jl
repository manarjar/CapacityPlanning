export ThermalPlant, MustRunPlant, RenewablePlant, Storage, StageSpecificData, ProjectParameters, Zone, TransmissionLine

# StageID and ScenarioID are conceptually Int for now.

struct Zone
    id::Int
    name::String
    function Zone(id::Int, name::String)
        id > 0 || throw(ArgumentError("Zone id must be positive"))
        !isempty(name) || throw(ArgumentError("Zone name cannot be empty"))
        new(id, name)
    end
end

struct TransmissionLine
    id::String
    from_zone_id::Int
    to_zone_id::Int
    reactance_pu::Float64
    thermal_limit_mw::Float64
    length_km::Float64
    investment_cost_usd_per_mw_year::Float64
    initial_capacity_mw::Float64

    function TransmissionLine(id::String, from_zone_id::Int, to_zone_id::Int, reactance_pu::Float64, thermal_limit_mw::Float64, length_km::Float64, investment_cost_usd_per_mw_year::Float64, initial_capacity_mw::Float64)
        !isempty(id) || throw(ArgumentError("TransmissionLine id cannot be empty"))
        from_zone_id > 0 || throw(ArgumentError("from_zone_id must be positive"))
        to_zone_id > 0 || throw(ArgumentError("to_zone_id must be positive"))
        from_zone_id != to_zone_id || throw(ArgumentError("from_zone_id and to_zone_id cannot be the same for a transmission line"))
        thermal_limit_mw >= 0 || throw(ArgumentError("thermal_limit_mw must be non-negative"))
        length_km >= 0 || throw(ArgumentError("length_km must be non-negative"))
        investment_cost_usd_per_mw_year >= 0 || throw(ArgumentError("investment_cost_usd_per_mw_year must be non-negative"))
        initial_capacity_mw >= 0 || throw(ArgumentError("initial_capacity_mw must be non-negative"))
        new(id, from_zone_id, to_zone_id, reactance_pu, thermal_limit_mw, length_km, investment_cost_usd_per_mw_year, initial_capacity_mw)
    end
end

struct ThermalPlant
    name::String
    capacity_mw::Float64
    min_stable_level_mw::Float64
    ramp_up_mw_per_hr::Float64
    ramp_down_mw_per_hr::Float64
    startup_cost_usd::Float64
    shutdown_cost_usd::Float64
    variable_om_cost_usd_per_mwh::Float64
    fuel_cost_usd_per_mmbtu::Float64
    heat_rate_mmbtu_per_mwh::Float64
    investment_cost_usd_per_mw_year::Float64
    zone_id::Int
    initial_capacity_mw::Float64

    function ThermalPlant(name, capacity_mw, min_stable_level_mw, ramp_up_mw_per_hr, ramp_down_mw_per_hr, startup_cost_usd, shutdown_cost_usd, variable_om_cost_usd_per_mwh, fuel_cost_usd_per_mmbtu, heat_rate_mmbtu_per_mwh, investment_cost_usd_per_mw_year, zone_id, initial_capacity_mw)
        zone_id > 0 || throw(ArgumentError("zone_id must be positive for ThermalPlant '$name'"))
        initial_capacity_mw >= 0 || throw(ArgumentError("initial_capacity_mw must be non-negative for ThermalPlant '$name'"))
        capacity_mw >= initial_capacity_mw || throw(ArgumentError("capacity_mw (max buildable) must be >= initial_capacity_mw for ThermalPlant '$name'"))
        min_stable_level_mw <= capacity_mw || throw(ArgumentError("min_stable_level_mw cannot exceed capacity_mw for ThermalPlant '$name'"))
        min_stable_level_mw >= 0 || throw(ArgumentError("min_stable_level_mw must be non-negative for ThermalPlant '$name'"))
        # Add cost validations
        startup_cost_usd >=0 || throw(ArgumentError("startup_cost_usd must be non-negative for ThermalPlant '$name'"))
        shutdown_cost_usd >=0 || throw(ArgumentError("shutdown_cost_usd must be non-negative for ThermalPlant '$name'"))
        variable_om_cost_usd_per_mwh >=0 || throw(ArgumentError("variable_om_cost_usd_per_mwh must be non-negative for ThermalPlant '$name'"))
        fuel_cost_usd_per_mmbtu >=0 || throw(ArgumentError("fuel_cost_usd_per_mmbtu must be non-negative for ThermalPlant '$name'"))
        heat_rate_mmbtu_per_mwh >=0 || throw(ArgumentError("heat_rate_mmbtu_per_mwh must be non-negative for ThermalPlant '$name'"))
        investment_cost_usd_per_mw_year >=0 || throw(ArgumentError("investment_cost_usd_per_mw_year must be non-negative for ThermalPlant '$name'"))
        new(name, capacity_mw, min_stable_level_mw, ramp_up_mw_per_hr, ramp_down_mw_per_hr, startup_cost_usd, shutdown_cost_usd, variable_om_cost_usd_per_mwh, fuel_cost_usd_per_mmbtu, heat_rate_mmbtu_per_mwh, investment_cost_usd_per_mw_year, zone_id, initial_capacity_mw)
    end
end

struct MustRunPlant
    name::String
    capacity_mw::Float64
    variable_om_cost_usd_per_mwh::Float64
    investment_cost_usd_per_mw_year::Float64 # Retained field, set to 0 in constructor
    zone_id::Int

    function MustRunPlant(name, capacity_mw, variable_om_cost_usd_per_mwh, zone_id)
        zone_id > 0 || throw(ArgumentError("zone_id must be positive for MustRunPlant '$name'"))
        capacity_mw >=0 || throw(ArgumentError("capacity_mw must be non-negative for MustRunPlant '$name'"))
        variable_om_cost_usd_per_mwh >=0 || throw(ArgumentError("variable_om_cost_usd_per_mwh must be non-negative for MustRunPlant '$name'"))
        new(name, capacity_mw, variable_om_cost_usd_per_mwh, 0.0, zone_id)
    end
end

struct RenewablePlant
    name::String
    capacity_mw::Float64
    scenario_availability_profiles::Dict{Tuple{Int, Int}, Vector{Float64}}
    variable_om_cost_usd_per_mwh::Float64
    curtailment_cost_usd_per_mwh::Float64
    investment_cost_usd_per_mw_year::Float64
    zone_id::Int
    initial_capacity_mw::Float64

    function RenewablePlant(name, capacity_mw, scenario_availability_profiles, variable_om_cost_usd_per_mwh, curtailment_cost_usd_per_mwh, investment_cost_usd_per_mw_year, zone_id, initial_capacity_mw)
        zone_id > 0 || throw(ArgumentError("zone_id must be positive for RenewablePlant '$name'"))
        initial_capacity_mw >= 0 || throw(ArgumentError("initial_capacity_mw must be non-negative for RenewablePlant '$name'"))
        capacity_mw >= initial_capacity_mw || throw(ArgumentError("capacity_mw (max buildable) must be >= initial_capacity_mw for RenewablePlant '$name'"))
        variable_om_cost_usd_per_mwh >=0 || throw(ArgumentError("variable_om_cost_usd_per_mwh must be non-negative for RenewablePlant '$name'"))
        curtailment_cost_usd_per_mwh >=0 || throw(ArgumentError("curtailment_cost_usd_per_mwh must be non-negative for RenewablePlant '$name'"))
        investment_cost_usd_per_mw_year >=0 || throw(ArgumentError("investment_cost_usd_per_mw_year must be non-negative for RenewablePlant '$name'"))
        new(name, capacity_mw, scenario_availability_profiles, variable_om_cost_usd_per_mwh, curtailment_cost_usd_per_mwh, investment_cost_usd_per_mw_year, zone_id, initial_capacity_mw)
    end
end

struct Storage
    name::String
    zone_id::Int
    storage_capacity_mwh::Float64
    charge_power_mw::Float64
    discharge_power_mw::Float64
    charge_efficiency::Float64
    discharge_efficiency::Float64
    soc_min_fraction::Float64
    soc_max_fraction::Float64
    initial_storage_capacity_mwh::Float64
    initial_charge_power_mw::Float64
    initial_discharge_power_mw::Float64
    variable_om_cost_charge_usd_per_mwh::Float64
    variable_om_cost_discharge_usd_per_mwh::Float64
    investment_cost_usd_per_mw_year_power::Float64
    investment_cost_usd_per_mwh_year_energy::Float64

    function Storage(name, zone_id, storage_capacity_mwh, charge_power_mw, discharge_power_mw, charge_efficiency, discharge_efficiency, soc_min_fraction, soc_max_fraction, initial_storage_capacity_mwh, initial_charge_power_mw, initial_discharge_power_mw, variable_om_cost_charge_usd_per_mwh, variable_om_cost_discharge_usd_per_mwh, investment_cost_usd_per_mw_year_power, investment_cost_usd_per_mwh_year_energy)
        zone_id > 0 || throw(ArgumentError("zone_id must be positive for Storage '$name'"))
        storage_capacity_mwh >= 0 || throw(ArgumentError("storage_capacity_mwh must be non-negative for Storage '$name'"))
        charge_power_mw >= 0 || throw(ArgumentError("charge_power_mw must be non-negative for Storage '$name'"))
        discharge_power_mw >= 0 || throw(ArgumentError("discharge_power_mw must be non-negative for Storage '$name'"))
        0.0 <= charge_efficiency <= 1.0 || throw(ArgumentError("Charge efficiency must be between 0.0 and 1.0 for Storage '$name'"))
        0.0 <= discharge_efficiency <= 1.0 || throw(ArgumentError("Discharge efficiency must be between 0.0 and 1.0 for Storage '$name'"))
        0.0 <= soc_min_fraction <= 1.0 || throw(ArgumentError("soc_min_fraction must be between 0.0 and 1.0 for Storage '$name'"))
        0.0 <= soc_max_fraction <= 1.0 || throw(ArgumentError("soc_max_fraction must be between 0.0 and 1.0 for Storage '$name'"))
        soc_max_fraction >= soc_min_fraction || throw(ArgumentError("soc_max_fraction must be >= soc_min_fraction for Storage '$name'"))

        initial_storage_capacity_mwh >=0 || throw(ArgumentError("initial_storage_capacity_mwh must be non-negative for Storage '$name'"))
        initial_charge_power_mw >=0 || throw(ArgumentError("initial_charge_power_mw must be non-negative for Storage '$name'"))
        initial_discharge_power_mw >=0 || throw(ArgumentError("initial_discharge_power_mw must be non-negative for Storage '$name'"))

        storage_capacity_mwh >= initial_storage_capacity_mwh || throw(ArgumentError("storage_capacity_mwh must be >= initial_storage_capacity_mwh for Storage '$name'"))
        charge_power_mw >= initial_charge_power_mw || throw(ArgumentError("charge_power_mw must be >= initial_charge_power_mw for Storage '$name'"))
        discharge_power_mw >= initial_discharge_power_mw || throw(ArgumentError("discharge_power_mw must be >= initial_discharge_power_mw for Storage '$name'"))

        variable_om_cost_charge_usd_per_mwh >= 0 || throw(ArgumentError("variable_om_cost_charge_usd_per_mwh must be non-negative for Storage '$name'"))
        variable_om_cost_discharge_usd_per_mwh >= 0 || throw(ArgumentError("variable_om_cost_discharge_usd_per_mwh must be non-negative for Storage '$name'"))
        investment_cost_usd_per_mw_year_power >= 0 || throw(ArgumentError("investment_cost_usd_per_mw_year_power must be non-negative for Storage '$name'"))
        investment_cost_usd_per_mwh_year_energy >= 0 || throw(ArgumentError("investment_cost_usd_per_mwh_year_energy must be non-negative for Storage '$name'"))

        new(name, zone_id, storage_capacity_mwh, charge_power_mw, discharge_power_mw, charge_efficiency, discharge_efficiency, soc_min_fraction, soc_max_fraction, initial_storage_capacity_mwh, initial_charge_power_mw, initial_discharge_power_mw, variable_om_cost_charge_usd_per_mwh, variable_om_cost_discharge_usd_per_mwh, investment_cost_usd_per_mw_year_power, investment_cost_usd_per_mwh_year_energy)
    end
end

struct StageSpecificData
    stage_id::Int
    zone_id::Int
    demand_profile::Vector{Float64}

    function StageSpecificData(stage_id::Int, zone_id::Int, demand_profile::Vector{Float64})
        stage_id > 0 || throw(ArgumentError("stage_id must be positive for StageSpecificData"))
        zone_id > 0 || throw(ArgumentError("zone_id must be positive for StageSpecificData"))
        new(stage_id, zone_id, demand_profile)
    end
end

struct ProjectParameters
    num_stages::Int
    years_per_stage::Int
    discount_rate::Float64
    zones::Vector{Zone}
    transmission_lines::Vector{TransmissionLine}

    function ProjectParameters(num_stages::Int, years_per_stage::Int, discount_rate::Float64, zones::Vector{Zone}=Zone[], transmission_lines::Vector{TransmissionLine}=TransmissionLine[])
        num_stages > 0 || throw(ArgumentError("num_stages must be positive"))
        years_per_stage > 0 || throw(ArgumentError("years_per_stage must be positive"))
        0.0 <= discount_rate <= 1.0 || throw(ArgumentError("discount_rate must be between 0.0 and 1.0"))
        new(num_stages, years_per_stage, discount_rate, zones, transmission_lines)
    end
end
