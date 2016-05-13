#!/usr/bin/env python
import numpy as np
import scipy.optimize
import scipy.linalg
import scipy.spatial
import rbf.basis
import rbf.poly
import rbf.geometry
import modest
import matplotlib.pyplot as plt

def product_trace(A,B):
  ''' 
  efficiently returns the trace of a matrix product. this is used for 
  general cross validation
  '''
  return np.sum(A*B.T)


def laplacian_diff_op(dim):
  ''' 
  returns the coefficients and derivatives for each term in a 
  Laplacian differential operator for the given number of dimensions.
  For example, calling this function with dim=2 will return

    array([[1.0,(2,0)],
           [1.0,(0,2)]], dtype=object),

  which is represents the differential operator

    1.0*d^2/dx_1^2 + 1.0*d^2/dx_2^2

  '''
  I = np.eye(dim,dtype=int)
  out = [[1.0,tuple(2*i)] for i in I]
  return np.array(out,dtype=object)


def coefficient_matrix(x,eps=None,basis=rbf.basis.phs3,order=0):
  ''' 
  returns the matrix that maps the coefficients to the function values 
  at the observation points. 
  
  Parameters
  ----------
    x: (N,D) array of observation points
    diff: (D,) tuple of derivatives 
    basis (default=phs3): radial basis function 
    order (default=0): additional polynomial order
  '''
  # number of observation points and spatial dimensions
  N,D = x.shape

  # powers for the additional polynomials
  powers = rbf.poly.monomial_powers(order,D)
  # number of polynomial terms
  P = powers.shape[0]

  # allocate array 
  A = np.zeros((N+P,N+P))
  A[:N,:N] = basis(x,x,eps=eps)
  Ap = rbf.poly.mvmonos(x,powers)
  A[N:,:N] = Ap.T
  A[:N,N:] = Ap
  return A  


def regularization_matrix(x,eps=None,basis=rbf.basis.phs3,order=0,diff=None):
  # number of observation points and spatial dimensions
  N,D = x.shape
  # powers for the additional polynomials
  powers = rbf.poly.monomial_powers(order,D)
  # number of polynomial terms
  P = powers.shape[0]
  A = np.zeros((N,N+P)) 
  A[:,:N] = basis(x,x,eps=eps,diff=diff)
  A[:,N:] = rbf.poly.mvmonos(x,powers,diff=diff)
  return A  


def interpolation_matrix(xitp,x,diff=None,eps=None,basis=rbf.basis.phs3,order=0):
  # number of interpolation points and spatial dimensions
  I,D = xitp.shape

  # number of observation points
  N = x.shape[0]

  # powers for the additional polynomials
  powers = rbf.poly.monomial_powers(order,D)
  # number of polynomial terms
  P = powers.shape[0]

  A = np.zeros((I,N+P))
  A[:,:N] = basis(xitp,x,eps=eps,diff=diff)
  A[:,N:] = rbf.poly.mvmonos(xitp,powers,diff=diff)
  return A

def find_coeff(A,L,value,damping):
  ''' 
  Parameters
  ----------
    A: (N+P,N+P) coefficient matrix
    L: (K,K) regularization matrix 
    value: (N,...) observations
    damping: scalar damping parameter
  '''
  # number of data points
  N = value.shape[0]
  # number of added polynomials
  P = A.shape[0] - N

  # number of model parameters  
  M = P + N

  # extend values to have a consistent size
  value = np.concatenate((value,np.zeros(P)))

  # Make Gramian matrices
  ATA = A.T.dot(A) 
  print(np.linalg.cond(ATA))
  LTL = L.T.dot(L)

  if damping == 'gcv':
    # define function to be minimized
    def predictive_error(d):
      d = 10**d
      A_ginv = scipy.linalg.inv(ATA + d**2*LTL).dot(A.T)
      coeff = A_ginv.dot(value)
      predicted = A.dot(coeff)
      residual = predicted - value
      misfit = residual.dot(residual)
      numerator = M*misfit
      denominator = (M - product_trace(A,A_ginv))**2
      return numerator/denominator

    #damping = scipy.optimize.minimize_scalar(predictive_error).x
    damping = scipy.optimize.fmin(predictive_error,0.0)
    damping = 10**damping

  A_ginv = scipy.linalg.inv(ATA + damping**2*LTL).dot(A.T)
  coeff = A_ginv.dot(value)
  return coeff   


