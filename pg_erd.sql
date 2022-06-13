--
-- Generate Graphviz .dot file for a database --
-- params:
-- * schema (string) (optional):
--      limit diagram to one schema vs show all user schemas
-- * show_partitions (boolean) (optional):
--      whether to display tables that are children of partitioned tables or not
-- * show_implied_references (boolean) (optional):
--      whether to show name matches as potential foreign keys
--
-- notes:
-- * no indication on relationship arrows of one-to-many vs one-to-one
-- * there are no optional-marks on the relationships in the case of nulls
-- * all strings that will be used as graphviz port numbers contain a '~' to ensure that
--   the format %I operator will always quote the string
-- * similarly, node names are fully schema qualified to ensure %I double quotes them all
--

--
-- If schema is defined and not a wildcard, then we will only generate a
-- diagram of that schema, and table names will not have schema-qualification
--
\if :{?schema}
    SELECT  :'schema' AS schema_pattern,
            coalesce(nullif(:'schema', '%'), 'public') AS default_schema
    \gset
\else
    \set default_schema 'public'
    \set schema_pattern '%'
\endif
\unset schema

--
-- If show_partitions is set to true, we will not filter out all tables that are partitions
-- of a partitioned table. While it is possible for such tables to have referential
-- integrity that is independent of the parent table, such things are not common
-- and generally users want a less cluttered diagram
--
\if :{?show_partitions}
\else
    \set show_partitions 'f'
\endif

--
-- If show_implied_references is set to true (the default) we will show those
-- as dotted lines
--
\if :{?show_implied_references}
\else
    \set show_implied_references 't'
\endif

--
-- Give names to several ugly constants needed by Graphviz/dot
--
\set TOOLTIP_CRLF '&#013;&#010;'
\set TOOLTIP_TAB '&#009'
\set TOOLTIP_ARROW '&#10230;'
\set TOOLTIP_SINGLE_QUOTE '&apos;'
\set TOOLTIP_DOUBLE_QUOTE '&quot;'

