#!/bin/bash
#SBATCH -A hpcl-cli185
#SBATCH -p parallel
#SBATCH -q normal
#SBATCH --job-name=manual_build_ndep_fix
#SBATCH --constraint=BL
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --mem=120G
#SBATCH --time=00:45:00
#SBATCH --output=/projects/hpcl-cli185/proj-shared/zw5/E3SM/jobs/manual_build_ndep_fix.%j.out

set -x
source /software/baseline/nsp/lmod/8.7.37/init/sh
module purge
module load miniforge3/24.11.3-0
module load DefApps
module load cmake/3.30.5
module load gcc/12.4.0
module load openmpi/5.0.5
module load netlib-lapack/3.11.0
module load hdf5/1.14.5-mpi
module load netcdf-c/4.9.2-mpi-h5f
module load netcdf-cxx/4.2-mpi
module load netcdf-fortran/4.6.1-mpi-h5f
module load parallel-netcdf/1.12.3-mpi
module list

export HDF5_ROOT=${OLCF_HDF5_ROOT}
export NETCDF_C_PATH=${OLCF_NETCDF_C_ROOT}
export NETCDF_FORTRAN_PATH=${OLCF_NETCDF_FORTRAN_ROOT}
export PNETCDF_PATH=${OLCF_PARALLEL_NETCDF_ROOT}
export BLASLAPACK_LIBDIR=${OLCF_NETLIB_LAPACK_ROOT}/lib64
export PETSC_PATH=/projects/hpcl-cli185/proj-shared/ccsi-apps/petsc-3.x-noopt/
env | grep -E 'OLCF_|NETCDF|PNETCDF|HDF5_ROOT|BLASLAPACK'

which gfortran mpif90 cmake

BLD=/projects/hpcl-cli185/proj-shared/zw5/e3sm_run/20260712_Southeast_hires_s7P_s8hdm_ICB1850CNRDCTCBC_ad_spinup/bld
cd "${BLD}/cmake-bld"
make -j32 e3sm.exe
echo "make exit code: $?"

ls -la "${BLD}/e3sm.exe"
