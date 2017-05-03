#!/bin/bash
# helper script to bisect probabilistic test failures which can also loop
#
# CAUTION!!!! This kills any running bitcoind's as part of cleanup!
# Only run in an isolated test environment!
#
# it needs you to configure a bunch of parameters below, most urgently
# TEST_COMMAND, RECONFIGURE_BETWEEN_RUNS, STOP_ITERATIONS, ITERATION_TIMEOUT_SECS
# Read up on these in the comments below.
# In future, maybe it is possible to query these on first run, deposit them
# in a file and re-use the responses at further invocations.

# need this coreutils command to abort jobs which are deemed to loop
TIMEOUT_CMD=/usr/bin/timeout

# check that we have the timeout command, else abort with code 2
[ -x "${TIMEOUT_CMD}" ] || {
    echo "Error: this script needs ${TIMEOUT_CMD}"
    exit 2
}

# optional tool for use with "test_bitcoin" tests
# if not present, unit tests will be done sequentially
# the default below places it in user's bin/ because it may disappear
# in early commits, so it's good to put it in a safe place.
PARALLEL_TEST_TOOL=~/bin/gtest-parallel-bitcoin


############ Test run specific configuration ##########

# number of cores to use for building and parallel testing
NUM_CORES_TO_USE=5

# should we do autogen + configure before each build ?
# non-zero value means yes
RECONFIGURE_BETWEEN_RUNS=0

# if non-zero, remove the cache/ folder before each iteration
CLEAR_CACHE_BETWEEN_RUNS=1

# the command to test
TEST_COMMAND="qa/pull-tester/rpc-tests.py txn_doublespend.py --mineblock"

# number of iterations after which to stop and consider the test as passed
STOP_ITERATIONS=${1:-100}

# timeouts (in seconds) for one iteration
# if it takes longer than this, test is considered failed
ITERATION_TIMEOUT_SECS=${2:-180}


############ Platform specific configure instruction ##########

# helper function to do actual configure on my own machine.
# You might want to do things differently - I call this in do_configure()
_btcconfig()
{
    BOOST_VER=${1:-"1_58"}
    BTCDEBUG=${2:-""}
    ./configure CXXFLAGS="-I$HOME/include -I/opt/boost_${BOOST_VER}/include" $BTCDEBUG --prefix=$HOME --with-pic --disable-shared --enable-cxx LDFLAGS="-Wl,-rpath-link,/opt/boost_${BOOST_VER}/lib -Wl,-rpath,/opt/boost_${BOOST_VER}/lib -Wl,-rpath,/usr/local/BerkeleyDB.4.8/lib -Wl,-rpath,$HOME/lib -L/usr/local/BerkeleyDB.4.8/lib/ -L$HOME/lib/" CPPFLAGS="-I $HOME/include/ -I/usr/local/BerkeleyDB.4.8/include/" --with-boost=/opt/boost_${BOOST_VER} --with-boost-libdir=/opt/boost_${BOOST_VER}/lib
}


# helper function which does the configure according to what user can do.
# Cannot code a one-size-fits-all-test-platforms system, so you need to
# modify this according to the system you are testing on.
do_configure()
{
    _btcconfig 1_62 --without-miniupnpc
}


############ Misc utility function, no adaptation needed ##########

# contains(string, substring)
#
# Returns 0 if the specified string contains the specified substring,
# otherwise returns 1.
# from http://stackoverflow.com/a/8811800
contains() {
    string="$1"
    substring="$2"
    if test "${string#*$substring}" != "$string"
    then
        return 0    # $substring is in $string
    else
        return 1    # $substring is not in $string
    fi
}


############ beginning of actual test steps ############

# starting assumption is that git has just checked out a revision to test,
# and that our working area still contains build products from the test of
# the previous revision in the bisection.


# clear the build
echo "cleaning up from previous run..."
rm -rf cache
make clean


# if the reconfiguration has been enabled for this bisection, do it
if [ $RECONFIGURE_BETWEEN_RUNS -ne 0 ]
then
    do_configure
fi


# either way, must do a build now before we can test
echo "building..."
make -j ${NUM_CORES_TO_USE}

# start the test runs...
echo "testing for at most ${STOP_ITERATIONS} iterations"
echo "timeout is ${ITERATION_TIMEOUT_SECS} seconds per run..."
iteration=0
while :;
do
    iteration=$((++iteration))
    echo "`date`: iteration ${iteration}"

    # clear cache if necessary
    if [ $CLEAR_CACHE_BETWEEN_RUNS -ne 0 ]
    then
        rm -rf cache
    fi

    # check if we have parallel test runner
    contains "${TEST_COMMAND}" "test_bitcoin"
    is_test_bitcoin=$?
    if [ ${is_test_bitcoin} -eq 0 ]
    then
        if [ -x "${PARALLEL_TEST_TOOL}" ]
        then
            # check if it is a unit test bisection, then do parallel if possible
            # TODO : this may go wrong if test command is not simply
            # a Boost test binary, but a complex command with options.
            # This is just a first attempt, so need to refine later.
            timeout --foreground ${ITERATION_TIMEOUT_SECS} \
                    ${PARALLEL_TEST_TOOL} -w ${NUM_CORES_TO_USE} \
                    "${TEST_COMMAND}"
        else
            # no parallel execution
            timeout --foreground ${ITERATION_TIMEOUT_SECS} ${TEST_COMMAND}
        fi
    else
        timeout --foreground ${ITERATION_TIMEOUT_SECS} ${TEST_COMMAND}
    fi
    run_exit_code=$?
    if [ ${run_exit_code} -ne 0 ]
    then
        if [ ${run_exit_code} -ne 124 ]
        then
            killall bitcoind
            echo "failed during iteration ${iteration} with exit code: ${run_exit_code}"
            exit 1
        else
            # timed out
            killall bitcoind
            echo "timed out after ${ITERATION_TIMEOUT_SECS} seconds during iteration ${iteration}"
            echo "check if you need to adjust the timeout to be higher!"
            exit 1
        fi
    fi
    if [ ${iteration} -eq ${STOP_ITERATIONS} ]
    then
        echo "accepted test as passed after ${STOP_ITERATIONS} successful iterations"
        exit 0
    fi
done
