#!/bin/sh
#
# Generate a series of E-R diagrams for a given database
#
# Assume that all necessary PG* environment variables have been defined
#

show_usage() {
    cat <<EOF
usage:   [PGSERVICE=<service-name] [PGHOST=...] [OPTION=value ...] $0 [-h|--help]

note: psql connects without parameters, which means that suitable PG* environment variables
      must be supplied to ths script

Available OPTIONs:

PGERD_FILE_PREFIX

If provided, all files generated should being with this string. The default is empty.

PGERD_SCHEMA_PATTERN

If provided, is a SQL ILIKE pattern of names of schemas to graph. The default is %.

PGERD_GRAPH_PER_SCHEMA

If set to true, then the program will generate one graph per schema in addition to
the all-schema graph. The default is false.

PGERD_KEEP_DOTFILES

If set to true, then the program will not delete the .dot files that were generated
for graphviz. The default is false.

PGERD_SHOW_IMPLIED_REFERENCES

If set to true, then the graph will show dotted lines between columns that are likely
to be foreign keys to other tables based on name matching between that column name and
the table name. This is often helpful in situations where referential integrity is not
enforced, either as a design decision or because the postgresql variant does not
suppport referential integrity (ex. Redshift). The default is true.

PGERD_SHOW_PARTITIONS

If set to true, the graph will include all partitions of a partitioned table. While it
is true that members of a partitioned table can have additional columns and referential
integrity constraints independent of the parent table, this is rarely the case and
therefore the partitions just add clutter to the graph. The default is false.

EOF
}

##
# exit with an error message
#
die() {
    echo >&2 "$1"
    exit 1
}

# Check for pleas for help
case "$1" in
    -h|--help)
        show_usage
        exit 0
esac

#
# Assign default values if not supplied
#
PGERD_GRAPH_PER_SCHEMA=${PGERD_GRAPH_PER_SCHEMA:-false}
PGERD_KEEP_DOTFILES=${PGERD_KEEP_DOTFILES:-false}
PGERD_SHOW_IMPLIED_REFERENCES=${PGERD_SHOW_IMPLIED_REFERENCES:-true}
PGERD_SHOW_PARTITIONS=${PGERD_SHOW_PARTITIONS:-false}
PGERD_FILE_PREFIX=${PGERD_FILE_PREFIX:-}
PGERD_SCHEMA_PATTERN=${PG_ERD_SCHEMA_PATTERN:-%}
script_path=${0%.sh}.sql

#
# assert that a vars are boolean
#
for param in PGERD_GRAPH_PER_SCHEMA PGERD_KEEP_DOTFILES PGERD_SHOW_IMPLIED_REFERENCES PGERD_SHOW_PARTITIONS
do
    param_value=$(eval "echo \${$param}")
    if [ "${param_value}" != "true" -a "${param_value}" != "false" ]
    then
        echo "${param} = ${param_value}"
        die "${param} must be true or false"
    fi
done

#
# switch to strict variable checking
#
set -eu

#
# test for dependencies
#
command -v psql > /dev/null || die "error: psql not found"
command -v dot > /dev/null || die "error: dot (of graphviz) not found"

#
# test for connection
#
psql -c "SELECT 1" > /dev/null 2>&1 || {
    echo "unable to connect to database"
    echo
    show_usage
    exit 1
}

#
# generate a .dot file and .svg file
#
make_svg() {
    psql --quiet --tuples-only --no-align --no-psqlrc -f "${script_path}" \
        --set "schema=$1" \
        --set "show_implied_references=${PGERD_SHOW_IMPLIED_REFERENCES}" \
        --set "show_partitions=${PGERD_SHOW_PARTITIONS}" > "$2.dot"

    dot -Tsvg "$2.dot" -o "$2.svg"

    if [ "${PGERD_KEEP_DOTFILES}" = "true" ]
    then
        echo "$2.dot"
    else
        rm "$2.dot"
    fi
    echo "$2.svg"
}

#
# generate global ERD
#
file_prefix="${PGERD_FILE_PREFIX}erd"
echo -n "all schemas..."
make_svg "%" "${file_prefix}"

if [ "${PGERD_GRAPH_PER_SCHEMA}" = "true" ]
then
    echo "connecting to database and to find list of schemas"
    schema_list=$( psql --quiet --tuples-only --no-align --no-psqlrc --set "pat=${PGERD_SCHEMA_PATTERN}" <<'EOSQL'
SELECT string_agg(format('%I', nspname), ' ' ORDER BY nspname)
FROM pg_namespace
WHERE nspname NOT LIKE ALL(ARRAY['pg_catalog', 'information_schema', 'pg_toast%', 'pg_temp%'])
AND nspname ILIKE :'pat'
EOSQL
    )

    #
    # generate one ERD per schema
    #
    for schema in ${schema_list}
    do
        file_prefix="${PGERD_FILE_PREFIX}${schema}_erd"
        echo -n "schema: ${schema}..."
        make_svg "${schema}" "${file_prefix}"
    done
fi
