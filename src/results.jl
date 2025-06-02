using JuMP
using JuMP.MOI # For termination_status codes
using Printf # For formatted printing

export print_results

# Helper function to safely get variable value
function get_var_value(var_ref, default_val="N/A"; digits=2)
    try
        val = value(var_ref)
        # Handle cases where value might be NaN or Inf before rounding
        if isnan(val) || isinf(val)
            return string(val)
        end
        return round(val, digits=digits)
    catch e
        return default_val
    end
end


"""
    print_results(model::JuMP.Model)

Prints detailed results from the solved JuMP model.
"""
function print_results(model::JuMP.Model)
    status = termination_status(model)
    println("\n" * "="^60)
    println("MODEL RESULTS")
    println("="^60)
    @printf "%-25s %s\n" "Termination Status:" status

    has_solution = primal_status(model) == MOI.FEASIBLE_POINT ||
                   primal_status(model) == MOI.NEARLY_FEASIBLE_POINT ||
                   (status == MOI.OPTIMAL || status == MOI.LOCALLY_SOLVED ||
                    status == MOI.ALMOST_OPTIMAL || status == MOI.ALMOST_LOCALLY_SOLVED)

    if has_objective(model) && has_solution
        @printf "%-25s %.2f\n" "Objective Value:" objective_value(model)
    else
        println("Objective Value: Not available or model not solved to optimality/feasibility.")
    end
    println("-"^60)

    if !has_solution
        println("No primal solution available to display variable values.")
        if status == MOI.INFEASIBLE_OR_UNBOUNDED || status == MOI.INFEASIBLE || status == MOI.DUAL_INFEASIBLE
             println("Model was Infeasible or Unbounded. Consider checking constraints or solver logs.")
        end
        println("="^60)
        return
    end

    S_keys = Set{Int}(); P_all_gen_keys = Set{String}(); L_keys = Set{String}()
    P_thermal_keys = Set{String}(); P_renewable_keys = Set{String}(); P_storage_keys = Set{String}()
    T_keys = Set{Int}()

    # Reconstruct sets from generation plant variables
    if isdefined(model, :CapNew) && !isempty(model[:CapNew]); for k in keys(model[:CapNew].data); push!(P_all_gen_keys, k[1]); push!(S_keys, k[2]); end; end
    if isdefined(model, :TxCapNew) && !isempty(model[:TxCapNew]); for k in keys(model[:TxCapNew].data); push!(L_keys, k[1]); union!(S_keys, Set([k[2]])); end; end
    if isdefined(model, :Dispatch_thermal) && !isempty(model[:Dispatch_thermal]); for k in keys(model[:Dispatch_thermal].data); push!(P_thermal_keys, k[1]); union!(S_keys, Set([k[2]])); push!(T_keys, k[3]); end; end
    if isdefined(model, :Dispatch_renewable) && !isempty(model[:Dispatch_renewable]); for k in keys(model[:Dispatch_renewable].data); push!(P_renewable_keys, k[1]); union!(S_keys, Set([k[2]])); union!(T_keys, Set([k[3]])); end; end

    # Reconstruct P_storage from its capacity or operational variables
    if isdefined(model, :StoCapEnergyTotal) && !isempty(model[:StoCapEnergyTotal]); for k in keys(model[:StoCapEnergyTotal].data); push!(P_storage_keys, k[1]); union!(S_keys, Set([k[2]])); end;
    elseif isdefined(model, :StoCharge) && !isempty(model[:StoCharge]); for k in keys(model[:StoCharge].data); push!(P_storage_keys, k[1]); union!(S_keys, Set([k[2]])); union!(T_keys, Set([k[3]])); end;end

    S = sort(collect(S_keys)); P_all_generation = sort(collect(P_all_gen_keys)); L = sort(collect(L_keys))
    P_thermal = sort(collect(P_thermal_keys)); P_renewable = sort(collect(P_renewable_keys)); P_storage = sort(collect(P_storage_keys))
    T_set = sort(collect(T_keys)); num_timesteps = length(T_set)

    println("\n--- Generation Plant Capacities ---")
    if isdefined(model, :CapNew) && isdefined(model, :CapTotal) && isdefined(model, :CapRetire) && !isempty(P_all_generation)
        for s in S; println("  Stage: $s"); @printf "    %-20s %10s %10s %10s\n" "Plant" "CapNew" "CapTotal" "CapRetire"
            for p in P_all_generation; cap_new=get_var_value(model[:CapNew][p,s]); cap_total=get_var_value(model[:CapTotal][p,s]); cap_retire=get_var_value(model[:CapRetire][p,s])
                if cap_new != 0.0 || cap_total != 0.0 || cap_retire != 0.0 || cap_new=="N/A"; @printf "    %-20s %10s %10s %10s\n" p cap_new cap_total cap_retire; end
            end; end
    else; println("  Generation plant capacity variables not defined or no generation plants."); end

    println("\n--- Transmission Capacities ---")
    if isdefined(model, :TxCapNew) && isdefined(model, :TxCapTotal) && isdefined(model, :TxCapRetire) && !isempty(L)
        for s in S; println("  Stage: $s"); @printf "    %-15s %10s %10s %10s\n" "Line" "TxCapNew" "TxCapTotal" "TxCapRetire"
            for l_id in L; tx_new=get_var_value(model[:TxCapNew][l_id,s]); tx_total=get_var_value(model[:TxCapTotal][l_id,s]); tx_retire=get_var_value(model[:TxCapRetire][l_id,s])
                if tx_new != 0.0 || tx_total != 0.0 || tx_retire != 0.0 || tx_new=="N/A"; @printf "    %-15s %10s %10s %10s\n" l_id tx_new tx_total tx_retire; end
            end; end
    else; println("  Transmission capacity variables not defined or no lines."); end

    println("\n--- Storage Capacities ---")
    if !isempty(P_storage) && isdefined(model, :StoCapEnergyNew) # Check one set of vars
        for s in S; println("  Stage: $s");
            @printf "    %-20s %10s %10s %10s %10s %10s %10s %10s %10s %10s\n" "Storage" "EngNew" "EngTot" "EngRet" "ChgNew" "ChgTot" "ChgRet" "DchNew" "DchTot" "DchRet"
            for p in P_storage
                vals = [
                    get_var_value(model[:StoCapEnergyNew][p,s]), get_var_value(model[:StoCapEnergyTotal][p,s]), get_var_value(model[:StoCapEnergyRetire][p,s]),
                    get_var_value(model[:StoCapChargeNew][p,s]), get_var_value(model[:StoCapChargeTotal][p,s]), get_var_value(model[:StoCapChargeRetire][p,s]),
                    get_var_value(model[:StoCapDischargeNew][p,s]), get_var_value(model[:StoCapDischargeTotal][p,s]), get_var_value(model[:StoCapDischargeRetire][p,s])
                ]
                if any(x -> (x isa Number && x != 0.0) || x == "N/A", vals)
                    @printf "    %-20s %10s %10s %10s %10s %10s %10s %10s %10s %10s\n" p vals...
                end
            end; end
    else; println("  Storage capacity variables not defined or no storage units."); end

    if num_timesteps > 0
        println("\n--- Dispatch Summary (Thermal) ---"); if isdefined(model, :Dispatch_thermal) && !isempty(P_thermal)
            for s in S; println("  Stage: $s"); @printf "    %-20s %15s %15s\n" "Plant" "Avg Dispatch" "Total Dispatch"
                for p in P_thermal; total_dispatch=sum(get_var_value(model[:Dispatch_thermal][p,s,t],0.0) for t in T_set); avg_dispatch=total_dispatch/num_timesteps; if total_dispatch!=0.0||avg_dispatch=="N/A"; @printf "    %-20s %15.2f %15.2f\n" p avg_dispatch total_dispatch; end; end; end
        else; println("  Thermal dispatch variables not defined or no thermal plants."); end

        println("\n--- Dispatch Summary (Renewable) ---"); if isdefined(model, :Dispatch_renewable) && !isempty(P_renewable)
            for s in S; println("  Stage: $s"); @printf "    %-20s %15s %15s\n" "Plant" "Avg Dispatch" "Avg Curtailment"
                for p in P_renewable; total_disp=sum(get_var_value(model[:Dispatch_renewable][p,s,t],0.0) for t in T_set); avg_disp=total_disp/num_timesteps; total_curt=sum(get_var_value(model[:Curtailment_renewable][p,s,t],0.0) for t in T_set); avg_curt=total_curt/num_timesteps; if total_disp!=0.0||total_curt!=0.0||avg_disp=="N/A"; @printf "    %-20s %15.2f %15.2f\n" p avg_disp avg_curt; end; end; end
        else; println("  Renewable dispatch/curtailment variables not defined or no renewable plants."); end

        println("\n--- Storage Operations Summary ---"); if !isempty(P_storage) && isdefined(model, :StoCharge)
            for s in S; println("  Stage: $s"); @printf "    %-20s %15s %15s %15s\n" "Storage" "Avg Charge" "Avg Discharge" "Avg Level"
                for p in P_storage; total_charge=sum(get_var_value(model[:StoCharge][p,s,t],0.0) for t in T_set); avg_charge=total_charge/num_timesteps; total_discharge=sum(get_var_value(model[:StoDischarge][p,s,t],0.0) for t in T_set); avg_discharge=total_discharge/num_timesteps; total_level=sum(get_var_value(model[:StoLevel][p,s,t],0.0) for t in T_set); avg_level=total_level/num_timesteps; if total_charge!=0.0||total_discharge!=0.0||total_level!=0.0||avg_charge=="N/A"; @printf "    %-20s %15.2f %15.2f %15.2f\n" p avg_charge avg_discharge avg_level; end; end; end
        else; println("  Storage operational variables not defined or no storage units."); end

        println("\n--- Transmission Flow Summary ---"); if isdefined(model, :Flow) && !isempty(L)
            for s in S; println("  Stage: $s"); @printf "    %-15s %15s\n" "Line" "Avg Flow (MW)"
                for l_id in L; avg_flow=sum(get_var_value(model[:Flow][l_id,s,t],0.0) for t in T_set)/num_timesteps; if avg_flow!=0.0||avg_flow=="N/A"; @printf "    %-15s %15.2f\n" l_id avg_flow; end; end; end
        else; println("  Transmission flow variables not defined or no lines."); end
    else
        println("\n--- Time-dependent results (Dispatch, Flow, Storage Ops) omitted as num_timesteps is 0 ---")
    end

    println("="^60)
end
