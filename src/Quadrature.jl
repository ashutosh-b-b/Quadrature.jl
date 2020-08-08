module Quadrature

using Requires, Reexport,  MonteCarloIntegration, QuadGK, HCubature
@reexport using DiffEqBase
using ZygoteRules, Zygote, ReverseDiff, ForwardDiff , LinearAlgebra

struct QuadGKJL <: DiffEqBase.AbstractQuadratureAlgorithm end
struct HCubatureJL <: DiffEqBase.AbstractQuadratureAlgorithm end
struct VEGAS <: DiffEqBase.AbstractQuadratureAlgorithm
    nbins::Int
    ncalls::Int
end

VEGAS(;nbins = 100,ncalls = 1000) = VEGAS(nbins,ncalls)

abstract type AbstractCubaAlgorithm <: DiffEqBase.AbstractQuadratureAlgorithm end
struct CubaVegas <:AbstractCubaAlgorithm end
struct CubaSUAVE <: AbstractCubaAlgorithm end
struct CubaDivonne <: AbstractCubaAlgorithm end
struct CubaCuhre <: AbstractCubaAlgorithm end

abstract type AbstractCubatureJLAlgorithm <: DiffEqBase.AbstractQuadratureAlgorithm end
struct CubatureJLh <: AbstractCubatureJLAlgorithm end
struct CubatureJLp <: AbstractCubatureJLAlgorithm end

abstract type QuadSensitivityAlg end
struct ReCallVJP{V}
    vjp::V
end

abstract type QuadratureVJP end
struct ZygoteVJP end
struct ReverseDiffVJP
    compile::Bool
end

function scale_x!(_x,ub,lb,x)
    _x .= (ub .- lb) .* x .+ lb
    _x
end

function transform_inf(t , p , f)
  v(t) = t ./ (1 .- t.^2)
  j = det(ForwardDiff.jacobian(x ->v(x), t))
  f(v(t)).*(j)
end

function transform_semiinf(t , p , f)
  v(t) = a .+ (t ./ (1 .- t))
  j = det(ForwardDiff.jacobian(x ->v(x), t))
  f(v(t)).*(j)
end

function scale_x(ub,lb,x)
    (ub .- lb) .* x .+ lb
end

function DiffEqBase.solve(prob::QuadratureProblem,::Nothing,sensealg,lb,ub,p,args...;
                          reltol = 1e-8, abstol = 1e-8, kwargs...)

    if lb isa Number
        __solve(prob,QuadGKJL();reltol=reltol,abstol=abstol,kwargs...)
    elseif length(lb) > 8 && reltol < 1e-4 || abstol < 1e-4
        __solve(prob,VEGAS();reltol=reltol,abstol=abstol,kwargs...)
    else
        __solve(prob,HCubatureJL();reltol=reltol,abstol=abstol,kwargs...)
    end
end

function DiffEqBase.solve(prob::QuadratureProblem,
                            alg::DiffEqBase.AbstractQuadratureAlgorithm,
                            args...; sensealg = ReCallVJP(ZygoteVJP()), kwargs...)

  __solvebp(prob,alg,sensealg,prob.lb,prob.ub,prob.p,args...;kwargs...)
end

# Give a layer to intercept with AD
__solvebp(args...;kwargs...) = __solvebp_call(args...;kwargs...)

function __solvebp_call(prob::QuadratureProblem,::QuadGKJL,sensealg,lb,ub,p,args...;
                          reltol = 1e-8, abstol = 1e-8,
                          maxiters = typemax(Int),
                          kwargs...)

    if isinplace(prob) || lb isa AbstractArray || ub isa AbstractArray
        error("QuadGKJL only accepts one-dimensional quadrature problems.")
    end
    @assert prob.batch == 0
    @assert prob.nout == 1
    p = p
    f = x -> prob.f(x,p)
    val,err = quadgk(f, lb, ub,
                     rtol=reltol, atol=abstol,
                     kwargs...)
    DiffEqBase.build_solution(prob,QuadGKJL(),val,err,retcode = :Success)
end

