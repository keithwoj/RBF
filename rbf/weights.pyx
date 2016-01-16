from __future__ import division
import numpy as np
cimport numpy as np
from cython cimport cdivision
import rbf.basis
import modest
import scipy
import scipy.spatial
import random
import logging
from itertools import combinations_with_replacement as cr
from scipy.special import binom
from functools import wraps

logger = logging.getLogger(__name__)

def memoize(f):
  '''
  Description
  -----------
    decorator that stores the output of functions with hashable
    arguments and returns that output when the function is called
    again with the same arguments.

  Note
  ----
    Cached output is not copied. If the function output is mutable
    then any modifications to the output will result in modifications
    to the cached output

  '''
  cache = {}
  @wraps(f)
  def fout(*args):
    if args not in cache:
      cache[args] = f(*args)
    return cache[args]

  return fout  


def uvmono(np.ndarray[ndim=1,dtype=double] x,
                       float power,int diff):
  '''
  Description
  -----------
    univariate monomial 

  Parameters
  ----------
    x: (N,) numpy array of positions where the monomial will be evaluated

    power: scalar power of the monomial

    diff: integer derivative order of the monomial

  Returns
  -------
    out: (N,) array

  '''
  cdef:
    float coeff = 1.0
    
  while diff > 0:
    coeff *= power
    power -= 1.0
    diff -= 1

  # prevents division by zero error
  if coeff == 0.0:
    power = 0.0

  return coeff*x**power


cdef np.ndarray mvmono(np.ndarray[ndim=2,dtype=double] x,
                       tuple power,tuple diff):
  '''
  Description
  -----------
    multivariate monomial

  Parameters
  ----------
    x: (N,D) numpy array of positions where the monomial will be evaluated

    power: (D,) list of powers for each variable 

    diff: (D,) list of derivative order for each variable

  Returns
  -------
    out: (N,) array

  '''
  cdef:
    np.ndarray out = uvmono(x[:,0],power[0],diff[0])
    int i

  for i in range(1,x.shape[1]):
    out *= uvmono(x[:,i],float(power[i]),int(diff[i]))

  return out


@memoize
def monomial_powers(order,dim):
  '''
  Description
  -----------
    returns a list of tuples describing the powers for each monomial
    in a polymonial with the given order and number of dimensions.
    Because there should be the possibility of having zero terms in a
    polynomial, the integer value of order given to this function
    needs to be the polynomial order minus 1.  Calling this function
    with 0 for the order will return an empty list. Calling this
    function with 1 for the order will return the monomial powers for
    a polynomial of degree 0 (i.e. [(0,)*dim]).

  Example
  -------
    This will return the powers of x and y for each monomial term in a
    two dimensional polynomial with order 1 

      In [1]: monomial_powers(2,2) 
      Out[1]: [(0,0),(1,0),(0,1)]

  '''
  out = []
  for p in xrange(order):
    if p == 0:
      out.append((0,)*dim)    
    else:
      out.extend(tuple(sum(i)) for i in cr(np.eye(dim,dtype=int),p))

  return out

  
@memoize
def monomial_count(order,dim):
  '''
  Description
  -----------
    returns the number of monomial terms in a polynomial with the
    given order and number of dimensions

  '''
  return int(binom(order+dim-1,dim))


@memoize
def maximum_order(stencil_size,dim):
  '''
  Description
  -----------
    returns the maximum polynomial order allowed for the given stencil
    size and number of dimensions
  '''
  order = 0
  while (monomial_count(order+1,dim) <= stencil_size):
    order += 1

  return order  


def vpoly(nodes,order):
  '''
  Description
  -----------
    returns the polynomial Vandermond matrix, A_ij, consisting of
    monomial i evaluated at center j.  The monomials used consist of
    all monomials which would be found in a polynomial of the given
    order.

  Paramters
  ---------
    nodes: (N,D) numpy array of collocation points
    order: order of polynomial terms
  '''
  diff = (0,)*nodes.shape[1]
  powers = monomial_powers(order,nodes.shape[1])
  out = np.empty((len(powers),nodes.shape[0]))
  for itr,p in enumerate(powers):
    out[itr,:] = mvmono(nodes,p,diff)

  return out


def dpoly(x,order,diff):
  '''
  Description
  -----------
    returns the data vector, d_i, consisting of monomial i evaluated 
    at x.

  Parameters
  ----------
    x: (D,) vector where the polynomials are evaluated

    order: order of polynomials

    diff: derivative order of polynomial terms 
  '''
  x = x[None,:]
  powers = monomial_powers(order,x.shape[1])
  out = np.empty(len(powers))
  for itr,p in enumerate(powers):
    out[itr] = mvmono(x,p,diff)  
  
  return out


