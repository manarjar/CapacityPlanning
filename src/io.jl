include("types.jl")

using CSV, DataFrames
using JSON

export read_thermal_plants, parse_main_config, read_renewable_plant_definitions, read_stage_specific_data, read_zones, read_transmission_lines, read_storage_units # Added read_storage_units

# Functions read_thermal_plants, read_renewable_plant_definitions, read_stage_specific_data,
# read_zones, read_transmission_lines are assumed to be here, correct as per previous steps.
# For brevity, their full text is omitted in this specific diff view, only new/changed functions shown below.

function read_thermal_plants(filepath::String)::Vector{ThermalPlant}
    plants = ThermalPlant[]
    expected_columns = ["name", "capacity_mw", "min_stable_level_mw", "ramp_up_mw_per_hr", "ramp_down_mw_per_hr", "startup_cost_usd", "shutdown_cost_usd", "variable_om_cost_usd_per_mwh", "fuel_cost_usd_per_mmbtu", "heat_rate_mmbtu_per_mwh", "investment_cost_usd_per_mw_year", "zone_id", "initial_capacity_mw"]
    if !isfile(filepath); @error "Thermal plants file not found: $filepath"; return ThermalPlant[]; end
    local df; try df = CSV.read(filepath, DataFrame); catch e; @error "CSV read error for thermal plants $filepath: $e"; return ThermalPlant[]; end
    actual_cols = Symbol.(names(df)); expected_sym_cols = Symbol.(expected_columns)
    if !issubset(expected_sym_cols, actual_cols); missing_cols = setdiff(expected_sym_cols, actual_cols); @error "Missing expected columns in thermal plants file $filepath: $(join(string.(missing_cols), ", "))"; return ThermalPlant[]; end
    for row in eachrow(df); try push!(plants, ThermalPlant(String(row.name), Float64(row.capacity_mw), Float64(row.min_stable_level_mw), Float64(row.ramp_up_mw_per_hr), Float64(row.ramp_down_mw_per_hr), Float64(row.startup_cost_usd), Float64(row.shutdown_cost_usd), Float64(row.variable_om_cost_usd_per_mwh), Float64(row.fuel_cost_usd_per_mmbtu), Float64(row.heat_rate_mmbtu_per_mwh), Float64(row.investment_cost_usd_per_mw_year), Int(row.zone_id), Float64(row.initial_capacity_mw) )); catch e_row; @error "Error processing a thermal plant row in $filepath: $row. Details: $e_row"; end; end
    if isempty(plants) && nrow(df) > 0; @warn "No thermal plants processed from $filepath."; end
    return plants
end

function read_renewable_plant_definitions(filepath::String)::Vector{RenewablePlant}
    plants = RenewablePlant[]
    expected_columns = ["name", "capacity_mw", "variable_om_cost_usd_per_mwh", "curtailment_cost_usd_per_mwh", "investment_cost_usd_per_mw_year", "zone_id", "initial_capacity_mw"]
    if !isfile(filepath); @error "Renewable plant definitions file not found: $filepath"; return RenewablePlant[]; end
    local df; try df = CSV.read(filepath, DataFrame); catch e; @error "CSV read error for renewable defs $filepath: $e"; return RenewablePlant[]; end
    actual_cols = Symbol.(names(df)); expected_sym_cols = Symbol.(expected_columns)
    if !issubset(expected_sym_cols, actual_cols); missing_cols = setdiff(expected_sym_cols, actual_cols); @error "Missing expected columns in renewable definitions file $filepath: $(join(string.(missing_cols), ", "))"; return RenewablePlant[]; end
    for row in eachrow(df); try push!(plants, RenewablePlant(String(row.name), Float64(row.capacity_mw), Dict{Tuple{Int, Int}, Vector{Float64}}(), Float64(row.variable_om_cost_usd_per_mwh), Float64(row.curtailment_cost_usd_per_mwh), Float64(row.investment_cost_usd_per_mw_year), Int(row.zone_id), Float64(row.initial_capacity_mw) )); catch e_row; @error "Error processing a renewable plant definition row in $filepath: $row. Details: $e_row"; end; end
    if isempty(plants) && nrow(df) > 0; @warn "No renewable plants processed from $filepath."; end
    return plants
end