function __solvebp_call(prob::QuadratureProblem,::HCubatureJL,sensealg,lb,ub,p,args...;
                          reltol = 1e-8, abstol = 1e-8,
                          maxiters = typemax(Int),
                          kwargs...)
    
    p = p

    if isinplace(prob)
        dx = zeros(prob.nout)
        f = (x) -> (prob.f(dx,x,p); dx)
    else
        f = (x) -> prob.f(x,p)
    end
    @assert prob.batch == 0

    if lb isa Number
        val,err = hquadrature(f, lb, ub;
                            rtol=reltol, atol=abstol,
                            maxevals=maxiters, initdiv=1)
    else
        val,err = hcubature(f, lb, ub;
                            rtol=reltol, atol=abstol,
                            maxevals=maxiters, initdiv=1)
    end
    DiffEqBase.build_solution(prob,HCubatureJL(),val,err,retcode = :Success)
end

function __solvebp_call(prob::QuadratureProblem,alg::VEGAS,sensealg,lb,ub,p,args...;
                          reltol = 1e-8, abstol = 1e-8,
                          maxiters = typemax(Int),
                          kwargs...)
    p = p
    @assert prob.nout == 1
    if prob.batch == 0
        if isinplace(prob)
          dx = zeros(prob.nout)
          f = (x) -> (prob.f(dx,x,p); dx)
        else
          f = (x) -> prob.f(x,p)
        end
    else
        if isinplace(prob)
          dx = zeros(prob.batch)
          f = (x) -> (prob.f(dx,x',p); dx)
        else
          f = (x) -> prob.f(x',p)
        end
    end
    val,err,chi = vegas(f, lb, ub, rtol=reltol, atol=abstol,
                        maxiter = maxiters, nbins = alg.nbins,
                        ncalls = alg.ncalls, batch=prob.batch != 0, kwargs...)
    DiffEqBase.build_solution(prob,alg,val,err,chi=chi,retcode = :Success)
end

function __init__()
    @require Cubature="667455a9-e2ce-5579-9412-b964f529a492" begin
        function __solvebp_call(prob::QuadratureProblem,
                                  alg::AbstractCubatureJLAlgorithm,
                                  sensealg, lb, ub, p, args...;
                                  reltol = 1e-8, abstol = 1e-8,
                                  maxiters = typemax(Int),
                                  kwargs...)
            nout = prob.nout
            if nout == 1
                if prob.batch == 0
                    if isinplace(prob)
                        dx = zeros(prob.nout)
                        f = (x) -> (prob.f(dx,x,p); dx[1])
                    else
                        f = (x) -> prob.f(x,p)[1]
                    end
                    if lb isa Number
                        if alg isa CubatureJLh
                            _val,err = Cubature.hquadrature(f, lb, ub;
                                                           reltol=reltol, abstol=abstol,
                                                           maxevals=maxiters)
                        else
                            _val,err = Cubature.pquadrature(f, lb, ub;
                                                           reltol=reltol, abstol=abstol,
                                                           maxevals=maxiters)
                        end
                        val = prob.f(lb,p) isa Number ? _val : [_val]
                    else
                        if alg isa CubatureJLh
                            _val,err = Cubature.hcubature(f, lb, ub;
                                                     reltol=reltol, abstol=abstol,
                                                     maxevals=maxiters)
                        else
                            _val,err = Cubature.pcubature(f, lb, ub;
                                                         reltol=reltol, abstol=abstol,
                                                         maxevals=maxiters)
                        end

                        if isinplace(prob) || !isa(prob.f(lb,p), Number)
                            val = [_val]
                        else
                            val = _val
                        end
                     end
                else
                    if isinplace(prob)
                        f = (x,dx) -> prob.f(dx',x,p)
                    elseif lb isa Number
                        if prob.f([lb ub], p) isa Vector
                            f = (x,dx) -> (dx .= prob.f(x',p))
                        else
                            f = function (x,dx)
                                dx[:] = prob.f(x',p)
                            end
                        end
                    else
                        if prob.f([lb ub], p) isa Vector
                            f = (x,dx) -> (dx .= prob.f(x,p))
                        else
                            f = function (x,dx)
                                dx .= prob.f(x,p)[:]
                            end
                        end
                    end
                    if lb isa Number
                        if alg isa CubatureJLh
                            _val,err = Cubature.hquadrature_v(f, lb, ub;
                                                             reltol=reltol, abstol=abstol,
                                                             maxevals=maxiters)
                        else
                            _val,err = Cubature.pquadrature_v(f, lb, ub;
                                                             reltol=reltol, abstol=abstol,
                                                             maxevals=maxiters)
                        end
                    else
                        if alg isa CubatureJLh
                            _val,err = Cubature.hcubature_v(f, lb, ub;
                                                           reltol=reltol, abstol=abstol,
                                                           maxevals=maxiters)
                        else
                            _val,err = Cubature.pcubature_v(f, lb, ub;
                                                           reltol=reltol, abstol=abstol,
                                                           maxevals=maxiters)
                        end
                     end
                     val = _val isa Number ? [_val] : _val
                 end
             else
                 if prob.batch == 0
                     if isinplace(prob)
                         f = (x,dx) -> (prob.f(dx,x,p); dx)
                     else
                         f = (x,dx) -> (dx .= prob.f(x,p))
                     end
                     if lb isa Number
                         if alg isa CubatureJLh
                             val,err = Cubature.hquadrature(nout, f, lb, ub;
                                                            reltol=reltol, abstol=abstol,
                                                            maxevals=maxiters)
                         else
                             val,err = Cubature.pquadrature(nout, f, lb, ub;
                                                            reltol=reltol, abstol=abstol,
                                                            maxevals=maxiters)
                         end
                     else
                         if alg isa CubatureJLh
                             val,err = Cubature.hcubature(nout, f, lb, ub;
                                                          reltol=reltol, abstol=abstol,
                                                          maxevals=maxiters)
                         else
                             val,err = Cubature.pcubature(nout, f, lb, ub;
                                                          reltol=reltol, abstol=abstol,
                                                          maxevals=maxiters)
                         end
                      end
                 else
                     if isinplace(prob)
                         f = (x,dx) -> prob.f(dx,x,p)
                     else
                         if lb isa Number
                             f = (x,dx) -> (dx .= prob.f(x',p))
                         else
                             f = (x,dx) -> (dx .= prob.f(x,p))
                         end
                     end

                     if lb isa Number
                         if alg isa CubatureJLh
                             val,err = Cubature.hquadrature_v(nout, f, lb, ub;
                                                              reltol=reltol, abstol=abstol,
                                                              maxevals=maxiters)
                         else
                             val,err = Cubature.pquadrature_v(nout, f, lb, ub;
                                                              reltol=reltol, abstol=abstol,
                                                              maxevals=maxiters)
                         end
                     else
                         if alg isa CubatureJLh
                             val,err = Cubature.hcubature_v(nout, f, lb, ub;
                                                            reltol=reltol, abstol=abstol,
                                                            maxevals=maxiters)
                         else
                             val,err = Cubature.pcubature_v(nout, f, lb, ub;
                                                            reltol=reltol, abstol=abstol,
                                                            maxevals=maxiters)
                         end
                      end
                  end
              end
              DiffEqBase.build_solution(prob,alg,val,err,retcode = :Success)
        end
    end

    @require Cuba="8a292aeb-7a57-582c-b821-06e4c11590b1" begin
        function __solvebp_call(prob::QuadratureProblem,alg::AbstractCubaAlgorithm,sensealg,
                                  lb,ub,p,args...;
                                  reltol = 1e-8, abstol = 1e-8,
                                  maxiters = alg isa CubaSUAVE ? 1000000 : typemax(Int),
                                  kwargs...)
          p = p
          if lb isa Number && prob.batch == 0
              _x = Float64[lb]
          elseif lb isa Number
              _x = zeros(length(lb),prob.batch)
          elseif prob.batch == 0
              _x = zeros(length(lb))
          else
              _x = zeros(length(lb),prob.batch)
          end
          ub = ub
          lb = lb

          if prob.batch == 0
              if isinplace(prob)
                  f = function (x,dx)
                      prob.f(dx,scale_x!(_x,ub,lb,x),p)
                      dx .*= prod((y)->y[1]-y[2],zip(ub,lb))
                  end
              else
                  f = function (x,dx)
                      dx .= prob.f(scale_x!(_x,ub,lb,x),p) .* prod((y)->y[1]-y[2],zip(ub,lb))
                  end
              end
          else
              if lb isa Number
                  if isinplace(prob)
                      f = function (x,dx)
                          #todo check scale_x!
                          prob.f(dx',scale_x!(view(_x,1:length(x)),ub,lb,x),p)
                          dx .*= prod((y)->y[1]-y[2],zip(ub,lb))
                      end
                  else
                      if prob.f([lb ub], p) isa Vector
                          f = function (x,dx)
                              dx .= prob.f(scale_x(ub,lb,x),p)' .* prod((y)->y[1]-y[2],zip(ub,lb))
                          end
                      else
                          f = function (x,dx)
                              dx .= prob.f(scale_x(ub,lb,x),p) .* prod((y)->y[1]-y[2],zip(ub,lb))
                          end
                      end
                  end
              else
                  if isinplace(prob)
                      f = function (x,dx)
                          prob.f(dx,scale_x(ub,lb,x),p)
                          dx .*= prod((y)->y[1]-y[2],zip(ub,lb))
                      end
                  else
                      if prob.f([lb ub], p) isa Vector
                          f = function (x,dx)
                              dx .= prob.f(scale_x(ub,lb,x),p)' .* prod((y)->y[1]-y[2],zip(ub,lb))
                          end
                      else
                          f = function (x,dx)
                              dx .= prob.f(scale_x(ub,lb,x),p) .* prod((y)->y[1]-y[2],zip(ub,lb))
                          end
                      end
                  end
              end
          end

          ndim = length(lb)

          nvec = prob.batch == 0 ? 1 : prob.batch

          if alg isa CubaVegas
              out = Cuba.vegas(f, ndim, prob.nout; rtol = reltol,
                               atol = abstol, nvec = nvec,
                               maxevals = maxiters, kwargs...)
          elseif alg isa CubaSUAVE
              out = Cuba.suave(f, ndim, prob.nout; rtol = reltol,
                               atol = abstol, nvec = nvec,
                               maxevals = maxiters, kwargs...)
          elseif alg isa CubaDivonne
              out = Cuba.divonne(f, ndim, prob.nout; rtol = reltol,
                                 atol = abstol, nvec = nvec,
                                 maxevals = maxiters, kwargs...)
          elseif alg isa CubaCuhre
              out = Cuba.cuhre(f, ndim, prob.nout; rtol = reltol,
                               atol = abstol, nvec = nvec,
                               maxevals = maxiters, kwargs...)
          end

          if isinplace(prob) || prob.batch != 0
              val = out.integral
          else
              if prob.nout == 1 && prob.f(lb, p) isa Number
                  val = out.integral[1]
              else
                  val = out.integral
              end
          end

          DiffEqBase.build_solution(prob,alg,val,out.error,
                         chi=out.probability,retcode = :Success)
        end
    end
end

ZygoteRules.@adjoint function __solvebp(prob,alg,sensealg,lb,ub,p,args...;kwargs...)
    out = __solvebp_call(prob,alg,sensealg,lb,ub,p,args...;kwargs...)
    function quadrature_adjoint(Δ)
        y = typeof(Δ) <: Array{<:Number,0} ? Δ[1] : Δ
        if isinplace(prob)
            if lb isa Number && prob.batch == 0
                dx = Float64[lb]
            elseif lb isa Number
                dx = zeros(length(lb),prob.batch)
            elseif prob.batch == 0
                dx = zeros(length(lb))
            else
                dx = zeros(length(lb),prob.batch)
            end
            _f = (x) -> (prob.f(dx,x,p); dx)

            if sensealg.vjp isa ZygoteVJP
                dfdp = function (dx,x,p)
                    _,back = Zygote.pullback(p) do p
                        dx = Zygote.Buffer(x)
                        prob.f(dx,x,p)
                        copy(dx)
                    end
                    back(y)[1]
                end
            elseif sensealg.vjp isa ReverseDiffVJP
                error("TODO")
            end
        else
            _f = (x) -> prob.f(x,p)
            if sensealg.vjp isa ZygoteVJP
                dfdp = function (x,p)
                    _,back = Zygote.pullback(p->prob.f(x,p),p)
                    back(y)[1]
                end
            elseif sensealg.vjp isa ReverseDiffVJP
                error("TODO")
            end
        end

        dp_prob = QuadratureProblem(dfdp,lb,ub,p;nout=length(p),batch = prob.batch,kwargs...)

        if p isa Number
            dp = __solvebp_call(dp_prob,alg,sensealg,lb,ub,p,args...;kwargs...)[1]
        else
            dp = __solvebp_call(dp_prob,alg,sensealg,lb,ub,p,args...;kwargs...).u
        end

        if lb isa Number
            dlb = -_f(lb)
            dub = _f(ub)
            return (nothing,nothing,nothing,dlb,dub,dp,ntuple(x->nothing,length(args))...)
        else
            return (nothing,nothing,nothing,nothing,nothing,dp,ntuple(x->nothing,length(args))...)
        end
    end
    out,quadrature_adjoint
end

ZygoteRules.@adjoint function ZygoteRules.literal_getproperty(
                        sol::DiffEqBase.QuadratureSolution,::Val{:u})
    sol.u,Δ->(DiffEqBase.build_solution(sol.prob,sol.alg,Δ,sol.resid),)
end


### Forward-Mode AD Intercepts

# Direct AD on solvers with QuadGK and HCubature
function __solvebp(prob,alg::QuadGKJL,sensealg,lb,ub,p::AbstractArray{<:ForwardDiff.Dual{T,V,P},N},args...;kwargs...) where {T,V,P,N}
    __solvebp_call(prob,alg,sensealg,lb,ub,p,args...;kwargs...)
end

function __solvebp(prob,alg::HCubatureJL,sensealg,lb,ub,p::AbstractArray{<:ForwardDiff.Dual{T,V,P},N},args...;kwargs...) where {T,V,P,N}
    __solvebp_call(prob,alg,sensealg,lb,ub,p,args...;kwargs...)
end

# Manually split for the pushforward
function __solvebp(prob,alg,sensealg,lb,ub,p::AbstractArray{<:ForwardDiff.Dual{T,V,P},N},args...;kwargs...) where {T,V,P,N}
    primal = __solvebp_call(prob,alg,sensealg,lb,ub,ForwardDiff.value.(p),args...;kwargs...)
    nout = prob.nout*P

    if isinplace(prob)
        dx = similar(p, V, nout)
        dfdp = function (out,x,p)
            dualp = reinterpret(ForwardDiff.Dual{T,V,P}, p)
            prob.f(dx,x,dualp)
            ys = reinterpret(ForwardDiff.Dual{T,V,P}, dx)
            idx = 0
            for y in ys
                for p in ForwardDiff.partials(y)
                    out[idx+=1] = p
                end
            end
            return out
        end
    else
        dfdp = function (x,p)
            dualp = reinterpret(ForwardDiff.Dual{T,V,P}, p)
            ys = prob.f(x,dualp)
            out = zeros(nout)
            idx = 0
            for y in ys
                for p in ForwardDiff.partials(y)
                    out[idx+=1] = p
                end
            end
            return out
        end
    end
    rawp = copy(reinterpret(V, p))

    dp_prob = QuadratureProblem(dfdp,lb,ub,rawp;nout=nout,batch = prob.batch,kwargs...)
    dual = __solvebp_call(dp_prob,alg,sensealg,lb,ub,rawp,args...;kwargs...)
    res = similar(p, prob.nout)
    partials = reinterpret(typeof(first(res).partials), dual.u)
    for idx in eachindex(res)
        res[idx] = ForwardDiff.Dual{T,V,P}(primal.u[idx], partials[idx])
    end
    if primal.u isa Number
        res = first(res)
    end
    DiffEqBase.build_solution(prob,alg,res,primal.resid)
end

export QuadGKJL, HCubatureJL, VEGAS
export CubatureJLh, CubatureJLp
export CubaVegas, CubaSUAVE, CubaDivonne, CubaCuhre
end # module