def vrbf(nodes,centers,eps,order,basis):
  '''
  Description
  -----------
    returns the matrix:

    A =   | Ar Ap.T |
          | Ap 0    |

    where Ar is the RBF Vandermonde matrix which consists of the
    specified centers evaluated at the specified nodes.  Ap is the
    polynomial Vandermonde matrix.

  Parameters
  ----------
    nodes: (N,D) numpy array of collocation points
    centers: (N,D) numpy array of RBF centers
    eps: RBF shape parameter
    
  '''
  # number of centers and dimensions
  Ns,Ndim = nodes.shape

  # number of monomial terms  
  Np = monomial_count(order,Ndim)

  # create an array of repeated eps values
  # this is faster than using np.repeat
  eps_array = np.empty(Ns)
  eps_array[:] = eps

  A = np.zeros((Ns+Np,Ns+Np))

  # Ar
  A[:Ns,:Ns] = basis(nodes,centers,eps_array).T

  # Ap
  Ap = vpoly(centers,order)  
  A[Ns:,:Ns] = Ap
  A[:Ns,Ns:] = Ap.T
  return A


def drbf(x,centers,eps,order,diff,basis): 
  '''
  Description
  -----------
    returns the vector:

      d = |dr|
          |dp|

    where dr consists of RBFs with the given centers evaulated at x
    and dp consists of the the polynomial data

  '''
  #centers = np.asarray(centers)
  #x = np.asarray(x)
  x = x[None,:]

  # number of centers and dimensions
  Ns,Ndim = centers.shape

  # number of monomial terms
  Np = monomial_count(order,Ndim)

  # create an array of repeated eps values
  # this is faster than using np.repeat
  eps_array = np.empty(Ns)
  eps_array[:] = eps

  d = np.empty(Ns+Np)

  # dr
  d[:Ns] = basis(x,centers,eps_array,diff=diff)[0,:]

  # dp
  d[Ns:] = dpoly(x[0,:],order,diff)

  return d


def shape_factor(nodes,s,basis,centers=None,alpha=None,cond=10,samples=100):
  '''
  The shape factor for stencil i, eps_i, is chosen by
 
    eps_i = alpha/mu_i                  
 
  where mu_i is the mean shortest path between nodes in stencil i. and 
  alpha is a proportionality constant.  This function assumes the same 
  alpha for each stencil.  If alpha is not given then an alpha is estimated
  which produces the desired condition number for the Vandermonde matrix 
  of each stencil. if alpha is given then cond does nothing.  This funtion
  returns eps_i for each stencil
  '''
  if centers is None:
    centers = nodes

  nodes = np.asarray(nodes,dtype=float)
  s = np.asarray(s,dtype=int)
  centers = np.asarray(centers,dtype=float)

  if alpha is None:
    alpha_list = []
    for si in random.sample(s,samples):
      eps = condition_based_shape_factor(nodes[si,:],centers[si,:],basis,cond)
      if eps is not None:
        T = scipy.spatial.cKDTree(centers[si,:])
        dx,idx = T.query(centers[si,:],2)
        mu = np.mean(dx[:,1])
        alpha_list += [eps*mu]

    if len(alpha_list) == 0:
      raise ValueError(
        'did not find a shape parameters which produces the desired '
        'condition number for any stencils')
  
    alpha = np.mean(alpha_list)
    logger.info('using shape parameter %s' % alpha)

  eps_list = np.zeros(s.shape[0])
  for i,si in enumerate(s):
    T = scipy.spatial.cKDTree(centers[si,:])
    dx,idx = T.query(centers[si,:],2)
    mu = np.mean(dx[:,1])
    eps_list[i] = alpha/mu

  return eps_list


def condition_based_shape_factor(nodes,centers,basis,cond):
  nodes = np.asarray(nodes)
  centers = np.asarray(centers)
  def system(eps):
    A = basis(nodes,centers,eps[0]*np.ones(len(nodes)))
    cond = np.linalg.cond(A)
    return np.array([np.log10(cond)])

  T = scipy.spatial.cKDTree(centers)
  dist,idx = T.query(centers,2)
  # average shortest distance between nodes
  dx = np.mean(dist[:,1])
  eps = [0.1/dx]
  eps,pred_cond = modest.nonlin_lstsq(system,[cond],
                                      eps,
                                      solver=modest.nnls,
                                      atol=1e-2,rtol=1e-8,
                                      LM_param=1e-2,
                                      maxitr=500,
                                      output=['solution','predicted'])
  if np.abs(pred_cond - cond) > 1e-2:
    logger.warning(
      'did not find a shape parameter which produces the desired '
      'condition number')  
    return None

  else:
    return eps[0]


