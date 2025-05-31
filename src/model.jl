include("types.jl")

using JuMP
using HiGHS # Or any other solver

export build_model

"""
    build_model(...) -> Model

Builds the optimization model with all data structures prepared for JuMP.
"""
function build_model(
    project_params::ProjectParameters,
    thermal_plants::Vector{ThermalPlant},
    renewable_plants::Vector{RenewablePlant},
    # must_run_plants::Vector{MustRunPlant}, # Placeholder for future
    # storage_units::Vector{Storage},       # Placeholder for future
    initial_capacities::Dict{String, Float64},
    all_stage_zone_data::Dict{Tuple{Int, Int}, StageSpecificData}
)
    model = Model(HiGHS.Optimizer)

    # --- 1. Define Sets ---
    S = 1:project_params.num_stages
    Z = [z.id for z in project_params.zones]
    if isempty(all_stage_zone_data) && project_params.num_stages > 0
        error("No stage-zone data available to determine number of timesteps for project with num_stages > 0.")
    end
    num_timesteps = 0
    if !isempty(all_stage_zone_data)
        first_key = first(keys(all_stage_zone_data))
        num_timesteps = length(all_stage_zone_data[first_key].demand_profile)
        if num_timesteps == 0; @warn "Demand profile for key $first_key is empty. T will be empty."; end
    elseif project_params.num_stages > 0
        @warn "No stage-zone data provided, but num_stages > 0. Operational variables/constraints might be ill-defined if T is empty."
    end
    T = 1:num_timesteps

    P_thermal = [p.name for p in thermal_plants]
    P_renewable = [p.name for p in renewable_plants]
    P_all = union(P_thermal, P_renewable)
    L_set = [line.id for line in project_params.transmission_lines]

    # --- 2. Prepare Parameters ---
    model[:Params] = Dict{Symbol, Any}()
    model[:Params][:DiscountRate] = project_params.discount_rate # Store for objective
    model[:Params][:YearsPerStage] = project_params.years_per_stage # Store for objective

    Demand = Dict{Tuple{Int, Int, Int}, Float64}(); for s_idx in S, z_id in Z, t_idx in T; Demand[(z_id, s_idx, t_idx)] = 0.0; end
    for s_idx in S; for z_id in Z; stage_zone_key = (s_idx, z_id); if haskey(all_stage_zone_data, stage_zone_key); profile = all_stage_zone_data[stage_zone_key].demand_profile; for t_idx in T; if t_idx <= length(profile); Demand[(z_id, s_idx, t_idx)] = profile[t_idx]; else; Demand[(z_id, s_idx, t_idx)] = 0.0; end; end; else; for t_idx in T Demand[(z_id,s_idx,t_idx)] = 0.0; end; @warn "Missing demand data zone $z_id, stage $s_idx. Assuming 0 demand."; end; end; end
    model[:Params][:Demand] = Demand

    model[:Params][:Thermal_Inv_Cost] = Dict(p.name => p.investment_cost_usd_per_mw_year for p in thermal_plants)
    model[:Params][:Renewable_Inv_Cost] = Dict(p.name => p.investment_cost_usd_per_mw_year for p in renewable_plants)
    model[:Params][:Thermal_VarOM_Cost] = Dict(p.name => p.variable_om_cost_usd_per_mwh for p in thermal_plants)
    model[:Params][:Renewable_VarOM_Cost] = Dict(p.name => p.variable_om_cost_usd_per_mwh for p in renewable_plants)
    # For fuel cost per MWh for thermal plants
    Thermal_FuelCost_per_MWh = Dict(p.name => p.fuel_cost_usd_per_mmbtu * p.heat_rate_mmbtu_per_mwh for p in thermal_plants)
    model[:Params][:Thermal_FuelCost_per_MWh] = Thermal_FuelCost_per_MWh

    model[:Params][:Thermal_Max_Capacity] = Dict(p.name => p.capacity_mw for p in thermal_plants)
    model[:Params][:Renewable_Max_Capacity] = Dict(p.name => p.capacity_mw for p in renewable_plants)
    Plant_ZoneID = Dict{String, Int}(); for p in thermal_plants Plant_ZoneID[p.name] = p.zone_id; end; for p in renewable_plants Plant_ZoneID[p.name] = p.zone_id; end
    model[:Params][:Plant_ZoneID] = Plant_ZoneID
    model[:Params][:Initial_Capacity_Plant] = Dict(name => get(initial_capacities, name, 0.0) for name in P_all)

    RenewableAvailability = Dict{Tuple{String, Int, Int}, Float64}(); for p_name in P_renewable, s_idx in S, t_idx in T RenewableAvailability[(p_name, s_idx, t_idx)] = 0.0; end;
    for p in renewable_plants; for s_idx in S; profile_key = (s_idx, 1); if haskey(p.scenario_availability_profiles, profile_key); profile = p.scenario_availability_profiles[profile_key]; for t_idx in T; if t_idx <= length(profile); RenewableAvailability[(p.name, s_idx, t_idx)] = profile[t_idx]; else; RenewableAvailability[(p.name, s_idx, t_idx)] = 0.0; end; end; else; @warn "Missing renewable profile $(p.name), stage $s_idx. Assuming 0 avail."; end; end; end
    model[:Params][:RenewableAvailability] = RenewableAvailability

    model[:Params][:Line_From_Zone] = Dict(line.id => line.from_zone_id for line in project_params.transmission_lines)
    model[:Params][:Line_To_Zone] = Dict(line.id => line.to_zone_id for line in project_params.transmission_lines)
    model[:Params][:Line_Reactance] = Dict(line.id => line.reactance_pu for line in project_params.transmission_lines)
    model[:Params][:Line_Thermal_Limit] = Dict(line.id => line.thermal_limit_mw for line in project_params.transmission_lines)
    model[:Params][:Line_Inv_Cost] = Dict(line.id => line.investment_cost_usd_per_mw_year for line in project_params.transmission_lines)
    model[:Params][:Initial_Capacity_Line] = Dict(line.id => line.initial_capacity_mw for line in project_params.transmission_lines)

    # --- 3. Define Decision Variables ---
    model[:CapNew] = @variable(model, [p in P_all, s in S], base_name="CapNew", lower_bound=0.0)
    model[:CapTotal] = @variable(model, [p in P_all, s in S], base_name="CapTotal", lower_bound=0.0)
    model[:CapRetire] = @variable(model, [p in P_all, s in S], base_name="CapRetire", lower_bound=0.0)
    model[:TxCapNew] = @variable(model, [l in L_set, s in S], base_name="TxCapNew", lower_bound=0.0)
    model[:TxCapTotal] = @variable(model, [l in L_set, s in S], base_name="TxCapTotal", lower_bound=0.0)
    model[:TxCapRetire] = @variable(model, [l in L_set, s in S], base_name="TxCapRetire", lower_bound=0.0)
    if num_timesteps > 0
        model[:Dispatch_thermal] = @variable(model, [p in P_thermal, s in S, t in T], base_name="DispTh", lower_bound=0.0)
        model[:Dispatch_renewable] = @variable(model, [p in P_renewable, s in S, t in T], base_name="DispRen", lower_bound=0.0)
        model[:Curtailment_renewable] = @variable(model, [p in P_renewable, s in S, t in T], base_name="CurtRen", lower_bound=0.0)
        model[:Flow] = @variable(model, [l in L_set, s in S, t in T], base_name="Flow")
    end

    # --- 4. Define Constraints ---
    Plant_initial_capacity = model[:Params][:Initial_Capacity_Plant]; Line_initial_capacity = model[:Params][:Initial_Capacity_Line]
    Plant_max_capacity = merge(model[:Params][:Thermal_Max_Capacity], model[:Params][:Renewable_Max_Capacity])
    CapNew = model[:CapNew]; CapTotal = model[:CapTotal]; CapRetire = model[:CapRetire]
    TxCapNew = model[:TxCapNew]; TxCapTotal = model[:TxCapTotal]; TxCapRetire = model[:TxCapRetire]
    @constraint(model, PlantCapEvolution[p in P_all, s in S], CapTotal[p,s] == (s > 1 ? CapTotal[p,s-1] : get(Plant_initial_capacity, p, 0.0)) + CapNew[p,s] - CapRetire[p,s])
    @constraint(model, PlantRetireLimit[p in P_all, s in S], CapRetire[p,s] <= (s > 1 ? CapTotal[p,s-1] : get(Plant_initial_capacity, p, 0.0)))
    @constraint(model, PlantMaxCapacity[p in P_all, s in S], CapTotal[p,s] <= get(Plant_max_capacity, p, Inf))
    @constraint(model, LineCapEvolution[l in L_set, s in S], TxCapTotal[l,s] == (s > 1 ? TxCapTotal[l,s-1] : get(Line_initial_capacity, l, 0.0)) + TxCapNew[l,s] - TxCapRetire[l,s])
    @constraint(model, LineRetireLimit[l in L_set, s in S], TxCapRetire[l,s] <= (s > 1 ? TxCapTotal[l,s-1] : get(Line_initial_capacity, l, 0.0)))

    if num_timesteps > 0
        Dispatch_thermal = model[:Dispatch_thermal]; Dispatch_renewable = model[:Dispatch_renewable]; Curtailment_renewable = model[:Curtailment_renewable]; Flow = model[:Flow]
        RenAvailability = model[:Params][:RenewableAvailability]; Demand_param = model[:Params][:Demand]; Plant_ZoneID_param = model[:Params][:Plant_ZoneID]
        Line_From_Zone_param = model[:Params][:Line_From_Zone]; Line_To_Zone_param = model[:Params][:Line_To_Zone]
        @constraint(model, ThermalDispatchLimit[p in P_thermal, s in S, t in T], Dispatch_thermal[p,s,t] <= CapTotal[p,s])
        @constraint(model, RenewableDispatchBalance[p in P_renewable, s in S, t in T], Dispatch_renewable[p,s,t] + Curtailment_renewable[p,s,t] == CapTotal[p,s] * RenAvailability[(p,s,t)])
        @constraint(model, TxFlowUpper[l in L_set, s in S, t in T], Flow[l,s,t] <= TxCapTotal[l,s])
        @constraint(model, TxFlowLower[l in L_set, s in S, t in T], Flow[l,s,t] >= -TxCapTotal[l,s])
        @constraint(model, NodalBalance[z_id in Z, s in S, t in T], sum(Dispatch_thermal[p,s,t] for p in P_thermal if get(Plant_ZoneID_param,p,-1)==z_id) + sum(Dispatch_renewable[p,s,t] for p in P_renewable if get(Plant_ZoneID_param,p,-1)==z_id) + sum(Flow[l,s,t] for l in L_set if get(Line_To_Zone_param,l,-1)==z_id) - sum(Flow[l,s,t] for l in L_set if get(Line_From_Zone_param,l,-1)==z_id) == Demand_param[(z_id,s,t)])
    end

    # --- 5. Define Objective Function ---
    @info "Defining objective function..."
    # Retrieve necessary parameters
    DiscountRate = model[:Params][:DiscountRate]
    YearsPerStage = model[:Params][:YearsPerStage]

    Plant_Inv_Cost_Thermal = model[:Params][:Thermal_Inv_Cost]
    Plant_Inv_Cost_Renewable = model[:Params][:Renewable_Inv_Cost]
    Plant_Inv_Cost = merge(Plant_Inv_Cost_Thermal, Plant_Inv_Cost_Renewable) # Combine for P_all

    Line_Inv_Cost = model[:Params][:Line_Inv_Cost]

    Thermal_VarOM_Cost = model[:Params][:Thermal_VarOM_Cost]
    Thermal_FuelCost_MWh = model[:Params][:Thermal_FuelCost_per_MWh] # Used the precomputed one
    Renewable_VarOM_Cost = model[:Params][:Renewable_VarOM_Cost]


    # Discount factors for investments (start of stage)
    df_invest = Dict(s_idx => (1 / (1 + DiscountRate))^((s_idx - 1) * YearsPerStage) for s_idx in S)

    # Present value factor for a stream of annual costs over a stage, discounted to start of that stage
    pvf_annual_op = Dict(s_idx => sum((1 / (1 + DiscountRate))^(yr - 1) for yr in 1:YearsPerStage) for s_idx in S)

    # Total Investment Costs
    TotalPlantInvCost = @expression(model, sum(Plant_Inv_Cost[p] * CapNew[p,s] * df_invest[s] for p in P_all, s in S))
    TotalTxInvCost = @expression(model, sum(Line_Inv_Cost[l] * TxCapNew[l,s] * df_invest[s] for l in L_set, s in S))

    TotalInvestmentCost = @expression(model, TotalPlantInvCost + TotalTxInvCost)

    # Total Operational Costs
    AnnualThermalOpCost = AffExpr(0.0)
    AnnualRenewableOpCost = AffExpr(0.0)

    if num_timesteps > 0
        HoursPerTimeStep = 1 # Assuming T represents hourly intervals
        ScalingFactor8760 = 8760.0 / num_timesteps # Scales representative hours to annual hours

        AnnualThermalOpCost = @expression(model,
            sum( (Thermal_VarOM_Cost[p] + Thermal_FuelCost_MWh[p]) * model[:Dispatch_thermal][p,s,t] * HoursPerTimeStep * ScalingFactor8760
                 for p in P_thermal, s in S, t in T) # This is sum over all stages, need to adjust
        )
        # Corrected: Summing for one year's profile, then discounting per stage
        # This expression will be built stage by stage
        DiscountedThermalOpCost = @expression(model,
            sum( df_invest[s] * pvf_annual_op[s] *
                 sum( (Thermal_VarOM_Cost[p] + Thermal_FuelCost_MWh[p]) * model[:Dispatch_thermal][p,s,t] * HoursPerTimeStep * ScalingFactor8760
                      for p in P_thermal, t in T)
                 for s in S)
        )

        DiscountedRenewableOpCost = @expression(model,
            sum( df_invest[s] * pvf_annual_op[s] *
                 sum( Renewable_VarOM_Cost[p] * model[:Dispatch_renewable][p,s,t] * HoursPerTimeStep * ScalingFactor8760
                      for p in P_renewable, t in T)
                 for s in S)
        )
        TotalOperationalCost = @expression(model, DiscountedThermalOpCost + DiscountedRenewableOpCost)
    else
        TotalOperationalCost = AffExpr(0.0) # No operational costs if no timesteps
    end

    @objective(model, Min, TotalInvestmentCost + TotalOperationalCost)
    @info "Objective function defined."

    return model
end
