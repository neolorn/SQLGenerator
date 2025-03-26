/**************************************************************************************************
* SQL Server Stored Procedure Generator
* Author     : Hossam Ismail (Neolorn)
* Version    : 5.2.0
* License    : MIT
* Repository : https://github.com/neolorn/SQLGenerator
*
* Overview:
*   This script dynamically generates standardized CRUD stored procedures for user-defined tables
*   in Microsoft SQL Server. It's optimized for scaffolding, rapid prototyping, and automation.
*
* Generated Procedures per Table:
*   - <Table>_Select      : Supports key-set and offset pagination with optional full-text search.
*   - <Table>_SelectById  : Fetches a single record by primary key(s).
*   - <Table>_Insert      : Inserts a new row with support for NULL/defaults and ID output.
*   - <Table>_Update      : Updates columns using COALESCE semantics for patch-style behavior.
*   - <Table>_Delete      : Deletes a row by primary key(s).
*
* Compatibility (= tested on):
*   - SQL Server 2019 and above
*
* Use Cases:
*   - Rapid prototyping
*   - Internal tooling and automation
*   - Schema-first development
*
* Change Log:
*   v5.2.0 - Added conditional key-set/offset pagination + single-key optimization
*   v5.1.2 - Added multi-table support, computed column search, fixed GUID insert handling
*   v5.0.0 - Rewriten for GitHub release
*/

/**************************************************************************************************
-- START CONFIGURATION SETTINGS
**************************************************************************************************/

-- Formatting constants
DECLARE @S VARCHAR(1) = CHAR(32); -- Single space
DECLARE @L VARCHAR(1) = CHAR(13); -- Line break
DECLARE @T VARCHAR(1) = CHAR(9); -- Tab
DECLARE @TT VARCHAR(2) = @T + CHAR(9);
DECLARE @TTT VARCHAR(3) = @TT + CHAR(9);

-- Database and table configuration
DECLARE @TargetTables VARCHAR(MAX); -- Comma-separated list; leave blank for all tables
SET @TargetTables = '';

DECLARE @TargetSchema VARCHAR(MAX);
SET @TargetSchema = 'dbo';

DECLARE @TargetDatabase VARCHAR(MAX);
SET @TargetDatabase = '';

DECLARE @OutputMethod VARCHAR(MAX); -- Options: 'Print' or 'Execute'
SET @OutputMethod = 'Print';

DECLARE @ExcludePrefix VARCHAR(MAX); -- Optional prefix to strip from table names
SET @ExcludePrefix = '';

DECLARE @UseSelectWildCard BIT; -- Set to 1 to generate SELECT * instead of listing each column
SET @UseSelectWildCard = 0;

DECLARE @SearchColumn VARCHAR(MAX); -- Computed column for generic search
SET @SearchColumn = 'Summary';

/**************************************************************************************************
-- END CONFIGURATION SETTINGS
**************************************************************************************************/

-- Flag indicating if the computed search column exists in the table
DECLARE @CanSearch BIT;

-- Variable to accumulate column list for SELECT (when not using wildcard)
DECLARE @ColumnList NVARCHAR(MAX) = '';

-- Cursor to iterate over all user table columns
DECLARE ColumnCursor CURSOR FOR
  SELECT c.TABLE_SCHEMA,
         c.TABLE_NAME,
         c.COLUMN_NAME,
         c.DATA_TYPE,
         c.CHARACTER_MAXIMUM_LENGTH,
         CASE
           WHEN COLUMNPROPERTY(OBJECT_ID(QUOTENAME(c.TABLE_SCHEMA) + '.' + QUOTENAME(c.TABLE_NAME)),
                               c.COLUMN_NAME, 'IsComputed') = 1 THEN CAST(1 AS BIT)
           ELSE CAST(0 AS BIT)
           END AS IsComputed
    FROM INFORMATION_SCHEMA.COLUMNS c
           INNER JOIN INFORMATION_SCHEMA.TABLES t
                      ON c.TABLE_NAME = t.TABLE_NAME AND c.TABLE_SCHEMA = t.TABLE_SCHEMA
    WHERE t.TABLE_CATALOG = @TargetDatabase
      AND t.TABLE_TYPE = 'BASE TABLE'
      AND t.TABLE_SCHEMA = @TargetSchema
    ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;

