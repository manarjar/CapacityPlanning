# Attempt to clear potential Pkg corruption first.
try
    julia_dir = joinpath(homedir(), ".julia")
    if isdir(julia_dir)
        @info "Attempting to remove existing ~/.julia directory to reset Pkg state..."
        rm(julia_dir, recursive=true, force=true)
        @info "~/.julia directory removed."
    end
catch e
    @warn "Could not remove ~/.julia directory. Proceeding with Pkg operations. Error: $e"
end

using Pkg
Pkg.activate(".") # Activate the project environment based on Project.toml in current dir
@info "Updating Pkg registry..."
Pkg.Registry.update() # Explicitly update the registry
@info "Registry update complete."

dependencies = ["ArgParse", "CSV", "DataFrames", "HiGHS", "JSON", "JuMP", "Test"]
for dep in dependencies
    try @info "Attempting to explicitly add package: $dep..."; Pkg.add(dep); @info "$dep added or already present."; catch e; @warn "Pkg.add(\"$dep\") failed. Error: $e"; end
end
@info "Attempting to instantiate/resolve all dependencies post Pkg.add loop..."
try Pkg.instantiate(); @info "Pkg.instantiate() completed."; catch e; @error "Pkg.instantiate() failed. Error: $e"; end

include("src/types.jl")
include("src/io.jl")
include("src/model.jl")
include("src/results.jl")

using JuMP
using ArgParse

function main()
    s = ArgParseSettings(description="Capacity Expansion Model Runner.")
    @add_arg_table! s begin
        "--config", "-c"; help = "Path to main JSON config"; arg_type = String; default = "data/config.json"
    end
    parsed_args = parse_args(ARGS, s)
    config_file_path = parsed_args["config"]

    println("Starting Capacity Expansion Model..."); @info "Using config: $(config_file_path)"

    project_params_base, stage_data_paths, global_data_paths = try parse_main_config(config_file_path) catch e; @error "Config parsing failed: $e"; return; end
    @info "Base configuration parsed."

    zones_data = Zone[]; transmission_lines_data = TransmissionLine[]
    if !isnothing(global_data_paths)
        zones_filepath = get(global_data_paths, "zones", ""); if !isempty(zones_filepath); @info "Loading zones from: $(zones_filepath)"; zones_data = read_zones(zones_filepath); @info "Loaded $(length(zones_data)) zones."; else @warn "Zones path not found/empty."; end
        lines_filepath = get(global_data_paths, "transmission_lines", ""); if !isempty(lines_filepath); @info "Loading lines from: $(lines_filepath)"; transmission_lines_data = read_transmission_lines(lines_filepath); @info "Loaded $(length(transmission_lines_data)) lines."; else @warn "Lines path not found/empty."; end
    else @error "Global data paths missing. Exiting."; return; end

    project_params = ProjectParameters(project_params_base.num_stages, project_params_base.years_per_stage, project_params_base.discount_rate, zones_data, transmission_lines_data)
    @info "ProjectParameters updated with zones and lines."

    thermal_plants_data = ThermalPlant[]
    renewable_plants_data = RenewablePlant[]
    storage_units_data = Storage[]
    all_stage_zone_data = Dict{Tuple{Int, Int}, StageSpecificData}()

    if !isnothing(global_data_paths) && !isnothing(project_params)
        thermal_plants_csv_path = get(global_data_paths, "thermal_plants", ""); if !isempty(thermal_plants_csv_path); @info "Loading thermal plants from: $(thermal_plants_csv_path)"; thermal_plants_data = read_thermal_plants(thermal_plants_csv_path); @info "Loaded $(length(thermal_plants_data)) thermal plants."; else @warn "'thermal_plants' path not found."; end
        renewable_defs_csv_path = get(global_data_paths, "renewable_plants_definitions", ""); if !isempty(renewable_defs_csv_path); @info "Loading renewable definitions from: $(renewable_defs_csv_path)"; renewable_plants_data = read_renewable_plant_definitions(renewable_defs_csv_path); @info "Loaded $(length(renewable_plants_data)) renewable definitions."; else @warn "'renewable_plants_definitions' path not found."; end
        storage_units_csv_path = get(global_data_paths, "storage_units", ""); if !isempty(storage_units_csv_path); @info "Loading storage units from: $(storage_units_csv_path)"; storage_units_data = read_storage_units(storage_units_csv_path); @info "Loaded $(length(storage_units_data)) storage units."; else @warn "'storage_units' path not found in global_data_paths."; end
    end

    @info "\nLoading stage-specific data for each zone..."
    if !isnothing(stage_data_paths) && !isnothing(project_params) && !isempty(project_params.zones)
        if length(stage_data_paths) != project_params.num_stages; @error "Mismatch num_stages and stage_data_paths length."; return; end
        for stage_id in 1:project_params.num_stages
            stage_path = stage_data_paths[stage_id]
            @info "Processing Stage $stage_id from path: $stage_path"
            stage_specific_data_for_all_zones_in_stage = read_stage_specific_data(stage_id, stage_path, project_params.zones, renewable_plants_data)

            if !isempty(stage_specific_data_for_all_zones_in_stage)
                for ssd_obj in stage_specific_data_for_all_zones_in_stage
                    all_stage_zone_data[(stage_id, ssd_obj.zone_id)] = ssd_obj
                    @info "  Loaded data for Stage $stage_id, Zone $(ssd_obj.zone_id). Demand: $(length(ssd_obj.demand_profile)) steps."
                end
            else; @warn "No stage-specific data successfully loaded for Stage $stage_id from path $stage_path."; end
        end
        @info "Finished loading data for $(length(all_stage_zone_data)) stage-zone combinations."
        @info "\nVerification of renewable scenario profiles (after all stages processed):"
        if !isempty(renewable_plants_data); for rp in renewable_plants_data; if !isempty(rp.scenario_availability_profiles); @info "Plant $(rp.name) (Zone $(rp.zone_id)): $(length(rp.scenario_availability_profiles)) profiles. Keys: $(sort(collect(keys(rp.scenario_availability_profiles))))"; else @warn "Plant $(rp.name) (Zone $(rp.zone_id)): No profiles."; end; end; else @info "No renewable plants loaded."; end
    else; @warn "Project params, stage paths, or zones not available for stage-specific loading."; end

    @info "\nBuilding the optimization model..."
    model = build_model(
        project_params,
        thermal_plants_data,
        renewable_plants_data,
        storage_units_data, # Added storage_units_data
        all_stage_zone_data
    )
    @info "Model built."

    @info "\nOptimizing the model..."
    JuMP.optimize!(model)

    @info "\nPrinting results..."
    print_results(model)

    println("\nModel run script finished.")
end

main()