WITH suffixes(suffix) AS (
    -- these are all the suffixes that can be on an implied foreign key
    VALUES ('id'), ('_id'), ('_key'), ('_ref')
),
schemas AS (
    --
    -- collect all the schemas that will be search for this query
    --
    SELECT  n.oid,
            n.nspname::text AS schema_name,
            format('cluster.%s', n.nspname::text) AS subgraph_name,
            format('schema: %s', n.nspname::text) AS subgraph_label
    FROM pg_namespace n
    WHERE n.nspname LIKE :'schema_pattern'
	AND n.nspname NOT LIKE 'pg_temp%'
	AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
),
tabs AS (
    --
    -- collect all table-level information
    --
	SELECT 	c.oid,
            c.relnamespace,
			format('%s.%s', s.schema_name, c.relname ) AS node_name,
            tn.table_name,
            pk.conkey as pk_conkey,
            m.matching_column_names,
            replace(
                replace(
                    concat_ws(:'TOOLTIP_CRLF',
                        format('TABLE: %s', tn.table_name),
                        format('DESCRIPTION: %s', coalesce(d.description, '(no description available)'))),
                    '"', :'TOOLTIP_DOUBLE_QUOTE'),
                    '''', :'TOOLTIP_SINGLE_QUOTE') AS table_tooltip
	FROM pg_class c
    JOIN schemas AS s ON s.oid = c.relnamespace
    -- normalize table names based on selected schema or public if default
    CROSS JOIN LATERAL (SELECT CASE
                            WHEN s.schema_name = :'default_schema' THEN c.relname
                            ELSE format('%s.%s', s.schema_name, c.relname )
			            END) AS tn(table_name)
    -- build an array of column names that would imply a foreign key match to this table
    CROSS JOIN LATERAL (
                        SELECT array_agg(n.col_name)
                        FROM (  SELECT c.relname || s.suffix
                                FROM suffixes s
                                UNION ALL
                                -- trim plurals for extra matches so term_id matches term and terms
                                SELECT regexp_replace(c.relname, 's$','') || s.suffix
                                FROM suffixes s
                                WHERE c.relname LIKE '%s' ) AS n(col_name)
                        ) AS m(matching_column_names)
    LEFT JOIN pg_constraint pk ON pk.conrelid = c.oid AND pk.contype = 'p'
    LEFT JOIN pg_description d ON d.objoid = c.oid AND d.objsubid = 0
	WHERE c.relkind in ('r','p') 
    -- and either this table is not a child of a partitioned table, or we have show_partitions set
    AND (   :'show_partitions'::boolean
            OR
            NOT EXISTS( SELECT NULL
                        FROM pg_inherits AS i
                        JOIN pg_class AS p ON p.oid = i.inhparent
                        -- AND p.relkind = 'p'
                        WHERE i.inhrelid = c.oid ))
),
cols AS (
    --
    -- collect all column-level information
    --
    SELECT  a.attrelid,
            a.attnum,
            a.attname,
            t.relnamespace,
            pk.is_primary_key,
            pk.is_first_pk_column,
            format('%s~%s', a.attrelid::regclass::text, a.attname) as port_name,
            replace(
                replace(
                    concat_ws(:'TOOLTIP_CRLF',
                        format('COLUMN: %s', a.attname),
                        format('TYPE: %s %s',
                                format_type(a.atttypid, a.atttypmod),
                                CASE
                                    WHEN pk.is_primary_key THEN 'NOT NULL PRIMARY KEY'
                                    WHEN a.attnotnull THEN 'NOT NULL'
                                    ELSE 'NULL'
                                END),
                        format('DEFAULT: %s',
                                CASE
                                    WHEN a.atthasdef THEN pg_get_expr(def.adbin, def.adrelid)
                                    ELSE '(no default defined)'
                                END),
                        format('DESCRIPTION: %s', coalesce(descr.description, '(no description available)'))),
                    '"', :'TOOLTIP_DOUBLE_QUOTE'),
                '''', :'TOOLTIP_SINGLE_QUOTE') AS column_tooltip
    FROM tabs AS t
    JOIN pg_attribute AS a ON a.attrelid = t.oid
    LEFT JOIN pg_description AS descr ON descr.objoid = a.attrelid AND descr.objsubid = a.attnum
    LEFT JOIN pg_attrdef AS def ON def.adrelid = a.attrelid AND def.adnum = a.attnum
    CROSS JOIN LATERAL ( SELECT (a.attnum = ANY(t.pk_conkey)),
                                (a.attnum = t.pk_conkey[1])) AS pk(is_primary_key, is_first_pk_column)
    WHERE NOT a.attisdropped
    AND a.attnum > 0
),
defined_foreign_keys AS (
    --
    -- defined foreign keys are ones that are declared in the database
    --
    SELECT  fk.conrelid,
            fk.confrelid,
            fk.conkey,
            a.port_name,
            replace(
                replace(
                    concat_ws(:'TOOLTIP_CRLF',
                        format('%s(%s) %s %I', fk.conrelid::regclass::text, fc.col_list, :'TOOLTIP_ARROW', fk.confrelid::regclass::text),
                        format('FOREIGN KEY NAME: %s', fk.conname),
                        format('DESCRIPTION: %s', coalesce(descr.description, '(no description available)'))),
                    '"', :'TOOLTIP_DOUBLE_QUOTE'),
                '''', :'TOOLTIP_SINGLE_QUOTE') AS tooltip
    FROM pg_constraint AS fk
    JOIN cols AS a ON a.attrelid = fk.conrelid AND a.attnum = fk.conkey[1]
    CROSS JOIN LATERAL (SELECT COUNT(*),
                                string_agg(fa.attname, ', ' ORDER BY fa.attnum)
                        FROM pg_attribute AS fa
                        WHERE fa.attrelid = fk.conrelid
                        AND fa.attnum = ANY(fk.conkey)) AS fc(col_count, col_list)
    LEFT JOIN pg_description AS descr ON descr.objoid = fk.oid AND descr.classoid = fk.tableoid
	WHERE fk.contype = 'f'
),
implied_foreign_keys AS (
    --
    -- These are potential referential integrity links based upon name patterns.
    --
    -- This is enabled/disabled through the show_implied_references variable.
    --
    SELECT  a.attrelid,
            a.attnum,
            a.attname,
            -- a.column_tooltip,
            a.port_name,
            rt.oid as ref_oid,
            concat_ws(:'TOOLTIP_CRLF',
                        format('%s(%s) %s %I', a.attrelid::regclass::text, a.attname, :'TOOLTIP_ARROW', rt.oid::regclass::text),
                        'reference implied by name match') AS tooltip
    FROM cols a
    JOIN tabs AS rt ON rt.relnamespace = a.relnamespace
    -- implied references are turned on
    WHERE :'show_implied_references'::boolean
    -- column name is a pattern match of a table name in same schema
    AND a.attname = ANY(rt.matching_column_names)
    -- column isn't already part of defined foreign key to that table
    AND NOT EXISTS( SELECT NULL
                    FROM defined_foreign_keys fk
                    WHERE fk.conrelid = a.attrelid
                    AND fk.confrelid = rt.oid
                    AND a.attnum = ANY(fk.conkey) )
    -- if self reference, then column cannot be in the primary key
    AND NOT (a.attrelid = rt.oid AND a.is_primary_key)
),
table_references(oid) AS (
    --
    -- Enumerate each time a table is referenced
    --
    SELECT d.conrelid FROM defined_foreign_keys AS d
    UNION ALL
    SELECT d.confrelid FROM defined_foreign_keys AS d
    UNION ALL
    SELECT i.attrelid FROM implied_foreign_keys AS i
    UNION ALL
    SELECT i.ref_oid FROM implied_foreign_keys AS i
),
table_reference_counts(oid, num_references) AS (
    --
    -- count the number of times each table is referenced by another table
    --
    SELECT tr.oid, count(*)
    FROM table_references AS tr
    GROUP BY tr.oid
),
table_nodes AS (
    --
    -- every table is a graphviz node
    --
    SELECT  t.relnamespace,
            coalesce(trc.num_references, 0) as num_references,
            format(E'%I [ label=<<table style="rounded" border="1" cellborder="1" cellspacing="0">%s</table>>];',
                    t.node_name,
                    replace(coalesce(label_str.label_str,''), E'\n', E'\n\t')
                    ) AS node_string
    FROM tabs AS t
    CROSS JOIN LATERAL (
        SELECT string_agg(format(E'\n<tr>%s</tr>', l.str), '' ORDER BY l.label_order)
        FROM (	-- table, center and bold
                SELECT  0, -- always first
                        format(E'<td align="center" sides="b" tooltip=%I href="."><b>%s</b></td>',
                                t.table_tooltip,
                                t.table_name)
                UNION ALL
                -- all of the columns for that table get their own port
                SELECT  a.attnum,
                        format(E'<td port=%I align="left" border="0" tooltip=%I href=".">%s</td>',
                                a.port_name,
                                a.column_tooltip,
                                CASE
                                    WHEN a.is_primary_key THEN format('<u>%s</u>', a.attname)
                                    ELSE a.attname
                                END
                            )
                FROM cols a
                WHERE a.attrelid = t.oid
                ) AS l(label_order, str) 
        ) AS label_str(label_str)
    LEFT OUTER JOIN table_reference_counts AS trc ON trc.oid = t.oid
),
schema_subgraphs AS (
    --
    -- every schema is a subgraph
    --
    -- place table nodes within the subgraph in declining order of num_references, as this
    -- seems to make for a smoother layout, and the unreferenced tables end up on the periphery 
    --
    SELECT format(E'subgraph %I {\n\tlabel=%I;\n\tlabelloc="top";\n\tshape="Mrecord";\n\t%s\n}',
                    s.subgraph_name,
                    s.subgraph_label,
                    tn.table_nodes) as subgraph_string
    FROM schemas s
    CROSS JOIN LATERAL (SELECT  replace(string_agg(tn.node_string, '' ORDER BY tn.num_references DESC), E'\n', E'\n\t'),
                                count(*)
                        FROM table_nodes tn
                        WHERE tn.relnamespace = s.oid
                        ) AS tn(table_nodes, num_tables)
    ORDER BY tn.num_tables DESC
),
digraph_header_lines(line) AS (
    --
    -- This is the description and legend at the top of the digraph
    --
    SELECT format('Database: %s', current_database())
    UNION ALL
    -- name the schema in the header only if it is the only schema in the graph
    SELECT format('Schema: %s', :'default_schema')
    WHERE NOT :'schema_pattern' = '%'
    UNION ALL
    SELECT 'Entity-Relationship Diagram'
    UNION ALL
    SELECT '==============================================='
    UNION ALL
    SELECT 'Solid lines with solid dot are defined foreign keys.'
    UNION ALL
    SELECT 'Dashed lines with solid dot are implied foreign keys.'
    UNION ALL
    SELECT 'Hover over table names to show table description.'
    UNION ALL
    SELECT 'Hover over column names to show column details.'
    UNION ALL
    SELECT 'Hover over lines/dots to show foreign key relationships.'
),
digraph_contents(digraph_contents_string) AS (
    SELECT 'labelloc="top";'::text
    UNION ALL
    SELECT format('label=%I;', string_agg(format('%s\l', dgl.line), ''))
    FROM digraph_header_lines AS dgl
    UNION ALL
    SELECT 'graph [ rankdir = "LR" ]'
    UNION ALL
    SELECT 'compound=true'
    UNION ALL
    SELECT 'node [ shape=none, margin=0 ]'
    UNION ALL
    SELECT s.subgraph_string
    FROM schema_subgraphs s
    UNION ALL
    -- defined keys edge defaults
    SELECT 'edge[arrowhead=dot, arrowtail=none, dir=both]'
    UNION ALL
    -- plus defined keys
    SELECT format('%I:%I->%I:%I [labeltooltip = %I, edgetooltip=%I];',
                    tf.node_name,
                    cf.port_name,
                    t.node_name,
                    fk.port_name,
                    fk.tooltip,
                    fk.tooltip)
    FROM defined_foreign_keys fk
    JOIN tabs AS t ON t.oid = fk.conrelid
    JOIN tabs AS tf ON tf.oid = fk.confrelid
    JOIN cols AS cf ON cf.attrelid = tf.oid AND cf.is_first_pk_column
    UNION ALL
    -- implied keys edge defaults (same as defined key but dashed line
    SELECT 'edge[arrowhead=dot, arrowtail=none, dir=both, style=dashed]'
    UNION ALL
    -- implied keys
    SELECT format('%I:%I->%I:%I [labeltooltip = %I, edgetooltip=%I];',
                    tf.node_name,
                    cf.port_name,
                    t.node_name,
                    i.port_name,
                    i.tooltip,
                    i.tooltip)
    FROM implied_foreign_keys i
    JOIN tabs AS t ON t.oid = i.attrelid
    JOIN tabs AS tf ON tf.oid = i.ref_oid
    JOIN cols AS cf ON cf.attrelid = tf.oid AND cf.is_first_pk_column
)
SELECT format(E'digraph "ER Diagram" {%s\n}',
                replace(string_agg(format(E'\n%s', dg.digraph_contents_string), ''), E'\n', E'\n\t'))
FROM digraph_contents dg;
