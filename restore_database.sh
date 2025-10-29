#!/bin/bash

# Universal script for restoring MySQL database from .ibd files

set -e

# Check parameters
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <backup_directory_path> <database_name>"
    echo "Example: $0 /backup/payoma payoma"
    exit 1
fi

BACKUP_DIR="$1"
DATABASE="$2"
MYSQL_HOST="mysql"
MYSQL_USER="root"
LOG_DIR="/scripts/logs"
LOG_FILE="${LOG_DIR}/restore_${DATABASE}.log"
DDL_DIR="/recovery/ddl_${DATABASE}"
SQL_DIR="/recovery/sql_${DATABASE}"

# Create logs directory
mkdir -p "$LOG_DIR"

# Check if backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    echo "ERROR: Directory $BACKUP_DIR does not exist"
    exit 1
fi

echo "=== Starting database restoration: $DATABASE ===" | tee "$LOG_FILE"
echo "Source: $BACKUP_DIR" | tee -a "$LOG_FILE"
echo "Start time: $(date)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Create directories for DDL and SQL
mkdir -p "$DDL_DIR" "$SQL_DIR"

# Create database
echo "Creating database $DATABASE..." | tee -a "$LOG_FILE"
mysql -h "$MYSQL_HOST" -u"$MYSQL_USER" -e "CREATE DATABASE IF NOT EXISTS $DATABASE CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>&1 | tee -a "$LOG_FILE"

# Disable foreign key checks
echo "Disabling foreign key checks..." | tee -a "$LOG_FILE"
mysql -h "$MYSQL_HOST" -u"$MYSQL_USER" "$DATABASE" -e "SET FOREIGN_KEY_CHECKS=0;" 2>&1 | tee -a "$LOG_FILE"

# Get list of all .ibd files
IBD_FILES=$(find "$BACKUP_DIR" -name "*.ibd" -type f | sort)
TOTAL_FILES=$(echo "$IBD_FILES" | wc -l)

if [ "$TOTAL_FILES" -eq 0 ]; then
    echo "ERROR: No .ibd files found in directory $BACKUP_DIR" | tee -a "$LOG_FILE"
    exit 1
fi

CURRENT=0
SUCCESS=0
FAILED=0

echo "Found files: $TOTAL_FILES" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Process each .ibd file
for IBD_FILE in $IBD_FILES; do
    CURRENT=$((CURRENT + 1))
    TABLE_NAME=$(basename "$IBD_FILE" .ibd)

    echo "[$CURRENT/$TOTAL_FILES] Processing table: $TABLE_NAME" | tee -a "$LOG_FILE"

    # Extract DDL
    DDL_FILE="$DDL_DIR/${TABLE_NAME}.sql"
    echo "  - Extracting DDL..." | tee -a "$LOG_FILE"

    if python3 -m pyinnodb.cli --fn "$IBD_FILE" tosql --mode ddl > "$DDL_FILE" 2>> "$LOG_FILE"; then
        echo "  - DDL extracted successfully" | tee -a "$LOG_FILE"

        # Create table
        echo "  - Creating table..." | tee -a "$LOG_FILE"
        # Prepend SET FOREIGN_KEY_CHECKS=0 to DDL
        echo "SET FOREIGN_KEY_CHECKS=0;" | cat - "$DDL_FILE" > "$DDL_FILE.tmp" && mv "$DDL_FILE.tmp" "$DDL_FILE"
        if mysql -h "$MYSQL_HOST" -u"$MYSQL_USER" "$DATABASE" < "$DDL_FILE" 2>> "$LOG_FILE"; then
            echo "  - Table created successfully" | tee -a "$LOG_FILE"

            # Import data
            echo "  - Importing data..." | tee -a "$LOG_FILE"
            SQL_FILE="$SQL_DIR/${TABLE_NAME}.sql"

            if python3 -m pyinnodb.cli --fn "$IBD_FILE" tosql --mode dump > "$SQL_FILE" 2>> "$LOG_FILE"; then
                # Check if there is data (skip if file contains "no data")
                if [ -s "$SQL_FILE" ] && ! grep -q "^no data$" "$SQL_FILE"; then
                    # Prepend SET FOREIGN_KEY_CHECKS=0 to SQL file
                    echo "SET FOREIGN_KEY_CHECKS=0;" | cat - "$SQL_FILE" > "$SQL_FILE.tmp" && mv "$SQL_FILE.tmp" "$SQL_FILE"
                    if mysql -h "$MYSQL_HOST" -u"$MYSQL_USER" "$DATABASE" < "$SQL_FILE" 2>> "$LOG_FILE"; then
                        echo "  - Data imported successfully" | tee -a "$LOG_FILE"
                        SUCCESS=$((SUCCESS + 1))
                        # Remove SQL file after successful import
                        rm "$SQL_FILE"
                    else
                        echo "  - ERROR importing data" | tee -a "$LOG_FILE"
                        FAILED=$((FAILED + 1))
                    fi
                else
                    echo "  - Table is empty, skipping data import" | tee -a "$LOG_FILE"
                    SUCCESS=$((SUCCESS + 1))
                    rm "$SQL_FILE"
                fi
            else
                echo "  - ERROR extracting data" | tee -a "$LOG_FILE"
                FAILED=$((FAILED + 1))
            fi
        else
            echo "  - ERROR creating table" | tee -a "$LOG_FILE"
            FAILED=$((FAILED + 1))
        fi
    else
        echo "  - ERROR extracting DDL" | tee -a "$LOG_FILE"
        FAILED=$((FAILED + 1))
    fi

    echo "" | tee -a "$LOG_FILE"
done

echo "=== Restoration completed ===" | tee -a "$LOG_FILE"
echo "End time: $(date)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Re-enable foreign key checks
echo "Re-enabling foreign key checks..." | tee -a "$LOG_FILE"
mysql -h "$MYSQL_HOST" -u"$MYSQL_USER" "$DATABASE" -e "SET FOREIGN_KEY_CHECKS=1;" 2>&1 | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Show statistics
echo "=== Processing statistics ===" | tee -a "$LOG_FILE"
echo "Total tables: $TOTAL_FILES" | tee -a "$LOG_FILE"
echo "Successful: $SUCCESS" | tee -a "$LOG_FILE"
echo "Failed: $FAILED" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

echo "=== Database statistics ===" | tee -a "$LOG_FILE"
mysql -h "$MYSQL_HOST" -u"$MYSQL_USER" "$DATABASE" -e "
    SELECT
        COUNT(*) as total_tables,
        SUM(TABLE_ROWS) as total_rows,
        ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1024 / 1024, 2) as total_size_mb
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = '$DATABASE';
" 2>&1 | tee -a "$LOG_FILE"

echo "" | tee -a "$LOG_FILE"
echo "Log saved to: $LOG_FILE"
