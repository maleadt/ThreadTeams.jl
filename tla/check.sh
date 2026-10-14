#!/bin/sh
# Model-check tla/HandOff.tla with TLC for one configuration.
#
#     tla/check.sh NAME [KEY=VALUE ...]
#
# NAME is the name of the run (its files go to tla/out/NAME), and the KEY=VALUEs override
# the constants of the model (N, TREE, BACKUP, SCENC, OrdCmd, ...; LIVE=0 skips the
# liveness property) starting from the orderings
# that src/pool.jl uses. Needs Java 11+ and tla2tools.jar from
# https://github.com/tlaplus/tlaplus/releases (set TLA2TOOLS to its path, default
# tla/tla2tools.jar). See tla/README.md for the configurations that were checked.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
name=$1; shift
jar=${TLA2TOOLS:-$dir/tla2tools.jar}
out=$dir/out/$name
mkdir -p "$out"

# the orderings of src/pool.jl
N=1; TREE=chain; SLEEPERS="{1}"; MAXSLEEP=1; BACKUP=TRUE; SCENC=fence; LIVE=1
OrdRegion=rlx; OrdCmd=rel; OrdFence=sc; OrdWakeSlp=sc; OrdWakeCmd=sc
OrdSteal=acq; OrdStealCAS=sc; OrdIdle=acq; OrdBackup=sc
OrdSpin=acq; OrdClaim=sc; OrdClaimFail=sc; OrdSleep=sc; OrdSleepCheck=sc; OrdAwake=sc
OrdDone=rel
for kv in "$@"; do eval "$kv"; done

{
    echo "SPECIFICATION Spec"
    echo "CONSTANTS N = $N"
    echo "          TREE = \"$TREE\""
    echo "          SLEEPERS = $SLEEPERS"
    echo "          MAXSLEEP = $MAXSLEEP"
    echo "          BACKUP = $BACKUP"
    echo "          SCENC = \"$SCENC\""
    for o in OrdRegion OrdCmd OrdFence OrdWakeSlp OrdWakeCmd OrdSteal OrdStealCAS OrdIdle \
             OrdBackup OrdSpin OrdClaim OrdClaimFail OrdSleep OrdSleepCheck OrdAwake OrdDone; do
        eval "echo \"          $o = \\\"\$$o\\\"\""
    done
    echo "INVARIANTS ExactlyOnce AllRun FreshRegion ResultsVisible NoWorkerLeftBehind"
    [ "$BACKUP" = FALSE ] && echo "INVARIANTS WakeupDelivered"
    [ "$LIVE" = 1 ] && echo "PROPERTIES Terminates"
} > "$out/HandOff.cfg"
cp "$dir/HandOff.tla" "$out/"
cd "$out"
# -deadlock: a state without successors is not an error (the region is over and the
# workers sleep)
java -XX:+UseParallelGC -Xmx24g -cp "$jar" tlc2.TLC -config HandOff.cfg -deadlock \
    -workers auto -metadir "$out/states" -nowarning HandOff.tla > tlc.log 2>&1 || true
if grep -q "Model checking completed. No error has been found" tlc.log; then
    echo "$name: OK ($(grep -o '[0-9,]* distinct states' tlc.log | tail -1))"
elif grep -q "Error:" tlc.log; then
    echo "$name: FAILED: $(grep -m1 'Error:' tlc.log | sed 's/^Error: //')"
else
    echo "$name: TLC did not finish, see $out/tlc.log"
    tail -5 tlc.log
fi
