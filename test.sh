#!/bin/bash

BLUD="../blud"
cd ./test || { echo "Failed to change directory to ./test"; exit 1; }

run_test() {
    local test_name=$1

    # rm -f "${test_name}.out" "${test_name}.luac" 

    echo "$BLUD -f ${test_name}"
    if ! $BLUD -f "${test_name}" ; then
        echo "$BLUD -f ${test_name}  failed on: ${test_name}"
        exit 2
    fi
    # Check if the output file was created
    if [ ! -f "${test_name}.out" ]; then
        echo "Output file missing after test: ${test_name}"
        exit 3
    fi
}

# Check if a specific test name was given
if [ -n "$1" ]; then
    # Run the specified test
    run_test "$1"
else
    test_files=(test[0-9][0-9][0-9][0-9]{.blud,})
    echo "test files: ${test_files[@]}"
    for test_file in "${test_files[@]}"; do
        # Extract the test name without file extension if needed
        test_name=$(basename -s .blud "$test_file")
        # Run the test
        run_test "$test_name"
    done
fi

echo "All tests completed successfully."
