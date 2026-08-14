#!/bin/bash
#SBATCH -A hpcl-cli185
#SBATCH -p parallel
#SBATCH -q normal
#SBATCH --job-name=test_module_load
#SBATCH --constraint=BL
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=00:05:00
#SBATCH --output=/projects/hpcl-cli185/proj-shared/zw5/E3SM/jobs/test_module_load.%j.out

set -x
source /software/baseline/nsp/lmod/8.7.37/init/sh
module purge
echo "=== attempt 1: single combined load ==="
module load miniforge3/24.11.3-0 DefApps cmake/3.30.5 gcc/12.4.0 openmpi/5.0.5 netlib-lapack/3.11.0 hdf5/1.14.5-mpi netcdf-c/4.9.2-mpi-h5f netcdf-cxx/4.2-mpi netcdf-fortran/4.6.1-mpi-h5f parallel-netcdf/1.12.3-mpi
echo "exit code: $?"
module list

echo "=== attempt 2: one at a time ==="
module purge
module load miniforge3/24.11.3-0
echo "after miniforge3: $?"
module load DefApps
echo "after DefApps: $?"
module load cmake/3.30.5
echo "after cmake: $?"
module load gcc/12.4.0
echo "after gcc: $?"
module load openmpi/5.0.5
echo "after openmpi: $?"
module list
