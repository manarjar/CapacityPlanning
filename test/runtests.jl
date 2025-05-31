using Test
# Add src to load path to find modules, or use relative paths if project is structured as a package
# For now, assuming runtests.jl is in test/ and modules are in src/
include("../src/types.jl")
include("../src/io.jl")

@testset "IO Tests" begin
    @testset "read_thermal_plants" begin
        # Create a temporary valid CSV for testing
        # Ensure this matches the updated column name investment_cost_usd_per_mw_year
        temp_csv_content = "name,capacity_mw,min_stable_level_mw,ramp_up_mw_per_hr,ramp_down_mw_per_hr,startup_cost_usd,shutdown_cost_usd,variable_om_cost_usd_per_mwh,fuel_cost_usd_per_mmbtu,heat_rate_mmbtu_per_mwh,investment_cost_usd_per_mw_year\nPlantA,100,20,50,50,1000,500,2,3,10,90000" # Value updated to per-MW
        temp_csv_path = "test_thermal.csv" # Will be created in the 'test' directory
        open(temp_csv_path, "w") do f
            write(f, temp_csv_content)
        end

        plants = read_thermal_plants(temp_csv_path)
        @test length(plants) == 1
        @test plants[1].name == "PlantA"
        @test plants[1].capacity_mw == 100.0
        @test plants[1].min_stable_level_mw == 20.0
        @test plants[1].investment_cost_usd_per_mw_year == 90000.0 # Assertion value updated

        # Test for non-existent file
        # We expect an error message and an empty vector
        @test isempty(read_thermal_plants("non_existent_file.csv"))

        # Clean up temporary file
        rm(temp_csv_path)
    end
end
println("Tests completed.")
