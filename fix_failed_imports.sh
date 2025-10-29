#!/bin/bash

# Universal script to fix and retry failed table imports

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <database_name>"
    echo "Example: $0 payoma"
    exit 1
fi

DATABASE="$1"
MYSQL_HOST="mysql"
MYSQL_USER="root"
SQL_DIR="/recovery/sql_${DATABASE}"
LOG_DIR="/scripts/logs"
RESTORE_LOG="${LOG_DIR}/restore_${DATABASE}.log"
FIX_LOG="${LOG_DIR}/fix_import_${DATABASE}.log"

mkdir -p "$LOG_DIR"

if [ ! -f "$RESTORE_LOG" ]; then
    echo "ERROR: Restore log not found: $RESTORE_LOG"
    exit 1
fi

echo "=== Fixing failed imports for database: $DATABASE ===" | tee "$FIX_LOG"
echo "Start time: $(date)" | tee -a "$FIX_LOG"
echo "" | tee -a "$FIX_LOG"

# Extract failed table names from restore log
echo "Analyzing errors from restore log..." | tee -a "$FIX_LOG"
FAILED_TABLES=$(grep -B 7 "ERROR importing data" "$RESTORE_LOG" | grep "Processing table:" | awk '{print $4}' | sort -u)
TOTAL_FAILED=$(echo "$FAILED_TABLES" | wc -l)

echo "Found $TOTAL_FAILED tables with import errors" | tee -a "$FIX_LOG"
echo "" | tee -a "$FIX_LOG"

SUCCESS=0
STILL_FAILED=0

# MySQL reserved words - comprehensive list
RESERVED_WORDS=(
    "accessible" "add" "all" "alter" "analyze" "and" "as" "asc"
    "before" "between" "bigint" "binary" "blob" "both" "by"
    "call" "cascade" "case" "change" "char" "character" "check"
    "collate" "column" "condition" "constraint" "continue" "convert"
    "create" "cross" "current_date" "current_time" "current_timestamp"
    "current_user" "cursor" "database" "databases" "day_hour" "day_microsecond"
    "day_minute" "day_second" "dec" "decimal" "declare" "default" "delayed"
    "delete" "desc" "describe" "deterministic" "distinct" "distinctrow"
    "div" "double" "drop" "dual" "each" "else" "elseif" "enclosed"
    "escaped" "exists" "exit" "explain" "false" "fetch" "float" "float4"
    "float8" "for" "force" "foreign" "from" "fulltext" "grant" "group"
    "having" "high_priority" "hour_microsecond" "hour_minute" "hour_second"
    "if" "ignore" "in" "index" "infile" "inner" "inout" "insensitive"
    "insert" "int" "int1" "int2" "int3" "int4" "int8" "integer" "interval"
    "into" "is" "iterate" "join" "key" "keys" "kill" "leading" "leave"
    "left" "like" "limit" "linear" "lines" "load" "localtime" "localtimestamp"
    "lock" "long" "longblob" "longtext" "loop" "low_priority" "match"
    "mediumblob" "mediumint" "mediumtext" "middleint" "minute_microsecond"
    "minute_second" "mod" "modifies" "natural" "not" "no_write_to_binlog"
    "null" "numeric" "on" "optimize" "option" "optionally" "or" "order"
    "out" "outer" "outfile" "precision" "primary" "procedure" "purge"
    "range" "read" "reads" "read_write" "real" "references" "regexp"
    "release" "rename" "repeat" "replace" "require" "resignal" "restrict"
    "return" "revoke" "right" "rlike" "schema" "schemas" "second_microsecond"
    "select" "sensitive" "separator" "set" "show" "signal" "smallint"
    "spatial" "specific" "sql" "sqlexception" "sqlstate" "sqlwarning"
    "sql_big_result" "sql_calc_found_rows" "sql_small_result" "ssl"
    "starting" "straight_join" "system" "table" "terminated" "then"
    "tinyblob" "tinyint" "tinytext" "to" "trailing" "trigger" "true"
    "undo" "union" "unique" "unlock" "unsigned" "update" "usage" "use"
    "using" "utc_date" "utc_time" "utc_timestamp" "values" "varbinary"
    "varchar" "varcharacter" "varying" "when" "where" "while" "with"
    "write" "xor" "year_month" "zerofill"
)

