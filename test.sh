#!/bin/bash

BLUD="../blud"
cd ./test || { echo "Failed to change directory to ./test"; exit 1; }

get_expected() {
    local file="$1"
    local first_line

    IFS= read -r first_line < "$file" || return 1

    case "$first_line" in
        "-- expect:"*)
            # strip prefix
            first_line="${first_line#-- expect:}"
            # trim leading whitespace
            first_line="${first_line#"${first_line%%[![:space:]]*}"}"
            if [ -n "$first_line" ]; then
                echo "$first_line"
                return
            fi
            ;;
    esac

    # default: replace .blud with .out
    echo "${file%.blud}.out"
}

run_test() {
    local test_name=$1

    # rm -f "${test_name}.out" "${test_name}.luac" 

    echo "$BLUD -f ${test_name}"
    if ! $BLUD -f "${test_name}" ; then
        echo "$BLUD -f ${test_name}  failed on: ${test_name}"
        exit 2
    fi
    # for each expected output file
    for f in $(get_expected "$test_name"); do
        # Check if the output files were created
        if [ ! -f "$f" ]; then
            echo "Output file missing after test: ${f}"
            exit 3
        fi
    done
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
