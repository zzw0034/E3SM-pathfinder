#!/bin/bash
# Build mksurfdata_map on Pathfinder (pflogin*.ornl.gov).
# Verified working 2026-07-12 with gcc/12.4.0 + openmpi/5.0.5 spack stack.
#
# Usage:  source this file (or just run it) from a login shell, then it builds src/.
#   cd /projects/hpcl-cli185/proj-shared/zw5/E3SM/components/elm/tools/mksurfdata_map
#   bash build_pathfinder.sh
set -e

# 1) Compiler + MPI + I/O libraries (same module names as Baseline; all present on Pathfinder)
module purge
module load gcc/12.4.0
module load openmpi/5.0.5
module load hdf5/1.14.5-mpi
module load netcdf-c/4.9.2-mpi-h5f
module load netcdf-fortran/4.6.1-mpi-h5f

# 2) NETCDF_HOME / HDF5_HOME. On this stack the modules set no NETCDF_DIR/OLCF_* vars,
#    so we fall back to nf-config / nc-config (both resolve to the spack install dirs).
export NETCDF_HOME=${OLCF_NETCDF_FORTRAN_ROOT:-${NETCDF_DIR:-$NETCDF_ROOT}}
[[ -z "$NETCDF_HOME" ]] && export NETCDF_HOME=$(nf-config --prefix)
export HDF5_HOME=${OLCF_HDF5_ROOT:-${HDF5_DIR:-$HDF5_ROOT}}
[[ -z "$HDF5_HOME" ]] && export HDF5_HOME=$(nc-config --prefix)

# 3) Makefile variables
export LIB_NETCDF=$NETCDF_HOME/lib
export INC_NETCDF=$NETCDF_HOME/include
export USER_FC=mpifort
export USER_CC=mpicc
export USER_LDFLAGS="$(nc-config --libs) $(nf-config --flibs)"

# 4) gfortran 12 needs THREE compatibility flags for this older E3SM source:
#      -fallow-invalid-boz       : nanMod.F90 octal BOZ literals
#      -fallow-argument-mismatch : nf_def_var/nf_put_var_int called with array & scalar (rank mismatch)
#      -ffree-line-length-none   : long attribute strings in mkfileMod.F90 exceed 132 cols
#    (The Baseline note only listed -fallow-invalid-boz; the other two are required here.)
export USER_FFLAGS="-fallow-invalid-boz -fallow-argument-mismatch -ffree-line-length-none"

# 5) Build
cd "$(dirname "$0")/src"
gmake clean
gmake -j 8

echo "Built: $(cd .. && pwd)/mksurfdata_map"
