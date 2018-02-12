#!/bin/bash
. ../config_params.sh
. ../utilities/lib_utils.sh

../utilities/check_dependencies.sh bash awk gnuplot
if [[ $? -ne 0 ]]; then
	exit
fi

# see the following string for usage, or invoke ./run_main_benchmarks.sh -h
usage_msg="\
Usage (as root):\n\
./run_main_benchmarks.sh [fs|raw] [<set of benchmarks>] [<set of schedulers>] [also-rand]

If fs mode is selected, or if no value, i.e., \"\", is given, then file
reads and writes are used as background workloads. Instead, if raw
mode is selected, then only raw reads are executed in the background
workloads (this option also avoids intense writes). Raw mode is not
yet implemented.

If also-rand is passed, then also random background workloads are considered.

The set of benchmarks can be built out of the following benchmarks:
throughput startup replaied-startup fairness video-playing kernel-devel interleaved-io

If no set or an empty set, i.e., \"\", is given, then all benchmarks are
executed.

If no set of schedulers or an empty set of schedulers, i.e., \"\", is
given, then all available schedulers are tested.

Examples
# run all available benchmarks for all available schedulers, using fs
sudo ./run_main_benchmarks.sh

# run all available benchmarks for all available schedulers, using raw device
sudo ./run_main_benchmarks.sh raw

# run selected benchmarks for all available schedulers, using fs
sudo ./run_main_benchmarks.sh \"\" \"throughput startup\"

# run selected benchmarks for cfq and noop, using fs
sudo ./run_main_benchmarks.sh \"\" \"throughput startup\" \"cfq noop\"

"

MODE=${1-}
BENCHMARKS=${2-}
SCHEDULERS=${3-}

if [[ "$4" == also-rand ]]; then
    RAND_WL=yes
fi

# number of time each type of benchmark is repeated: increase this
# number to increase the accuracy of the results
NUM_REPETITIONS=2
NUM_ITER_STARTUP=$NUM_REPETITIONS # number of iterations for each repetition
# only two iterations for video playing: every single playback already
# provides many fram-drop samples
NUM_ITER_VIDEO=2
cur_date=`date +%y%m%d_%H%M`
RES_DIR=../results/run_main_benchmarks/$cur_date

# startup test cases
testcases=(xterm_startup gnome_terminal_startup lowriter_startup)
# replaied-startup test cases
replaied_testcases=(replaied_xterm_startup replaied_gnome_terminal_startup replaied_lowriter_startup)
# reference start-up times for test cases, will be set during execution
reftimes=(0 0 0)
# command for each test case
commands=("xterm /bin/true" "gnome-terminal -e /bin/true" "lowriter --terminate_after_init")
# replay command for each replaied-startup test case
replay_commands=("replay-startup-io xterm" "replay-startup-io gnometerm" "replay-startup-io lowriter")

function send_partial_stats
{
	if [ "$MAIL_REPORTS" == "1" ]; then
		if [ "$MAIL_REPORTS_RECIPIENT" == "" ]; then
			echo "WARNING: missing recipient name for mail reports"
			return
		fi
		KVER=`uname -r`
		echo -e "*** Stats for $1 on $HNAME with kernel $KVER ***\n" \
		     "$(cat $2)" | \
			mail -s "Stats for $1 on $HNAME" $MAIL_REPORTS_RECIPIENT
	fi
}

function send_email
{
	if [ "$MAIL_REPORTS" == "1" ]; then
		if [ "$MAIL_REPORTS_RECIPIENT" == "" ]; then
			echo "WARNING: missing recipient name for mail reports"
			return
		fi
		HNAME=`uname -n`
		KVER=`uname -r`
		TSTAMP=`date +%y%m%d_%H%M%S`
		echo "$1 on $HNAME with scheduler $sched and kernel $KVER at $TSTAMP" | \
			mail -s "$1 on $HNAME" $MAIL_REPORTS_RECIPIENT
	fi
}

