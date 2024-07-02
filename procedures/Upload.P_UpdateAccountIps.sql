--liquibase formatted sql

--changeset  BrandonStahl:4313f452-1479-4d06-b412-7d6be78b35a4 stripComments:false runOnChange:true splitStatements:false

-- =============================================
-- Author:		Brandon Stahl
-- Create date: 2024-06-24
-- Description: Upload file to landing table SSIS job.
-- =============================================
CREATE OR ALTER PROCEDURE [upload].[P_UpdateAccountIps]
    (
        @TopParentAccountId INT,
        @FileId INT
    )
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
        DECLARE @FileTypeID INT = (SELECT TOP 1 FileTypeId FROM Upload.tblFile WHERE FileID = @FileID);

        DECLARE
            @Delimiter VARCHAR(8) =
            (
                SELECT u.Delimiter
                FROM upload.tblFileType AS u
                WHERE u.FileTypeID = @FileTypeID
            );

        DELETE i
        FROM Upload.tblAccountIpWhiteList AS i
        WHERE i.ProcessAccountId = @TopParentAccountId;

        DROP TABLE IF EXISTS #SplitValues;

        WITH SplitValues AS (
            SELECT
                t.Id,
                s.[Value] AS txt,
                ROW_NUMBER() OVER (PARTITION BY t.Id ORDER BY (SELECT 1)) AS RowNum
            FROM Upload.tblPlainTextFiles AS t
            CROSS APPLY STRING_SPLIT(t.txt, ',') AS s
            WHERE t.FileID = @FileId
        )
        SELECT
            sv.Id,
            MAX(CASE WHEN sv.RowNum = 1 THEN sv.txt END) AS AccountId,
            MAX(CASE WHEN sv.RowNum = 2 THEN sv.txt END) AS IPAddresses
        INTO #SplitValues
        FROM SplitValues AS sv
        GROUP BY sv.Id
        HAVING MAX(CASE WHEN sv.RowNum = 1 THEN sv.txt END) != 'AccountId';

        BEGIN TRANSACTION
        INSERT INTO Upload.tblAccountIpWhiteList
        (
            AccountId,
            IPAddresses,
            ProcessAccountId
        )
        SELECT
            s.AccountId,
            LEFT(s.IPAddresses, 500) AS IPAddresses,
            @TopParentAccountId AS ProcessAccountId
        FROM #SplitValues AS s;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        ROLLBACK;
        DELETE i
        FROM Upload.tblAccountIpWhiteList AS i
        WHERE i.ProcessAccountId = @TopParentAccountId
    END CATCH
END;