function read_stage_specific_data(stage_id::Int, stage_path::String, zones::Vector{Zone}, all_renewable_plants::Vector{RenewablePlant})::Vector{StageSpecificData}
    parsed_stage_data = StageSpecificData[]
    demand_filename = joinpath(stage_path, "demand_data.csv")
    if !isfile(demand_filename); @error "Consolidated demand data file not found for Stage $stage_id at: $demand_filename"; else
        local df_demand; try df_demand = CSV.read(demand_filename, DataFrame); catch e; @error "Error reading demand CSV for Stage $stage_id at $demand_filename: $e"; return parsed_stage_data; end
        for zone_obj in zones; zone_name_str = String(zone_obj.name)
            if Symbol(zone_name_str) in Symbol.(names(df_demand)); demand_profile_vector = Vector{Float64}(); for val in df_demand[!, Symbol(zone_name_str)]; if val isa Number; push!(demand_profile_vector, Float64(val)); else; @error "Non-numeric value '$val' in demand column '$zone_name_str' of $demand_filename for Stage $stage_id."; empty!(demand_profile_vector); break; end; end
                if !isempty(demand_profile_vector); push!(parsed_stage_data, StageSpecificData(stage_id, zone_obj.id, demand_profile_vector)); elseif !(Symbol(zone_name_str) in Symbol.(names(df_demand))); @warn "Demand profile for Stage $stage_id, Zone '$(zone_obj.name)' in $demand_filename resulted in an empty profile."; end
            else; @warn "Demand column for zone '$(zone_obj.name)' not found in $demand_filename for Stage $stage_id."; end
        end; end
    for rp in all_renewable_plants; profile_filename = "zone_$(rp.zone_id)_$(rp.name)_profile.csv"; profile_filepath = joinpath(stage_path, profile_filename)
        if isfile(profile_filepath); try profile_df = CSV.read(profile_filepath, DataFrame); if "availability" in names(profile_df); profile_vector = Vector{Float64}(); for val in profile_df.availability; if val isa Number; push!(profile_vector, Float64(val)); else; @warn "Non-numeric value '$val' in availability column of $profile_filepath. Skipping."; end; end; rp.scenario_availability_profiles[(stage_id, 1)] = profile_vector; else; @warn "Missing 'availability' column in $profile_filepath."; end; catch e_csv; @warn "Error reading/processing profile CSV $profile_filepath. Error: $e_csv"; end
        elseif any(z -> z.id == rp.zone_id, zones); @warn "Profile CSV $profile_filepath not found for plant $(rp.name) in relevant zone $(rp.zone_id) for stage $stage_id.";end
    end
    return parsed_stage_data
end

function read_zones(filepath::String)::Vector{Zone}
    zones = Zone[]; expected_columns = ["id", "name"]; if !isfile(filepath); @error "Zones file not found: $filepath"; return zones; end
    local df; try df = CSV.read(filepath, DataFrame); catch e; @error "CSV read error for zones $filepath: $e"; return zones; end
    actual_cols = Symbol.(names(df)); expected_sym_cols = Symbol.(expected_columns); if !issubset(expected_sym_cols, actual_cols); missing_cols = setdiff(expected_sym_cols, actual_cols); @error "Missing columns in zones file $filepath: $(join(string.(missing_cols), ", "))"; return zones; end
    for row in eachrow(df); try push!(zones, Zone(Int(row.id), String(row.name))); catch e_row; @error "Error processing zone row in $filepath: $row. Details: $e_row"; end; end
    if isempty(zones) && nrow(df) > 0; @warn "No zones processed from $filepath."; end; return zones;
end

function read_transmission_lines(filepath::String)::Vector{TransmissionLine}
    lines = TransmissionLine[]; expected_columns = ["id", "from_zone_id", "to_zone_id", "reactance_pu", "thermal_limit_mw", "length_km", "investment_cost_usd_per_mw_year", "initial_capacity_mw"]; if !isfile(filepath); @error "Lines file not found: $filepath"; return lines; end
    local df; try df = CSV.read(filepath, DataFrame); catch e; @error "CSV read error for lines $filepath: $e"; return lines; end
    actual_cols = Symbol.(names(df)); expected_sym_cols = Symbol.(expected_columns); if !issubset(expected_sym_cols, actual_cols); missing_cols = setdiff(expected_sym_cols, actual_cols); @error "Missing columns in lines file $filepath: $(join(string.(missing_cols), ", "))"; return lines; end
    for row in eachrow(df); try push!(lines, TransmissionLine(String(row.id), Int(row.from_zone_id), Int(row.to_zone_id), Float64(row.reactance_pu), Float64(row.thermal_limit_mw), Float64(row.length_km), Float64(row.investment_cost_usd_per_mw_year), Float64(row.initial_capacity_mw))); catch e_row; @error "Error processing line row in $filepath: $row. Details: $e_row"; end; end
    if isempty(lines) && nrow(df) > 0; @warn "No lines processed from $filepath."; end; return lines;
end

