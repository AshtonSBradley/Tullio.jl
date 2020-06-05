
#========== use TensorOperations when you can ==========#
# This seems to always be faster, when applicable.
# When not, it will return nothing, and we go back the the loops.

function try_tensor(expr, ranges, store)

    fail = nothing
    if expr isa Expr && expr.head in [:(:=), :(=), :(+=)]
    else
        fail = "TensorOperations not used, expected left := right etc"
    end
    if @capture_(expr.args[1], Z_[leftind__])
    else
        fail = "TensorOperations not used, expected A[i,j,k] := ..."
    end
    MacroTools_postwalk(expr.args[2]) do ex
        ex isa Expr || return ex
        if ex.head == :call && ex.args[1] == :*
        elseif ex.head == :ref
        elseif ex.head == :call && ex.args[1] in [:+, :-] && length(ex.args)==2 # -A[i]
        elseif ex.head == :call
            fail = "TensorOperations not used, can't handle $(ex.args[1])"
        else
            fail = "TensorOperations not used, can't handle $(ex.head)"
        end
        ex
    end
    if fail != nothing
        store.verbose > 0 && @warn fail
        return nothing
    end

    outex = []
    try
        tex = macroexpand(store.mod, :(TensorOperations.@tensor $expr))

        if @capture_(expr, left_ := right_)
            #===== new array =====#

            MacroTools_postwalk(right) do ex
                ex isa Expr || return ex
                # Save array and scalar arguments
                if @capture_(ex, A_[ijk__])
                    push!(store.arrays, arrayonly(A))
                    push!(store.indices, ijk)
                elseif ex.head == :call && ex.args[1] == :*
                    foreach(ex.args[2:end]) do a
                        a isa Symbol && push!(store.scalars, a)
                    end
                end
                ex
            end

            args = unique(vcat(store.arrays, store.scalars))
            push!(outex, quote
                function $MAKE($(args...),)
                    $tex
                end
            end)

            if store.grad != false
                ∇make, backdefs = tensor_grad(right, leftind, store)
                append!(outex, backdefs)
                push!(outex, :( $Z = $Eval($MAKE, $∇make)($(args...)) ))
            else
                push!(outex, :( $Z = $Eval($MAKE, $nothing)($(args...)) ))
            end

        else
            #===== in-place =====#
            push!(outex, tex)
        end

        # @tensor may return "throw(TensorOperations.IndexError("non-matching indices ..."
        for line in outex
            MacroTools_postwalk(line) do ex
                ex isa Expr && ex.head==:call && ex.args[1] == :throw && error(string(ex.args[2]))
                ex
            end
        end
        store.verbose == 2 && verbose_tensor(outex)
        return outex

    catch err
        store.verbose > 0 && @warn "TensorOperations failed" err
        return nothing
    end
end

verbose_tensor(outex) = begin
    @info "using TensorOperations"
    printstyled("    outex =\n", color=:blue)
    foreach(ex -> printstyled(Base.remove_linenums!(ex) , "\n", color=:green), outex)
end





#========== symbolic gradient ==========#
# Originally TensorGrad.jl (an unregistered package),
# all terms are again @tensor expressions.

function tensor_grad(right, leftind, store)
    dZ = Symbol(DEL, ZED)
    ∇make = Symbol(:∇, MAKE)
    backsteps, backseen = [], []

    for (B, Binds) in zip(store.arrays, store.indices)
        deltaB = Symbol(DEL, B)

        newright, extra, ijk = replace_B_with_Δ(B, Binds, right, leftind)

        append!(backsteps, extra)

        if B in backseen
            addon = macroexpand(store.mod, :( @tensor $deltaB[$(ijk...)] = $deltaB[$(ijk...)] + $newright ))
            push!(backsteps, addon)
        else
            push!(backseen, B)
            symB = Symbol(DEL, B, '_', join(ijk))
            create = macroexpand(store.mod, :( @tensor( $deltaB[$(ijk...)] := $newright ) ))
            push!(backsteps, create)
        end
    end

    args = unique(vcat(store.arrays, store.scalars))
    backtuple = vcat(
        map(B -> Symbol(DEL, B), unique(store.arrays)),
        map(_ -> nothing, unique(store.scalars)),
        )

    outex = [:(
        function $∇make($dZ, $(args...))
            $(backsteps...)
            return ($(backtuple...),)
        end
    )]

    if isdefined(store.mod, :Zygote) # special case for FillArrays
        backsteps_fill = fillarrayreplace(backsteps, dZ)
        ex_value = :($(Symbol(dZ, :_value)) = $dZ.value)
        push!(outex, :(
            function $∇make($dZ::Zygote.Fill, $(args...))
                $ex_value
                $(backsteps_fill...)
                return ($(backtuple...),)
            end
        ))
    end

    ∇make, outex
end

using LinearAlgebra

function replace_B_with_Δ(B, Bijk, right, leftind)
    dZ = Symbol(DEL, ZED)

    # If B[ijk] occurs twice this will be wrong:
    countB = 0

    # Construct the new RHS
    out = MacroTools_postwalk(right) do x
        if @capture_(x, A_[ijk__]) && A==B && ijk == Bijk
            countB += 1
            return :( $dZ[$(leftind...)] )
        else
            return x
        end
    end

    # Deal with partial traces -- repeated indices on same array
    extra, deltas = [], []
    newijk = copy(Bijk)
    if !allunique(Bijk)
        for n in 1:length(Bijk)
            i = newijk[n]
            m = findfirst(isequal(i), newijk[n+1:end])
            if m != nothing
                j = Symbol('_',i,'′')
                newijk[n] = j
                delta = Symbol("_δ_",i,j)

                # This definition is added up front:
                push!(extra, quote
                    local $delta = $Diagonal(fill!(similar($B, real(eltype($B)), size($B,$n)),true))
                end)
                # This factor is included in the new RHS:
                push!(deltas, :( $delta[$i,$j] ))
            end
        end
    end
    if length(extra) > 0
        out = :( *($out, $(deltas...)) )
    end

    # I said:
    # Gradient has indices appearing only on LHS... so you need * ones()[i,j]?

    countB > 1 && error("can't handle case of $B appearing twice with same indices")
    # Could also multiply by countB, and replace just once, would that be safe?

    return out, extra, newijk
end

#========== the end ==========#