function repeat
{
	test_suffix=$(echo $1 | sed 's/.*startup/startup/')
	if [ "$test_suffix" == startup ] ; then
		out_filename=$5
	else
		out_filename=$3
	fi

	mkdir -p $RES_DIR/$1
	for ((i = 0 ; $i < $NUM_REPETITIONS ; i++))
	do
		echo
		echo -n "Repetition $(($i + 1)) / $NUM_REPETITIONS "
		echo -n "[$sched ($sched_id/$num_scheds), "
		echo "$1 ($bench_id/$num_benchs)]"

		# make sure that I/O generators/monitors are dead
		# (sometimes shutdown does not work properly)
		sudo killall dd fio iostat 2> /dev/null
		if [ "$test_suffix" == startup ] ; then
			bash $2 "$3" $RES_DIR/$1/repetition$i $4
		else
			bash $2 $RES_DIR/$1/repetition$i
		fi
		if [[ "$out_filename" != "" && \
			! -f $RES_DIR/$1/repetition$i/$out_filename ]] ; then
		    echo Stats file $RES_DIR/$1/repetition$i/$out_filename not found
		    echo No stats produced: aborting repetitions for $1 $2 \"$3\"
		    break
		fi
		echo Syncing and waiting for a few seconds, to better mimick real usage,
		echo and let benchmarks start in more homogeneous conditions.
		sync
		sleep 2
	done

	if [[ $1 == interleaved-io || $1 == kernel_devel \
	    || $1 == fairness ]]; then # no overall stats
	    return
	fi

	cur_dir_repetitions=`pwd`
	cd ../utilities
	./calc_overall_stats.sh $RES_DIR/$1 "${SCHEDULERS[@]}"
	strid="$2"
	if [[ "$3" != "" ]]; then
		strid="$strid $3"
	fi
	send_partial_stats "$strid" $RES_DIR/$1/overall_stats-$1.txt
	cd $cur_dir_repetitions
}