"""
    read_storage_units(filepath::String)::Vector{Storage}

Reads storage unit data from a CSV file.
"""
function read_storage_units(filepath::String)::Vector{Storage}
    storage_units = Storage[]
    expected_columns = [
        "name", "zone_id", "storage_capacity_mwh", "charge_power_mw", "discharge_power_mw",
        "charge_efficiency", "discharge_efficiency", "soc_min_fraction", "soc_max_fraction",
        "initial_storage_capacity_mwh", "initial_charge_power_mw", "initial_discharge_power_mw",
        "variable_om_cost_charge_usd_per_mwh", "variable_om_cost_discharge_usd_per_mwh",
        "investment_cost_usd_per_mw_year_power", "investment_cost_usd_per_mwh_year_energy"
    ]
    if !isfile(filepath); @error "Storage units file not found: $filepath"; return storage_units; end
    local df; try df = CSV.read(filepath, DataFrame); catch e; @error "CSV read error for storage units $filepath: $e"; return storage_units; end

    actual_cols = Symbol.(names(df))
    expected_sym_cols = Symbol.(expected_columns)
    if !issubset(expected_sym_cols, actual_cols)
        missing_cols = setdiff(expected_sym_cols, actual_cols)
        @error "Missing expected columns in storage units file $filepath: $(join(string.(missing_cols), ", "))"
        return storage_units
    end

    for row in eachrow(df)
        try
            push!(storage_units, Storage(
                String(row.name), Int(row.zone_id),
                Float64(row.storage_capacity_mwh), Float64(row.charge_power_mw), Float64(row.discharge_power_mw),
                Float64(row.charge_efficiency), Float64(row.discharge_efficiency),
                Float64(row.soc_min_fraction), Float64(row.soc_max_fraction),
                Float64(row.initial_storage_capacity_mwh), Float64(row.initial_charge_power_mw), Float64(row.initial_discharge_power_mw),
                Float64(row.variable_om_cost_charge_usd_per_mwh), Float64(row.variable_om_cost_discharge_usd_per_mwh),
                Float64(row.investment_cost_usd_per_mw_year_power), Float64(row.investment_cost_usd_per_mwh_year_energy)
            ))
        catch e_row; @error "Error processing a storage unit row in $filepath: $row. Details: $e_row"; end
    end
    if isempty(storage_units) && nrow(df) > 0; @warn "No storage units processed from $filepath."; end
    return storage_units
end

function parse_main_config(config_filepath::String)
    if !isfile(config_filepath); error("Configuration file not found: $config_filepath"); end
    try
        config_data = JSON.parsefile(config_filepath)
        pp_dict = get(config_data, "project_parameters", nothing); if isnothing(pp_dict); error("Missing 'project_parameters' key in $config_filepath"); end
        num_stages = get(pp_dict, "num_stages", nothing); years_per_stage = get(pp_dict, "years_per_stage", nothing); discount_rate = get(pp_dict, "discount_rate", nothing)
        if isnothing(num_stages) || isnothing(years_per_stage) || isnothing(discount_rate); error("Missing required keys (num_stages, years_per_stage, discount_rate) in 'project_parameters' of $config_filepath"); end
        project_params = ProjectParameters(Int(num_stages), Int(years_per_stage), Float64(discount_rate))
        stage_data_paths_json = get(config_data, "stage_data_paths", nothing); if isnothing(stage_data_paths_json) || !(stage_data_paths_json isa Vector); error("Missing or invalid 'stage_data_paths' in $config_filepath"); end
        stage_paths_vec = Vector{String}(); for path in stage_data_paths_json; if !(path isa String); error("All elements in 'stage_data_paths' must be strings. Found: $path"); end; push!(stage_paths_vec, path); end
        global_data_paths_json = get(config_data, "global_data_paths", nothing); if isnothing(global_data_paths_json) || !(global_data_paths_json isa Dict); error("Missing or invalid 'global_data_paths' in $config_filepath"); end

        required_global_keys = ["zones", "transmission_lines", "thermal_plants", "renewable_plants_definitions", "storage_units"] # Added "storage_units"
        # Optional: "must_run_plants", "initial_capacities" (if still used, but now part of plant files)

        for r_key in required_global_keys; if !haskey(global_data_paths_json, r_key); error("Missing required key '$r_key' in 'global_data_paths' of $config_filepath"); end; end

        global_paths_typed_dict = Dict{String, String}(); for (key, value) in global_data_paths_json; if !(value isa String); error("All values in 'global_data_paths' must be strings. Key: '$key' has value '$value'"); end; global_paths_typed_dict[String(key)] = value; end
        return project_params, stage_paths_vec, global_paths_typed_dict
    catch e
        if e isa SystemError; error("System error accessing config file $config_filepath: $e"); elseif e isa JSON.JSONParseException; error("Error parsing JSON in $config_filepath: $e"); else; rethrow(e); end
    end
end
