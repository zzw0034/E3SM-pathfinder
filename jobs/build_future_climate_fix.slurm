#!/bin/bash
#SBATCH -A hpcl-cli185
#SBATCH -p parallel
#SBATCH -q normal
#SBATCH --job-name=build_future_climate_fix
#SBATCH --constraint=BL
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --mem=120G
#SBATCH --time=00:30:00
#SBATCH --output=/projects/hpcl-cli185/proj-shared/zw5/e3sm_cases/20260712_Southeast_hires_s7P_s8hdm_ICB1850CNRDCTCBC_ad_spinup/build_future_climate_fix.%j.out

set -euo pipefail
unset SLURM_EXPORT_ENV
export OMP_NUM_THREADS=1

CASE_ROOT=/projects/hpcl-cli185/proj-shared/zw5/e3sm_cases/20260712_Southeast_hires_s7P_s8hdm_ICB1850CNRDCTCBC_ad_spinup
cd "${CASE_ROOT}"

./case.build
echo "case.build exit code: $?"
