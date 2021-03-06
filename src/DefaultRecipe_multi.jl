function multi_fit(source::QSO{TRecipe}; ref_id=1) where TRecipe <: DefaultRecipe
    Nspec = length(source.domain)

    elapsed = time()
    mzer = GFit.cmpfit()
    mzer.Δfitstat_theshold = 1.e-5

    # Initialize components and guess initial values
    println(logio(source), "\nFit continuum components...")

    multi = MultiModel()
    for id in 1:Nspec
        λ = source.domain[id][:]
        model = Model(source.domain[id],
                      :qso_cont => QSFit.qso_cont_component(TRecipe),
                      :Continuum => SumReducer([:qso_cont]))

        # TODO if source.options[:instr_broadening]
        # TODO     GFit.set_instr_response!(model, (l, f) -> instrumental_broadening(l, f, source.spectra[id].resolution))
        # TODO end

        c = model[:qso_cont]
        c.x0.val = median(λ)
        c.norm.val = Spline1D(λ, source.data[id].val, k=1, bc="error")(c.x0.val)
        push!(multi, model)
    end

    for id in 1:Nspec
        model = multi[id]
        λ = source.domain[id][:]

        # Host galaxy template
        if source.options[:use_host_template]   &&
            (minimum(λ) .< 5500 .< maximum(λ))
            model[:galaxy] = QSFit.hostgalaxy(source.options[:host_template])
            model[:Continuum] = SumReducer([:qso_cont, :galaxy])

            # Split total flux between continuum and host galaxy
            vv = Spline1D(λ, source.data[id].val, k=1, bc="error")(5500.)
            model[:galaxy].norm.val  = 1/2 * vv
            model[:qso_cont].x0.val *= 1/2 * vv / Spline1D(λ, model(:qso_cont), k=1, bc="error")(5500.)

            if id != ref_id
                @patch! multi[id][:galaxy].norm = multi[ref_id][:galaxy].norm
            end
        end

        # Balmer continuum and pseudo-continuum
        if source.options[:use_balmer]
            tmp = [:qso_cont, :balmer]
            (:galaxy in keys(model))  &&  push!(tmp, :galaxy)
            model[:balmer] = QSFit.balmercont(0.1, 0.5)
            model[:Continuum] = SumReducer(tmp)
            c = model[:balmer]
            c.norm.val  = 0.1
            c.norm.fixed = false
            c.norm.high = 0.5
            c.ratio.val = 0.5
            c.ratio.fixed = false
            c.ratio.low  = 0.1
            c.ratio.high = 1
            @patch! model[:balmer].norm *= model[:qso_cont].norm
        end
    end
    bestfit = fit!(multi, source.data, minimizer=mzer);  show(logio(source), bestfit)

    # QSO continuum renormalization
    for id in 1:Nspec
        model = multi[id]
        freeze(model, :qso_cont)
        c = model[:qso_cont]
        initialnorm = c.norm.val
        if c.norm.val > 0
            println(logio(source), "$id: Cont. norm. (before): ", c.norm.val)
            while true
                residuals = (model() - source.data[id].val) ./ source.data[id].unc
                (count(residuals .< 0) / length(residuals) > 0.9)  &&  break
                (c.norm.val < initialnorm / 5)  &&  break # give up
                c.norm.val *= 0.99
                evaluate!(model)
            end
            println(logio(source), "$id : Cont. norm. (after) : ", c.norm.val)
        else
            println(logio(source), "$id: Skipping cont. renormalization")
        end
        freeze(model, :qso_cont)
        (:galaxy in keys(model))  &&  freeze(model, :galaxy)
        (:balmer in keys(model))  &&  freeze(model, :balmer)
    end
    evaluate!(multi)

    # Fit iron templates
    println(logio(source), "\nFit iron templates...")
    for id in 1:Nspec
        model = multi[id]
        λ = source.domain[id][:]

        iron_components = Vector{Symbol}()
        if source.options[:use_ironuv]
            fwhm = 3000.
            source.options[:instr_broadening]  ||  (fwhm = sqrt(fwhm^2 + (source.spectra[id].resolution * 2.355)^2))
            comp = QSFit.ironuv(fwhm)
            (_1, _2, coverage) = spectral_coverage(λ, source.spectra[id].resolution, comp)
            threshold = get(source.options[:min_spectral_coverage], :ironuv, source.options[:min_spectral_coverage][:default])
            if coverage >= threshold
                model[:ironuv] = comp
                model[:ironuv].norm.val = 0.5
                push!(iron_components, :ironuv)
            else
                println(logio(source), "Ignoring ironuv component on prediction $id (threshold: $threshold)")
            end
        end

        if source.options[:use_ironopt]
            fwhm = 3000.
            source.options[:instr_broadening]  ||  (fwhm = sqrt(fwhm^2 + (source.spectra[id].resolution * 2.355)^2))
            comp = QSFit.ironopt_broad(fwhm)
            (_1, _2, coverage) = spectral_coverage(λ, source.spectra[id].resolution, comp)
            threshold = get(source.options[:min_spectral_coverage], :ironopt, source.options[:min_spectral_coverage][:default])
            if coverage >= threshold
                fwhm = 500.
                source.options[:instr_broadening]  ||  (fwhm = sqrt(fwhm^2 + (source.spectra[id].resolution * 2.355)^2))
                model[:ironoptbr] = comp
                model[:ironoptna] = QSFit.ironopt_narrow(fwhm)
                model[:ironoptbr].norm.val = 0.1  # TODO: guess a sensible value
                model[:ironoptna].norm.val = 0.0
                freeze(model, :ironoptna)  # will be freed during last run
                push!(iron_components, :ironoptbr, :ironoptna)
            else
                println(logio(source), "Ignoring ironopt component on prediction $id (threshold: $threshold)")
            end
        end
        if length(iron_components) > 0
            model[:Iron] = SumReducer(iron_components)
            model[:main] = SumReducer([:Continuum, :Iron])
            evaluate!(model)
            bestfit = fit!(model, source.data[id], minimizer=mzer); show(logio(source), bestfit)
        else
            model[:Iron] = @expr m -> [0.]
            model[:main] = SumReducer([:Continuum, :Iron])
        end
        (:ironuv    in keys(model))  &&  freeze(model, :ironuv)
        (:ironoptbr in keys(model))  &&  freeze(model, :ironoptbr)
        (:ironoptna in keys(model))  &&  freeze(model, :ironoptna)
    end
    evaluate!(multi)

    # Add emission lines
    line_names = [collect(keys(source.line_names[id])) for id in 1:Nspec]
    line_groups = [unique(collect(values(source.line_names[id]))) for id in 1:Nspec]
    println(logio(source), "\nFit known emission lines...")
    for id in 1:Nspec
        model = multi[id]
        λ = source.domain[id][:]
        resid = source.data[id].val - model()  # will be used to guess line normalization
        for (cname, comp) in source.line_comps[id]
            model[cname] = comp
        end
        for (group, lnames) in QSFit.invert_dictionary(source.line_names[id])
            model[group] = SumReducer(lnames)
        end
        model[:main] = SumReducer([:Continuum, :Iron, line_groups[id]...])

        if haskey(model, :MgII_2798)
            model[:MgII_2798].voff.low  = -1000
            model[:MgII_2798].voff.high =  1000
        end
        if haskey(model, :OIII_5007_bw)
            model[:OIII_5007_bw].fwhm.val  = 500
            model[:OIII_5007_bw].fwhm.low  = 1e2
            model[:OIII_5007_bw].fwhm.high = 1e3
            model[:OIII_5007_bw].voff.low  = 0
            model[:OIII_5007_bw].voff.high = 2e3
        end
        for cname in line_names[id]
            model[cname].norm_integrated = source.options[:norm_integrated]
        end

        # Guess values
        evaluate!(model)
        for cname in line_names[id]
            c = model[cname]
            resid_at_line = Spline1D(λ, resid, k=1, bc="nearest")(c.center.val)
            c.norm.val *= abs(resid_at_line) / maximum(model(cname))

            # If instrumental broadening is not used and the line profile
            # is a Gaussian one take spectral resolution into account.
            # This is significantly faster than convolving with an
            # instrument response but has some limitations:
            # - works only with Gaussian profiles;
            # - all components must be additive (i.e. no absorptions)
            # - further narrow components (besides known emission lines)
            #   will not be corrected for instrumental resolution
            if !source.options[:instr_broadening]
                if isa(c, QSFit.SpecLineGauss)
                    c.spec_res_kms = source.spectra[id].resolution
                else
                    println(logio(source), "Line $cname is not a Gaussian profile: Can't take spectral resolution into account")
                end
            end
        end

        # Patch parameters
        @patch! begin
         # model[:OIII_4959].norm = model[:OIII_5007].norm / 3
            model[:OIII_4959].voff = model[:OIII_5007].voff
        end
        @patch! begin
            model[:OIII_5007_bw].voff += model[:OIII_5007].voff
            model[:OIII_5007_bw].fwhm += model[:OIII_5007].fwhm
        end
        @patch! begin
            # model[:OI_6300].norm = model[:OI_6364].norm / 3
            model[:OI_6300].voff = model[:OI_6364].voff
        end
        @patch! begin
            # model[:NII_6549].norm = model[:NII_6583].norm / 3
            model[:NII_6549].voff = model[:NII_6583].voff
        end
        @patch! begin
            # model[:SII_6716].norm = model[:SII_6731].norm / 1.5
            model[:SII_6716].voff = model[:SII_6731].voff
        end

        @patch! model[:na_Hb].voff = model[:na_Ha].voff

        # The following are required to avoid degeneracy with iron
        # template
        @patch! begin
            model[:Hg].voff = model[:br_Hb].voff
            model[:Hg].fwhm = model[:br_Hb].fwhm
        end
        @patch! begin
            model[:br_Hg].voff = model[:br_Hb].voff
            model[:br_Hg].fwhm = model[:br_Hb].fwhm
        end
        @patch! begin
            model[:na_Hg].voff = model[:na_Hb].voff
            model[:na_Hg].fwhm = model[:na_Hb].fwhm
        end

        # Ensure luminosity at peak of the broad base component is
        # smaller than the associated broad component:
        if  haskey(model, :br_Hb)  &&
            haskey(model, :bb_Hb)
            model[:bb_Hb].norm.high = 1
            model[:bb_Hb].norm.val  = 0.5
            @patch! model[:bb_Hb].norm *= model[:br_Hb].norm / model[:br_Hb].fwhm * model[:bb_Hb].fwhm
        end
        if  haskey(model, :br_Ha)  &&
            haskey(model, :bb_Ha)
            model[:bb_Ha].norm.high = 1
            model[:bb_Ha].norm.val  = 0.5
            @patch! model[:bb_Ha].norm *= model[:br_Ha].norm / model[:br_Ha].fwhm * model[:bb_Ha].fwhm
        end

        bestfit = fit!(model, source.data[id], minimizer=mzer); show(logio(source), bestfit)

        for lname in line_names[id]
            freeze(model, lname)
        end
    end

    # Add unknown lines
    println(logio(source), "\nFit unknown emission lines...")
    if source.options[:n_unk] > 0
        for id in 1:Nspec
            model = multi[id]
            tmp = OrderedDict{Symbol, GFit.AbstractComponent}()
            for j in 1:source.options[:n_unk]
                tmp[Symbol(:unk, j)] = line_component(TRecipe, QSFit.UnkLine(5e3))
                tmp[Symbol(:unk, j)].norm_integrated = source.options[:norm_integrated]
            end
            for (cname, comp) in tmp
                model[cname] = comp
            end
            model[:UnkLines] = SumReducer(collect(keys(tmp)))
            model[:main] = SumReducer([:Continuum, :Iron, line_groups[id]..., :UnkLines])
            evaluate!(model)
            for j in 1:source.options[:n_unk]
                freeze(model, Symbol(:unk, j))
            end
        end
    else
        # Here we need a :UnkLines reducer, even when n_unk is 0
        for id in 1:Nspec
            model = multi[id]
            model[:UnkLines] = @expr m -> [0.]
            model[:main] = SumReducer([:Continuum, :Iron, line_groups[id]...])
        end
    end
    evaluate!(multi)

    # Set "unknown" line center wavelength where there is a maximum in
    # the fit residuals, and re-run a fit.
    for id in 1:Nspec
        model = multi[id]
        λ = source.domain[id][:]
        λunk = Vector{Float64}()
        while true
            (length(λunk) >= source.options[:n_unk])  &&  break
            evaluate!(model)
            Δ = (source.data[id].val - model()) ./ source.data[id].unc

            # Avoid considering again the same region (within 1A) TODO: within resolution
            for l in λunk
                Δ[findall(abs.(l .- λ) .< 1)] .= 0.
            end

            # Avoidance regions
            for rr in source.options[:unk_avoid]
                Δ[findall(rr[1] .< λ .< rr[2])] .= 0.
            end

            # Do not add lines close to from the edges since these may
            # affect qso_cont fitting
            Δ[findall((λ .< minimum(λ)*1.02)  .|
                      (λ .> maximum(λ)*0.98))] .= 0.
            iadd = argmax(Δ)
            (Δ[iadd] <= 0)  &&  break  # No residual is greater than 0, skip further residuals....
            push!(λunk, λ[iadd])

            cname = Symbol(:unk, length(λunk))
            model[cname].norm.val = 1.
            model[cname].center.val  = λ[iadd]
            model[cname].center.low  = λ[iadd] - λ[iadd]/10. # allow to shift 10%
            model[cname].center.high = λ[iadd] + λ[iadd]/10.

            thaw(model, cname)
            bestfit = fit!(model, source.data[id], minimizer=mzer); show(logio(source), bestfit)
            freeze(model, cname)
        end
    end
    evaluate!(multi)

    # ----------------------------------------------------------------
    # Last run with all parameters free
    println(logio(source), "\nLast run with all parameters free...")
    for id in 1:Nspec
        model = multi[id]
        thaw(model, :qso_cont)
        (:galaxy in keys(model))        &&  thaw(model, :galaxy)
        (:balmer in keys(model))        &&  thaw(model, :balmer)
        (:ironuv    in keys(model))     &&  thaw(model, :ironuv)
        (:ironoptbr in keys(model))     &&  thaw(model, :ironoptbr)
        (:ironoptna in keys(model))     &&  thaw(model, :ironoptna)

        for lname in line_names[id]
            thaw(model, lname)
        end
        for j in 1:source.options[:n_unk]
            cname = Symbol(:unk, j)
            if model[cname].norm.val > 0
                thaw(model, cname)
            else
                freeze(model, cname)
            end
        end
    end
    bestfit = fit!(multi, source.data, minimizer=mzer)

    # Disable "unknown" lines whose normalization uncertainty is larger
    # than 3 times the normalization
    needs_fitting = false
    for id in 1:Nspec
        model = multi[id]
        for ii in 1:source.options[:n_unk]
            cname = Symbol(:unk, ii)
            isfixed(model, cname)  &&  continue
            if bestfit[id][cname].norm.val == 0.
                freeze(model, cname)
                needs_fitting = true
                println(logio(source), "Disabling $cname (norm. = 0)")
            elseif bestfit[id][cname].norm.unc / bestfit[id][cname].norm.val > 3
                model[cname].norm.val = 0.
                freeze(model, cname)
                needs_fitting = true
                println(logio(source), "Disabling $cname (unc. / norm. > 3)")
            end
        end
    end
    if needs_fitting
        println(logio(source), "\nRe-run fit...")
        bestfit = fit!(multi, source.data, minimizer=mzer)
    end

    println(logio(source))
    show(logio(source), bestfit)

    out = QSFit.QSFitMultiResults(source, multi, bestfit)
    elapsed = time() - elapsed
    println(logio(source), "\nElapsed time: $elapsed s")
    QSFit.close_logio(source)
    return out
end
