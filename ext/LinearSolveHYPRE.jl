module LinearSolveHYPRE

using HYPRE.LibHYPRE: HYPRE_Complex
using HYPRE: HYPRE, HYPREMatrix, HYPRESolver, HYPREVector
using IterativeSolvers: Identity
using LinearSolve: HYPREAlgorithm, LinearCache, LinearProblem, LinearSolve,
                   OperatorAssumptions, default_tol, init_cacheval, issquare, set_cacheval
using SciMLBase: LinearProblem, SciMLBase
using UnPack: @unpack
using Setfield: @set!

mutable struct HYPRECache
    solver::Union{HYPRE.HYPRESolver, Nothing}
    A::Union{HYPREMatrix, Nothing}
    b::Union{HYPREVector, Nothing}
    u::Union{HYPREVector, Nothing}
    isfresh_A::Bool
    isfresh_b::Bool
    isfresh_u::Bool
end

function LinearSolve.init_cacheval(alg::HYPREAlgorithm, A, b, u, Pl, Pr, maxiters::Int,
                                   abstol, reltol,
                                   verbose::Bool, assumptions::OperatorAssumptions)
    return HYPRECache(nothing, nothing, nothing, nothing, true, true, true)
end

# Overload set_(A|b|u) in order to keep track of "isfresh" for all of them
const LinearCacheHYPRE = LinearCache{<:Any, <:Any, <:Any, <:Any, <:Any, HYPRECache}
function LinearSolve.set_A(cache::LinearCacheHYPRE, A)
    @set! cache.A = A
    cache.cacheval.isfresh_A = true
    @set! cache.isfresh = true
    return cache
end
function LinearSolve.set_b(cache::LinearCacheHYPRE, b)
    @set! cache.b = b
    cache.cacheval.isfresh_b = true
    return cache
end
function LinearSolve.set_u(cache::LinearCacheHYPRE, u)
    @set! cache.u = u
    cache.cacheval.isfresh_u = true
    return cache
end

# Note:
# SciMLBase.init is overloaded here instead of just LinearSolve.init_cacheval for two
# reasons:
# - HYPREArrays can't really be `deepcopy`d, so that is turned off by default
# - The solution vector/initial guess u0 can't be created with
#   fill!(similar(b, size(A, 2)), false) since HYPREArrays are not AbstractArrays.

function SciMLBase.init(prob::LinearProblem, alg::HYPREAlgorithm,
                        args...;
                        alias_A = false, alias_b = false,
                        # TODO: Implement eltype for HYPREMatrix in HYPRE.jl? Looks useful
                        #       even if it is not AbstractArray.
                        abstol = default_tol(prob.A isa HYPREMatrix ? HYPRE_Complex :
                                             eltype(prob.A)),
                        reltol = default_tol(prob.A isa HYPREMatrix ? HYPRE_Complex :
                                             eltype(prob.A)),
                        # TODO: Implement length() for HYPREVector in HYPRE.jl?
                        maxiters::Int = prob.b isa HYPREVector ? 1000 : length(prob.b),
                        verbose::Bool = false,
                        Pl = Identity(),
                        Pr = Identity(),
                        assumptions = OperatorAssumptions(),
                        kwargs...)
    @unpack A, b, u0, p = prob

    # Create solution vector/initial guess
    if u0 === nothing
        u0 = zero(b)
    end

    # Initialize internal alg cache
    cacheval = init_cacheval(alg, A, b, u0, Pl, Pr, maxiters, abstol, reltol, verbose,
                             assumptions)
    Tc = typeof(cacheval)
    isfresh = true

    cache = LinearCache{
                        typeof(A), typeof(b), typeof(u0), typeof(p), typeof(alg), Tc,
                        typeof(Pl), typeof(Pr), typeof(reltol), issquare(assumptions)
                        }(A, b, u0, p, alg, cacheval, isfresh, Pl, Pr, abstol, reltol,
                          maxiters,
                          verbose, assumptions)
    return cache
end

# Solvers whose constructor requires passing the MPI communicator
const COMM_SOLVERS = Union{HYPRE.BiCGSTAB, HYPRE.FlexGMRES, HYPRE.GMRES, HYPRE.ParaSails,
                           HYPRE.PCG}
create_solver(::Type{S}, comm) where {S <: COMM_SOLVERS} = S(comm)

# Solvers whose constructor should not be passed the MPI communicator
const NO_COMM_SOLVERS = Union{HYPRE.BoomerAMG, HYPRE.Hybrid, HYPRE.ILU}
create_solver(::Type{S}, comm) where {S <: NO_COMM_SOLVERS} = S()