-- Column-level variables
DECLARE @TableSchema VARCHAR(MAX);
DECLARE @TableName VARCHAR(MAX);
DECLARE @ColumnName VARCHAR(MAX);
DECLARE @DataType VARCHAR(MAX);
DECLARE @CharLength INT;
DECLARE @IsComputed BIT;
DECLARE @IsPrimaryKey BIT;
DECLARE @IdColumnExists BIT;

-- Table-level trackers
DECLARE @CurrentTable VARCHAR(MAX);
DECLARE @PrimaryKeyColumn VARCHAR(MAX);
DECLARE @PrimaryKeyDataType VARCHAR(MAX);
DECLARE @RawTableName VARCHAR(MAX);
DECLARE @ExcludePrefixLength INT;

-- Compound primary key trackers
DECLARE @PKParameters NVARCHAR(MAX) = ''; -- Pure comma-separated list of key parameters (each on its own line)
DECLARE @PKWhereClause NVARCHAR(MAX) = '';

-- New variables for key-set logic over all PKs
DECLARE @PKCondition NVARCHAR(MAX) = '';
DECLARE @PKCaseColumn NVARCHAR(MAX) = '';
DECLARE @PKCaseParam NVARCHAR(MAX) = '';
DECLARE @PKCount INT;

-- Stored procedure definition builders
DECLARE @SelectProcedure NVARCHAR(MAX);
DECLARE @SelectByIdProcedure NVARCHAR(MAX);
DECLARE @InsertIntoClause NVARCHAR(MAX);
DECLARE @InsertValuesClause NVARCHAR(MAX);
DECLARE @InsertProcedure NVARCHAR(MAX);
DECLARE @UpdateSetClause NVARCHAR(MAX);
DECLARE @UpdateProcedure NVARCHAR(MAX);
DECLARE @DeleteProcedure NVARCHAR(MAX);
DECLARE @FinalOutput NVARCHAR(MAX) = N'';

-- Initialize trackers
SET @CurrentTable = '';
SET @ExcludePrefixLength = LEN(@ExcludePrefix);

OPEN ColumnCursor;
FETCH NEXT FROM ColumnCursor INTO @TableSchema, @TableName, @ColumnName, @DataType, @CharLength, @IsComputed;
SET @DataType = UPPER(@DataType);

-- Determine if the current column is part of the primary key.
SET @IsPrimaryKey =
    CASE
      WHEN EXISTS (SELECT 1
                     FROM sys.indexes i
                            INNER JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                            INNER JOIN sys.columns c2 ON ic.object_id = c2.object_id AND ic.column_id = c2.column_id
                     WHERE i.object_id = OBJECT_ID(QUOTENAME(@TableSchema) + '.' + QUOTENAME(@TableName))
                       AND i.is_primary_key = 1
                       AND c2.name = @ColumnName) THEN 1
      ELSE 0
      END;

