--Sort all fluid into categories. Fluids are ignored, Sluids get converted to items, mush stays fluid but also gets an item version.
--[[==examples of fluid only:
        steam and other fluidbox filtered generator fluids
        heat(omnienergy)]]
--[[examples of mush:
        mining fluids (sulfuric acid etc...)
        fluids with fuel value
        fluids with temperature requirements]]
local fluid_cats = {fluid = {}, sluid = {}, mush = {}}
local generator_fluid = {} --is used in a generator
--build a list of recipes to modify after the sluids list is generated
local recipe_mods = {}


local function sort_fluid(fluidname, category, temperature)
    local fluid = data.raw.fluid[fluidname]
    if temperature and not next(temperature) then temperature = nil end
    --Fluid doesnt exist in this category or as mush yet
    if fluid and not fluid_cats[category][fluid.name] and not fluid_cats["mush"][fluid.name] then
        --Check for a combination of fluid / sluid. If both is required, add it as mush and remove it from sluids/fluids
        if category == "fluid" and fluid_cats["sluid"][fluid.name] then
            category = "mush"
            --Pick up the already known temperature table
            temperature = omni.lib.union(fluid_cats["sluid"][fluid.name].temperatures, temperature or {temp = "none"})
            fluid_cats["sluid"][fluid.name] = nil
        elseif category == "sluid" and fluid_cats["fluid"][fluid.name] then
            category = "mush"
            temperature = omni.lib.union(fluid_cats["fluid"][fluid.name].temperatures, temperature or {temp = "none"})
            fluid_cats["fluid"][fluid.name] = nil
        end

        fluid_cats[category][fluid.name] = table.deepcopy(fluid)
        fluid_cats[category][fluid.name].temperatures = {temperature or {temp = "none"}}
    --Fluid already exists: Update temperatures table if a temperature is specified. Check if "none" is already in the table if no temp is specified
    elseif fluid then
        --Check if it already exists as mush and repoint category to that
        if category ~= "mush" and fluid_cats["mush"][fluid.name] then category = "mush" end
        table.insert(fluid_cats[category][fluid.name].temperatures, temperature or {temp = "none"})
    else
        log(serpent.block(temperature))
        log("Fail")
    end
end


------------------------------
-----Analyse all entities-----
------------------------------
--generators
for _, gen in pairs(data.raw.generator) do
    --Check exclusion table
    if not omni.fluid.check_string_excluded(gen.name) then
        --Ignore fluid burning gens, looking for things that must stay fluid like steam and save their required temperature in case of getting mush
        if not gen.burns_fluid and gen.fluid_box and gen.fluid_box.filter then
            sort_fluid(gen.fluid_box.filter, "fluid")
            generator_fluid[gen.fluid_box.filter] = true --set the fluid up as a known filter
            --log("Added "..gen.fluid_box.filter.." as fluid. Generator: "..gen.name)
        end
    end
end

--fluid throwing type turrets
for _, turr in pairs(data.raw["fluid-turret"]) do
    if turr.attack_parameters.fluids then
        for _, flu in pairs(turr.attack_parameters.fluids) do
            sort_fluid(flu.type, "fluid")
            --log("Added "..flu.type.." as fluid. Generator: "..turr.name)
        end
    end
end

--mining fluid detection
for _,res in pairs(data.raw.resource) do
    if res.minable and res.minable.required_fluid then
        sort_fluid(res.minable.required_fluid, "fluid")
        --log("Added "..res.minable.required_fluid.." as fluid. Generator: "..res.name)
    end
end

