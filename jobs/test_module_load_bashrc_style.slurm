#!/bin/bash
#SBATCH -A hpcl-cli185
#SBATCH -p parallel
#SBATCH -q normal
#SBATCH --job-name=test_module_bashrc_style
#SBATCH --constraint=BL
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=00:05:00
#SBATCH --output=/projects/hpcl-cli185/proj-shared/zw5/E3SM/jobs/test_module_bashrc_style.%j.out

set -x
source /software/baseline/nsp/lmod/8.7.37/init/sh

echo "=== run 1: exactly like .bashrc, one at a time, no explicit gcc/openmpi ==="
module purge
module load miniforge3/24.11.3-0
echo "after miniforge3: $?"
module load DefApps
echo "after DefApps: $?"
module load cmake/3.30.5
echo "after cmake: $?"
module load netlib-lapack/3.11.0
echo "after netlib-lapack: $?"
module load hdf5/1.14.5-mpi
echo "after hdf5: $?"
module load netcdf-c/4.9.2-mpi-h5f
echo "after netcdf-c: $?"
module load netcdf-cxx/4.2-mpi
echo "after netcdf-cxx: $?"
module load netcdf-fortran/4.6.1-mpi-h5f
echo "after netcdf-fortran: $?"
module load parallel-netcdf/1.12.3-mpi
echo "after parallel-netcdf: $?"
module list

echo ""
echo "=== run 2 (repeat, same node/session, check reproducibility) ==="
module purge
module load miniforge3/24.11.3-0
echo "after miniforge3: $?"
module load DefApps
echo "after DefApps: $?"
module load cmake/3.30.5
echo "after cmake: $?"
module load netlib-lapack/3.11.0
echo "after netlib-lapack: $?"
module load hdf5/1.14.5-mpi
echo "after hdf5: $?"
module load netcdf-c/4.9.2-mpi-h5f
echo "after netcdf-c: $?"
module load netcdf-cxx/4.2-mpi
echo "after netcdf-cxx: $?"
module load netcdf-fortran/4.6.1-mpi-h5f
echo "after netcdf-fortran: $?"
module load parallel-netcdf/1.12.3-mpi
echo "after parallel-netcdf: $?"
module list
