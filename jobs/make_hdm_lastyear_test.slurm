#!/bin/bash
#SBATCH -A hpcl-cli185
#SBATCH -p hpcl-cli185
#SBATCH -q hpcl-cli185
#SBATCH --job-name=make_hdm_lasttest
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=00:10:00
#SBATCH --output=/projects/hpcl-cli185/proj-shared/zw5/e3sm_run/20260717_hdm_highres_smoke/run/make_hdm_lastyear_test.%j.out

set -euo pipefail
unset SLURM_EXPORT_ENV

module purge
module load Core/25.05
module load gcc/12.4.0
module load openmpi/5.0.5
module load nco/5.2.4-mpi

SOURCE=/projects/hpcl-cli185/proj-shared/zw5/ELM_makeSurfdata/Make_surface_data/s8_update_hdm/elmforc.Li_hdm_1_24x1_24_bilinear_SEUS_simyr1850-2100.nc
OUTPUT=/projects/hpcl-cli185/proj-shared/zw5/e3sm_run/20260717_hdm_highres_smoke/run/hdm_last_record_year1849_test.nc

ncks -O -d time,250,250 "${SOURCE}" "${OUTPUT}"
ncap2 -O -s 'year(:)=1849' "${OUTPUT}" "${OUTPUT}"
ncks -H -C -v year "${OUTPUT}"
