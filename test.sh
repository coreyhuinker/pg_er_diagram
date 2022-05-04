#!/bin/bash

#
# Generate the test output file erd.svg
#
PGDATABASE=dvdrental PGERD_FILE_PREFIX=test_output/ ./pg_erd.sh
#
# Generate the dvdrental_* output files usin all available options and export them rather than inline
#
export PGDATABASE=dvdrental
export PGERD_GRAPH_PER_SCHEMA=true
export PGERD_FILE_PREFIX=test_output/dvdrental_
export PGERD_SCHEMA_PATTERN=public
export PGERD_KEEP_DOTFILES=true 
export PGERD_SHOW_IMPLIED_REFERENCES=false
export PGERD_SHOW_PARTITIONS=true
./pg_erd.sh
