# Add src to load path or use relative includes
include("src/types.jl")
include("src/io.jl")
include("src/model.jl")
include("src/results.jl") # Now contains the enhanced print_results

using JuMP
using ArgParse

"""
    main()

Main function to run the capacity expansion model.
Parses a main JSON configuration file to set up the model run.
"""
function main()
    s = ArgParseSettings(description="Capacity Expansion Model Runner.")
    @add_arg_table! s begin
        "--config", "-c"; help = "Path to the main JSON configuration file"; arg_type = String; default = "data/config.json"
    end
    parsed_args = parse_args(ARGS, s)
    config_file_path = parsed_args["config"]

    println("Starting Capacity Expansion Model...")
    @info "Using main configuration file from: $(config_file_path)"

    local project_params_base::Union{ProjectParameters, Nothing} = nothing
    local project_params::Union{ProjectParameters, Nothing} = nothing
    local stage_data_paths::Union{Vector{String}, Nothing} = nothing
    local global_data_paths::Union{Dict{String, String}, Nothing} = nothing
    local config_parsed_successfully = false

    try
        project_params_base, stage_data_paths, global_data_paths = parse_main_config(config_file_path)
        config_parsed_successfully = true
        @info "Successfully parsed base configuration from JSON."
    catch e
        @error "Failed to parse or validate configuration: $e"; println("Exiting."); return
    end

    local zones_data = Zone[]
    local transmission_lines_data = TransmissionLine[]

    if config_parsed_successfully && !isnothing(global_data_paths)
        zones_filepath = get(global_data_paths, "zones", "")
        if !isempty(zones_filepath)
            @info "Attempting to load zones data from: $(zones_filepath)"; zones_data = read_zones(zones_filepath)
            if isempty(zones_data); @warn "No zones data loaded."; else; @info "Loaded $(length(zones_data)) zones."; end
        else; @warn "'zones' key not found or path empty."; end

        lines_filepath = get(global_data_paths, "transmission_lines", "")
        if !isempty(lines_filepath)
            @info "Attempting to load transmission lines from: $(lines_filepath)"; transmission_lines_data = read_transmission_lines(lines_filepath)
            if isempty(transmission_lines_data); @warn "No transmission lines loaded."; else; @info "Loaded $(length(transmission_lines_data)) lines."; end
        else; @warn "'transmission_lines' key not found or path empty."; end

        if !isnothing(project_params_base)
            project_params = ProjectParameters(project_params_base.num_stages, project_params_base.years_per_stage, project_params_base.discount_rate, zones_data, transmission_lines_data)
            @info "ProjectParameters created with zones and transmission lines."
            # println("\nProject Parameters Summary:"); println("  Num Stages: ", project_params.num_stages, ", Years/Stage: ", project_params.years_per_stage, ", Discount Rate: ", project_params.discount_rate); println("  Num Zones: ", length(project_params.zones), ", Num Lines: ", length(project_params.transmission_lines))
        else; @error "Base project_params not available. Exiting."; return; end
    else
        @error "Configuration not parsed successfully or global_data_paths is missing. Exiting."
        return
    end

    local thermal_plants_data = ThermalPlant[]
    local renewable_plants_data = RenewablePlant[]
    local all_stage_zone_data = Dict{Tuple{Int, Int}, StageSpecificData}()
    local initial_capacities = Dict{String, Float64}()
    # Placeholders for future types
    # local must_run_plants_data = MustRunPlant[] # Uncomment when ready
    # local storage_units_data = Storage[]       # Uncomment when ready


    if config_parsed_successfully && !isnothing(project_params) && !isnothing(global_data_paths)
        # Load thermal plants
        thermal_plants_csv_path = get(global_data_paths, "thermal_plants", ""); if !isempty(thermal_plants_csv_path); @info "Loading thermal plants from: $(thermal_plants_csv_path)"; thermal_plants_data = read_thermal_plants(thermal_plants_csv_path); if isempty(thermal_plants_data); @warn "No thermal plants loaded."; else; @info "Loaded $(length(thermal_plants_data)) thermal plants."; end; else; @warn "'thermal_plants' path not found."; end
        # Load renewable definitions
        renewable_defs_csv_path = get(global_data_paths, "renewable_plants_definitions", ""); if !isempty(renewable_defs_csv_path); @info "Loading renewable definitions from: $(renewable_defs_csv_path)"; renewable_plants_data = read_renewable_plant_definitions(renewable_defs_csv_path); if isempty(renewable_plants_data); @warn "No renewable definitions loaded."; else; @info "Loaded $(length(renewable_plants_data)) renewable definitions."; end; else; @warn "'renewable_plants_definitions' path not found."; end
        # Load initial capacities
        initial_caps_csv_path = get(global_data_paths, "initial_capacities", ""); if !isempty(initial_caps_csv_path); @info "Loading initial capacities from: $(initial_caps_csv_path)"; initial_capacities = read_initial_capacities(initial_caps_csv_path); if isempty(initial_capacities); @warn "No initial capacities loaded."; else; @info "Loaded $(length(initial_capacities)) initial capacities."; end; else; @warn "'initial_capacities' path not found."; end

        @info "\nLoading stage-specific data for each zone..."
        if !isnothing(stage_data_paths) && !isempty(project_params.zones)
            if length(stage_data_paths) != project_params.num_stages; @error "Mismatch num_stages and stage_data_paths length."; return; end
            for stage_id in 1:project_params.num_stages
                stage_path = stage_data_paths[stage_id]
                for zone_obj in project_params.zones
                    current_zone_id = zone_obj.id
                    # @info "Loading data for Stage $stage_id, Zone $current_zone_id from path: $stage_path" # Can be too verbose
                    stage_zone_data_obj = read_stage_specific_data(stage_id, stage_path, current_zone_id, renewable_plants_data)
                    if !isnothing(stage_zone_data_obj); all_stage_zone_data[(stage_id, current_zone_id)] = stage_zone_data_obj; # @info "Loaded Stage $stage_id, Zone $current_zone_id data."
                    else; @warn "Could not load data for Stage $stage_id, Zone $current_zone_id."; end
                end
            end
            @info "Finished loading data for $(length(all_stage_zone_data)) stage-zone combinations."
            # Verification print for renewable scenario profiles can be very verbose, consider a debug flag
            # @info "\nVerification of loaded renewable scenario profiles:"
            # if !isempty(renewable_plants_data); for rp in renewable_plants_data; if !isempty(rp.scenario_availability_profiles); @info "Plant: $(rp.name) (Zone $(rp.zone_id)) - $(length(rp.scenario_availability_profiles)) profiles. Keys: $(collect(keys(rp.scenario_availability_profiles)))"; else; @warn "Plant: $(rp.name) (Zone $(rp.zone_id)) - No profiles."; end; end; else; @info "No renewable plant definitions loaded."; end
        else; @warn "Stage data paths or zones not available for stage-specific loading."; end

        @info "\nBuilding the optimization model..."
        model = build_model(
            project_params,
            thermal_plants_data,
            renewable_plants_data,
            # must_run_plants_data,
            # storage_units_data,
            initial_capacities,
            all_stage_zone_data
        )
        @info "Model built."

        @info "\nOptimizing the model..."
        JuMP.optimize!(model) # Uncommented

        @info "\nPrinting results..."
        print_results(model) # Uncommented

    end
    println("\nModel run script finished.")
end

main()
