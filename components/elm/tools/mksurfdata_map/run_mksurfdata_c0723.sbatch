#!/bin/bash
#SBATCH -J mksurf_c0723
#SBATCH -A hpcl-cli185
#SBATCH -p hpcl-cli185
#SBATCH -q hpcl-cli185
#SBATCH -N 1
#SBATCH -n 1
#SBATCH -c 8
#SBATCH --mem=128g
#SBATCH -t 08:00:00
#SBATCH -o /projects/hpcl-cli185/proj-shared/zw5/E3SM/components/elm/tools/mksurfdata_map/mksurf_c0723_%j.out
#SBATCH -e /projects/hpcl-cli185/proj-shared/zw5/E3SM/components/elm/tools/mksurfdata_map/mksurf_c0723_%j.err

unset SLURM_EXPORT_ENV
set -euo pipefail

module purge
module load gcc/12.4.0
module load openmpi/5.0.5
module load hdf5/1.14.5-mpi
module load netcdf-c/4.9.2-mpi-h5f
module load netcdf-fortran/4.6.1-mpi-h5f

cd /projects/hpcl-cli185/proj-shared/zw5/E3SM/components/elm/tools/mksurfdata_map

echo "Start : $(date)  Node: $(hostname)"
echo "-------------------------------------------------------------"
# Proven single-process invocation (same as interactive run in the s5 doc).
./mksurfdata_map < namelist
echo "-------------------------------------------------------------"
echo "End   : $(date)"