def in_hull(p, hull):
  ''' 
  Tests if points in p are in the convex hull made up by hull
  '''
  dim = p.shape[1]
  if dim >= 2:
    hull = scipy.spatial.Delaunay(hull)
    return hull.find_simplex(p)>=0
  else:
    # one dimensional points
    min = np.min(hull)
    max = np.max(hull)
    return (p[:,0] >= min) & (p[:,0] <= max)


class RBFInterpolant(object):
  ''' 
  Regularized Radial Basis Function Interpolant

  Description
  -----------

    returns an interpolant consisting of a linear combination of 
    radial basis functions and a polynomial with the specified order.
    
    We use A to denote the RBF alternant matrix with the additional 
    polynomial constraints. m is a vector consisting of the unknown 
    coefficients.  The coefficients are chosen to minimize

      ||W(Am - d)||_2^2 + ||p*Lm||_2^2

    where L is a regularization matrix which approximates the 
    Laplacian of the interpolant, p is the penalty parameter, and W is 
    a weight matrix consisting of the data uncertainty.
  '''
  def __init__(self,
               x,
               value, 
               weight=None,
               eps=None, 
               basis=rbf.basis.phs3,
               order=0,  
               extrapolate=True,
               fill=np.nan,
               penalty=0.0):
    ''' 
    Initiates the RBF interpolant

    Parameters 
    ---------- 
      x: (N,D) array of interpolation points which make up the rbf
        centers

      value: (N,) function values at the interpolation points.

      weight (default=None): (N,) array of weights to put on each 
        interpolation point
        
      eps (default=None): (N,) array of shape parameters for each RBF. 
        this has no effect for the default basis function, which is 
        scale invariant. 

      basis (default=phs3): type of basis function to use
 
      extrapolate (default=True): whether to allows points to be
        extrapolated outside of a convex hull formed by x. 

      fill (default=np.nan): if extrapolate is False then points
        outside of the convex hull will be assigned this value

    '''
    x = np.asarray(x)
    # number of observation points
    N = x.shape[0]
    if eps is None:
      eps = np.ones(N)
    else:
      eps = np.asarray(eps)

    if weight is None:
      weight = np.ones(N)
    else:
      weight = np.asarray(weight)

    # form matrix for the LHS
    A = coefficient_matrix(x,eps=eps,basis=basis,order=order)

    # scale RHS and LHS by weight
    A[:N,:] *= weight[:,None]
    value *= weight

    # form regularization matrix
    laplacian = laplacian_diff_op(x.shape[1])
    L = np.sum(c*regularization_matrix(x,eps=eps,basis=basis,diff=d,order=order)
               for c,d in laplacian)

    coeff = find_coeff(A,L,value,penalty)

    self.x = x
    self.coeff = coeff
    self.basis = basis
    self.order = order 
    self.eps = eps
    self.extrapolate = extrapolate
    self.fill = fill

  def __call__(self,xitp,diff=None):
    '''Returns the interpolant evaluated at xitp

    Parameters 
    ---------- 
      xitp: ((N,) or (N,D) array) points where the interpolant is to 
        be evaluated

      diff: ((D,) tuple, default=(0,)*dim) a tuple whos length is
        equal to the number of spatial dimensions.  Each value in the
        tfuple must be an integer indicating the order of the
        derivative in that spatial dimension.  For example, if the the
        spatial dimensions of the problem are 3 then diff=(2,0,1)
        would compute the second derivative in the first dimension and
        the first derivative in the third dimension.

    '''
    max_chunk = 100000
    n = 0
    xitp = np.asarray(xitp,dtype=float)
    Nitp = xitp.shape[0]
    # allocate output array
    out = np.zeros(Nitp)
    while n < Nitp:
      # xitp indices for this chunk
      idx = range(n,min(n+max_chunk,Nitp))
      A = interpolation_matrix(xitp[idx],self.x,
                               diff=diff,eps=self.eps,
                               basis=self.basis,order=self.order)
      out[idx] = np.einsum('ij,j...->i...',A,self.coeff)
      n += max_chunk

    # return zero for points outside of the convex hull if 
    # extrapolation is not allowed
    if not self.extrapolate:
      out[~in_hull(xitp,self.x)] = self.fill

    return out

