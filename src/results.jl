using JuMP
using JuMP.MOI # For termination_status codes
using Printf # For formatted printing

export print_results

# Helper function to safely get variable value
function get_var_value(var_ref, default_val="N/A")
    try
        val = value(var_ref)
        return round(val, digits=2)
    catch e
        # Check if the error is because the variable is not in the solved model (e.g., infeasible)
        # or if the variable itself is the issue.
        # A more specific check might be needed if JuMP provides more detailed error types here.
        # For now, any error in value() call results in default_val.
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

    # Check if a primal solution exists (might not if infeasible, etc.)
    has_solution = primal_status(model) == MOI.FEASIBLE_POINT ||
                   primal_status(model) == MOI.NEARLY_FEASIBLE_POINT ||
                   (status == MOI.OPTIMAL || status == MOI.LOCALLY_SOLVED ||
                    status == MOI.ALMOST_OPTIMAL || status == MOI.ALMOST_LOCALLY_SOLVED)


    if has_objective(model) && has_solution
        @printf "%-25s %.2f\n" "Objective Value:" objective_value(model)
    else
        println("Objective Value: Not available or model not solved to optimality.")
    end
    println("-"^60)

    if !has_solution
        println("No primal solution available to display variable values.")
        println("="^60)
        return
    end

    # Attempt to reconstruct sets from variable keys if not explicitly stored in model object
    # This is a common pattern if sets aren't passed around manually.
    # Note: This assumes variables were defined and stored in the model object with these keys.

    S_keys = Set{Int}()
    P_all_keys = Set{String}()
    L_keys = Set{String}()
    P_thermal_keys = Set{String}()
    P_renewable_keys = Set{String}()
    T_keys = Set{Int}() # For time-dependent variables

    if isdefined(model, :CapNew) && !isempty(model[:CapNew])
        for k in keys(model[:CapNew].data); push!(P_all_keys, k[1]); push!(S_keys, k[2]); end
    end
    if isdefined(model, :TxCapNew) && !isempty(model[:TxCapNew])
        for k in keys(model[:TxCapNew].data); push!(L_keys, k[1]); union!(S_keys, Set([k[2]])); end # S_keys could also get from here
    end
    if isdefined(model, :Dispatch_thermal) && !isempty(model[:Dispatch_thermal])
        for k in keys(model[:Dispatch_thermal].data); push!(P_thermal_keys, k[1]); union!(S_keys, Set([k[2]])); push!(T_keys, k[3]); end
    end
    if isdefined(model, :Dispatch_renewable) && !isempty(model[:Dispatch_renewable])
        for k in keys(model[:Dispatch_renewable].data); push!(P_renewable_keys, k[1]); union!(S_keys, Set([k[2]])); union!(T_keys, Set([k[3]])); end
    end

    # Convert sets to sorted vectors for ordered printing
    S = sort(collect(S_keys))
    P_all = sort(collect(P_all_keys))
    L = sort(collect(L_keys))
    P_thermal = sort(collect(P_thermal_keys))
    P_renewable = sort(collect(P_renewable_keys))
    T_set = sort(collect(T_keys)) # Using T_set to avoid conflict if T was a global constant
    num_timesteps = length(T_set)


    println("\n--- Plant Capacities ---")
    if isdefined(model, :CapNew) && isdefined(model, :CapTotal) && isdefined(model, :CapRetire)
        for s in S
            println("  Stage: $s")
            @printf "    %-20s %10s %10s %10s\n" "Plant" "CapNew" "CapTotal" "CapRetire"
            for p in P_all
                cap_new_val = get_var_value(model[:CapNew][p,s])
                cap_total_val = get_var_value(model[:CapTotal][p,s])
                cap_retire_val = get_var_value(model[:CapRetire][p,s])
                if cap_new_val != 0.0 || cap_total_val != 0.0 || cap_retire_val != 0.0 || cap_new_val == "N/A" # Print if any value is non-zero or N/A
                    @printf "    %-20s %10s %10s %10s\n" p cap_new_val cap_total_val cap_retire_val
                end
            end
        end
    else; println("  Plant capacity variables not defined in model."); end

    println("\n--- Transmission Capacities ---")
    if isdefined(model, :TxCapNew) && isdefined(model, :TxCapTotal) && isdefined(model, :TxCapRetire) && !isempty(L)
        for s in S
            println("  Stage: $s")
            @printf "    %-15s %10s %10s %10s\n" "Line" "TxCapNew" "TxCapTotal" "TxCapRetire"
            for l_id in L # Using L (reconstructed from TxCapNew keys)
                tx_cap_new_val = get_var_value(model[:TxCapNew][l_id,s])
                tx_cap_total_val = get_var_value(model[:TxCapTotal][l_id,s])
                tx_cap_retire_val = get_var_value(model[:TxCapRetire][l_id,s])
                 if tx_cap_new_val != 0.0 || tx_cap_total_val != 0.0 || tx_cap_retire_val != 0.0 || tx_cap_new_val == "N/A"
                    @printf "    %-15s %10s %10s %10s\n" l_id tx_cap_new_val tx_cap_total_val tx_cap_retire_val
                end
            end
        end
    else; println("  Transmission capacity variables not defined or no lines in the model."); end

    if num_timesteps > 0
        println("\n--- Dispatch Summary (Thermal) ---")
        if isdefined(model, :Dispatch_thermal) && !isempty(P_thermal)
            for s in S
                println("  Stage: $s")
                @printf "    %-20s %15s %15s\n" "Plant" "Avg Dispatch" "Total Dispatch"
                for p in P_thermal
                    total_dispatch = sum(get_var_value(model[:Dispatch_thermal][p,s,t], 0.0) for t in T_set)
                    avg_dispatch = total_dispatch / num_timesteps
                    if total_dispatch != 0.0 || avg_dispatch == "N/A"
                         @printf "    %-20s %15.2f %15.2f\n" p avg_dispatch total_dispatch
                    end
                end
            end
        else; println("  Thermal dispatch variables not defined or no thermal plants."); end

        println("\n--- Dispatch Summary (Renewable) ---")
        if isdefined(model, :Dispatch_renewable) && isdefined(model, :Curtailment_renewable) && !isempty(P_renewable)
            for s in S
                println("  Stage: $s")
                @printf "    %-20s %15s %15s\n" "Plant" "Avg Dispatch" "Avg Curtailment"
                for p in P_renewable
                    total_dispatch = sum(get_var_value(model[:Dispatch_renewable][p,s,t], 0.0) for t in T_set)
                    avg_dispatch = total_dispatch / num_timesteps
                    total_curtailment = sum(get_var_value(model[:Curtailment_renewable][p,s,t], 0.0) for t in T_set)
                    avg_curtailment = total_curtailment / num_timesteps
                    if total_dispatch != 0.0 || total_curtailment != 0.0 || avg_dispatch == "N/A"
                        @printf "    %-20s %15.2f %15.2f\n" p avg_dispatch avg_curtailment
                    end
                end
            end
        else; println("  Renewable dispatch/curtailment variables not defined or no renewable plants."); end

        println("\n--- Transmission Flow Summary ---")
        if isdefined(model, :Flow) && !isempty(L)
            for s in S
                println("  Stage: $s")
                @printf "    %-15s %15s\n" "Line" "Avg Flow (MW)"
                for l_id in L
                    avg_flow = sum(get_var_value(model[:Flow][l_id,s,t], 0.0) for t in T_set) / num_timesteps
                     if avg_flow != 0.0 || avg_flow == "N/A"
                        @printf "    %-15s %15.2f\n" l_id avg_flow
                    end
                end
            end
        else; println("  Transmission flow variables not defined or no lines in the model."); end
    else
        println("\n--- Time-dependent results (Dispatch, Flow) omitted as num_timesteps is 0 ---")
    end

    println("="^60)
end