function create_solver(alg::HYPREAlgorithm, cache::LinearCache)
    # If the solver is already instantiated, return it directly
    if alg.solver isa HYPRE.HYPRESolver
        return alg.solver
    end

    # Otherwise instantiate
    if !(alg.solver <: Union{COMM_SOLVERS, NO_COMM_SOLVERS})
        throw(ArgumentError("unknown or unsupported HYPRE solver: $(alg.solver)"))
    end
    comm = cache.cacheval.A.comm # communicator from the matrix
    solver = create_solver(alg.solver, comm)

    # Construct solver options
    solver_options = (;
                      AbsoluteTol = cache.abstol,
                      MaxIter = cache.maxiters,
                      PrintLevel = Int(cache.verbose),
                      Tol = cache.reltol)

    # Preconditioner (uses Pl even though it might not be a *left* preconditioner just *a*
    # preconditioner)
    if !(cache.Pl isa Identity)
        precond = if cache.Pl isa HYPRESolver
            cache.Pl
        elseif cache.Pl <: HYPRESolver
            create_solver(cache.Pl, comm)
        else
            throw(ArgumentError("unknown HYPRE preconditioner $(cache.Pl)"))
        end
        solver_options = merge(solver_options, (; Precond = precond))
    end

    # Filter out some options that are not supported for some solvers
    if solver isa HYPRE.Hybrid
        # Rename MaxIter to PCGMaxIter
        MaxIter = solver_options.MaxIter
        ks = filter(x -> x !== :MaxIter, keys(solver_options))
        solver_options = NamedTuple{ks}(solver_options)
        solver_options = merge(solver_options, (; PCGMaxIter = MaxIter))
    elseif solver isa HYPRE.BoomerAMG || solver isa HYPRE.ILU
        # Remove AbsoluteTol, Precond
        ks = filter(x -> !in(x, (:AbsoluteTol, :Precond)), keys(solver_options))
        solver_options = NamedTuple{ks}(solver_options)
    end

    # Set the options
    HYPRE.Internals.set_options(solver, pairs(solver_options))

    return solver
end

# TODO: How are args... and kwargs... supposed to be used here?
function SciMLBase.solve(cache::LinearCache, alg::HYPREAlgorithm, args...; kwargs...)
    # It is possible to reach here without HYPRE.Init() being called if HYPRE structures are
    # only to be created here internally (i.e. when cache.A::SparseMatrixCSC and not a
    # ::HYPREMatrix created externally by the user). Be nice to the user and call it :)
    if !(cache.A isa HYPREMatrix || cache.b isa HYPREVector || cache.u isa HYPREVector ||
         alg.solver isa HYPRESolver)
        HYPRE.Init()
    end

    # Move matrix and vectors to HYPRE, if not already provided as HYPREArrays
    hcache = cache.cacheval
    if hcache.isfresh_A || hcache.A === nothing
        hcache.A = cache.A isa HYPREMatrix ? cache.A : HYPREMatrix(cache.A)
        hcache.isfresh_A = false
    end
    if hcache.isfresh_b || hcache.b === nothing
        hcache.b = cache.b isa HYPREVector ? cache.b : HYPREVector(cache.b)
        hcache.isfresh_b = false
    end
    if hcache.isfresh_u || hcache.u === nothing
        hcache.u = cache.u isa HYPREVector ? cache.u : HYPREVector(cache.u)
        hcache.isfresh_u = false
    end

    # Create the solver.
    if hcache.solver === nothing
        hcache.solver = create_solver(alg, cache)
    end

    # Done with cache updates; set it
    cache = set_cacheval(cache, hcache)

    # Solve!
    HYPRE.solve!(hcache.solver, hcache.u, hcache.A, hcache.b)

    # Copy back if the output is not HYPREVector
    if cache.u !== hcache.u
        @assert !(cache.u isa HYPREVector)
        copy!(cache.u, hcache.u)
    end

    # Note: Inlining SciMLBase.build_linear_solution(alg, u, resid, cache; retcode, iters)
    # since some of the functions used in there does not play well with HYPREVector.

    T = cache.u isa HYPREVector ? HYPRE_Complex : eltype(cache.u) # eltype(u)
    N = 1 # length((size(u)...,))
    resid = nothing                     # TODO: Fetch from solver
    iters = 0                           # TODO: Fetch from solver
    retc = SciMLBase.ReturnCode.Default # TODO: Fetch from solver

    ret = SciMLBase.LinearSolution{T, N, typeof(cache.u), typeof(resid), typeof(alg),
                                   typeof(cache)}(cache.u, resid, alg, retc, iters, cache)

    return ret
end

# HYPREArrays are not AbstractArrays so perform some type-piracy
function SciMLBase.LinearProblem(A::HYPREMatrix, b::HYPREVector,
                                 p = SciMLBase.NullParameters();
                                 u0::Union{HYPREVector, Nothing} = nothing, kwargs...)
    return LinearProblem{true}(A, b, p; u0 = u0, kwargs)
end

end # module LinearSolveHYPRE