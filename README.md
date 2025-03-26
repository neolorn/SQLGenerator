# SQL Server CRUD Stored Procedure Generator

[![License](https://img.shields.io/github/license/neolorn/SQLGenerator.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-5.2.0-blue)](https://github.com/neolorn/SQLGenerator/releases)
[![SQL Server](https://img.shields.io/badge/SQL%20Server-2019%2B-success)](https://www.microsoft.com/en-us/sql-server)

Quickly generate stored procedures for your tables.

## Features

 **Full CRUD Procedures** for each table:
  - `Select`, `SelectById`, `Insert`, `Update`, `Delete`
- **Search Support** via named computed column
- **Key-set & Offset Pagination** (with fallback)
- **Composite Primary Key** support
- **Batch Table Processing**
- **Patch-style Updates** via `COALESCE`
- **Sequential GUID-friendly**

## Configuration

Set these variables in the script before execution:

| Variable              | Description                                              |
|-----------------------|----------------------------------------------------------|
| `@TargetTables`       | Comma-separated list of tables (blank = all tables)      |
| `@TargetSchema`       | Schema name (e.g., `dbo`)                                |
| `@TargetDatabase`     | Database name                                            |
| `@OutputMethod`       | `'Print'` or `'Execute'`                                 |
| `@SearchColumn`       | Computed column used for full-text search                |
| `@UseSelectWildCard`  | `1 = SELECT *`, `0 = explicit columns`                   |
| `@ExcludePrefix`      | Optional prefix to remove from procedure names           |

## Output

For each table, the generator creates:

- `Table_Select`
- `Table_SelectById`
- `Table_Insert`
- `Table_Update`
- `Table_Delete`

Each procedure is generated dynamically using metadata from `INFORMATION_SCHEMA` and `sys` views.

## Samples

### This table uses a single PK

```sql
CREATE PROCEDURE dbo.UserAccount_Select(
	@Id UNIQUEIDENTIFIER,
	@PageSize INT = 10,
	@PageNumber INT = NULL
)
AS
BEGIN
	SET NOCOUNT ON
	IF @PageNumber IS NOT NULL
	BEGIN
		SELECT 
			Id, 
			Cuid, 
			Username, 
			ReferrerId, 
			TypeId, 
			StatusId
		FROM dbo.UserAccount WITH(NOLOCK)
		ORDER BY Id
		OFFSET ((@PageNumber - 1) * @PageSize) ROWS
		FETCH NEXT @PageSize ROWS ONLY;
	END
	ELSE IF (@Id IS NOT NULL)
	BEGIN
		SELECT TOP (@PageSize) 
			Id, 
			Cuid, 
			Username, 
			ReferrerId, 
			TypeId, 
			StatusId
		FROM dbo.UserAccount WITH(NOLOCK)
		WHERE (Id) > (@Id) 
		ORDER BY (Id);
	END
	ELSE
	BEGIN
		SELECT 
			Id, 
			Cuid, 
			Username, 
			ReferrerId, 
			TypeId, 
			StatusId
		FROM dbo.UserAccount WITH(NOLOCK)
	END
	SET NOCOUNT OFF
END
GO

CREATE PROCEDURE dbo.UserAccount_SelectById
	@Id UNIQUEIDENTIFIER
AS
BEGIN
	SET NOCOUNT ON
	SELECT 
		Id,
		Cuid,
		Username,
		ReferrerId,
		TypeId,
		StatusId
	FROM dbo.UserAccount WITH(NOLOCK)
	WHERE Id = @Id
	SET NOCOUNT OFF
END
GO

CREATE PROCEDURE dbo.UserAccount_Insert
	@Id UNIQUEIDENTIFIER = NULL,
	@Cuid BIGINT = NULL,
	@Username NVARCHAR(50) = NULL,
	@ReferrerId UNIQUEIDENTIFIER = NULL,
	@TypeId UNIQUEIDENTIFIER = NULL,
	@StatusId UNIQUEIDENTIFIER = NULL
AS
BEGIN
	SET NOCOUNT ON
	INSERT INTO dbo.UserAccount (
		Id,
		Cuid,
		Username,
		ReferrerId,
		TypeId,
		StatusId
	)
	OUTPUT INSERTED.Id
	VALUES (
		@Id,
		@Cuid,
		@Username,
		@ReferrerId,
		@TypeId,
		@StatusId
	)
	SET NOCOUNT OFF
END
GO

CREATE PROCEDURE dbo.UserAccount_Update
	@Id UNIQUEIDENTIFIER,
	@Cuid BIGINT = NULL,
	@Username NVARCHAR(50) = NULL,
	@ReferrerId UNIQUEIDENTIFIER = NULL,
	@TypeId UNIQUEIDENTIFIER = NULL,
	@StatusId UNIQUEIDENTIFIER = NULL
AS
BEGIN
	SET NOCOUNT ON
	UPDATE UserAccount SET 
		Cuid = COALESCE(@Cuid, Cuid),
		Username = COALESCE(@Username, Username),
		ReferrerId = COALESCE(@ReferrerId, ReferrerId),
		TypeId = COALESCE(@TypeId, TypeId),
		StatusId = COALESCE(@StatusId, StatusId)
	WHERE Id = @Id
	SET NOCOUNT OFF
END
GO

CREATE PROCEDURE dbo.UserAccount_Delete
	@Id UNIQUEIDENTIFIER
AS
BEGIN
	SET NOCOUNT ON
	DELETE FROM dbo.UserAccount
	WHERE Id = @Id
	SET NOCOUNT OFF
END
GO
```

### This table uses a composite PK

```sql
CREATE PROCEDURE dbo.BusinessShippingAddress_Select(
	@BusinessId UNIQUEIDENTIFIER,
	@ShippingAddressId UNIQUEIDENTIFIER,
	@PageSize INT = 10,
	@PageNumber INT = NULL
)
AS
BEGIN
	SET NOCOUNT ON
	IF @PageNumber IS NOT NULL
	BEGIN
		SELECT 
			BusinessId, 
			ShippingAddressId, 
			IsPrimary
		FROM dbo.BusinessShippingAddress WITH(NOLOCK)
		ORDER BY BusinessId
		OFFSET ((@PageNumber - 1) * @PageSize) ROWS
		FETCH NEXT @PageSize ROWS ONLY;
	END
	ELSE IF (@BusinessId IS NOT NULL OR @ShippingAddressId IS NOT NULL)
	BEGIN
		SELECT TOP (@PageSize) 
			BusinessId, 
			ShippingAddressId, 
			IsPrimary
		FROM dbo.BusinessShippingAddress WITH(NOLOCK)
		WHERE (CASE
			WHEN @BusinessId IS NOT NULL THEN BusinessId
			WHEN @ShippingAddressId IS NOT NULL THEN ShippingAddressId
		END) > (COALESCE(@BusinessId, @ShippingAddressId)) 
		ORDER BY (CASE
			WHEN @BusinessId IS NOT NULL THEN BusinessId
			WHEN @ShippingAddressId IS NOT NULL THEN ShippingAddressId
		END);
	END
	ELSE
	BEGIN
		SELECT 
			BusinessId, 
			ShippingAddressId, 
			IsPrimary
		FROM dbo.BusinessShippingAddress WITH(NOLOCK)
	END
	SET NOCOUNT OFF
END
GO

CREATE PROCEDURE dbo.BusinessShippingAddress_SelectById
	@BusinessId UNIQUEIDENTIFIER,
	@ShippingAddressId UNIQUEIDENTIFIER
AS
BEGIN
	SET NOCOUNT ON
	SELECT 
		BusinessId,
		ShippingAddressId,
		IsPrimary
	FROM dbo.BusinessShippingAddress WITH(NOLOCK)
	WHERE BusinessId = @BusinessId AND ShippingAddressId = @ShippingAddressId
	SET NOCOUNT OFF
END
GO

CREATE PROCEDURE dbo.BusinessShippingAddress_Insert
	@BusinessId UNIQUEIDENTIFIER = NULL,
	@ShippingAddressId UNIQUEIDENTIFIER = NULL,
	@IsPrimary BIT = NULL
AS
BEGIN
	SET NOCOUNT ON
	INSERT INTO dbo.BusinessShippingAddress (
		BusinessId,
		ShippingAddressId,
		IsPrimary
	)
	VALUES (
		@BusinessId,
		@ShippingAddressId,
		@IsPrimary
	)
	SET NOCOUNT OFF
END
GO

CREATE PROCEDURE dbo.BusinessShippingAddress_Update
	@BusinessId UNIQUEIDENTIFIER,
	@ShippingAddressId UNIQUEIDENTIFIER,
	@IsPrimary BIT = NULL
AS
BEGIN
	SET NOCOUNT ON
	UPDATE BusinessShippingAddress SET 
		IsPrimary = COALESCE(@IsPrimary, IsPrimary)
	WHERE BusinessId = @BusinessId AND ShippingAddressId = @ShippingAddressId
	SET NOCOUNT OFF
END
GO

CREATE PROCEDURE dbo.BusinessShippingAddress_Delete
	@BusinessId UNIQUEIDENTIFIER,
	@ShippingAddressId UNIQUEIDENTIFIER
AS
BEGIN
	SET NOCOUNT ON
	DELETE FROM dbo.BusinessShippingAddress
	WHERE BusinessId = @BusinessId AND ShippingAddressId = @ShippingAddressId
	SET NOCOUNT OFF
END
GO
```
