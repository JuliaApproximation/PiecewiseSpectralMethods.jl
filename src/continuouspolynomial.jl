struct ContinuousPolynomial{order,T,P<:AbstractVector} <: AbstractPiecewisePolynomial{order,T,P}
    points::P
end


ContinuousPolynomial{o,T}(pts::P) where {o,T,P} = ContinuousPolynomial{o,T,P}(pts)
ContinuousPolynomial{o}(pts) where {o} = ContinuousPolynomial{o,Float64}(pts)
ContinuousPolynomial{o,T}(P::ContinuousPolynomial) where {o,T} = ContinuousPolynomial{o,T}(P.points)
ContinuousPolynomial{o}(P::ContinuousPolynomial) where {o} = ContinuousPolynomial{o,eltype(P)}(P)

PiecewisePolynomial(P::ContinuousPolynomial{o,T}) where {o,T} = PiecewisePolynomial(Legendre{T}(), P.points)

axes(B::ContinuousPolynomial{0}) = axes(PiecewisePolynomial(B))
axes(B::ContinuousPolynomial{1}) = (Inclusion(first(B.points) .. last(B.points)), blockedrange(Vcat(length(B.points), Fill(length(B.points) - 1, ∞))))
axes(B::ContinuousPolynomial{-1}) = (Inclusion(first(B.points) .. last(B.points)), blockedrange(Vcat(length(B.points)-2, Fill(length(B.points) - 1, ∞))))

==(P::PiecewisePolynomial, C::ContinuousPolynomial{0}) = P == PiecewisePolynomial(C)
==(C::ContinuousPolynomial{0}, P::PiecewisePolynomial) = PiecewisePolynomial(C) == P
==(::PiecewisePolynomial, ::ContinuousPolynomial{1}) = false
==(::ContinuousPolynomial{1}, ::PiecewisePolynomial) = false
==(A::ContinuousPolynomial{o}, B::ContinuousPolynomial{o}) where o = A.points == B.points
==(A::ContinuousPolynomial, B::ContinuousPolynomial) = false



getindex(P::ContinuousPolynomial{0,T}, x::Number, Kk::BlockIndex{1}) where {T} = PiecewisePolynomial(P)[x, Kk]

function getindex(P::ContinuousPolynomial{1,T}, x::Number, Kk::BlockIndex{1}) where {T}
    K, k = block(Kk), blockindex(Kk)
    if K == Block(1)
        LinearSpline(P.points)[x, k]
    else
        b = searchsortedlast(P.points, x)
        if b == k
            α, β = convert(T, P.points[b]), convert(T, P.points[b+1])
            Weighted(Jacobi{T}(1, 1))[affine(α.. β, ChebyshevInterval{real(T)}())[x], Int(K)-1]
        else
            zero(T)
        end
    end
end

function getindex(P::ContinuousPolynomial{-1,T}, x::Number, Kk::BlockIndex{1}) where {T}
    K, k = block(Kk), blockindex(Kk)
    if K == Block(1)
        Spline{-1,T}(P.points)[x, k]
    else
        b = searchsortedlast(P.points, x)
        if b == k
            α, β = convert(T, P.points[b]), convert(T, P.points[b+1])
            Jacobi{T}(1, 1)[affine(α.. β, ChebyshevInterval{real(T)}())[x], Int(K)-1]
        else
            zero(T)
        end
    end
end



factorize(V::SubQuasiArray{T,N,<:ContinuousPolynomial{0},<:Tuple{Inclusion,BlockSlice}}, dims...) where {T,N} =
    factorize(view(PiecewisePolynomial(parent(V)), parentindices(V)...), dims...)

plan_transform(P::ContinuousPolynomial{0}, szs::NTuple{N,Union{Int,Block{1}}}, dims=ntuple(identity,Val(N))) where N = plan_transform(PiecewisePolynomial(P), szs, dims)