def is_operator(diff):
  '''
  Description
  -----------
    diff can either be a tuple describing the differentiation order in
    each direction, e.g. (0,0,1), or it can describe a differential
    operator, e.g. [(1,(0,0,1)),(2,(0,1,0))], where each element
    contains a coefficient and differentiation tuple for each term in
    the operator. This function returns true if diff is describing an
    operator.

  '''
  # if each element in diff is iterable then return True. This returns
  # True if diff is an empty list 
  if all(hasattr(d,'__iter__') for d in diff):
    return True
  else:
    return False


def rbf_weight(x,nodes,diff,centers=None,basis=rbf.basis.phs5,order='max',eps=1.0):
  '''
  Description
  -----------
    Finds the finite difference weights, w_i, such that 

      L[f(x)] \approx \sum_i w_i*f(n_i)

    where n_i are the provided nodes and L is a differential operaotor
    specified with the diff argument.  The weights are found by
    assuming that the function, f(x), consists of a linear combination
    of M monomial terms, p_i(x), and radial basis functions, r(x),
    with N centers, c_i

      f(x) = \sum_i a_i*r(||x - c_i||) + \sum_i b_i*p_i(x)

    To ensure an equal number of equations and unknown parameters, we
    add M constaints to the parameters a_i
    
      \sum_i a_i*p_j(n_i) = 0.

    The weights are then found by solving the following linear system
 
      | r(||n_0-c_0||) ... r(||n_N-c_0||) p_0(n_0) ... p_M(n_0) |    
      |       :         :        :          :             :     | 
      | r(||n_0-c_N||) ... r(||n_N-c_N||) p_0(n_N) ... p_M(n_N) | w = d    
      |    p_0(n_0)    ...    p_0(n_N)                          |    
      |       :        ...       :                  0           |    
      |    p_M(n_0)    ...    p_M(n_N)                          |    

    where d is

          | L[r(||y-c_o||)]|_y=x |
          |         :            |
      d = | L[r(||y-c_N||)]|_y=x |
          |    L[p_0(y)]|_y=x    |
          |         :            |
          |    L[p_M(y)]|_y=x    |


  Parameters
  ----------
    x: 
    nodes:
    diff:
    centers:
    basis:
    order:
    eps:

  '''
  x = np.array(x,dtype=float,copy=True)
  nodes = np.array(nodes,dtype=float,copy=True)
  if centers is None:
    centers = nodes

  centers = np.array(centers,dtype=float,copy=True)

  if order == 'max':
    order = maximum_order(*nodes.shape)

  # center about x
  centers -= x
  nodes -= x 
  x -= x

  # number of polynomial terms that will be used
  Np = monomial_count(order,x.shape[0])
  assert Np <= nodes.shape[0], (
    'the number of monomials exceeds the number of RBFs for the '
    'stencil. Lower the polynomial order or ' 
    'increase the stencil size')

  A = vrbf(nodes,centers,eps,order,basis)
  if is_operator(diff):
    d = np.zeros(nodes.shape[0] + Np)
    for coeff,diff_tuple in diff:
      d += coeff*drbf(x,centers,eps,order,diff_tuple,basis)

  else:
    d = drbf(x,centers,eps,order,diff,basis)

  w = np.linalg.solve(A,d)[:nodes.shape[0]]

  return w 


def poly_weight(x,nodes,diff):
  '''
  finds the weights, w, such that

  f_i(c_j) = c_j**i

  | f_0(c_0) ... f_0(c_N) |     | L[f_0(y)]y=x  |
  |    :             :    | w = |     :         |
  | f_N(c_0) ... f_N(c_N) |     | L[f_N(y)]y=x  |
  '''
  x = np.array(x,copy=True)
  nodes = np.array(nodes,copy=True)
  order = rbf.weights.maximum_order(*nodes.shape)
  Np = rbf.weights.monomial_count(order,nodes.shape[1])
  assert Np == nodes.shape[0], (
    'the number of nodes in a 2D stencil needs to be 1,3,6,10,15,21,... '
    'the number of nodes in a 3D stencil needs to be 1,4,10,20,35,56,... ')
  nodes -= x
  x -= x
  A =  vpoly(nodes,order)
  d =  dpoly(x,order,diff) 
  w = np.linalg.solve(A,d)
  return w 
