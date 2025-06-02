using Pkg
using Logging

# Activate project environment and instantiate packages
try
    Pkg.activate(".")
    @info "Updating package registry..."
    Pkg.Registry.update()
    @info "Instantiating packages..."
    Pkg.instantiate()
    @info "Precompiling packages..."
    Pkg.precompile()
catch e
    @error "Package setup failed: $e"
    exit(1)
end

# Include source files
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

    @info "Starting Capacity Expansion Model..."
    @info "Using config: $config_file_path"

    project_params_base, stage_data_paths, global_data_paths = try
        parse_main_config(config_file_path)
    catch e
        @error "Config parsing failed: $e"
        return
    end

    # Load global data
    zones_data = !isempty(get(global_data_paths, "zones", "")) ? read_zones(global_data_paths["zones"]) : Zone[]
    transmission_lines_data = !isempty(get(global_data_paths, "transmission_lines", "")) ? read_transmission_lines(global_data_paths["transmission_lines"]) : TransmissionLine[]

    project_params = ProjectParameters(
        project_params_base.num_stages,
        project_params_base.years_per_stage,
        project_params_base.discount_rate,
        zones_data,
        transmission_lines_data
    )

    # Load plant and storage data
    thermal_plants_data = !isempty(get(global_data_paths, "thermal_plants", "")) ? read_thermal_plants(global_data_paths["thermal_plants"]) : ThermalPlant[]
    renewable_plants_data = !isempty(get(global_data_paths, "renewable_plants_definitions", "")) ? read_renewable_plant_definitions(global_data_paths["renewable_plants_definitions"]) : RenewablePlant[]
    storage_units_data = !isempty(get(global_data_paths, "storage_units", "")) ? read_storage_units(global_data_paths["storage_units"]) : Storage[]

    all_stage_zone_data = Dict{Tuple{Int, Int}, StageSpecificData}()

    # Load stage-specific data
    if length(stage_data_paths) == project_params.num_stages
        for stage_id in 1:project_params.num_stages
            stage_path = stage_data_paths[stage_id]
            stage_data = read_stage_specific_data(stage_id, stage_path, project_params.zones, renewable_plants_data)
            for ssd in stage_data
                all_stage_zone_data[(stage_id, ssd.zone_id)] = ssd
            end
        end
    else
        @warn "Mismatch between number of stages and stage data paths"
    end

    # Build and optimize the model
    model = build_model(
        project_params,
        thermal_plants_data,
        renewable_plants_data,
        storage_units_data,
        all_stage_zone_data
    )
    JuMP.optimize!(model)

    print_results(model)
    println("Model run finished.")
end

main()
