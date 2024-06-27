--liquibase formatted sql

--changeset  BrandonStahl:3bd8b369-4f98-403d-a6da-1d09a8dcbd48 stripComments:false runOnChange:true splitStatements:false

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
        WHERE i.ProcessAccountId = @TopParentAccountId

        BEGIN TRANSACTION
        INSERT INTO Upload.tblAccountIpWhiteList
        (
            AccountId,
            IPAddresses,
            ProcessAccountId
        )
        SELECT
            TRIM(A.Chr1) AS AccountId,
            TRIM(REPLACE(REPLACE(A.Chr9, CHAR(13), ''), CHAR(10), '')) AS IPAddresses,
            @TopParentAccountId AS ProcessAccountId
        FROM Upload.tblPlainTextFiles AS t
        CROSS APPLY dbo.SplitText(t.txt, @Delimiter, '"') AS A
        WHERE
            t.FileID = @FileID
            AND TRIM(A.Chr1) != 'AccountId';;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        ROLLBACK;
        DELETE i
        FROM Upload.tblAccountIpWhiteList AS i
        WHERE i.ProcessAccountId = @TopParentAccountId
    END CATCH
END;
