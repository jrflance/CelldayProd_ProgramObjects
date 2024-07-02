--liquibase formatted sql

--changeset  BrandonStahl:4313f452-1479-4d06-b412-7d6be78b35a4 stripComments:false runOnChange:true splitStatements:false

-- =============================================
-- Author:Brandon Stahl
-- Create date: 2024-06-27
-- Description: Validates IPv4 Addresses
-- =============================================
CREATE OR ALTER FUNCTION [dbo].[IsValidIPv4] (@ipAddress VARCHAR(15))
RETURNS BIT
AS
BEGIN
    DECLARE @isValid BIT = 0;

    DECLARE @part1 INT, @part2 INT, @part3 INT, @part4 INT;
    IF (@ipAddress NOT LIKE '%.%.%.%')
        RETURN 0;

    SET
        @part4 =
        CASE
            WHEN TRY_CAST(TRIM(PARSENAME(@ipAddress, 4)) AS INT) IS NOT NULL THEN CAST(TRIM(PARSENAME(@ipAddress, 4)) AS INT)
            ELSE -1
        END;

    SET
        @part3 =
        CASE
            WHEN TRY_CAST(TRIM(PARSENAME(@ipAddress, 3)) AS INT) IS NOT NULL THEN CAST(TRIM(PARSENAME(@ipAddress, 3)) AS INT)
            ELSE -1
        END;

    SET
        @part2 =
        CASE
            WHEN TRY_CAST(TRIM(PARSENAME(@ipAddress, 2)) AS INT) IS NOT NULL THEN CAST(TRIM(PARSENAME(@ipAddress, 2)) AS INT)
            ELSE -1
        END;

    SET
        @part1 =
        CASE
            WHEN TRY_CAST(TRIM(PARSENAME(@ipAddress, 1)) AS INT) IS NOT NULL THEN CAST(TRIM(PARSENAME(@ipAddress, 1)) AS INT)
            ELSE -1
        END;

    IF
        @part1 BETWEEN 0 AND 255 AND @part2 BETWEEN 0 AND 255
        AND @part3 BETWEEN 0 AND 255 AND @part4 BETWEEN 0 AND 255
        BEGIN
            SET @isValid = 1;
        END;

    RETURN @isValid;
END;
