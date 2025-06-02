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
    storage_units::Vector{Storage}, # Added
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
    P_storage = isempty(storage_units) ? String[] : [p.name for p in storage_units] # Added
    P_all_generation = union(P_thermal, P_renewable) # Plants that only generate
    P_all = union(P_all_generation, P_storage) # All "units" that have capacity decisions

    L_set = [line.id for line in project_params.transmission_lines]

    # --- 2. Prepare Parameters ---
    model[:Params] = Dict{Symbol, Any}()
    model[:Params][:DiscountRate] = project_params.discount_rate
    model[:Params][:YearsPerStage] = project_params.years_per_stage

    Demand = Dict{Tuple{Int, Int, Int}, Float64}(); for s_idx in S, z_id in Z, t_idx in T; Demand[(z_id, s_idx, t_idx)] = 0.0; end
    for s_idx in S; for z_id in Z; stage_zone_key = (s_idx, z_id); if haskey(all_stage_zone_data, stage_zone_key); profile = all_stage_zone_data[stage_zone_key].demand_profile; for t_idx in T; if t_idx <= length(profile); Demand[(z_id, s_idx, t_idx)] = profile[t_idx]; else; Demand[(z_id, s_idx, t_idx)] = 0.0; end; end; else; for t_idx in T Demand[(z_id,s_idx,t_idx)] = 0.0; end; @warn "Missing demand data zone $z_id, stage $s_idx. Assuming 0 demand."; end; end; end
    model[:Params][:Demand] = Demand

    # Plant Investment & Max Capacity (Generation Plants)
    model[:Params][:Thermal_Inv_Cost] = Dict(p.name => p.investment_cost_usd_per_mw_year for p in thermal_plants)
    model[:Params][:Renewable_Inv_Cost] = Dict(p.name => p.investment_cost_usd_per_mw_year for p in renewable_plants)
    model[:Params][:Thermal_Max_Capacity] = Dict(p.name => p.capacity_mw for p in thermal_plants)
    model[:Params][:Renewable_Max_Capacity] = Dict(p.name => p.capacity_mw for p in renewable_plants)

    # Plant Operational Costs (Generation Plants)
    model[:Params][:Thermal_VarOM_Cost] = Dict(p.name => p.variable_om_cost_usd_per_mwh for p in thermal_plants)
    model[:Params][:Renewable_VarOM_Cost] = Dict(p.name => p.variable_om_cost_usd_per_mwh for p in renewable_plants)
    Thermal_FuelCost_per_MWh = Dict(p.name => p.fuel_cost_usd_per_mmbtu * p.heat_rate_mmbtu_per_mwh for p in thermal_plants)
    model[:Params][:Thermal_FuelCost_per_MWh] = Thermal_FuelCost_per_MWh

    # Zone IDs (All units)
    Plant_ZoneID = Dict{String, Int}();
    for p in thermal_plants Plant_ZoneID[p.name] = p.zone_id; end
    for p in renewable_plants Plant_ZoneID[p.name] = p.zone_id; end
    for p in storage_units Plant_ZoneID[p.name] = p.zone_id; end # Added for storage
    model[:Params][:Plant_ZoneID] = Plant_ZoneID # Note: "Plant" here means any unit with a zone_id

    # Initial Capacities (Generation Plants)
    Initial_Capacity_Plant = Dict{String, Float64}()
    for p in thermal_plants; Initial_Capacity_Plant[p.name] = p.initial_capacity_mw; end
    for p in renewable_plants; Initial_Capacity_Plant[p.name] = p.initial_capacity_mw; end
    model[:Params][:Initial_Capacity_Plant] = Initial_Capacity_Plant

    # Renewable Availability
    RenewableAvailability = Dict{Tuple{String, Int, Int}, Float64}(); for p_name in P_renewable, s_idx in S, t_idx in T RenewableAvailability[(p_name, s_idx, t_idx)] = 0.0; end;
    for p in renewable_plants; for s_idx in S; profile_key = (s_idx, 1); if haskey(p.scenario_availability_profiles, profile_key); profile = p.scenario_availability_profiles[profile_key]; for t_idx in T; if t_idx <= length(profile); RenewableAvailability[(p.name, s_idx, t_idx)] = profile[t_idx]; else; RenewableAvailability[(p.name, s_idx, t_idx)] = 0.0; end; end; else; @warn "Missing renewable profile $(p.name), stage $s_idx. Assuming 0 avail."; end; end; end
    model[:Params][:RenewableAvailability] = RenewableAvailability

    # Storage Parameters
    model[:Params][:Sto_MaxEnergyCap] = Dict(p.name => p.storage_capacity_mwh for p in storage_units)
    model[:Params][:Sto_MaxChargeCap] = Dict(p.name => p.charge_power_mw for p in storage_units)
    model[:Params][:Sto_MaxDischargeCap] = Dict(p.name => p.discharge_power_mw for p in storage_units)
    model[:Params][:Sto_ChargeEff] = Dict(p.name => p.charge_efficiency for p in storage_units)
    model[:Params][:Sto_DischargeEff] = Dict(p.name => p.discharge_efficiency for p in storage_units)
    model[:Params][:Sto_MinSOC_frac] = Dict(p.name => p.soc_min_fraction for p in storage_units)
    model[:Params][:Sto_MaxSOC_frac] = Dict(p.name => p.soc_max_fraction for p in storage_units)
    model[:Params][:Sto_InitialEnergyCap] = Dict(p.name => p.initial_storage_capacity_mwh for p in storage_units)
    model[:Params][:Sto_InitialChargeCap] = Dict(p.name => p.initial_charge_power_mw for p in storage_units)
    model[:Params][:Sto_InitialDischargeCap] = Dict(p.name => p.initial_discharge_power_mw for p in storage_units)
    model[:Params][:Sto_VarOM_Charge] = Dict(p.name => p.variable_om_cost_charge_usd_per_mwh for p in storage_units)
    model[:Params][:Sto_VarOM_Discharge] = Dict(p.name => p.variable_om_cost_discharge_usd_per_mwh for p in storage_units)
    model[:Params][:Sto_InvCost_Power] = Dict(p.name => p.investment_cost_usd_per_mw_year_power for p in storage_units)
    model[:Params][:Sto_InvCost_Energy] = Dict(p.name => p.investment_cost_usd_per_mwh_year_energy for p in storage_units)

    # Line Params (no changes here from previous step)
    model[:Params][:Line_From_Zone] = Dict(line.id => line.from_zone_id for line in project_params.transmission_lines); model[:Params][:Line_To_Zone] = Dict(line.id => line.to_zone_id for line in project_params.transmission_lines); model[:Params][:Line_Reactance] = Dict(line.id => line.reactance_pu for line in project_params.transmission_lines); model[:Params][:Line_Thermal_Limit] = Dict(line.id => line.thermal_limit_mw for line in project_params.transmission_lines); model[:Params][:Line_Inv_Cost] = Dict(line.id => line.investment_cost_usd_per_mw_year for line in project_params.transmission_lines); model[:Params][:Initial_Capacity_Line] = Dict(line.id => line.initial_capacity_mw for line in project_params.transmission_lines)

    # --- 3. Define Decision Variables ---
    # Generation Plant Capacity Variables (P_all_generation might be better here if P_storage has different Cap variables)
    # For now, P_all includes storage, implying CapNew[storage_plant, s] is for its "power" aspect if generic. This needs care.
    # Let's assume CapNew for storage refers to its power block for now, and energy cap is separate.
    # This means the interpretation of Plant_Inv_Cost for storage in the objective will need to be 0 or power-related.
    # A cleaner way: define specific capacity variables for storage.

    model[:CapNew] = @variable(model, [p in P_all_generation, s in S], base_name="CapNew", lower_bound=0.0)
    model[:CapTotal] = @variable(model, [p in P_all_generation, s in S], base_name="CapTotal", lower_bound=0.0)
    model[:CapRetire] = @variable(model, [p in P_all_generation, s in S], base_name="CapRetire", lower_bound=0.0)

    model[:TxCapNew] = @variable(model, [l in L_set, s in S], base_name="TxCapNew", lower_bound=0.0)
    model[:TxCapTotal] = @variable(model, [l in L_set, s in S], base_name="TxCapTotal", lower_bound=0.0)
    model[:TxCapRetire] = @variable(model, [l in L_set, s in S], base_name="TxCapRetire", lower_bound=0.0)

    # Storage Capacity Variables
    model[:StoCapEnergyNew] = @variable(model, [p in P_storage, s in S], base_name="StoCapEnergyNew", lower_bound=0.0)
    model[:StoCapEnergyTotal] = @variable(model, [p in P_storage, s in S], base_name="StoCapEnergyTotal", lower_bound=0.0)
    model[:StoCapEnergyRetire] = @variable(model, [p in P_storage, s in S], base_name="StoCapEnergyRetire", lower_bound=0.0)
    model[:StoCapChargeNew] = @variable(model, [p in P_storage, s in S], base_name="StoCapChargeNew", lower_bound=0.0)
    model[:StoCapChargeTotal] = @variable(model, [p in P_storage, s in S], base_name="StoCapChargeTotal", lower_bound=0.0)
    model[:StoCapChargeRetire] = @variable(model, [p in P_storage, s in S], base_name="StoCapChargeRetire", lower_bound=0.0)
    model[:StoCapDischargeNew] = @variable(model, [p in P_storage, s in S], base_name="StoCapDischargeNew", lower_bound=0.0)
    model[:StoCapDischargeTotal] = @variable(model, [p in P_storage, s in S], base_name="StoCapDischargeTotal", lower_bound=0.0)
    model[:StoCapDischargeRetire] = @variable(model, [p in P_storage, s in S], base_name="StoCapDischargeRetire", lower_bound=0.0)

    if num_timesteps > 0
        model[:Dispatch_thermal] = @variable(model, [p in P_thermal, s in S, t in T], base_name="DispTh", lower_bound=0.0)
        model[:Dispatch_renewable] = @variable(model, [p in P_renewable, s in S, t in T], base_name="DispRen", lower_bound=0.0)
        model[:Curtailment_renewable] = @variable(model, [p in P_renewable, s in S, t in T], base_name="CurtRen", lower_bound=0.0)
        model[:Flow] = @variable(model, [l in L_set, s in S, t in T], base_name="Flow")
        # Storage Operational Variables
        model[:StoCharge] = @variable(model, [p in P_storage, s in S, t in T], base_name="StoCharge", lower_bound=0.0)
        model[:StoDischarge] = @variable(model, [p in P_storage, s in S, t in T], base_name="StoDischarge", lower_bound=0.0)
        model[:StoLevel] = @variable(model, [p in P_storage, s in S, t in T], base_name="StoLevel", lower_bound=0.0)
    end

    # --- 4. Define Constraints ---
    Plant_initial_capacity_param = model[:Params][:Initial_Capacity_Plant]; Line_initial_capacity_param = model[:Params][:Initial_Capacity_Line]
    Plant_max_capacity_gen = merge(model[:Params][:Thermal_Max_Capacity], model[:Params][:Renewable_Max_Capacity])
    CapNew = model[:CapNew]; CapTotal = model[:CapTotal]; CapRetire = model[:CapRetire]
    TxCapNew = model[:TxCapNew]; TxCapTotal = model[:TxCapTotal]; TxCapRetire = model[:TxCapRetire]

    @constraint(model, GenPlantCapEvolution[p in P_all_generation, s in S], CapTotal[p,s] == (s > 1 ? CapTotal[p,s-1] : get(Plant_initial_capacity_param, p, 0.0)) + CapNew[p,s] - CapRetire[p,s])
    @constraint(model, GenPlantRetireLimit[p in P_all_generation, s in S], CapRetire[p,s] <= (s > 1 ? CapTotal[p,s-1] : get(Plant_initial_capacity_param, p, 0.0)))
    @constraint(model, GenPlantMaxCapacity[p in P_all_generation, s in S], CapTotal[p,s] <= get(Plant_max_capacity_gen, p, Inf))

    @constraint(model, LineCapEvolution[l in L_set, s in S], TxCapTotal[l,s] == (s > 1 ? TxCapTotal[l,s-1] : get(Line_initial_capacity_param, l, 0.0)) + TxCapNew[l,s] - TxCapRetire[l,s])
    @constraint(model, LineRetireLimit[l in L_set, s in S], TxCapRetire[l,s] <= (s > 1 ? TxCapTotal[l,s-1] : get(Line_initial_capacity_param, l, 0.0)))

    # Storage Capacity Evolution
    StoCapEnergyNew=model[:StoCapEnergyNew]; StoCapEnergyTotal=model[:StoCapEnergyTotal]; StoCapEnergyRetire=model[:StoCapEnergyRetire]
    StoCapChargeNew=model[:StoCapChargeNew]; StoCapChargeTotal=model[:StoCapChargeTotal]; StoCapChargeRetire=model[:StoCapChargeRetire]
    StoCapDischargeNew=model[:StoCapDischargeNew]; StoCapDischargeTotal=model[:StoCapDischargeTotal]; StoCapDischargeRetire=model[:StoCapDischargeRetire]
    Sto_InitialEnergyCap=model[:Params][:Sto_InitialEnergyCap]; Sto_InitialChargeCap=model[:Params][:Sto_InitialChargeCap]; Sto_InitialDischargeCap=model[:Params][:Sto_InitialDischargeCap]
    Sto_MaxEnergyCap=model[:Params][:Sto_MaxEnergyCap]; Sto_MaxChargeCap=model[:Params][:Sto_MaxChargeCap]; Sto_MaxDischargeCap=model[:Params][:Sto_MaxDischargeCap]

    @constraint(model, StoEnergyCapEvo[p in P_storage, s in S], StoCapEnergyTotal[p,s] == (s > 1 ? StoCapEnergyTotal[p,s-1] : Sto_InitialEnergyCap[p]) + StoCapEnergyNew[p,s] - StoCapEnergyRetire[p,s])
    @constraint(model, StoChargeCapEvo[p in P_storage, s in S], StoCapChargeTotal[p,s] == (s > 1 ? StoCapChargeTotal[p,s-1] : Sto_InitialChargeCap[p]) + StoCapChargeNew[p,s] - StoCapChargeRetire[p,s])
    @constraint(model, StoDischargeCapEvo[p in P_storage, s in S], StoCapDischargeTotal[p,s] == (s > 1 ? StoCapDischargeTotal[p,s-1] : Sto_InitialDischargeCap[p]) + StoCapDischargeNew[p,s] - StoCapDischargeRetire[p,s])

    @constraint(model, StoEnergyRetireLimit[p in P_storage, s in S], StoCapEnergyRetire[p,s] <= (s > 1 ? StoCapEnergyTotal[p,s-1] : Sto_InitialEnergyCap[p]))
    @constraint(model, StoChargeRetireLimit[p in P_storage, s in S], StoCapChargeRetire[p,s] <= (s > 1 ? StoCapChargeTotal[p,s-1] : Sto_InitialChargeCap[p]))
    @constraint(model, StoDischargeRetireLimit[p in P_storage, s in S], StoCapDischargeRetire[p,s] <= (s > 1 ? StoCapDischargeTotal[p,s-1] : Sto_InitialDischargeCap[p]))

    @constraint(model, StoEnergyMaxCap[p in P_storage, s in S], StoCapEnergyTotal[p,s] <= Sto_MaxEnergyCap[p])
    @constraint(model, StoChargeMaxCap[p in P_storage, s in S], StoCapChargeTotal[p,s] <= Sto_MaxChargeCap[p])
    @constraint(model, StoDischargeMaxCap[p in P_storage, s in S], StoCapDischargeTotal[p,s] <= Sto_MaxDischargeCap[p])

    if num_timesteps > 0
        Dispatch_thermal = model[:Dispatch_thermal]; Dispatch_renewable = model[:Dispatch_renewable]; Curtailment_renewable = model[:Curtailment_renewable]; Flow = model[:Flow]
        StoCharge = model[:StoCharge]; StoDischarge = model[:StoDischarge]; StoLevel = model[:StoLevel]
        RenAvailability = model[:Params][:RenewableAvailability]; Demand_param = model[:Params][:Demand]; Plant_ZoneID_param = model[:Params][:Plant_ZoneID]
        Line_From_Zone_param = model[:Params][:Line_From_Zone]; Line_To_Zone_param = model[:Params][:Line_To_Zone]
        Sto_ZoneID = model[:Params][:Plant_ZoneID] # Re-using Plant_ZoneID which now includes storage
        Sto_ChargeEff = model[:Params][:Sto_ChargeEff]; Sto_DischargeEff = model[:Params][:Sto_DischargeEff]
        Sto_MinSOC_frac = model[:Params][:Sto_MinSOC_frac]; Sto_MaxSOC_frac = model[:Params][:Sto_MaxSOC_frac]

        @constraint(model, ThermalDispatchLimit[p in P_thermal, s in S, t in T], Dispatch_thermal[p,s,t] <= CapTotal[p,s])
        @constraint(model, RenewableDispatchBalance[p in P_renewable, s in S, t in T], Dispatch_renewable[p,s,t] + Curtailment_renewable[p,s,t] == CapTotal[p,s] * RenAvailability[(p,s,t)])

        # Storage Operational Constraints
        @constraint(model, StoChargeLimit[p in P_storage, s in S, t in T], StoCharge[p,s,t] <= StoCapChargeTotal[p,s])
        @constraint(model, StoDischargeLimit[p in P_storage, s in S, t in T], StoDischarge[p,s,t] <= StoCapDischargeTotal[p,s])
        @constraint(model, StoLevelMin[p in P_storage, s in S, t in T], StoLevel[p,s,t] >= StoCapEnergyTotal[p,s] * Sto_MinSOC_frac[p])
        @constraint(model, StoLevelMax[p in P_storage, s in S, t in T], StoLevel[p,s,t] <= StoCapEnergyTotal[p,s] * Sto_MaxSOC_frac[p])

        @constraint(model, StoBalance[p in P_storage, s in S, t in T],
            StoLevel[p,t,s] == (t > 1 ? StoLevel[p,t-1,s] : StoLevel[p,num_timesteps,s]) + # Cyclic over T
                               StoCharge[p,s,t] * Sto_ChargeEff[p] -
                               StoDischarge[p,s,t] / Sto_DischargeEff[p])

        @constraint(model, TxFlowUpper[l in L_set, s in S, t in T], Flow[l,s,t] <= TxCapTotal[l,s])
        @constraint(model, TxFlowLower[l in L_set, s in S, t in T], Flow[l,s,t] >= -TxCapTotal[l,s])

        @constraint(model, NodalBalance[z_id in Z, s in S, t in T],
            sum(Dispatch_thermal[p,s,t] for p in P_thermal if get(Plant_ZoneID_param,p,-1)==z_id) +
            sum(Dispatch_renewable[p,s,t] for p in P_renewable if get(Plant_ZoneID_param,p,-1)==z_id) +
            sum(StoDischarge[p,s,t] for p in P_storage if get(Sto_ZoneID,p,-1)==z_id) - # Discharging adds to supply
            sum(StoCharge[p,s,t] for p in P_storage if get(Sto_ZoneID,p,-1)==z_id) +    # Charging adds to demand
            sum(Flow[l,s,t] for l in L_set if get(Line_To_Zone_param,l,-1)==z_id) -
            sum(Flow[l,s,t] for l in L_set if get(Line_From_Zone_param,l,-1)==z_id)
            == Demand_param[(z_id,s,t)]
        )
    end

    # --- 5. Define Objective Function ---
    DiscountRate = model[:Params][:DiscountRate]; YearsPerStage = model[:Params][:YearsPerStage]
    Plant_Inv_Cost_Gen = merge(model[:Params][:Thermal_Inv_Cost], model[:Params][:Renewable_Inv_Cost])
    Line_Inv_Cost = model[:Params][:Line_Inv_Cost]
    Thermal_VarOM_Cost = model[:Params][:Thermal_VarOM_Cost]; Thermal_FuelCost_MWh = model[:Params][:Thermal_FuelCost_per_MWh]
    Renewable_VarOM_Cost = model[:Params][:Renewable_VarOM_Cost]
    Sto_InvCost_Energy = model[:Params][:Sto_InvCost_Energy]; Sto_InvCost_Power = model[:Params][:Sto_InvCost_Power]
    Sto_VarOM_Charge = model[:Params][:Sto_VarOM_Charge]; Sto_VarOM_Discharge = model[:Params][:Sto_VarOM_Discharge]

    df_invest = Dict(s_idx => (1 / (1 + DiscountRate))^((s_idx - 1) * YearsPerStage) for s_idx in S)
    pvf_annual_op = Dict(s_idx => sum((1 / (1 + DiscountRate))^(yr - 1) for yr in 1:YearsPerStage) for s_idx in S)

    TotalGenPlantInvCost = @expression(model, sum(Plant_Inv_Cost_Gen[p] * model[:CapNew][p,s] * df_invest[s] for p in P_all_generation, s in S))
    TotalTxInvCost = @expression(model, sum(Line_Inv_Cost[l] * model[:TxCapNew][l,s] * df_invest[s] for l in L_set, s in S))
    TotalStoInvCost = @expression(model, sum( (Sto_InvCost_Energy[p] * model[:StoCapEnergyNew][p,s] +
                                             Sto_InvCost_Power[p] * model[:StoCapChargeNew][p,s] + # Assuming cost applies to charge cap
                                             Sto_InvCost_Power[p] * model[:StoCapDischargeNew][p,s] # And separately to discharge cap if they can differ
                                            ) * df_invest[s] for p in P_storage, s in S ))
    TotalInvestmentCost = @expression(model, TotalGenPlantInvCost + TotalTxInvCost + TotalStoInvCost)

    TotalOperationalCost = AffExpr(0.0)
    if num_timesteps > 0
        HoursPerTimeStep = 1; ScalingFactor8760 = 8760.0 / num_timesteps
        DiscountedThermalOpCost = @expression(model, sum( df_invest[s] * pvf_annual_op[s] * sum( (Thermal_VarOM_Cost[p] + Thermal_FuelCost_MWh[p]) * model[:Dispatch_thermal][p,s,t] * HoursPerTimeStep * ScalingFactor8760 for p in P_thermal, t in T) for s in S))
        DiscountedRenewableOpCost = @expression(model, sum( df_invest[s] * pvf_annual_op[s] * sum( Renewable_VarOM_Cost[p] * model[:Dispatch_renewable][p,s,t] * HoursPerTimeStep * ScalingFactor8760 for p in P_renewable, t in T) for s in S))
        DiscountedStorageOpCost = @expression(model, sum( df_invest[s] * pvf_annual_op[s] * sum( (Sto_VarOM_Charge[p] * model[:StoCharge][p,s,t] + Sto_VarOM_Discharge[p] * model[:StoDischarge][p,s,t]) * HoursPerTimeStep * ScalingFactor8760 for p in P_storage, t in T) for s in S))
        TotalOperationalCost = @expression(model, DiscountedThermalOpCost + DiscountedRenewableOpCost + DiscountedStorageOpCost)
    end

    @objective(model, Min, TotalInvestmentCost + TotalOperationalCost)
    @info "Objective function defined."
    @info "Model build complete."
    return model
end
