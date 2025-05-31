include("types.jl")

using CSV, DataFrames
using JSON

export read_thermal_plants, parse_main_config, read_renewable_plant_definitions, read_stage_specific_data, read_initial_capacities, read_zones, read_transmission_lines

"""
    read_thermal_plants(filepath::String)::Vector{ThermalPlant}
    (Reads thermal plant data from CSV, including zone_id)
"""
function read_thermal_plants(filepath::String)::Vector{ThermalPlant}
    plants = ThermalPlant[]
    expected_columns = ["name", "capacity_mw", "min_stable_level_mw", "ramp_up_mw_per_hr", "ramp_down_mw_per_hr", "startup_cost_usd", "shutdown_cost_usd", "variable_om_cost_usd_per_mwh", "fuel_cost_usd_per_mmbtu", "heat_rate_mmbtu_per_mwh", "investment_cost_usd_per_mw_year", "zone_id"]
    if !isfile(filepath); @error "Thermal plants file not found: $filepath"; return ThermalPlant[]; end
    local df; try df = CSV.read(filepath, DataFrame); catch e; @error "CSV read error for thermal plants $filepath: $e"; return ThermalPlant[]; end
    actual_cols = Symbol.(names(df)); expected_sym_cols = Symbol.(expected_columns)
    if !issubset(expected_sym_cols, actual_cols); missing_cols = setdiff(expected_sym_cols, actual_cols); @error "Missing expected columns in thermal plants file $filepath: $(join(string.(missing_cols), ", "))"; return ThermalPlant[]; end
    for row in eachrow(df); try push!(plants, ThermalPlant(String(row.name), Float64(row.capacity_mw), Float64(row.min_stable_level_mw), Float64(row.ramp_up_mw_per_hr), Float64(row.ramp_down_mw_per_hr), Float64(row.startup_cost_usd), Float64(row.shutdown_cost_usd), Float64(row.variable_om_cost_usd_per_mwh), Float64(row.fuel_cost_usd_per_mmbtu), Float64(row.heat_rate_mmbtu_per_mwh), Float64(row.investment_cost_usd_per_mw_year), Int(row.zone_id) )); catch e_row; @error "Error processing a thermal plant row in $filepath: $row. Details: $e_row"; end; end
    if isempty(plants) && nrow(df) > 0; @warn "No thermal plants processed from $filepath."; end
    return plants
end

"""
    read_renewable_plant_definitions(filepath::String)::Vector{RenewablePlant}
    (Reads renewable plant definitions from CSV, including zone_id)
"""
function read_renewable_plant_definitions(filepath::String)::Vector{RenewablePlant}
    plants = RenewablePlant[]
    expected_columns = ["name", "capacity_mw", "variable_om_cost_usd_per_mwh", "curtailment_cost_usd_per_mwh", "investment_cost_usd_per_mw_year", "zone_id"]
    if !isfile(filepath); @error "Renewable plant definitions file not found: $filepath"; return RenewablePlant[]; end
    local df; try df = CSV.read(filepath, DataFrame); catch e; @error "CSV read error for renewable defs $filepath: $e"; return RenewablePlant[]; end
    actual_cols = Symbol.(names(df)); expected_sym_cols = Symbol.(expected_columns)
    if !issubset(expected_sym_cols, actual_cols); missing_cols = setdiff(expected_sym_cols, actual_cols); @error "Missing expected columns in renewable definitions file $filepath: $(join(string.(missing_cols), ", "))"; return RenewablePlant[]; end
    for row in eachrow(df); try push!(plants, RenewablePlant(String(row.name), Float64(row.capacity_mw), Dict{Tuple{Int, Int}, Vector{Float64}}(), Float64(row.variable_om_cost_usd_per_mwh), Float64(row.curtailment_cost_usd_per_mwh), Float64(row.investment_cost_usd_per_mw_year), Int(row.zone_id) )); catch e_row; @error "Error processing a renewable plant definition row in $filepath: $row. Details: $e_row"; end; end
    if isempty(plants) && nrow(df) > 0; @warn "No renewable plants processed from $filepath."; end
    return plants
end

