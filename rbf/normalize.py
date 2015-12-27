#!/usr/bin/env python
from __future__ import division
import numpy as np
from rbf.halton import Halton
from rbf.geometry import boundary_contains
from rbf.geometry import is_valid
import logging 
from modest import funtime
logger = logging.getLogger(__name__)


@funtime
def mcint(f,vert,smp,N=None):
  '''
  Monte Carlo integration of a function that takes a (M,2) or (M,3)
  array of points and returns an (M,) vector. vert and smp are the
  vertices and simplices which define the bounds of integration. N
  is the number of samples.
  '''
  assert is_valid(smp), (
    'invalid simplices, see documentation for rbf.geometry.is_valid')
  sample_size = 1000000  
  lb = np.min(vert,0)
  ub = np.max(vert,0)
  dim = lb.shape[0]
  soln = 0 
  count = 0
  H = Halton(dim)
  if N is None:
    N = 200**dim

  while count < N:
    if (count + sample_size) > N:
      sample_size = N - count

    pnts = H(sample_size)*(ub-lb) + lb
    val = f(pnts)
    val = val[boundary_contains(pnts,vert,smp)]

    soln += np.sum(val)*np.prod(ub-lb)
    count += sample_size
    
  soln /= N
  return soln


@funtime
def mcmax(f,vert,smp,N=None):
  '''
  Monte Carlo estimation of the maximum of a function that takes a
  (M,2) or (M,3) array of points and returns an (M,) vector. vert and
  smp are the vertices and simplices which define the bounds over which
  a maximum will be estimated. N is the number of samples.
  '''
  assert is_valid(smp), (
    'invalid simplices, see documentation for rbf.geometry.is_valid')

  sample_size = 1000000  
  lb = np.min(vert,0)
  ub = np.max(vert,0)
  dim = lb.shape[0]
  soln = -np.inf
  count = 0
  H = Halton(dim)
  if N is None:
    N = 200**dim

  while count < N:
    if (count + sample_size) > N:
      sample_size = N - count

    pnts = H(sample_size)*(ub-lb) + lb
    val = f(pnts)
    val = val[boundary_contains(pnts,vert,smp)]    

    maxval = np.max(val)
    if maxval > soln:
      soln = maxval
    
    count += sample_size

  return soln


def normalize(fin,vert,smp,kind='integral',N=None,nodes=None):
  '''
  normalize a function that takes a (N,1) array and returns an (N,)
  array. The kind of normalization is specified with "kind", which can
  either be "integral" to normalize so that the function integrates to
  1.0, "max" so that the maximum value is 1.0, or "density" so that
  the function returns a node density with "nodes" being the total
  number of nodes in the domain
  '''
  if kind == 'integral':
    denom = mcint(fin,vert,smp,N=N)
  if kind == 'max':
    denom = mcmax(fin,vert,smp,N=N)

  if kind == 'density':
    if nodes is None:
      raise ValueError(
        'must specify number of nodes with "nodes" key word argument '
        'if normalizing by density')

    denom = mcint(fin,vert,smp,N=N)/nodes

  if denom == 0.0:
    raise ValueError(
      'normalized function by 0, this may be due to to an '
      'insufficiently large MC integration sample size')

  def fout(p):
    return fin(p)/denom

  return fout


def normalize_decorator(*args,**kwargs):
  def dout(fin):
    fout = normalize(fin,*args,**kwargs)
    return fout
  return dout