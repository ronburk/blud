#!/usr/bin/env bash
set -euo pipefail

cleanup()
{
    rm -f test/test0006.prerequisite test/test0006.target
    rm -f test/test0006.prerequisite.ran test/test0006.target.ran
}
trap cleanup EXIT

rm -f test0006.out
touch test/test0006.prerequisite test/test0006.target
touch test/test0006.prerequisite.ran test/test0006.target.ran

./blud -f test/test0006.blud test/test0006.target
cmp -s test/test0006.prerequisite.ran /dev/null
cmp -s test/test0006.target.ran /dev/null

./blud -B -f test/test0006.blud test/test0006.target
test -s test/test0006.prerequisite.ran
test -s test/test0006.target.ran

touch test0006.out