"""
    read_stage_specific_data(stage_id::Int, stage_path::String, zone_id::Int, all_renewable_plants::Vector{RenewablePlant}) -> Union{StageSpecificData, Nothing}

Reads stage-specific data for a given stage and zone, including demand and renewable availability profiles.
Renewable profiles are updated directly in the `all_renewable_plants` objects (side-effect).
"""
function read_stage_specific_data(stage_id::Int, stage_path::String, zone_id::Int, all_renewable_plants::Vector{RenewablePlant})::Union{StageSpecificData, Nothing}
    # Demand Reading
    demand_filename = "zone_$(zone_id)_demand.csv"
    demand_csv_path = joinpath(stage_path, demand_filename)

    if !isfile(demand_csv_path)
        @error "Demand CSV file not found for Stage $stage_id, Zone $zone_id at: $demand_csv_path"
        return nothing
    end

    local demand_profile_df
    local demand_vector::Vector{Float64}
    try
        demand_profile_df = CSV.read(demand_csv_path, DataFrame)
        if !"demand_mw" in names(demand_profile_df)
            @error "Missing 'demand_mw' column in $demand_csv_path for Stage $stage_id, Zone $zone_id."
            return nothing
        end
        demand_vector = Vector{Float64}()
        for val in demand_profile_df.demand_mw
            if val isa Number
                push!(demand_vector, Float64(val))
            else
                @error "Non-numeric value '$val' in demand_mw column of $demand_csv_path for Stage $stage_id, Zone $zone_id."
                return nothing
            end
        end
        if isempty(demand_vector)
            @warn "Demand profile for Stage $stage_id, Zone $zone_id at $demand_csv_path is empty."
        end
    catch e
        @error "Error reading or processing demand CSV for Stage $stage_id, Zone $zone_id at $demand_csv_path: $e"
        return nothing
    end

    # Deterministic Renewable Profile Reading (Phase 1)
    for rp in all_renewable_plants
        if rp.zone_id == zone_id # Process only plants in the current zone
            profile_filename = "zone_$(zone_id)_$(rp.name)_profile.csv"
            profile_filepath = joinpath(stage_path, profile_filename)

            if isfile(profile_filepath)
                try
                    profile_df = CSV.read(profile_filepath, DataFrame)
                    if "availability" in names(profile_df)
                        profile_vector = Vector{Float64}()
                        for val in profile_df.availability
                            if val isa Number
                                push!(profile_vector, Float64(val))
                            else
                                @warn "Non-numeric value '$val' in availability column of $profile_filepath. Skipping value."
                                # Or, decide to make this an error: return nothing
                            end
                        end
                        # Store as scenario 1 for this stage (deterministic for now)
                        rp.scenario_availability_profiles[(stage_id, 1)] = profile_vector
                        # @info "Loaded profile for $(rp.name), Stage $stage_id, Zone $zone_id from $profile_filepath"
                    else
                        @warn "Missing 'availability' column in $profile_filepath for plant $(rp.name), stage $stage_id, zone $zone_id."
                    end
                catch e_csv
                    @warn "Error reading or processing profile CSV $profile_filepath for plant $(rp.name), stage $stage_id, zone $zone_id. Error: $e_csv"
                end
            else
                @warn "Profile CSV file $profile_filepath not found for plant $(rp.name), stage $stage_id, zone $zone_id."
            end
        end
    end

    return StageSpecificData(stage_id, zone_id, demand_vector)
end