for TABLE in $FAILED_TABLES; do
    SQL_FILE="${SQL_DIR}/${TABLE}.sql"

    if [ ! -f "$SQL_FILE" ]; then
        echo "[$TABLE] SQL file not found, skipping" | tee -a "$FIX_LOG"
        continue
    fi

    echo "Processing table: $TABLE" | tee -a "$FIX_LOG"

    # Get error details from restore log
    ERROR_MSG=$(grep -A 10 "Processing table: ${TABLE}$" "$RESTORE_LOG" | grep "^ERROR" | head -1)
    echo "  Original error: $ERROR_MSG" | tee -a "$FIX_LOG"

    # Create fixed SQL file
    FIXED_SQL="${SQL_FILE}.fixed"
    cp "$SQL_FILE" "$FIXED_SQL"

    # Fix 1: Escape all reserved words in column names
    echo "  - Escaping reserved words..." | tee -a "$FIX_LOG"
    for WORD in "${RESERVED_WORDS[@]}"; do
        # Match word as column name (followed by comma or closing paren)
        sed -i.bak -E "s/([,\(])${WORD}([,\)])/\1\`${WORD}\`\2/g" "$FIXED_SQL"
    done

    # Fix 2: Clear table before reimport to avoid duplicate key errors
    echo "  - Clearing table data..." | tee -a "$FIX_LOG"
    mysql -h "$MYSQL_HOST" -u"$MYSQL_USER" "$DATABASE" -e "SET FOREIGN_KEY_CHECKS=0; TRUNCATE TABLE \`$TABLE\`; SET FOREIGN_KEY_CHECKS=1;" 2>> "$FIX_LOG" || true

    # Fix 3: Convert binary data format '\xNN...' to 0xNN... for BINARY/VARBINARY columns
    echo "  - Checking for binary columns..." | tee -a "$FIX_LOG"
    BINARY_COLS=$(mysql -h "$MYSQL_HOST" -u"$MYSQL_USER" "$DATABASE" -sN -e "
        SELECT COLUMN_NAME FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA='$DATABASE' AND TABLE_NAME='$TABLE'
        AND DATA_TYPE IN ('binary', 'varbinary', 'blob', 'tinyblob', 'mediumblob', 'longblob')
    " 2>/dev/null | tr '\n' '|' | sed 's/|$//')

    if [ -n "$BINARY_COLS" ]; then
        echo "  - Found binary columns: $BINARY_COLS" | tee -a "$FIX_LOG"
        echo "  - Converting '\xNN...' to 0xNN... format" | tee -a "$FIX_LOG"

        # Use Python script to properly convert hex escape sequences
        python3 "$SCRIPT_DIR/convert_binary_values.py" < "$FIXED_SQL" > "${FIXED_SQL}.tmp" 2>> "$FIX_LOG"
        mv "${FIXED_SQL}.tmp" "$FIXED_SQL"
    fi

    # Fix 4: Convert hex literals to UTF8 for JSON columns
    JSON_COLS=$(mysql -h "$MYSQL_HOST" -u"$MYSQL_USER" "$DATABASE" -sN -e "
        SELECT COLUMN_NAME FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA='$DATABASE' AND TABLE_NAME='$TABLE'
        AND DATA_TYPE = 'json'
    " 2>/dev/null | tr '\n' '|' | sed 's/|$//')

    if [ -n "$JSON_COLS" ]; then
        echo "  - Found JSON columns: $JSON_COLS" | tee -a "$FIX_LOG"
        echo "  - Converting hex literals to UTF8" | tee -a "$FIX_LOG"

        # Replace X'NNN' with CONVERT(X'NNN' USING utf8mb4) for JSON columns
        sed -i.json "s/,X'\\([0-9a-fA-F]*\\)',/,CONVERT(X'\1' USING utf8mb4),/g" "$FIXED_SQL"
        sed -i.json "s/,X'\\([0-9a-fA-F]*\\)')/,CONVERT(X'\1' USING utf8mb4))/g" "$FIXED_SQL"
        rm -f "$FIXED_SQL.json"
    fi

    # Try to import fixed SQL
    echo "  - Attempting import with fixes..." | tee -a "$FIX_LOG"
    if mysql -h "$MYSQL_HOST" -u"$MYSQL_USER" "$DATABASE" < "$FIXED_SQL" 2>> "$FIX_LOG"; then
        echo "  ✓ Import successful!" | tee -a "$FIX_LOG"
        SUCCESS=$((SUCCESS + 1))
        rm "$FIXED_SQL" "$FIXED_SQL.bak" 2>/dev/null || true
    else
        echo "  ✗ Import still failed" | tee -a "$FIX_LOG"
        STILL_FAILED=$((STILL_FAILED + 1))
        echo "  - Fixed SQL saved for manual review: $FIXED_SQL" | tee -a "$FIX_LOG"
    fi

    echo "" | tee -a "$FIX_LOG"
done

echo "=== Fix process completed ===" | tee -a "$FIX_LOG"
echo "End time: $(date)" | tee -a "$FIX_LOG"
echo "" | tee -a "$FIX_LOG"

echo "=== Statistics ===" | tee -a "$FIX_LOG"
echo "Total failed tables: $TOTAL_FAILED" | tee -a "$FIX_LOG"
echo "Successfully fixed: $SUCCESS" | tee -a "$FIX_LOG"
echo "Still failing: $STILL_FAILED" | tee -a "$FIX_LOG"
echo "" | tee -a "$FIX_LOG"

# Final database stats
echo "=== Final database statistics ===" | tee -a "$FIX_LOG"
mysql -h "$MYSQL_HOST" -u"$MYSQL_USER" "$DATABASE" -e "
    SELECT
        COUNT(*) as total_tables,
        SUM(TABLE_ROWS) as total_rows,
        ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) as total_size_mb
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = '$DATABASE';
" 2>&1 | tee -a "$FIX_LOG"

echo "" | tee -a "$FIX_LOG"
echo "Log saved to: $FIX_LOG"
