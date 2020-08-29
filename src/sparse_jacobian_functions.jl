## sparse hadamard function matrix utilities

"
function hadamard_jacobian(Q::SparseMatrixCSC, dF::Fxn,
                           U, Fargs ...; scale = -1)

Assumes that Q/F is a skew-symmetric/symmetric pair
Can only deal with one coordinate component at a time in higher dimensions.
"
function hadamard_jacobian(Q::SparseMatrixCSC, dF::Fxn,
                           U, Fargs ...; scale = -1) where Fxn

    Nfields = length(U)
    NpK = size(Q,2)
    blockIds = repeat([NpK],Nfields)
    A = spzeros(NpK*Nfields,NpK*Nfields)

    accum_hadamard_jacobian!(A,Q,dF,U,Fargs...; scale=scale)

    return A
end

# "
# function hadamard_scale!(A::SparseMatrixCSC, Q::SparseMatrixCSC, F::Fxn,
#                         U, Fargs ...)
#
# computes the matrix A_ij = Q_ij * F(u_i,u_j)
# if you add extra args, they are passed to F(ux,uy) via F(u_i,u_j,args_i,args_j)
# "
# function hadamard_scale!(A::SparseMatrixCSC, Q::SparseMatrixCSC, F::Fxn,
#                         U, Fargs ...) where Fxn
#
#     Nfields = length(U)
#     num_pts = size(Q,1)
#     ids(m) = (1:num_pts) .+ (m-1)*num_pts
#     Block(m,n) = CartesianIndices((ids(m),ids(n)))
#
#     # loop over non-zero indices in Q
#     Qnz = zip(findnz(Q)...)
#     for (i,j,Qij) in Qnz
#         Ui = getindex.(U,i)
#         Uj = getindex.(U,j)
#
#         Fij = F(Ui,Uj,getindex.(Fargs,i)...,getindex.(Fargs,j)...)
#         for n = 1:length(U), m=1:length(U)
#             A[Block(m,n)[i,j]] += Fij[m,n]*Qij
#         end
#     end
# end

"
function accum_hadamard_jacobian!(A, Q, dF::Fxn, U, Fargs ...; scale = -1)

accumulate contributions from a Jacobian function dF into pre-allocated matrix A
"
function accum_hadamard_jacobian!(A, Q, dF::Fxn, U, Fargs ...; scale = -1) where Fxn

    Nfields = length(U)
    num_pts = size(Q,1)
    ids(m) = (1:num_pts) .+ (m-1)*num_pts
    Block(m,n) = CartesianIndices((ids(m),ids(n)))

    rows = rowvals(Q)
    vals = nonzeros(Q)

    # loop over columns and non-zero indices in Q
    dFaccum = zeros(eltype(Q),Nfields,Nfields) # accumulator for sum(Q.*dF,1) over jth column
    for j = 1:num_pts
        Uj = getindex.(U,j)

        fill!(dFaccum,zero(eltype(Q)))
        for id in nzrange(Q,j)
            i = rows[id]
            Qij = vals[id]
            Ui = getindex.(U,i)

            dFij = dF(Ui,Uj,getindex.(Fargs,i)...,getindex.(Fargs,j)...)

            # Aij = A[Block(m,n)]
            for n = 1:length(U), m=1:length(U)
                dFijQ = dFij[m,n]*Qij
                A[Block(m,n)[i,j]] += dFijQ
                dFaccum[m,n] += dFijQ # accumulate column sums on-the-fly
            end
        end

        # add diagonal entry for each block
        for n=1:Nfields, m=1:Nfields
            A[Block(m,n)[j,j]] += scale*dFaccum[m,n]
        end
    end
end

"
function banded_matrix_function(mat_fun::Fxn, U, Fargs ...)

computes block-banded matrix whose bands are entries of matrix-valued
function evals (e.g., a Jacobian function).
"
function banded_matrix_function(mat_fun::Fxn, U, Fargs ...) where Fxn
    Nfields = length(U)
    num_pts = length(U[1])

    A = spzeros(Nfields*num_pts,Nfields*num_pts)
    ids(m) = (1:num_pts) .+ (m-1)*num_pts
    Block(m,n) = CartesianIndices((ids(m),ids(n)))

    banded_matrix_function!(A, mat_fun, U, Fargs...)
    return A
end

"
function banded_matrix_function!(A::SparseMatrixCSC,mat_fun::Fxn, U, Fargs ...) where Fxn

computes a block-banded matrix whose bands are entries of matrix-valued
function evals (e.g., a Jacobian function) - mutating version.
"
function banded_matrix_function!(A::SparseMatrixCSC,mat_fun::Fxn, U, Fargs ...) where Fxn
    Nfields = length(U)
    num_pts = length(U[1])

    ids(m) = (1:num_pts) .+ (m-1)*num_pts
    Block(m,n) = CartesianIndices((ids(m),ids(n)))

    for i = 1:num_pts
        mat_i = mat_fun(getindex.(U,i),getindex.(Fargs,i)...)
        for n = 1:Nfields, m = 1:Nfields
            A[Block(m,n)[i,i]] = mat_i[m,n] # TODO: replace with fast sparse constructor
        end
    end
end

# =============== for residual evaluation ================

"
function hadamard_sum(ATr::SparseMatrixCSC{Tv,Ti},F::Fxn,u,Fargs ...) where {Tv,Ti,Fxn}

computes sum(A.*F,dims=2) while exploiting sparsity
uses ATr for faster col access of sparse CSC matrices
"
function hadamard_sum(ATr::SparseMatrixCSC{Tv,Ti},F::Fxn,u,Fargs ...) where {Tv,Ti,Fxn}
    m, n = size(ATr)
    # rhs = [zeros(n) for i in eachindex(u)]
    rhs = MVector{length(u)}([zeros(Tv,n) for i in eachindex(u)]) # probably faster w/StaticArrays?
    hadamard_sum!(rhs,ATr,F,u,Fargs...)
    return rhs
end

"
function hadamard_sum!(rhs, ATr::SparseMatrixCSC, F::Fxn,
                        u,Fargs ...) where Fxn

computes ∑ A_ij * F(u_i,u_j) = (A∘F)*1 for flux differencing
"
function hadamard_sum!(rhs, ATr::SparseMatrixCSC, F::Fxn,
                        u,Fargs ...) where Fxn
    cols = rowvals(ATr)
    vals = nonzeros(ATr)
    m, n = size(ATr)
    for i = 1:n
        ui = getindex.(u,i)
        val_i = zeros(length(u))
        #fill!(val_i,0.0)
        for j in nzrange(ATr, i) # column-major: extracts ith col of ATr = ith row of A
            col = cols[j]
            Aij = vals[j]
            uj = getindex.(u,col)
            val_i += Aij * F(ui,uj,getindex.(Fargs,i)...,getindex.(Fargs,col)...)
        end
        setindex!.(rhs,val_i,i)
    end
end