# --- read_initial_capacities, read_zones, read_transmission_lines, parse_main_config ---
# --- remain the same as in the previous `overwrite_file_with_block` call. ---
# --- For brevity, their full text is omitted here. ---
function read_initial_capacities(filepath::String)::Dict{String, Float64}
    capacities = Dict{String, Float64}()
    expected_columns = ["plant_name", "initial_capacity_mw"]
    if !isfile(filepath); @error "Initial capacities file not found: $filepath"; return capacities; end
    local df; try df = CSV.read(filepath, DataFrame); catch e; @error "CSV read error for initial capacities $filepath: $e"; return capacities; end
    actual_cols = Symbol.(names(df)); expected_sym_cols = Symbol.(expected_columns);
    if !issubset(expected_sym_cols, actual_cols); missing_cols = setdiff(expected_sym_cols, actual_cols); @error "Missing expected columns in initial capacities file $filepath: $(join(string.(missing_cols), ", "))"; return capacities; end
    for row in eachrow(df); try plant_name = String(row.plant_name); capacity_val = row.initial_capacity_mw; if capacity_val isa Number; capacities[plant_name] = Float64(capacity_val); else; @error "Non-numeric value '$(capacity_val)' for initial_capacity_mw for plant '$plant_name' in $filepath."; end; catch e_row; @error "Error processing a row in initial capacities file $filepath: $row. Details: $e_row"; end; end
    if isempty(capacities) && nrow(df) > 0; @warn "No initial capacities processed from $filepath."; end
    return capacities
end

function read_zones(filepath::String)::Vector{Zone}
    zones = Zone[]
    expected_columns = ["id", "name"]
    if !isfile(filepath); @error "Zones file not found: $filepath"; return zones; end
    local df; try df = CSV.read(filepath, DataFrame); catch e; @error "CSV read error for zones $filepath: $e"; return zones; end
    actual_cols = Symbol.(names(df)); expected_sym_cols = Symbol.(expected_columns);
    if !issubset(expected_sym_cols, actual_cols); missing_cols = setdiff(expected_sym_cols, actual_cols); @error "Missing expected columns in zones file $filepath: $(join(string.(missing_cols), ", "))"; return zones; end
    for row in eachrow(df)
        try push!(zones, Zone(Int(row.id), String(row.name))); catch e_row; @error "Error processing a zone row in $filepath: $row. Details: $e_row"; end
    end
    if isempty(zones) && nrow(df) > 0; @warn "No zones processed from $filepath."; end
    return zones
end

function read_transmission_lines(filepath::String)::Vector{TransmissionLine}
    lines = TransmissionLine[]
    expected_columns = ["id", "from_zone_id", "to_zone_id", "reactance_pu", "thermal_limit_mw", "length_km", "investment_cost_usd_per_mw_year", "initial_capacity_mw"]
    if !isfile(filepath); @error "Transmission lines file not found: $filepath"; return lines; end
    local df; try df = CSV.read(filepath, DataFrame); catch e; @error "CSV read error for transmission lines $filepath: $e"; return lines; end
    actual_cols = Symbol.(names(df)); expected_sym_cols = Symbol.(expected_columns);
    if !issubset(expected_sym_cols, actual_cols); missing_cols = setdiff(expected_sym_cols, actual_cols); @error "Missing expected columns in transmission lines file $filepath: $(join(string.(missing_cols), ", "))"; return lines; end
    for row in eachrow(df)
        try push!(lines, TransmissionLine(String(row.id), Int(row.from_zone_id), Int(row.to_zone_id), Float64(row.reactance_pu), Float64(row.thermal_limit_mw), Float64(row.length_km), Float64(row.investment_cost_usd_per_mw_year), Float64(row.initial_capacity_mw))); catch e_row; @error "Error processing a transmission line row in $filepath: $row. Details: $e_row"; end
    end
    if isempty(lines) && nrow(df) > 0; @warn "No transmission lines processed from $filepath."; end
    return lines
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
        required_global_keys = ["zones", "transmission_lines", "thermal_plants", "renewable_plants_definitions", "initial_capacities"];
        for r_key in required_global_keys; if !haskey(global_data_paths_json, r_key); error("Missing required key '$r_key' in 'global_data_paths' of $config_filepath"); end; end
        global_paths_typed_dict = Dict{String, String}(); for (key, value) in global_data_paths_json; if !(value isa String); error("All values in 'global_data_paths' must be strings. Key: '$key' has value '$value'"); end; global_paths_typed_dict[String(key)] = value; end
        return project_params, stage_paths_vec, global_paths_typed_dict
    catch e
        if e isa SystemError; error("System error accessing config file $config_filepath: $e"); elseif e isa JSON.JSONParseException; error("Error parsing JSON in $config_filepath: $e"); else; rethrow(e); end
    end
end