--recipes
for _, rec in pairs(data.raw.recipe) do
    if not omni.fluid.check_string_excluded(rec.name) and not omni.lib.recipe_is_hidden(rec.name) then
        local fluids = {}
        for _, ingres in pairs({"ingredients","results"}) do --ignore result/ingredient as they don't handle fluids
            if rec[ingres] then
                for _, it in pairs(rec[ingres]) do
                    if it and it.type and it.type == "fluid" then
                        fluids[#fluids+1] = it
                        recipe_mods[rec.name] = recipe_mods[rec.name] or {ingredients = {}, results = {}}
                    end
                end
            elseif (rec.normal and rec.normal[ingres]) or (rec.expensive and rec.expensive[ingres]) then
                for _, diff in pairs({"normal","expensive"}) do
                    for _, it in pairs(rec[diff][ingres]) do
                        if it and it.type and it.type == "fluid" then
                            fluids[#fluids+1] = it
                            recipe_mods[rec.name] = recipe_mods[rec.name] or {ingredients = {}, results = {}}
                        end
                    end
                end
            end
        end
        for _, fluid in pairs(fluids) do
            sort_fluid(fluid.name, "sluid", {temp = fluid.temperature, temp_min = fluid.default_temperature, temp_max = fluid.max_temperature})
        end
    end
end

---------------------------------
-----Sort temperatures-----
---------------------------------
--Should check if we can properly build this table so we dont need to clean it up
for _,cat in pairs(fluid_cats) do
    for _,fluid in pairs(cat) do
        local new_temps = {}
    
        --First loop: Get all entries that have .temperature or nothing (just one) set
        for i=#(fluid.temperatures),1,-1 do
            --log(serpent.block(fluid.temperatures[i]))
            if fluid.temperatures[i].temp and not omni.lib.is_in_table(fluid.temperatures[i].temp, new_temps) then
                new_temps[#new_temps+1] = fluid.temperatures[i].temp
            end
            fluid.temperatures[i] = nil
        end

        --Second Loop: Go through the leftovers which have min/max set and check if theres an entry already in its range
        for _,temps in pairs(fluid.temperatures) do
            local found = false
            for new in pairs(new_temps)do
                if temps.temp_min and new >= temps.temp_min and temps.temp_max and new <= temps.temp_max then
                    found = true
                    break
                end
            end
            if found == true then
                temps = nil
            end
        end
        for i=#(fluid.temperatures),1,-1 do
            local found = false
            for new in pairs(new_temps)do
                if fluid.temperatures[i].temp_min and new >= fluid.temperatures[i].temp_min and fluid.temperatures[i].temp_max and new <= fluid.temperatures[i].temp_max then
                    found = true
                    break
                end
            end
            if found == true then
                fluid.temperatures[i] = nil
            end
        end
        --Check if the table is empty --> Everything should be sorted out properly
        if next(fluid.temperatures) then
            log("This should be empty")
            log(serpent.block(fluid.temperatures))
        end
        fluid.temperatures = new_temps
    end
end


------------------------
-----Process fluids-----
------------------------
local ent = {}
--create subgroup
ent[#ent+1] = {
    type = "item-subgroup",
    name = "omni-solid-fluids",
    group = "intermediate-products",
    order = "aa",
}

--log(serpent.block(fluid_cats))
for catname, cat in pairs(fluid_cats) do
    for _, fluid in pairs(cat) do
        --sluid or mush: create items and replace recipe ings/res
        if catname ~= "fluid" --[[or catname == "mush"]] then
            for _,temp in pairs(fluid.temperatures) do
                if temp == "none" then
                    ent[#ent+1] = {
                        type = "item",
                        name = "solid-"..fluid.name,
                        localised_name = {"item-name.solid-fluid", fluid.name.localised_name or {"fluid-name."..fluid.name}},
                        localised_description = {"item-description.solid-fluid", fluid.localised_description or {"fluid-description."..fluid.name}},
                        icons = omni.lib.icon.of_generic(fluid),
                        subgroup = "omni-solid-fluids",
                        order = fluid.order or "a",
                        stack_size = omni.fluid.sluid_stack_size,
                    }
                    --log("Created solid-"..fluid.name)
                else
                    ent[#ent+1] = {
                        type = "item",
                        name = "solid-"..fluid.name.."-T-"..temp,
                        localised_name = {"item-name.solid-fluid-tmp", fluid.name.localised_name or {"fluid-name."..fluid.name},"T="..temp},
                        localised_description = {"item-description.solid-fluid", fluid.localised_description or {"fluid-description."..fluid.name}},
                        icons = omni.lib.icon.of_generic(fluid),
                        subgroup = "omni-solid-fluids",
                        order = fluid.order or "a",
                        stack_size = omni.fluid.sluid_stack_size,
                    }
                    --log("Created solid-"..fluid.name.."-T-"..temp)
                end
            end
        end
        --Sluid only: hide unused fluid
        if catname == "sluid" then
            fluid.hidden = true
            fluid.auto_barrel = false
        end
        --Mush only: create conversion recipe

    end
end
data:extend(ent)


----------------------------------------
-----Sluid Boiler recioe generation-----
----------------------------------------
local new_boiler = {}
local fix_boilers_recipe = {}
local fix_boilers_item = {}
local ing_replace={}
local boiler_tech = {}

for _, boiler in pairs(data.raw.boiler) do
    --PREPARE DATA FOR MANIPULATION
    local water = boiler.fluid_box.filter or "water"
    local water_cap = omni.lib.get_fuel_number(data.raw.fluid[water].heat_capacity)/1000000     --omni.fluid.convert_mj(data.raw.fluid[water].heat_capacity)
    local water_delta_tmp = data.raw.fluid[water].max_temperature - data.raw.fluid[water].default_temperature
    local steam = boiler.output_fluid_box.filter or "steam"
    local steam_cap = omni.lib.get_fuel_number(data.raw.fluid[steam].heat_capacity)/1000000  --omni.fluid.convert_mj(data.raw.fluid[steam].heat_capacity)
    local steam_delta_tmp = boiler.target_temperature - data.raw.fluid[water].max_temperature
    local prod_steam = omni.fluid.round_fluid(omni.lib.round(omni.lib.get_fuel_number(boiler.energy_consumption)/1000000 / (water_delta_tmp * water_cap + steam_delta_tmp * steam_cap)),1)
    local lcm = omni.lib.lcm(prod_steam, omni.fluid.sluid_contain_fluid)
    local prod = lcm / omni.fluid.sluid_contain_fluid
    local tid = lcm / prod_steam

    --clobber fluid_box_filter if it exists
    if generator_fluid[boiler.output_fluid_box.filter] then
        generator_fluid[boiler.output_fluid_box.filter] = nil
    end

    --if exists, find recipe, item and entity
    if not omni.fluid.forbidden_boilers[boiler.name] and boiler.minable then
        local rec = omni.lib.find_recipe(boiler.minable.result)

        new_boiler[#new_boiler+1] = {
            type = "recipe-category",
            name = "boiler-omnifluid-"..boiler.name,
        }

        --add boiler to recipe list and fix minable-result list
        fix_boilers_recipe[#fix_boilers_recipe+1] = rec.name
        fix_boilers_item[boiler.minable.result] = true

        --set-up result and main product values to be the new converter
        omni.lib.replace_recipe_result(rec.name, boiler.name, boiler.name.."-converter")

        --add boiling recipe to new listing
        new_boiler[#new_boiler+1] = {
            type = "recipe",
            name = boiler.name.."-boiling-steam-"..boiler.target_temperature,
            icons = {{icon = "__base__/graphics/icons/fluid/steam.png", icon_size = 64, icon_mipmaps = 4}},
            subgroup = "fluid-recipes",
            category = "boiler-omnifluid-"..boiler.name,
            order = "g[hydromnic-acid]",
            energy_required = tid,
            enabled = true,
            hide_from_player_crafting = true,
            main_product = steam,
            ingredients = {{type = "item", name = "solid-"..water, amount = prod},},
            results = {{type = "fluid", name = steam, amount = omni.fluid.sluid_contain_fluid*prod, temperature = math.min(boiler.target_temperature, data.raw.fluid[steam].max_temperature)},},
        }
        --log(serpent.block(fluid_cats.mush))
        for _, fugacity in pairs(fluid_cats.mush) do
            --deal with non-water mush fluids, allow temperature and specific boiler systems
            --if #fugacity.temperature >= 1 then --not sure if i want to add another level of analysis to split them into temperature specific ranges which may make modded hard, or leave it as is.
            for _, temp in pairs(fugacity.temperatures) do
                --deal with each instance
                if temp ~= "none"  and boiler.target_temperature >= temp then
                    if data.raw.item["solid-"..fugacity.name.."-T-"..temp] then
                        new_boiler[#new_boiler+1] = {
                            type = "recipe",
                            name = boiler.name.."-"..fugacity.name.."-fluidisation-"..temp,
                            icons = omni.lib.icon.of(fugacity.name,"fluid"),
                            subgroup = "fluid-recipes",
                            category = "boiler-omnifluid-"..boiler.name,
                            order = "g[hydromnic-acid]",
                            energy_required = tid,
                            enabled = true,--may change this to be linked to the boiler unlock if applicable
                            hide_from_player_crafting = true,
                            main_product = fugacity.name,
                            ingredients = {{type = "item", name = "solid-"..fugacity.name.."-T-"..temp, amount = prod}},
                            results = {{type = "fluid", name = fugacity.name, amount = omni.fluid.sluid_contain_fluid*prod, temperature = temp}},
                        }
                    else
                        log("item does not exist:".. fugacity.name.."-fluidisation-"..temp)
                    end
                else --no temperature specific fluid
                    new_boiler[#new_boiler+1] = {
                        type = "recipe",
                        name = fugacity.name.."-fluidisation",
                        icons = omni.lib.icon.of(fugacity.name,"fluid"),
                        subgroup = "fluid-recipes",
                        category = "general-omni-boiler",
                        order = "g[hydromnic-acid]",
                        energy_required = tid,
                        enabled = true,--may change this to be linked to the boiler unlock if applicable
                        hide_from_player_crafting = true,
                        main_product = fugacity.name,
                        ingredients = {{type = "item", name = "solid-"..fugacity.name, amount = prod}},
                        results = {{type = "fluid", name = fugacity.name, amount = omni.fluid.sluid_contain_fluid*prod, temperature = data.raw.fluid[fugacity.name].default_temperature}},
                    }
                end
            end
        end

        --duplicate boiler for each corresponding one? 
        --The sluids boiler is an assembly type so we cannot just override the old ones..., so we make the assemly type replacement and hide the original, Be careful with things like angels electric boilers as they are assembly type too.
        local new_item = table.deepcopy(data.raw.item[boiler.name])
        new_item.name = boiler.name.."-converter"
        new_item.place_result = boiler.name.."-converter"
        new_item.localised_name = {"item-name.boiler-converter", {"entity-name."..boiler.name}}
        new_boiler[#new_boiler+1] = new_item

        boiler.minable.result = boiler.name.."-converter"
        --stop it from being analysed further (stop recursive updates)
        omni.fluid.forbidden_assembler[boiler.name.."-converter"] = true
        --create entity

        local new_ent = table.deepcopy(data.raw.boiler[boiler.name])
        new_ent.type = "assembling-machine"
        new_ent.name = boiler.name.."-converter"
        new_ent.localised_name = {"item-name.boiler-converter", {"entity-name."..boiler.name}}
        new_ent.icon = boiler.icon
        new_ent.icons = boiler.icons
        new_ent.crafting_speed = 1
        --change source location to deal with the new size
        new_ent.energy_source = boiler.energy_source
        if new_ent.energy_source and new_ent.energy_source.connections then
            local HS=boiler.energy_source
            HS.connections = omni.fluid.heat_pipe_images.connections
            HS.pipe_covers = omni.fluid.heat_pipe_images.pipe_covers
            HS.heat_pipe_covers = omni.fluid.heat_pipe_images.heat_pipe_covers
            HS.heat_picture = omni.fluid.heat_pipe_images.heat_picture
            HS.heat_glow = omni.fluid.heat_pipe_images.heat_glow
        end
        new_ent.energy_usage = boiler.energy_consumption
        new_ent.ingredient_count = 4
        new_ent.crafting_categories = {"boiler-omnifluid-"..boiler.name,"general-omni-boiler"}
        new_ent.fluid_boxes = {
            {
                production_type = "output",
                pipe_covers = pipecoverspictures(),
                base_level = 1,
                pipe_connections = {{type = "output", position = {0, -2}}}
            }
        }--get_fluid_boxes(new.fluid_boxes or new.output_fluid_box)
        new_ent.fluid_box = nil --removes input box
        new_ent.mode = nil --invalid for assemblers
        new_ent.minable.result = boiler.name.."-converter"
        if new_ent.next_upgrade then
            new_ent.next_upgrade = new_ent.next_upgrade.."-converter"
        end
        if new_ent.energy_source and new_ent.energy_source.connections then --use HX graphics instead
            new_ent.animation = omni.fluid.exchanger_images.animation
            new_ent.working_visualisations = omni.fluid.exchanger_images.working_visualisations
        else
            new_ent.animation = omni.fluid.boiler_images.animation
            new_ent.working_visualisations = omni.fluid.boiler_images.working_visualisations
        end
        new_ent.collision_box = {{-1.29, -1.29}, {1.29, 1.29}}
        new_ent.selection_box = {{-1.5, -1.5}, {1.5, 1.5}}
        new_boiler[#new_boiler+1] = new_ent
        ing_replace[#ing_replace+1] = boiler.name

        --find tech unlock
        local found = false --if not found, force off (means enabled at start)
        for i,tech in pairs(data.raw.technology) do
            if tech.effects then
                for j,k in pairs(tech.effects) do
                    if k.recipe_name and k.recipe_name == boiler.name then
                        boiler_tech[#boiler_tech+1] = {tech_name = tech.name, old_name = boiler.name}
                    end
                end
            end
        end
        if found == false then
            --hide and disable starting items
            local old = data.raw.boiler[boiler.name]
            old.enabled = false
            if old.flags then
                if not old.flags["hidden"] then
                    table.insert(old.flags,"hidden")
                end
            else
                old.flags = {"hidden"}
            end
            data.raw.item[boiler.name].hidden = true
            data.raw.item[boiler.name].enabled = false
        end
    end
end

new_boiler[#new_boiler+1] = {
    type = "recipe-category",
    name = "general-omni-boiler",
}

data:extend(new_boiler)

--replace the item as an ingredient
for _,boiler in pairs(ing_replace) do
    omni.lib.replace_all_ingredient(boiler, boiler.."-converter")
end
--replace in tech unlock
for _,boil in pairs(boiler_tech) do
    omni.lib.replace_unlock_recipe(boil.tech_name, boil.old_name, boil.old_name.."-converter")
end


-------------------------------------------
-----Replace recipe ingres with sluids-----
-------------------------------------------
--log(serpent.block(recipe_mods))
for name, changes in pairs(recipe_mods) do
    local rec = data.raw.recipe[name]
    if rec then
        --check if needs standardisation
        local std = false
        for i,dif in pairs({"normal","expensive"}) do
            if not (rec[dif] and rec[dif].ingredients and rec[dif].expensive) then
                std = true
            end
        end
        if std == true then
            --standardise
            omni.lib.standardise(rec)
        end
        --declare sub-tabs
        local fluids = {normal = {ingredients = {}, results = {}}, expensive = {ingredients = {}, results = {}}}
        local primes = {normal = {ingredients = {}, results = {}}, expensive = {ingredients = {}, results = {}}}
        local mult = {normal = 1,expensive = 1}
        --start first layer of analysis
        for _,dif in pairs({"normal","expensive"}) do
            for _,ingres in pairs({"ingredients","results"}) do
                for j,ing in pairs(rec[dif][ingres]) do
                    if ing.type == "fluid" then
                        --if ing.amount then
                            fluids[dif][ingres][j] = {name= ing.name, amount = omni.fluid.get_fluid_amount(ing)}
                            mult[dif] = omni.lib.lcm(omni.lib.lcm(omni.fluid.sluid_contain_fluid, fluids[dif][ingres][j].amount)/fluids[dif][ingres][j].amount, mult[dif])
                            primes[dif][ingres][j] = omni.lib.factorize(fluids[dif][ingres][j].amount)
                        -- else --throw error
                        --     log("invalid fluid amount found in: "..rec.name.. " part: ".. dif.."."..ingres)
                        --     log(serpent.block(rec[dif][ingres]))
                        -- end
                    end
                end
            end
            --result value adjustments checker
            local div = 1
            local need_adjustment = nil
            local gcd_primes = {}
            for j,ing in pairs(rec[dif]["results"]) do
                if ing.type == "fluid" then
                    local c = fluids[dif]["results"][j].amount * mult[dif]
                    if c > 500 and (not need_adjustment or c > need_adjustment) then
                        need_adjustment = c
                    end
                    if gcd_primes == {} then
                        gcd_primes = primes[dif]["results"][j]
                    else
                        gcd_primes = omni.lib.prime.gcd(primes[dif]["results"][j],gcd_primes)
                    end
                end
            end
            --I thought most of these subs were already part of the library?
            if need_adjustment then
                --log("need adj")
                local modMult = mult[dif]*500/need_adjustment
                local multPrimes = omni.lib.factorize(mult[dif])
                local addPrimes = {}
                local checkPrimes = mult[dif]
                for i = 0, (multPrimes["2"] or 0) do
                    for j = 0, (multPrimes["3"] or 0) do
                        for k = 0, (multPrimes["5"] or 0) do
                            local c = math.pow(2,i)*math.pow(3,j)*math.pow(5,k)
                            if c > modMult and c < checkPrimes then
                                checkPrimes = c
                            end
                        end
                    end
                end
                addPrimes = omni.lib.factorize(checkPrimes)
                local totalPrimeVal = omni.lib.prime.value(omni.lib.prime.mult(addPrimes,gcd_primes))
                for _,ingres in pairs({"ingredients","results"}) do
                    for j,component in pairs(data.raw.recipe[rec.name][dif][ingres]) do
                        if component.type == "fluid" then
                            local fluid_amount = 0
                            local roundFluidValues = omni.fluid.SetRoundFluidValues()
                            for i=1,#roundFluidValues do
                                if roundFluidValues[i]%totalPrimeVal == 0 then
                                    if ingres == "ingredients" then
                                        if roundFluidValues[i] > fluids[dif][ingres][j].amount then
                                            fluid_amount = roundFluidValues[i]
                                            break
                                        end
                                    else
                                        if roundFluidValues[i] < fluids[dif][ingres][j].amount then
                                            fluid_amount = roundFluidValues[i]
                                        else
                                            break
                                        end
                                    end
                                elseif ingres == "results" and roundFluidValues[i] > fluids[dif][ingres][j].amount then
                                    break
                                end
                            end
                            --log(fluid_amount)
                            fluids[dif][ingres][j].amount = fluid_amount
                        end
                    end
                end
                mult[dif] = mult[dif]/checkPrimes
            end
        end
        --fix to pick up temperatures etc
        for _, dif in pairs({"normal","expensive"}) do
            for _, ingres in pairs({"ingredients","results"}) do
                for	n, ing in pairs(rec[dif][ingres]) do
                    if ing.type == "fluid" then
                        local new_ing={}--start empty to remove all old props to add only what is needed
                        new_ing.type = "item"
                        local cat = ""
                        if fluid_cats["sluid"][ing.name] then
                            cat = "sluid"
                        elseif fluid_cats["mush"][ing.name] then
                            cat = "mush"
                        else
                            break
                        end
                        --Has temperature set in recipe and that temperature is in our list
                        if ing.temperature and omni.lib.is_in_table(ing.temperature, fluid_cats[cat][ing.name].temperatures) then
                            new_ing.name = "solid-"..ing.name.."-T-"..ing.temperature
                        --Ingredient has to be in a specific temperature range, check if a solid between min and max exists
                        --May need to add a recipe for ALL temperatures that are in this range
                        elseif ing.minimum_temperature or ing.maximum_temperature then
                            local found_temp = nil
                            for _,temp in pairs(fluid_cats[cat][ing.name].temperatures) do
                                if type(temp) == "number" and temp >= (ing.minimum_temperature or 0) and temp <= (ing.maximum_temperature or math.huge) then
                                    found_temp = temp
                                    break
                                end
                            end
                            if found_temp then
                                new_ing.name = "solid-"..ing.name.."-T-"..found_temp
                            --No temperature matches, use the no temperature sluid as fallback
                            elseif  omni.lib.is_in_table("none", fluid_cats[cat][ing.name].temperatures) then
                                new_ing.name = "solid-"..ing.name
                                log("No sluid found that matches the correct temperature for "..ing.name)
                            else
                                log("Sluid Replacement error for "..ing.name)
                            end
                        -- No temperature set and "none" is in our list --> no temp sluid exists
                        elseif omni.lib.is_in_table("none", fluid_cats[cat][ing.name].temperatures) then
                            new_ing.name = "solid-"..ing.name
                        --Something is wrong...
                        else
                            log("Sluid Replacement error for "..ing.name)
                        end
                        new_ing.amount = omni.fluid.get_fluid_amount(ing)
                        --Main product checks
                        if ingres == "results" and rec[dif].main_product and rec[dif].main_product == ing.name then
                            rec[dif].main_product = new_ing.name
                        end
                        rec[dif][ingres][n] = new_ing
                    end
                end
            end
            --crafting time adjustment
            rec[dif].energy_required = rec[dif].energy_required*mult[dif]
        end
    else
        log("recipe not found:".. name)
    end
end

--Replace minable fluids result with a sluid
for _,resource in pairs(data.raw.resource) do
    local auto = resource.minable.result
    if resource.minable and resource.minable.results and resource.minable.results[1] and resource.minable.results[1].type == "fluid" then
        resource.minable.results[1].type = "item"
        resource.minable.results[1].name = "solid-"..resource.minable.results[1].name
        resource.minable.mining_time = resource.minable.mining_time * omni.fluid.sluid_contain_fluid
    end
end

---------------------------
-----Fluid box removal-----
---------------------------
for _, jack in pairs(data.raw["mining-drill"]) do
    if string.find(jack.name, "jack") then
        if jack.output_fluid_box then jack.output_fluid_box = nil end
        jack.vector_to_place_result = {0, -1.85}
    elseif string.find(jack.name, "thermal") then
        if jack.output_fluid_box then jack.output_fluid_box = nil end
        jack.vector_to_place_result = {-3, 5}
    end
end