function throughput
{
	cd ../agg_thr-with-greedy_rw

	wl_id=1
        for ((w=0 ; w<${#thr_workloads[@]};w++)); do
	    wl=${thr_workloads[w]}
	    echo
	    echo Testing workload \"$wl\" \($wl_id/${#thr_workloads[@]}\)
	    repeat throughput "aggthr-with-greedy_rw.sh $1 $wl" \
		$1-${thr_wl_infix[w]}-10sec-aggthr_stat.txt
	    ((++wl_id))
	done
}

function kernel-devel
{
	cd ../kern_dev_tasks-vs-rw

	wl_id=1
        for ((w=0 ; w<${#kern_workloads[@]};w++)); do
	    wl=${kern_workloads[w]}
	    echo
	    echo Testing workload \"$wl\" \($wl_id/${#kern_workloads[@]}\)
	    repeat make "kern_dev_tasks_vs_rw.sh $1 $wl make"
	    ((++wl_id))
	done

	repeat git-grep "kern_dev_tasks_vs_rw.sh $1 0 0 seq grep"
}

function do_startup
{
	cd ../comm_startup_lat

	wl_id=1
        for ((w=0 ; w<${#latency_workloads[@]};w++)); do
	    wl=${latency_workloads[w]}
	    echo
	    echo Testing workload \"$wl\" \($wl_id/${#latency_workloads[@]}\)
            for ((t=0 ; t<${#actual_testcases[@]} ; ++t)); do
                        repeat ${actual_testcases[t]} \
			    "comm_startup_lat.sh $1 $wl $NUM_ITER_STARTUP" \
                                "${cmd_lines[t]}" "60 ${reftimes[t]}" \
			    $1-${wl_infix[w]}-lat_thr_stat.txt

                        # If less than 2 repetitions were completed for this
                        # testcase, abort all heavier testcases
                        if [ $NUM_REPETITIONS -gt 1 ] && \
			   [ ! -f $RES_DIR/${actual_testcases[t]}/repetition1/$1-${wl_infix[w]}-lat_thr_stat.txt ]; then
                                break
                        fi
			if [[ $wl == "0 0 seq" ]]; then
			    stat_file=$RES_DIR/${actual_testcases[t]}/overall_stats-${actual_testcases[t]}.txt
			    reftimes[t]=$(head -n 5 $stat_file | tail -n 1 | \
				awk '{print $2;}')
			    TOOSMALL=$(echo "${reftimes[t]} <= 0.001" | bc -l)
			    if [ "$TOOSMALL" == 1 ]; then
				reftimes[t]=0.01
			    fi
			fi
                done
	((++wl_id))
	done
}

function startup
{
    cmd_lines=("${commands[@]}")
    actual_testcases=("${testcases[@]}");

    do_startup $1
}

function replaied-startup
{
    cmd_lines=("${replay_commands[@]}")
    actual_testcases=("${replaied_testcases[@]}");

    do_startup $1
}

function interleaved-io
{
	cd ../interleaved_io
	# dump emulation
	repeat interleaved-io "interleaved_io.sh $1 3"

	# more interleaved readers
	repeat interleaved-io "interleaved_io.sh $1 5"
	repeat interleaved-io "interleaved_io.sh $1 6"
	repeat interleaved-io "interleaved_io.sh $1 7"
	repeat interleaved-io "interleaved_io.sh $1 9"
}

function video-playing
{
	cd ../video_playing_vs_commands

	type=real
	VIDEOCMD=video_play_vs_comms.sh

	wl_id=1
        for ((w=0 ; w<${#latency_workloads[@]};w++)); do
	    wl=${latency_workloads[w]}
	    echo
	    echo Testing workload \"$wl\" \($wl_id/${#latency_workloads[@]}\)
            repeat video_playing "$VIDEOCMD $1 $wl $NUM_ITER_VIDEO $type n" \
		$1-${wl_infix[w]}-video_playing_stat.txt
	    ((++wl_id))
        done
}

function fairness
{
	if [[ $1 != bfq && $1 != cfq ]]; then
		echo $1 has no fairness notion: exiting
		return
	fi

	cd ../fairness

	echo ./fairness.sh $1 2 3 200 seq 100 100
	./fairness.sh $1 2 3 200 seq 100 100

	echo ./fairness.sh $1 2 3 200 seq 100 200
	./fairness.sh $1 2 3 200 seq 100 200

	echo ./fairness.sh $1 2 3 200 seq 100 1000
	./fairness.sh $1 2 3 200 seq 100 1000

	# no overall stat files generated for this benchmark for the
	# moment: remove temporary results
	rm results-$1
}

# MAIN

if [ "$1" == "-h" ]; then
	printf "$usage_msg"
	exit
fi

if [[ "$MODE" == "" ]]; then
    MODE=fs
fi

# next four cases are mutually exclusive
if [[ "$MODE" == fs && "$RAND_WL" == yes ]]; then
    latency_workloads=("0 0 seq" "10 0 seq" "5 5 seq" "10 0 rand" "5 5 rand")
    wl_infix=("0r0w-seq" "10r0w-seq" "5r5w-seq" "10r0w-rand" "5r5w-rand")

    thr_workloads=("1 0 seq" "10 0 seq" "10 0 rand" "5 5 seq" "5 5 rand")
    thr_wl_infix=("1r0w-seq" "10r0w-seq" "10r0w-rand" "5r5w-seq" "5r5w-rand")

    kern_workloads=("0 0 seq" "10 0 seq" "10 0 rand")
fi
if [[  "$MODE" == raw && "$RAND_WL" == yes ]]; then
    latency_workloads=("0 0 raw_seq" "10 0 raw_seq" "10 0 raw_rand")
    wl_infix=("0r0w-raw_seq" "10r0w-raw_seq" "10r0w-raw_rand")

    thr_workloads=("1 0 raw_seq" "10 0 raw_seq" "10 0 raw_rand")
    thr_wl_infix=("1r0w-raw_seq" "10r0w-raw_seq" "10r0w-raw_rand")

    kern_workloads=("0 0 raw_seq" "10 0 raw_seq" "10 0 raw_rand")
fi
if [[ "$MODE" == fs && "$RAND_WL" != yes ]]; then
    latency_workloads=("0 0 seq" "10 0 seq" "5 5 seq")
    wl_infix=("0r0w-seq" "10r0w-seq" "5r5w-seq")

    thr_workloads=("1 0 seq" "10 0 seq" "5 5 seq")
    thr_wl_infix=("1r0w-seq" "10r0w-seq" "5r5w-seq")

    kern_workloads=("0 0 seq" "10 0 seq")
fi
if [[  "$MODE" == raw && "$RAND_WL" != yes ]]; then
    latency_workloads=("0 0 raw_seq" "10 0 raw_seq")
    wl_infix=("0r0w-raw_seq" "10r0w-raw_seq")

    thr_workloads=("1 0 raw_seq" "10 0 raw_seq")
    thr_wl_infix=("1r0w-raw_seq" "10r0w-raw_seq")

    kern_workloads=("0 0 raw_seq" "10 0 raw_seq")
fi

if [[ "$BENCHMARKS" == "" ]]; then
    ../utilities/check_dependencies.sh dd fio iostat time mplayer \
	git xterm gnome-terminal lowriter
    if [[ $? -ne 0 ]]; then
	exit
    fi

    BENCHMARKS="throughput startup video-playing"
fi

if [[ "$SCHEDULERS" == "" ]]; then
    SCHEDULERS="$(cat /sys/block/$DEV/queue/scheduler | \
	sed 's/\[//' | sed 's/\]//')"
fi

echo Tests beginning on $cur_date

if command -v tracker-control >/dev/null 2>&1; then
        echo Stopping services, check that they are restarted
        echo at the end of the tests!!
	echo systemctl stop crond.service
	systemctl stop crond.service
	echo systemctl stop abrtd.service
	systemctl stop abrtd.service
else
    if [ -f /etc/init.d/cron ]; then
        echo Stopping services, check that they are restarted
        echo at the end of the tests!!
	# this causes warnings if upstart is used ...
	echo /etc/init.d/cron stop
	/etc/init.d/cron stop
    fi
fi

if command -v tracker-control >/dev/null 2>&1; then
    echo tracker-control -r
    tracker-control -r
fi

rm -rf $RES_DIR
mkdir -p $RES_DIR

if [ "${NCQ_QUEUE_DEPTH}" != "" ]; then
    (echo ${NCQ_QUEUE_DEPTH} > /sys/block/${DEV}/device/queue_depth)\
		 &> /dev/null
    ret=$?
    if [[ "$ret" -eq "0" ]]; then
	echo "Set queue depth to ${NCQ_QUEUE_DEPTH} on ${DEV}"
    else
	echo Failed to set queue depth
	exit 1
    fi
fi

send_email "S main-benchmark run started"
echo Schedulers: $SCHEDULERS
echo Benchmarks: $BENCHMARKS

num_scheds=0
for sched in $SCHEDULERS; do
    ((++num_scheds))
done

num_benchs=0
for sched in $BENCHMARKS; do
    ((++num_benchs))
done

# main loop
sched_id=1
for sched in $SCHEDULERS; do
    bench_id=1
    for benchmark in $BENCHMARKS
    do
	echo
	echo -n "Testing $sched scheduler ($sched_id/$num_scheds) "
	echo "for $benchmark ($bench_id/$num_benchs)"
	send_email "$benchmark tests beginning"
	$benchmark $sched
	send_email "$benchmark tests finished"
	((++bench_id))
    done
    ((++sched_id))
done
send_email "S main-benchmark run finished"

echo
echo Computing overall stats
cd ../utilities
./calc_overall_stats.sh $RES_DIR "${SCHEDULERS[@]}"

if [[ test_X_access ]]; then
    ./plot_stats.sh $RES_DIR
fi
./plot_stats.sh $RES_DIR ref gif 1.55 print_tables

cur_date=`date +%y%m%d_%H%M`
echo
echo All test finished on $cur_date
echo

if command -v tracker-control >/dev/null 2>&1; then
	echo systemctl restart crond.service
	systemctl restart crond.service
	echo systemctl restart abrtd.service
	systemctl restart abrtd.service
else
        if [ -f /etc/init.d/cron ]; then
	    # this generates warnings if upstart is used ...
	    echo /etc/init.d/cron restart
	    /etc/init.d/cron restart
	fi
fi

if command -v tracker-control >/dev/null 2>&1; then
    echo tracker-control -s
    tracker-control -s
fi
