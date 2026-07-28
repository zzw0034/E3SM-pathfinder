#!/bin/bash
#SBATCH -A hpcl-cli185
#SBATCH -p hpcl-cli185
#SBATCH -q hpcl-cli185
#SBATCH --job-name=check_hdm_smoke
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=00:10:00
#SBATCH --output=/projects/hpcl-cli185/proj-shared/zw5/e3sm_run/20260717_hdm_highres_smoke/run/check_hdm_smoke.%j.out

set -euo pipefail
unset SLURM_EXPORT_ENV

module purge
module load Core/25.05
module load gcc/12.4.0
module load openmpi/5.0.5
module load nco/5.2.4-mpi

RUN_DIR=/projects/hpcl-cli185/proj-shared/zw5/e3sm_run/20260717_hdm_highres_smoke/run
cd "${RUN_DIR}"

for input_file in \
  20260717_hdm_highres_smoke.elm.h0.1850-01-01-00000.nc \
  20260717_hdm_highres_smoke.elm.h0.1850-01-01-03600.nc
do
  stats_file="${input_file%.nc}.HDM_stats.nc"
  ncap2 -O -v -s 'HDM_min=HDM.min();HDM_max=HDM.max();HDM_avg=HDM.avg()' \
    "${input_file}" "${stats_file}"
  echo "${input_file}"
  ncks -H -C -v HDM_min,HDM_max,HDM_avg "${stats_file}"
done
