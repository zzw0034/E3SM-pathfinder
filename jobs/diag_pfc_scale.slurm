#!/bin/bash
#SBATCH -A hpcl-cli185
#SBATCH -p parallel
#SBATCH -q normal
#SBATCH --job-name=diag_pfc_scale
#SBATCH --constraint=PF
#SBATCH --nodes=2
#SBATCH --ntasks=168
#SBATCH --ntasks-per-node=84
#SBATCH --cpus-per-task=1
#SBATCH --mem=750g
#SBATCH --time=00:15:00
#SBATCH --output=/projects/hpcl-cli185/proj-shared/zw5/E3SM/jobs/diag_pfc_scale.%j.out

set -x
source /software/baseline/nsp/lmod/8.7.37/init/sh
module purge
module load miniforge3/24.11.3-0
module load DefApps
module load cmake/3.30.5
module load netlib-lapack/3.11.0
module load hdf5/1.14.5-mpi
module load netcdf-c/4.9.2-mpi-h5f
module load netcdf-cxx/4.2-mpi
module load netcdf-fortran/4.6.1-mpi-h5f
module load parallel-netcdf/1.12.3-mpi

EXE=/projects/hpcl-cli185/proj-shared/zw5/e3sm_run/20260712_Southeast_hires_s7P_s8hdm_ICB1850CNRDCTCBC_ad_spinup/bld/e3sm.exe

echo "########## 1 node, 4 tasks ##########"
srun --export=ALL --nodes=1 --ntasks=4 --ntasks-per-node=4 --cpu-bind=none -c 1 --time=00:01:00 timeout 20 $EXE 2>&1 | grep -i 'error\|out of resource\|MPI_Init\|Successfully' | head -5
echo "exit: $?"

echo "########## 1 node, 84 tasks (full node) ##########"
srun --export=ALL --nodes=1 --ntasks=84 --ntasks-per-node=84 --cpu-bind=none -c 1 --time=00:01:00 timeout 20 $EXE 2>&1 | grep -i 'error\|out of resource\|MPI_Init\|Successfully' | head -5
echo "exit: $?"

echo "########## 2 nodes, 8 tasks (multi-node, low count) ##########"
srun --export=ALL --nodes=2 --ntasks=8 --ntasks-per-node=4 --cpu-bind=none -c 1 --time=00:01:00 timeout 20 $EXE 2>&1 | grep -i 'error\|out of resource\|MPI_Init\|Successfully' | head -5
echo "exit: $?"

echo "########## 2 nodes, 168 tasks (full 2 nodes) ##########"
srun --export=ALL --nodes=2 --ntasks=168 --ntasks-per-node=84 --cpu-bind=none -c 1 --time=00:01:00 timeout 20 $EXE 2>&1 | grep -i 'error\|out of resource\|MPI_Init\|Successfully' | head -5
echo "exit: $?"