-- Loop through each column for all tables
WHILE @@FETCH_STATUS = 0
  BEGIN
    -- If this column is the computed search column, mark search support as available.
    IF UPPER(@ColumnName) = UPPER(@SearchColumn) AND @IsComputed = 1
      SET @CanSearch = 1;

    -- When a new table is encountered...
    IF @TableName <> @CurrentTable
      BEGIN
        -- Finalize stored procedures for the previous table (if any)
        IF @CurrentTable <> ''
          BEGIN
            IF @TargetTables = '' OR ',' + @TargetTables + ',' LIKE '%,' + @CurrentTable + ',%'
              BEGIN
                -- Finalize the SELECT procedure with the new pagination logic

                -- Use @PageNumber branch with OFFSET (ORDER BY first PK column)
                SET @SelectProcedure = @SelectProcedure +
                                       @T + 'IF @PageNumber IS NOT NULL' + @L +
                                       @T + 'BEGIN' + @L +
                                       @TT + 'SELECT' + @S + @ColumnList + @L +
                                       @TT + 'FROM' + @S + @TableSchema + '.' + @CurrentTable + @S + 'WITH(NOLOCK)' +
                                       @L +
                                       (CASE
                                         WHEN @CanSearch = 1 THEN @TT + 'WHERE (@SearchTerm IS NULL OR' + @S +
                                                                  @SearchColumn + @S +
                                                                  'LIKE ''%'' + @SearchTerm + ''%'')' + @L
                                         ELSE ''
                                         END) +
                                       @TT + 'ORDER BY' + @S + @PrimaryKeyColumn + @L +
                                       @TT + 'OFFSET ((@PageNumber - 1) * @PageSize) ROWS' + @L +
                                       @TT + 'FETCH NEXT @PageSize ROWS ONLY;' + @L +
                                       @T + 'END' + @L;

                -- Use key-set pagination if any PK parameter is non-null (using the CASE expressions)
                SET @SelectProcedure = @SelectProcedure +
                                       @T + 'ELSE IF (' + @PKCondition + ')' + @L +
                                       @T + 'BEGIN' + @L +
                                       @TT + 'SELECT TOP (@PageSize)' + @S + @ColumnList + @L +
                                       @TT + 'FROM' + @S + @TableSchema + '.' + @CurrentTable + @S + 'WITH(NOLOCK)' +
                                       @L +
                                       @TT + 'WHERE (' + @PKCaseColumn + ') > (' + @PKCaseParam + ')' + @S +
                                       (CASE
                                         WHEN @CanSearch = 1 THEN 'AND (@SearchTerm IS NULL OR ' + @SearchColumn + @S +
                                                                  'LIKE ''%'' + @SearchTerm + ''%'')'
                                         ELSE ''
                                         END) + @L +
                                       @TT + 'ORDER BY (' + @PKCaseColumn + ');' + @L +
                                       @T + 'END' + @L;

                -- Else, if neither page nor PK is supplied, return the entire table.
                SET @SelectProcedure = @SelectProcedure +
                                       @T + 'ELSE' + @L +
                                       @T + 'BEGIN' + @L +
                                       @TT + 'SELECT' + @S + @ColumnList + @L +
                                       @TT + 'FROM' + @S + @TableSchema + '.' + @CurrentTable + @S + 'WITH(NOLOCK)' +
                                       @L +
                                       (CASE
                                         WHEN @CanSearch = 1 THEN @TT + 'WHERE (@SearchTerm IS NULL OR' + @S +
                                                                  @SearchColumn + @S +
                                                                  'LIKE ''%'' + @SearchTerm + ''%'')' + @L
                                         ELSE ''
                                         END) +
                                       @T + 'END' + @L +
                                       @T + 'SET NOCOUNT OFF' + @L +
                                       'END' + @L +
                                       (CASE WHEN @OutputMethod <> 'Execute' THEN 'GO' ELSE '' END) + @L + @L;

                -- Finalize other procedures (unchanged parts) ...
                SET @SelectByIdProcedure = @SelectByIdProcedure + @L +
                                           @T + 'FROM' + @S + @TableSchema + '.' + @CurrentTable + @S + 'WITH(NOLOCK)' +
                                           @L +
                                           @T + 'WHERE' + @S + @PKWhereClause + @L +
                                           @T + 'SET NOCOUNT OFF' + @L +
                                           'END' + @L +
                                           (CASE WHEN @OutputMethod <> 'Execute' THEN 'GO' ELSE '' END) + @L + @L;

                SET @InsertIntoClause =
                    SUBSTRING(@InsertIntoClause, 0, LEN(@InsertIntoClause) - 1) + @L + @T + ')' + @L;
                SET @InsertValuesClause =
                    SUBSTRING(@InsertValuesClause, 0, LEN(@InsertValuesClause) - 1) + @L + @T + ')';

                SET @InsertProcedure = @InsertProcedure + @L +
                                       'AS' + @L +
                                       'BEGIN' + @L +
                                       @T + 'SET NOCOUNT ON' + @L +
                                       @InsertIntoClause +
                                       CASE
                                         WHEN @IdColumnExists = 1 THEN @T + 'OUTPUT INSERTED.Id' + @L
                                         ELSE ''
                                         END +
                                       @InsertValuesClause + @L +
                                       @T + 'SET NOCOUNT OFF' + @L +
                                       'END' + @L +
                                       (CASE WHEN @OutputMethod <> 'Execute' THEN 'GO' ELSE '' END) + @L + @L;

                SET @UpdateSetClause = SUBSTRING(@UpdateSetClause, 0, LEN(@UpdateSetClause) - 1) + @L +
                                       @T + 'WHERE' + @S + @PKWhereClause;
                SET @UpdateProcedure = @UpdateProcedure + @L +
                                       'AS' + @L +
                                       'BEGIN' + @L +
                                       @T + 'SET NOCOUNT ON' + @L +
                                       @UpdateSetClause + @L +
                                       @T + 'SET NOCOUNT OFF' + @L +
                                       'END' + @L +
                                       (CASE WHEN @OutputMethod <> 'Execute' THEN 'GO' ELSE '' END) + @L + @L;

                IF @OutputMethod <> 'Execute'
                  SET @FinalOutput = ISNULL(@FinalOutput, '') +
                                     ISNULL(@SelectProcedure, '') +
                                     ISNULL(@SelectByIdProcedure, '') +
                                     ISNULL(@InsertProcedure, '') +
                                     ISNULL(@UpdateProcedure, '') +
                                     ISNULL(@DeleteProcedure, '');
                ELSE
                  BEGIN
                    EXEC sp_executesql @SelectProcedure;
                    EXEC sp_executesql @SelectByIdProcedure;
                    EXEC sp_executesql @InsertProcedure;
                    EXEC sp_executesql @UpdateProcedure;
                    EXEC sp_executesql @DeleteProcedure;
                  END
              END
          END

        -- Begin processing for the new table.
        SET @CurrentTable = @TableName;
        SET @PKParameters = '';
        SET @PKWhereClause = '';
        SET @PKCondition = '';
        SET @PKCaseColumn = '';
        SET @PKCaseParam = '';
        SET @ColumnList = '';
        -- Reset for the new table

        -- Check if the table contains an 'ID' column.
        SELECT @IdColumnExists = CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END
          FROM INFORMATION_SCHEMA.COLUMNS
          WHERE TABLE_SCHEMA = @TableSchema
            AND TABLE_NAME = @TableName
            AND COLUMN_NAME = 'Id';

        -- Build the compound primary key parameter list.
        SELECT @PKParameters = STUFF((SELECT ',' + @L + @T + '@' + c.name + @S + UPPER(typ.name) +
                                             CASE
                                               WHEN typ.name IN ('varchar', 'nvarchar', 'char', 'nchar')
                                                 THEN '(' + CAST(c.max_length AS VARCHAR(10)) + ')'
                                               ELSE ''
                                               END
                                        FROM sys.indexes i
                                               INNER JOIN sys.index_columns ic
                                                          ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                                               INNER JOIN sys.columns c
                                                          ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                                               INNER JOIN sys.types typ ON c.user_type_id = typ.user_type_id
                                        WHERE
                                          i.object_id = OBJECT_ID(QUOTENAME(@TableSchema) + '.' + QUOTENAME(@TableName))
                                          AND i.is_primary_key = 1
                                        ORDER BY ic.key_ordinal
                                        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '');

        SELECT @PKCount = COUNT(*)
          FROM sys.index_columns ic
                 INNER JOIN sys.indexes i
                            ON ic.object_id = i.object_id AND ic.index_id = i.index_id
          WHERE i.is_primary_key = 1
            AND i.object_id = OBJECT_ID(QUOTENAME(@TableSchema) + '.' + QUOTENAME(@TableName));

        -- Build the compound primary key WHERE clause.
        SELECT @PKWhereClause = STUFF((SELECT @S + 'AND' + @S + c.name + @S + '= @' + c.name
                                         FROM sys.indexes i
                                                INNER JOIN sys.index_columns ic
                                                           ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                                                INNER JOIN sys.columns c
                                                           ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                                         WHERE i.object_id =
                                               OBJECT_ID(QUOTENAME(@TableSchema) + '.' + QUOTENAME(@TableName))
                                           AND i.is_primary_key = 1
                                         ORDER BY ic.key_ordinal
                                         FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 5, '');

        -- Build the PK condition (checks if any PK parameter is non-null).
        SELECT @PKCondition = STUFF((SELECT @S + 'OR' + @S + '@' + c.name + @S + 'IS NOT NULL'
                                       FROM sys.indexes i
                                              INNER JOIN sys.index_columns ic
                                                         ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                                              INNER JOIN sys.columns c
                                                         ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                                       WHERE
                                         i.object_id = OBJECT_ID(QUOTENAME(@TableSchema) + '.' + QUOTENAME(@TableName))
                                         AND i.is_primary_key = 1
                                       ORDER BY ic.key_ordinal
                                       FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 4, '');

        IF @PKCount = 1
          BEGIN
            -- Use the single PK column directly
            SET @PKCaseColumn = @PrimaryKeyColumn;
            SET @PKCaseParam = '@' + @PrimaryKeyColumn;
          END
        ELSE
          BEGIN
            -- Build the PK CASE expressions for key-set pagination.
            SELECT @PKCaseColumn = 'CASE' + @L +
                                   STUFF((SELECT @L + @TTT + 'WHEN @' + c.name + @S + 'IS NOT NULL THEN' + @S + c.name
                                            FROM sys.indexes i
                                                   INNER JOIN sys.index_columns ic
                                                              ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                                                   INNER JOIN sys.columns c
                                                              ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                                            WHERE i.object_id =
                                                  OBJECT_ID(QUOTENAME(@TableSchema) + '.' + QUOTENAME(@TableName))
                                              AND i.is_primary_key = 1
                                            ORDER BY ic.key_ordinal
                                            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 1, '')
              + @L + @TT + 'END';

            SELECT @PKCaseParam = 'COALESCE(' +
                                  STUFF((SELECT ', @' + c.name
                                           FROM sys.indexes i
                                                  INNER JOIN sys.index_columns ic
                                                             ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                                                  INNER JOIN sys.columns c
                                                             ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                                           WHERE i.object_id =
                                                 OBJECT_ID(QUOTENAME(@TableSchema) + '.' + QUOTENAME(@TableName))
                                             AND i.is_primary_key = 1
                                           ORDER BY ic.key_ordinal
                                           FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 2, '')
              + ')';
          END

        -- Retrieve details for the first primary key column (for OFFSET pagination ORDER BY).
        SELECT TOP 1 @PrimaryKeyColumn = c.name,
                     @PrimaryKeyDataType = UPPER(typ.name),
                     @CharLength = c.max_length
          FROM sys.indexes i
                 INNER JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                 INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                 INNER JOIN sys.types typ ON c.user_type_id = typ.user_type_id
          WHERE i.object_id = OBJECT_ID(QUOTENAME(@TableSchema) + '.' + QUOTENAME(@TableName))
            AND i.is_primary_key = 1
          ORDER BY ic.key_ordinal;

        -- Remove any defined prefix from the table name.
        IF @ExcludePrefixLength > 0 AND SUBSTRING(@TableName, 0, @ExcludePrefixLength) = @ExcludePrefix
          SET @RawTableName = RIGHT(@TableName, LEN(@TableName) - @ExcludePrefixLength);
        ELSE
          SET @RawTableName = @TableName;

        -- Check for the computed search column in the current table.
        SET @CanSearch = (SELECT CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END
                            FROM INFORMATION_SCHEMA.COLUMNS
                            WHERE TABLE_SCHEMA = @TableSchema
                              AND TABLE_NAME = @TableName
                              AND UPPER(COLUMN_NAME) = UPPER(@SearchColumn)
                              AND COLUMNPROPERTY(OBJECT_ID(QUOTENAME(TABLE_SCHEMA) + '.' + QUOTENAME(TABLE_NAME)),
                                                 COLUMN_NAME, 'IsComputed') = 1);

        IF @TargetTables = '' OR ',' + @TargetTables + ',' LIKE '%,' + @TableName + ',%'
          BEGIN
            -- Build the header for the SELECT procedure using the new PK parameters and adding @PageNumber.
            SET @SelectProcedure = 'CREATE PROCEDURE' + @S + @TargetSchema + '.' + @RawTableName + '_Select' +
                                   '(' + @L +
                                   @PKParameters + ',' + @L +
                                   @T + '@PageSize INT = 10,' + @L +
                                   @T + '@PageNumber INT = NULL';
            IF @CanSearch = 1
              SET @SelectProcedure = @SelectProcedure + ',' + @L +
                                     @T + '@SearchTerm NVARCHAR(MAX) = NULL';
            SET @SelectProcedure = @SelectProcedure + @L + ')' + @L +
                                   'AS' + @L +
                                   'BEGIN' + @L +
                                   @T + 'SET NOCOUNT ON' + @L;

            -- Initialize the SELECT column list.
            IF @UseSelectWildCard = 1
              SET @ColumnList = '*';
            ELSE
              BEGIN
                -- For the first encountered column, set @ColumnList to its name.
                SET @ColumnList = @L + @TTT + @ColumnName;
              END;

            -- Build the header for the SELECT BY ID procedure.
            SET @SelectByIdProcedure = 'CREATE PROCEDURE' + @S + @TargetSchema + '.' + @RawTableName + '_SelectById' +
                                       @L + @PKParameters + @L +
                                       'AS' + @L +
                                       'BEGIN' + @L +
                                       @T + 'SET NOCOUNT ON' + @L;
            IF @UseSelectWildCard = 1
              SET @SelectByIdProcedure = @SelectByIdProcedure + @T + 'SELECT * ';
            ELSE
              SET @SelectByIdProcedure = @SelectByIdProcedure + @T + 'SELECT' + @S + @L +
                                         @TT + @ColumnName;

            -- Build the initial header for the INSERT procedure (only for non-computed columns).
            IF @IsComputed = 0
              BEGIN
                SET @InsertProcedure = 'CREATE PROCEDURE' + @S + @TargetSchema + '.' + @RawTableName + '_Insert' + @L +
                                       @T + '@' + @ColumnName + @S + @DataType;
                IF @DataType IN ('VARCHAR', 'NVARCHAR', 'CHAR', 'NCHAR')
                  SET @InsertProcedure = @InsertProcedure + '(' + CAST(@CharLength AS VARCHAR(MAX)) + ')';
                SET @InsertProcedure = @InsertProcedure + @S + '= NULL';

                SET @UpdateProcedure = 'CREATE PROCEDURE' + @S + @TargetSchema + '.' + @RawTableName + '_Update' +
                                       @L + @PKParameters;
              END
            -- Begin building the UPDATE SET clause.
            SET @UpdateSetClause = @T + 'UPDATE' + @S + @TableName + @S + 'SET' + @S + @L;
            IF @IsComputed = 0 AND @IsPrimaryKey = 0
              SET @UpdateSetClause = @UpdateSetClause +
                                     @TT + @ColumnName + @S + '= COALESCE(@' + @ColumnName + ', ' + @ColumnName + '),' +
                                     @L;

            -- Build the INSERT INTO clause.
            SET @InsertIntoClause = @T + 'INSERT INTO' + @S + @TableSchema + '.' + @TableName + @S + '(' + @L;
            SET @InsertValuesClause = @T + 'VALUES (' + @L;
            IF @IsComputed = 0
              BEGIN
                SET @InsertIntoClause = @InsertIntoClause + @TT + @ColumnName + ',' + @L;
                SET @InsertValuesClause = @InsertValuesClause + @TT + '@' + @ColumnName + ',' + @L;
              END

            -- Build the DELETE procedure.
            SET @DeleteProcedure = 'CREATE PROCEDURE' + @S + @TargetSchema + '.' + @RawTableName + '_Delete' + @L +
                                   @PKParameters + @L +
                                   'AS' + @L +
                                   'BEGIN' + @L +
                                   @T + 'SET NOCOUNT ON' + @L +
                                   @T + 'DELETE FROM' + @S + @TargetSchema + '.' + @TableName + @L +
                                   @T + 'WHERE' + @S + @PKWhereClause + @L +
                                   @T + 'SET NOCOUNT OFF' + @L +
                                   'END' + @L +
                                   (CASE WHEN @OutputMethod <> 'Execute' THEN 'GO' ELSE '' END) + @L + @L;
          END
      END
    ELSE
      BEGIN
        IF @TargetTables = '' OR ',' + @TargetTables + ',' LIKE '%,' + @CurrentTable + ',%'
          BEGIN
            -- Append additional columns for SELECT procedures (if not using SELECT *).
            IF @UseSelectWildCard = 0
              BEGIN
                SET @SelectByIdProcedure = @SelectByIdProcedure + ',' + @L + @TT + @ColumnName;
                -- Also append to @ColumnList
                SET @ColumnList = @ColumnList + ', ' + @L + @TTT + @ColumnName;
              END

            -- Append parameters for the INSERT procedure.
            IF @IsComputed = 0
              BEGIN
                SET @InsertProcedure = @InsertProcedure + ',' + @L + @T + '@' + @ColumnName + @S + @DataType;
                IF @DataType IN ('VARCHAR', 'NVARCHAR', 'CHAR', 'NCHAR')
                  SET @InsertProcedure = @InsertProcedure + '(' + CAST(@CharLength AS VARCHAR(MAX)) + ')';
                SET @InsertProcedure = @InsertProcedure + @S + '= NULL';
              END

            -- Append parameters for the UPDATE procedure.
            IF @IsComputed = 0 AND @IsPrimaryKey = 0
              BEGIN
                SET @UpdateProcedure = @UpdateProcedure + ',' + @L + @T + '@' + @ColumnName + @S + @DataType;
                IF @DataType IN ('VARCHAR', 'NVARCHAR', 'CHAR', 'NCHAR')
                  SET @UpdateProcedure = @UpdateProcedure + '(' + CAST(@CharLength AS VARCHAR(MAX)) + ')';
                SET @UpdateProcedure = @UpdateProcedure + @S + '= NULL';
              END

            -- Append to the UPDATE SET clause.
            IF @IsComputed = 0 AND @IsPrimaryKey = 0
              SET @UpdateSetClause = @UpdateSetClause +
                                     @TT + @ColumnName + @S + '= COALESCE(@' + @ColumnName + ', ' + @ColumnName + '),' +
                                     @L;

            -- Append columns to the INSERT clauses.
            IF @IsComputed = 0
              BEGIN
                SET @InsertIntoClause = @InsertIntoClause + @TT + @ColumnName + ',' + @L;
                SET @InsertValuesClause = @InsertValuesClause + @TT + '@' + @ColumnName + ',' + @L;
              END
          END
      END

    FETCH NEXT FROM ColumnCursor INTO @TableSchema, @TableName, @ColumnName, @DataType, @CharLength, @IsComputed;
    SET @DataType = UPPER(@DataType);
    SET @IsPrimaryKey =
        CASE
          WHEN EXISTS (SELECT 1
                         FROM sys.indexes i
                                INNER JOIN sys.index_columns ic
                                           ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                                INNER JOIN sys.columns c2 ON ic.object_id = c2.object_id AND ic.column_id = c2.column_id
                         WHERE i.object_id = OBJECT_ID(QUOTENAME(@TableSchema) + '.' + QUOTENAME(@TableName))
                           AND i.is_primary_key = 1
                           AND c2.name = @ColumnName) THEN 1
          ELSE 0
          END;
  END

CLOSE ColumnCursor;
DEALLOCATE ColumnCursor;

-- If not executing directly, output the generated stored procedure scripts.
IF @OutputMethod <> 'Execute' SELECT @FinalOutput AS Output;
