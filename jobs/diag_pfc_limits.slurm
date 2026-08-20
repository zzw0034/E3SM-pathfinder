#!/bin/bash
#SBATCH -A hpcl-cli185
#SBATCH -p parallel
#SBATCH -q normal
#SBATCH --job-name=diag_pfc_limits
#SBATCH --constraint=PF
#SBATCH --nodes=1
#SBATCH --ntasks=84
#SBATCH --ntasks-per-node=84
#SBATCH --cpus-per-task=1
#SBATCH --mem=750g
#SBATCH --time=00:10:00
#SBATCH --output=/projects/hpcl-cli185/proj-shared/zw5/E3SM/jobs/diag_pfc_limits.%j.out

set -x
echo "=== batch script (submitting shell context) ulimits ==="
ulimit -a

echo ""
echo "=== /proc/sys shared memory settings on this node (via srun, single task) ==="
srun --export=ALL --ntasks=1 bash -c 'cat /proc/sys/kernel/shmmax; cat /proc/sys/kernel/shmall; cat /proc/sys/kernel/shmmni; echo "---ulimit inside srun task---"; ulimit -a; echo "---nproc---"; nproc; echo "---/dev/shm size---"; df -h /dev/shm'

echo ""
echo "=== ulimit -l as seen by EVERY one of the 84 srun-launched tasks ==="
ulimit -l unlimited
srun --export=ALL --nodes=1 --ntasks=84 --ntasks-per-node=84 bash -c 'ulimit -l' | sort | uniq -c

echo ""
echo "=== same but with --propagate=MEMLOCK explicitly ==="
srun --export=ALL --propagate=MEMLOCK --nodes=1 --ntasks=84 --ntasks-per-node=84 bash -c 'ulimit -l' | sort | uniq -c