for grd in (:grid, :plotgrid)
    @eval begin
        $grd(C::ContinuousPolynomial, n::Block{1}) = $grd(PiecewisePolynomial(C), n) 
        $grd(C::ContinuousPolynomial, n::Int) = $grd(PiecewisePolynomial(C), n) 
    end
end

function adaptivetransform_ldiv(Q::ContinuousPolynomial{1,V}, f::AbstractQuasiVector) where V
    T = promote_type(V, eltype(f))
    C₀ = ContinuousPolynomial{0,V}(Q)
    M = length(Q.points)-1

    c = C₀\f # Piecewise Legendre transform
    c̃ = paddeddata(c)
    N = max(2,div(length(c̃), M, RoundUp)) # degree
    P = Legendre{T}()
    W = Weighted(Jacobi{T}(1,1))
    
    # Restrict hat function to each element, add in bubble functions and compute connection
    # matrix to Legendre. [1 1; -1 1]/2 are the Legendre coefficients of the hat functions.
    R̃ = [[T[1 1; -1 1]/2; Zeros{T}(∞,2)] (P \ W)]

    # convert from Legendre to piecewise restricted hat + Bubble
    dat = R̃[1:N,1:N] \ reshape(pad(c̃, M*N), M, N)'
    cfs = T[]
    if size(dat,1) ≥ 1
        push!(cfs, dat[1,1])
        for j = 1:M-1
            isapprox(dat[2,j], dat[1,j+1]; atol=1000*M*eps()) || throw(ArgumentError("Discontinuity in data on order of $(abs(dat[2,j]- dat[1,j+1]))."))
        end
        for j = 1:M
            push!(cfs, dat[2,j])
        end
    end
    pad(append!(cfs, vec(dat[3:end,:]')), axes(Q,2))
end

adaptivetransform_ldiv(Q::ContinuousPolynomial{1,V}, f::AbstractQuasiMatrix) where V =
    BlockBroadcastArray(hcat, (Q \ f[:,j] for j = axes(f,2))...)

function grid(V::SubQuasiArray{T,2,<:ContinuousPolynomial{1},<:Tuple{Inclusion,BlockSlice}}) where {T}
    P = parent(V)
    _, JR = parentindices(V)
    pts = P.points
    grid(view(PiecewisePolynomial(Weighted(Jacobi{T}(1, 1)), pts), :, JR))
end

#######
# Conversion
#######

function \(P::ContinuousPolynomial{0}, C::ContinuousPolynomial{1})
    T = promote_type(eltype(P), eltype(C))
    @assert P.points == C.points
    v = (convert(T, 2):2:∞) ./ (3:2:∞)
    N = length(P.points)
    ArrowheadMatrix(_BandedMatrix(Ones{T}(2, N)/2, oneto(N-1), 0, 1),
        (_BandedMatrix(Fill(v[1], 1, N-1), oneto(N-1), 0, 0),),
        (_BandedMatrix(Vcat(Ones{T}(1, N)/2, -Ones{T}(1, N)/2), oneto(N-1), 0, 1),),
        Fill(_BandedMatrix(Hcat(v, Zeros{T}(∞), -v)', axes(v,1), 1, 1), N-1))
end


function \(D::ContinuousPolynomial{-1}, P::ContinuousPolynomial{0})
    T = promote_type(eltype(P), eltype(C))
    @assert P.points == C.points
    N = length(P.points)
    R = Jacobi{T}(1,1)\Legendre{T}()
    ArrowheadMatrix(0Eye{T}(N-2,N-1),
        (),
        (SquareEye{T}(N-1),),
        Fill(R, N-1))
end




######
# Gram matrix
######

function grammatrix(A::ContinuousPolynomial{0,T}) where T
    r = A.points
    N = length(r) - 1
    hs = diff(r)
    M = grammatrix(Legendre{T}())
    ArrowheadMatrix{T}(Diagonal(hs), (), (), [Diagonal(M.diag[2:end] * h/2) for h in hs])
end

function grammatrix(A::ContinuousPolynomial{0,T, <:AbstractRange}) where T
    r = A.points
    N = length(r)
    M = grammatrix(Legendre{T}())
    Diagonal(mortar(Fill.((step(r) / 2) .* M.diag, N - 1)))
end

function grammatrix(C::ContinuousPolynomial{1, T, <:AbstractRange}) where T
    r = C.points

    N = length(r) - 1
    h = step(r) # 2/N
    a = ((convert(T,4):4:∞) .* (convert(T,-2):2:∞)) ./ ((1:2:∞) .* (3:2:∞) .* (-1:2:∞))
    b = (((convert(T,2):2:∞) ./ (3:2:∞)).^2 .* (convert(T,2) ./ (1:2:∞) .+ convert(T,2) ./ (5:2:∞)))

    a11 = LazyBandedMatrices.Bidiagonal(Vcat(h/3, Fill(2h/3, N-1), h/3), Fill(h/6, N), :U)
    a21 = _BandedMatrix(Fill(h/3, 2, N), N+1, 1, 0)
    a31 = _BandedMatrix(Vcat(Fill(-2h/15, 1, N), Fill(2h/15, 1, N)), N+1, 1, 0)

    Symmetric(ArrowheadMatrix(a11, (a21, a31), (),
                Fill(_BandedMatrix(Vcat((-h*a/2)',
                Zeros{T}(1,∞),
                (h*b/2)'), ∞, 0, 2), N)))
end


function grammatrix(C::ContinuousPolynomial)
    P = ContinuousPolynomial{0}(C)
    L = P \ C
    L' * grammatrix(P) * L
end

@simplify function *(Ac::QuasiAdjoint{<:Any,<:ContinuousPolynomial}, B::ContinuousPolynomial)
    A = Ac'
    A == B && return grammatrix(A)
    P = ContinuousPolynomial{0}(A)
    (P \ A)' * grammatrix(P) * (P \ B)
end

@simplify function *(Ac::QuasiAdjoint{<:Any,<:ContinuousPolynomial{0}}, B::ContinuousPolynomial{0})
    A = Ac'
    @assert A == B
    grammatrix(A)
end



#####
# Derivative
#####

function diff(C::ContinuousPolynomial{1,T}; dims=1) where T
    # Legendre() \ (D*Weighted(Jacobi(1,1)))
    r = C.points
    N = length(r)
    s = one(T) ./ (r[2:end]-r[1:end-1])
    P = ContinuousPolynomial{0}(C)
    D = ArrowheadMatrix(_BandedMatrix([0 s'; -s' 0], length(s), 0, 1), (), (),
                        [Diagonal(2s̃ * (-convert(T, 2):-2:-∞)) for s̃ in s])
    ApplyQuasiMatrix(*, P, D)
end


function weaklaplacian(C::ContinuousPolynomial{1,T,<:AbstractRange}) where T
    r = C.points
    N = length(r)
    s = step(r)
    si = inv(s)
    t1 = Vcat(-si, Fill(-2si, N-2), -si)
    t2 = Fill(si, N-1)
    Symmetric(ArrowheadMatrix(LazyBandedMatrices.Bidiagonal(t1, t2, :U), (), (),
        Fill(Diagonal(convert(T, -16) .* (1:∞) .^ 2 ./ (s .* ((2:2:∞) .+ 1))), N-1)))
end



###
# singularities
###

singularities(C::ContinuousPolynomial{λ}) where λ = C
basis_singularities(C::ContinuousPolynomial) = C
singularitiesbroadcast(_, C::ContinuousPolynomial) = C # Assume we stay smooth


###
# sum
###

_sum(C::ContinuousPolynomial{0}, dims) = _sum(PiecewisePolynomial(C), dims)
function _sum(C::ContinuousPolynomial, dims)
    P = ContinuousPolynomial{0}(C)
    _sum(P, dims) * (P \ C)
end